/*
 Hypnos - a Matroska file's own sound, decoded on the device

 For a 3D Blu-ray remuxed to Matroska (its picture decoded here by
 `MVCPictureSource`) when the Atmos plugin has no object audio for it: no
 plugin, a plain DTS-HD or AC-3 track, or a DTS:X track in a build that may
 not ask for it. The track's channels play as sources pinned at the speaker
 positions plus an LFE bed, the same stage, clock and head tracking as object
 audio (`DiscAudioSource` does the same for a disc).

 MatroskaRemux's `MatroskaAudioReader` reads each 4 s segment from the file
 itself, apart from the picture's reads, with the remux's decoders: the
 system's AAC, AC-3 and E-AC-3 in every build, FFmpeg's DTS and TrueHD in the
 sideload edition (`HYPNOS_FFMPEG`). A track nothing here decodes isn't
 offered; a file with no such track has no sound in the film player.
 */

import AVFoundation
import DebugTrace
import Foundation
import MatroskaRemux
import RAVEFilm

final class MatroskaFilmAudioSource: FilmAudioSource, @unchecked Sendable {
    let itemID: String
    let audioStream: Int?
    private let shared: Shared

    private final class Shared: Sendable {
        let reader: MatroskaAudioReader
        let durationSeconds: Double
        init(reader: MatroskaAudioReader, durationSeconds: Double) {
            self.reader = reader
            self.durationSeconds = durationSeconds
        }
    }

    static let segmentSeconds = 4

    /// Opens the file's audio. Nil when no track can be decoded here (or
    /// the file can't be read), and the film plays without sound.
    static func open(itemID: String, url: URL, durationSeconds: Double) async -> MatroskaFilmAudioSource? {
        do {
            let source: any ByteSource = url.isFileURL ? try FileByteSource(url: url) : RemoteByteSource(url: url)
            let reader = try await MatroskaAudioReader.open(source: source, decoding: MatroskaRemuxService.audioDecoding)
            guard !reader.tracks.isEmpty else {
                AppLogger.filmPlayer.info("No audio track in this Matroska file can be decoded on this device")
                return nil
            }
            let duration = reader.durationSeconds ?? durationSeconds
            return MatroskaFilmAudioSource(itemID: itemID, audioStream: nil,
                                           shared: Shared(reader: reader, durationSeconds: duration))
        } catch {
            AppLogger.filmPlayer.error("Matroska audio unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private init(itemID: String, audioStream: Int?, shared: Shared) {
        self.itemID = itemID
        self.audioStream = audioStream
        self.shared = shared
    }

    func with(audioStream: Int?) -> any FilmAudioSource {
        MatroskaFilmAudioSource(itemID: itemID, audioStream: audioStream, shared: shared)
    }

    private var track: MatroskaAudioReader.Track? {
        let tracks = shared.reader.tracks
        return tracks.first { Int($0.number) == audioStream } ?? tracks.first(where: \.isDefault) ?? tracks.first
    }

    func audioTracks(languages: [String]) async throws -> [FilmAudioTrack] {
        let tracks = shared.reader.tracks
        let wanted = languages.map(Self.normalized)
        let chosen = wanted.lazy.compactMap { language in tracks.first { Self.normalized($0.language) == language } }.first
            ?? tracks.first(where: \.isDefault) ?? tracks.first
        return tracks.map { track in
            let language = track.language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
            let layout = switch track.channels {
            case 8: "7.1"
            case 6: "5.1"
            case 2: "Stereo"
            case 1: "Mono"
            default: "\(track.channels) ch"
            }
            let codec = Self.codecName(track.codecID)
            return FilmAudioTrack(index: Int(track.number), codec: codec, language: track.language,
                                  title: [language, track.name, "\(codec) \(layout)"].compactMap { $0 }.joined(separator: " · "),
                                  isDefault: track.number == chosen?.number)
        }
    }

    func audioScene(startSeconds: Double) async throws -> AtmosScene? {
        guard let track else { return nil }
        // The decoder names the channels: read a moment where the track has
        // sound (the start may be before it begins).
        var probe = try await shared.reader.read(track: track.number, from: max(startSeconds, 0), frames: 2400)
        if probe.speakers.allSatisfy({ $0 == .other }) {
            probe = try await shared.reader.read(track: track.number, from: min(10, shared.durationSeconds / 2), frames: 2400)
        }
        let speakers = probe.speakers
        let rate = probe.sampleRate
        let frames = Int(shared.durationSeconds * Double(rate))
        let segmentFrames = Self.segmentSeconds * rate
        return AtmosScene(
            sampleRate: rate,
            elements: speakers.enumerated().map { index, speaker in
                speaker == .lowFrequency
                    ? AtmosScene.Element(id: index, channel: index, kind: "bed", bedChannel: "LFE")
                    : AtmosScene.Element(id: index, channel: index, kind: "object", bedChannel: nil)
            },
            frameCount: frames,
            segmentFrames: segmentFrames,
            segmentCount: (frames + segmentFrames - 1) / segmentFrames,
            groups: [Array(speakers.indices)],
            startSeconds: 0)
    }

    func audioSegment(_ segment: Int, of scene: AtmosScene) async throws -> FilmAudioSegment {
        guard let track else { throw CocoaError(.fileReadNoSuchFile) }
        let rate = scene.sampleRate
        let frames = max(0, min(scene.segmentFrames, scene.frameCount - segment * scene.segmentFrames))
        let window = try await shared.reader.read(track: track.number,
                                                  from: Double(segment * scene.segmentFrames) / Double(rate), frames: frames)
        let channels = scene.elements.count
        // More than two channels need a layout, or the format doesn't exist.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)),
              case let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                              interleaved: false, channelLayout: layout),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let destination = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0 ..< channels {
            // A window read after a decoder changed its mind about the
            // layout (a damaged frame) keeps the scene's channel count.
            if channel < window.planes.count {
                window.planes[channel].withUnsafeBufferPointer { destination[channel].update(from: $0.baseAddress!, count: min(frames, $0.count)) }
            } else {
                destination[channel].update(repeating: 0, count: frames)
            }
        }
        let speakers = window.speakers
        let t = segment * scene.segmentFrames
        let events = scene.elements.map { element in
            let speaker = element.channel < speakers.count ? speakers[element.channel] : .other
            return AtmosScene.Event(id: element.id, t: t, ramp: 0, gain: 0,
                                    pos: Self.position(speaker, among: speakers) ?? [0, 1, 0])
        }
        return FilmAudioSegment(events: events, buffers: [buffer])
    }

    /// Where a channel's speaker stands in a room (DAMF: x right, y front,
    /// z up). Side surrounds stand a little behind the listener in 5.1 and
    /// beside them when 7.1 has a back pair too.
    static func position(_ speaker: RemuxSpeaker, among all: [RemuxSpeaker]) -> [Double]? {
        let hasBack = all.contains(.backLeft) || all.contains(.backRight)
        let hasSide = all.contains(.sideLeft) || all.contains(.sideRight)
        switch speaker {
        case .frontLeft: return [-1, 1, 0]
        case .frontRight: return [1, 1, 0]
        case .frontCenter, .other: return [0, 1, 0]
        case .lowFrequency: return nil
        case .sideLeft: return [-1, hasBack ? 0 : -0.35, 0]
        case .sideRight: return [1, hasBack ? 0 : -0.35, 0]
        case .backLeft: return [hasSide ? -0.7 : -1, hasSide ? -1 : -0.35, 0]
        case .backRight: return [hasSide ? 0.7 : 1, hasSide ? -1 : -0.35, 0]
        case .backCenter: return [0, -1, 0]
        }
    }

    static func codecName(_ codecID: String) -> String {
        switch codecID {
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10": "AC-3"
        case "A_EAC3": "E-AC-3"
        case let id where id.hasPrefix("A_AAC"): "AAC"
        case let id where id.hasPrefix("A_DTS"): "DTS"
        case "A_TRUEHD": "TrueHD"
        case "A_MLP": "MLP"
        default: codecID
        }
    }

    private static func normalized(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale.Language(identifier: code).languageCode?.identifier(.alpha3) ?? code.lowercased()
    }
}
