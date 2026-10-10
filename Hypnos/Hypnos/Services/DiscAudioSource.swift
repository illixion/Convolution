/*
 Hypnos - a Blu-ray disc's own sound, decoded on the device

 For a disc the Atmos plugin can't serve (no plugin, a disc without TrueHD,
 or a disc on the device itself), the film player plays the disc's AC-3:
 a plain AC-3 or E-AC-3 track, or the AC-3 core every Blu-ray TrueHD track
 carries. Vergence reads and decodes it (`PlaylistAudioReader`, through Apple's
 decoder) into 5.1, which plays as five sources pinned at the speaker
 positions plus an LFE bed: the same stage, clock and head tracking as
 object audio.

 Segments are read on demand from their own reader of the disc, apart from
 the picture's, so the sound can be ready ahead of where the picture has
 got to. Over HTTP that is a second read of the clip around the playhead
 (the audio is interleaved with the video); on the device it is a local
 file.
 */

import AVFoundation
import Foundation
import VergenceApple
import RAVEFilm

final class DiscAudioSource: FilmAudioSource, @unchecked Sendable {
    let itemID: String
    let audioStream: Int?
    private let shared: Shared

    /// The disc and its readers, shared by every track's copy of the source.
    private final class Shared: @unchecked Sendable {
        let disc: BlurayDisc
        let playlist: BlurayPlaylist
        let originSeconds: Double
        let tracks: [BlurayPlaylist.Stream]
        let lock = NSLock()
        var readers: [UInt16: PlaylistAudioReader] = [:]

        init(disc: BlurayDisc, playlist: BlurayPlaylist, originSeconds: Double) {
            self.disc = disc
            self.playlist = playlist
            self.originSeconds = originSeconds
            // AC-3, TrueHD (its AC-3 core) and E-AC-3: what Apple's decoders cover.
            tracks = (playlist.items.first?.audioStreams ?? []).filter { [0x81, 0x83, 0x84].contains($0.codingType) }
        }
    }

    static let segmentSeconds = 4
    static let sampleRate = PlaylistAudioReader.sampleRate

    /// L R C LFE Ls Rs at the speaker positions of a 5.1 room (DAMF: x right,
    /// y front, z up), the surrounds a little behind the listener.
    private static let speakers: [(kind: String, bed: String?, position: [Double]?)] = [
        ("object", nil, [-1, 1, 0]),
        ("object", nil, [1, 1, 0]),
        ("object", nil, [0, 1, 0]),
        ("bed", "LFE", nil),
        ("object", nil, [-1, -0.35, 0]),
        ("object", nil, [1, -0.35, 0]),
    ]

    init(itemID: String, disc: BlurayDisc, playlist: BlurayPlaylist, originSeconds: Double) {
        self.itemID = itemID
        audioStream = nil
        shared = Shared(disc: disc, playlist: playlist, originSeconds: originSeconds)
    }

    private init(itemID: String, audioStream: Int?, shared: Shared) {
        self.itemID = itemID
        self.audioStream = audioStream
        self.shared = shared
    }

    func with(audioStream: Int?) -> any FilmAudioSource {
        DiscAudioSource(itemID: itemID, audioStream: audioStream, shared: shared)
    }

    func audioTracks(languages: [String]) async throws -> [FilmAudioTrack] {
        let tracks = shared.tracks
        let wanted = languages.map(Self.normalized)
        let chosen = wanted.lazy.compactMap { language in tracks.first { Self.normalized($0.language) == language } }.first
            ?? tracks.first
        return tracks.map { track in
            let name = track.language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
            let codec = switch track.codingType {
            case 0x83: "AC-3 (from TrueHD)"
            case 0x84: "E-AC-3"
            default: "AC-3"
            }
            return FilmAudioTrack(index: Int(track.pid), codec: track.codecName, language: track.language,
                                  title: [name, codec].compactMap { $0 }.joined(separator: " · "),
                                  isDefault: track.pid == chosen?.pid)
        }
    }

    func audioScene(startSeconds: Double) async throws -> AtmosScene? {
        guard track != nil else { return nil }
        let frames = Int(shared.playlist.duration * Double(Self.sampleRate))
        let segmentFrames = Self.segmentSeconds * Self.sampleRate
        return AtmosScene(
            sampleRate: Self.sampleRate,
            elements: Self.speakers.enumerated().map { index, speaker in
                AtmosScene.Element(id: index, channel: index, kind: speaker.kind, bedChannel: speaker.bed)
            },
            frameCount: frames,
            segmentFrames: segmentFrames,
            segmentCount: (frames + segmentFrames - 1) / segmentFrames,
            groups: [Array(Self.speakers.indices)],
            startSeconds: shared.originSeconds)
    }

    func audioSegment(_ segment: Int, of scene: AtmosScene) async throws -> FilmAudioSegment {
        guard let track else { throw CocoaError(.fileReadNoSuchFile) }
        let shared = self.shared
        let planes = try await Task.detached(priority: .userInitiated) {
            try shared.lock.withLock {
                let reader = shared.readers[track.pid] ?? PlaylistAudioReader(disc: shared.disc, playlist: shared.playlist, pid: track.pid)
                shared.readers[track.pid] = reader
                let start = Int64(segment) * Int64(scene.segmentFrames) * 90_000 / Int64(Self.sampleRate)
                let frames = min(scene.segmentFrames, scene.frameCount - segment * scene.segmentFrames)
                return try reader.read(fromPTS: start, frames: max(frames, 0))
            }
        }.value
        // More than two channels need a layout, or the format doesn't exist.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(planes.count)),
              case let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate),
                                              interleaved: false, channelLayout: layout),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(planes.first?.count ?? 0)),
              let destination = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        buffer.frameLength = buffer.frameCapacity
        for (channel, plane) in planes.enumerated() {
            plane.withUnsafeBufferPointer { destination[channel].update(from: $0.baseAddress!, count: plane.count) }
        }
        let t = segment * scene.segmentFrames
        let events = Self.speakers.enumerated().map { index, speaker in
            AtmosScene.Event(id: index, t: t, ramp: 0, gain: 0, pos: speaker.position ?? [0, 1, 0])
        }
        return FilmAudioSegment(events: events, buffers: [buffer])
    }

    private var track: BlurayPlaylist.Stream? {
        shared.tracks.first { Int($0.pid) == audioStream } ?? shared.tracks.first
    }

    private static func normalized(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale.Language(identifier: code).languageCode?.identifier(.alpha3) ?? code.lowercased()
    }
}
