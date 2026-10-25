/*
 Hypnos - subtitles inside an MKV or WebM the player plays remuxed

 The remux (`MatroskaRemux`) hands over each subtitle track's blocks, timed
 on its own timeline, which is the player's clock. They are read near the
 playhead and never with the whole file: through the file's Cues, a few
 kilobytes a line, or, in a file without them, from the segments the player
 fetches anyway. So these are `live` tracks: while one shows, the stretch
 from `lookbehind` before the playhead to `lookahead` after it is read once
 a second, and the cues drawn grow with it; after a seek the new stretch is
 read first.

 Text tracks (SubRip, ASS, WebVTT) are put into SubRip text and parsed like
 every other subtitle; an ASS line keeps its italics, bold and top-of-screen
 placement, nothing else of its styling. PGS goes to the disc decoder
 (`PGSSupFile`), each display set given back the .sup headers Matroska
 leaves off. VobSub and the rest are listed but can't be picked.
 */

import DebugTrace
import Foundation
import MatroskaRemux
import RAVEUI

extension SubtitleSource {
    /// `session`'s subtitle tracks after `base`'s (sidecar files, Stash
    /// captions), which keep working as before.
    static func matroska(_ session: RemuxSession, identity: String, adding base: SubtitleSource?) -> SubtitleSource {
        let tracks = session.subtitleTracks
        let listed = tracks.map(MatroskaSubtitles.libraryTrack)
        let trackList: @Sendable () async throws -> [LibrarySubtitleTrack] = {
            let other = (try? await base?.tracks()) ?? []
            return other + listed
        }
        let data: @Sendable (LibrarySubtitleTrack) async throws -> Data = { track in
            guard let base, !MatroskaSubtitles.owns(track) else { throw URLError(.unsupportedURL) }
            return try await base.data(track)
        }
        var progressive: (@Sendable (LibrarySubtitleTrack, Double) -> AsyncThrowingStream<SubtitleStreamChunk, Error>?)?
        if let baseProgressive = base?.progressive {
            progressive = { track, start in MatroskaSubtitles.owns(track) ? nil : baseProgressive(track, start) }
        }
        let baseLive = base?.live
        let live: @Sendable (LibrarySubtitleTrack, @escaping @MainActor @Sendable () -> Double)
            -> AsyncStream<RAVESubtitleTrack>? = { track, playhead in
                guard MatroskaSubtitles.owns(track) else { return baseLive?(track, playhead) }
                guard let info = tracks.first(where: { MatroskaSubtitles.id(of: $0) == track.id }) else { return nil }
                return MatroskaSubtitles.cues(session, track: info, playhead: playhead)
            }
        return SubtitleSource(id: "mkv:\(identity)" + (base.map { "+" + $0.id } ?? ""), tracks: trackList, data: data,
                              progressive: progressive, live: live)
    }
}

enum MatroskaSubtitles {
    /// The stretch read around the playhead, in seconds.
    static let lookbehind = 15.0
    static let lookahead = 120.0
    static let interval = Duration.seconds(1)
    /// A line whose block gives no duration shows until the next, at most this.
    static let longestUntimed = 5.0

    private static let sourceId = "mkv"
    /// Clear of sidecar ids (0…) and an MP4's embedded ones (1000…).
    private static let idBase = 3000

    static func owns(_ track: LibrarySubtitleTrack) -> Bool { track.sourceId == sourceId }
    static func id(of track: MatroskaSubtitleTrack) -> Int { idBase + Int(track.number) }

    static func libraryTrack(_ track: MatroskaSubtitleTrack) -> LibrarySubtitleTrack {
        let label: String = switch track.format {
        case .subRip: "SRT"
        case .ass: "ASS"
        case .webVTT: "WebVTT"
        case .pgs: "PGS"
        case .unsupported: track.codecID.split(separator: "/").last.map(String.init) ?? track.codecID
        }
        let isText = [.subRip, .ass, .webVTT].contains(track.format)
        return LibrarySubtitleTrack(
            id: id(of: track), sourceId: sourceId, language: track.language,
            // The format names a track with neither name nor language ("SRT"
            // rather than "Track 3003").
            name: track.name ?? (track.language == nil ? label : nil),
            isDefault: track.isDefault, isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
            isText: isText && track.unsupportedReason == nil,
            isBitmap: track.format == .pgs && track.unsupportedReason == nil, isEmbedded: true)
    }

    /// The track's cues, growing as the stretch around the playhead is read.
    static func cues(_ session: RemuxSession, track: MatroskaSubtitleTrack,
                     playhead: @escaping @MainActor @Sendable () -> Double) -> AsyncStream<RAVESubtitleTrack> {
        AsyncStream { continuation in
            let task = Task {
                var shown = -1
                var failing = false
                while !Task.isCancelled {
                    let time = await playhead()
                    do {
                        let (blocks, revision) = try await session.subtitleBlocks(
                            track: track.number, from: time - lookbehind, through: time + lookahead)
                        if revision != shown {
                            shown = revision
                            continuation.yield(subtitleTrack(blocks, format: track.format, id: id(of: track)))
                        }
                        failing = false
                    } catch {
                        // Read again on the next pass; said once.
                        if !failing {
                            AppLogger.subtitles.error("Embedded subtitle track \(track.number, privacy: .public): read failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                        }
                        failing = true
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func subtitleTrack(_ blocks: [SubtitleBlock], format: MatroskaSubtitleTrack.Format, id: Int) -> RAVESubtitleTrack {
        switch format {
        case .subRip, .ass, .webVTT:
            return (try? RAVESubtitleTrack(text: subRip(blocks, format: format))) ?? RAVESubtitleTrack(cues: [])
        case .pgs:
            guard !blocks.isEmpty else { return RAVESubtitleTrack(cues: []) }
            return (try? PGSSupFile.track(from: sup(blocks), trackID: id)) ?? RAVESubtitleTrack(cues: [])
        case .unsupported:
            return RAVESubtitleTrack(cues: [])
        }
    }

    // MARK: Text

    /// The text blocks as one SubRip document.
    static func subRip(_ blocks: [SubtitleBlock], format: MatroskaSubtitleTrack.Format) -> String {
        var document = ""
        var number = 0
        for (index, block) in blocks.enumerated() {
            let lines = text(of: block, format: format)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } // a blank line would end the cue
            guard !lines.isEmpty else { continue }
            let start = max(0, block.start)
            let next = blocks[(index + 1)...].first { $0.start > block.start }?.start
            let end = block.duration.map { start + $0 } ?? min(next ?? .infinity, start + longestUntimed)
            guard end > start else { continue }
            number += 1
            document += "\(number)\n\(timestamp(start)) --> \(timestamp(end))\n\(lines.joined(separator: "\n"))\n\n"
        }
        return document
    }

    static func text(of block: SubtitleBlock, format: MatroskaSubtitleTrack.Format) -> String {
        let text = String(decoding: block.data, as: UTF8.self)
        guard format == .ass else { return text }
        // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
        let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        return assText(fields.count == 9 ? String(fields[8]) : text)
    }

    /// An ASS line's text with its override blocks read: \i and \b become
    /// SubRip tags, \an stays (the parser places top-row alignments at the
    /// top), the rest goes; \N and \n break the line, \h is a space.
    static func assText(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { rest = rest[open...]; break }
            for tag in rest[rest.index(after: open) ..< close].split(separator: "\\") {
                if tag.hasPrefix("an"), tag.count == 3 { result += "{\\\(tag)}"; continue }
                for (prefix, html) in [("i", "i"), ("b", "b")] where tag.hasPrefix(prefix) {
                    let value = tag.dropFirst(prefix.count)
                    guard !value.isEmpty, value.allSatisfy(\.isNumber) else { continue }
                    result += value == "0" ? "</\(html)>" : "<\(html)>"
                }
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    // MARK: PGS

    /// PGS blocks as a .sup file: each segment of a display set prefixed
    /// with "PG", its presentation time (90 kHz) and a decode time.
    static func sup(_ blocks: [SubtitleBlock]) -> Data {
        var data = Data()
        for block in blocks {
            let pts = UInt32(clamping: Int64((max(0, block.start) * 90_000).rounded()))
            let header: [UInt8] = [0x50, 0x47] + withUnsafeBytes(of: pts.bigEndian, Array.init) + [0, 0, 0, 0]
            var i = 0
            let bytes = block.data
            while i + 3 <= bytes.count {
                let length = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
                guard i + 3 + length <= bytes.count else { break }
                data.append(contentsOf: header)
                data.append(contentsOf: bytes[i ..< i + 3 + length])
                i += 3 + length
            }
        }
        return data
    }
}
