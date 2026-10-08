/*
 Hypnos - subtitles for a video file on the device

 Two kinds, both read without a server:
 - Sidecar files beside the video whose name starts with the video's own
   (`Film.mp4` → `Film.srt`, `Film.en.srt`, `Film.fr.forced.vtt`). What sits
   between the two names says the language and flags, the way Jellyfin and
   Plex read the same names.
 - Text tracks inside an MP4/MOV (`tx3g`, what ffmpeg's `mov_text` writes).
   They are read out with AVAssetReader and handed to the parser as SubRip.
   Other embedded formats are listed but disabled, like image subtitles from
   a server.
 */

import AVFoundation
import CoreMedia
import Foundation

extension SubtitleSource {
    /// A local video's sidecar files and embedded text tracks.
    static func localFile(_ url: URL, identity: String) -> SubtitleSource {
        SubtitleSource(
            id: "local:\(identity)",
            tracks: { try await LocalSubtitles.tracks(for: url) },
            data: { try await LocalSubtitles.data(for: $0, video: url) }
        )
    }
}

enum LocalSubtitles {
    static let sidecarExtensions: Set<String> = ["srt", "vtt"]
    /// Embedded track ids start here, so they never collide with sidecars'.
    private static let embeddedIdBase = 1000

    static func tracks(for video: URL) async throws -> [LibrarySubtitleTrack] {
        let sidecars = sidecarFiles(for: video).enumerated().map { index, file in
            sidecarTrack(file, id: index, video: video)
        }
        let embedded = (try? await embeddedTracks(of: video)) ?? []
        return sidecars + embedded
    }

    static func data(for track: LibrarySubtitleTrack, video: URL) async throws -> Data {
        if track.id >= embeddedIdBase {
            return try await embeddedSubRip(of: video, trackID: CMPersistentTrackID(track.id - embeddedIdBase))
        }
        let files = sidecarFiles(for: video)
        guard files.indices.contains(track.id) else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: files[track.id])
    }

    // MARK: Sidecars

    /// Sorted so a track's index is stable between listing and fetching.
    static func sidecarFiles(for video: URL) -> [URL] {
        let base = video.deletingPathExtension().lastPathComponent
        let folder = video.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { sidecarExtensions.contains($0.pathExtension.lowercased()) }
            .filter {
                let name = $0.deletingPathExtension().lastPathComponent
                return name == base || name.hasPrefix(base + ".")
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `Film.en.sdh.srt`: the dot-separated words between the video's name
    /// and the extension. A word that names a language is the language,
    /// `forced` / `sdh` / `cc` / `hi` / `default` are flags, the rest the
    /// track's name.
    static func sidecarTrack(_ file: URL, id: Int, video: URL) -> LibrarySubtitleTrack {
        let base = video.deletingPathExtension().lastPathComponent
        let name = file.deletingPathExtension().lastPathComponent
        let words = name.dropFirst(base.count).split(separator: ".").map(String.init)
        var track = LibrarySubtitleTrack(id: id, sourceId: "")
        var nameWords: [String] = []
        for word in words {
            switch word.lowercased() {
            case "forced", "foreign": track.isForced = true
            case "sdh", "cc", "hi": track.isHearingImpaired = true
            case "default": track.isDefault = true
            default:
                if track.language == nil, isLanguageCode(word) {
                    track.language = word.lowercased()
                } else {
                    nameWords.append(word)
                }
            }
        }
        // A language says enough on its own ("English", not "English – SRT").
        track.name = nameWords.isEmpty
            ? (track.language == nil ? file.pathExtension.uppercased() : nil)
            : nameWords.joined(separator: " ")
        return track
    }

    /// Two- or three-letter codes the system can name ("fr", "eng", "pt-BR").
    static func isLanguageCode(_ word: String) -> Bool {
        let code = word.split(separator: "-").first.map(String.init) ?? word
        guard (2 ... 3).contains(code.count), code.allSatisfy(\.isLetter) else { return false }
        return Locale(identifier: "en").localizedString(forLanguageCode: code.lowercased()) != nil
    }

    // MARK: Embedded

    static func embeddedTracks(of video: URL) async throws -> [LibrarySubtitleTrack] {
        let asset = AVURLAsset(url: video)
        var result: [LibrarySubtitleTrack] = []
        for mediaType in [AVMediaType.text, .subtitle] {
            for track in try await asset.loadTracks(withMediaType: mediaType) {
                let (formats, code, tag, enabled) = try await track.load(
                    .formatDescriptions, .languageCode, .extendedLanguageTag, .isEnabled
                )
                let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
                let language = code.flatMap { $0 == "und" ? nil : $0 } ?? tag
                result.append(LibrarySubtitleTrack(
                    id: embeddedIdBase + Int(track.trackID), sourceId: "", language: language,
                    name: language == nil ? "Embedded" : nil, isDefault: enabled,
                    isText: subtype == kCMTextFormatType_3GText
                ))
            }
        }
        return result
    }

    /// A `tx3g` track as SubRip: each sample is one cue's text, a 16-bit
    /// big-endian byte count then the text (style boxes after it are
    /// ignored); an empty sample is the gap between cues.
    static func embeddedSubRip(of video: URL, trackID: CMPersistentTrackID) async throws -> Data {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTrack(withTrackID: trackID) else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var srt = ""
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let text = cueText(of: sample), !text.isEmpty else { continue }
            let start = sample.presentationTimeStamp.seconds
            let duration = sample.duration.seconds
            guard start.isFinite, duration.isFinite, duration > 0 else { continue }
            index += 1
            srt += "\(index)\n\(timestamp(start)) --> \(timestamp(start + duration))\n\(text)\n\n"
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return Data(srt.utf8)
    }

    private static func cueText(of sample: CMSampleBuffer) -> String? {
        guard let block = sample.dataBuffer, let bytes = try? block.dataBytes(), bytes.count >= 2 else { return nil }
        let length = Int(bytes[bytes.startIndex]) << 8 | Int(bytes[bytes.startIndex + 1])
        guard length > 0, bytes.count >= 2 + length else { return nil }
        let body = bytes.subdata(in: bytes.startIndex + 2 ..< bytes.startIndex + 2 + length)
        // 3GPP timed text allows UTF-16 marked by a byte-order mark.
        if body.starts(with: [0xFE, 0xFF]) || body.starts(with: [0xFF, 0xFE]) {
            return String(data: body, encoding: .utf16)
        }
        return String(data: body, encoding: .utf8)
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
