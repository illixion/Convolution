/*
 Hypnos - a YouTube video's 5.1 track, found and served on the device
 (sideload builds only: `HYPNOS_YOUTUBE`)

 YouTube's own HLS master (the visionOS client's) carries stereo only. The
 5.1 tracks, EC-3 (itag 328) and AC-3 (380), are listed signed out to the
 TV client (`YouTubeInnertube.tvAudioFormats`), as fragmented MP4 files
 with a `sidx` index. Turning one into something AVPlayer plays beside
 YouTube's video takes four steps, all measured on 2026-10-25:

 1. **Solve the URL's challenges** with the player script
    (`YouTubePlayerScript`): without the `n` answer googlevideo says 403.
 2. **Wait out the pre-roll.** A signed-out TV answer comes with an ad, and
    googlevideo says 403 to the stream until its skip time (5-20 s) has
    passed since the answer. So the window starts in stereo and switches to
    surround when it's ready (`VideoWindowModel+YouTube`).
 3. **Read the index** (the `indexRange` bytes) for the file's fragments.
 4. **Write an audio-only HLS playlist** addressing the file by byte ranges,
    ~6 s a segment, and serve it on loopback. Its URIs are the googlevideo
    URL itself: AVPlayer fetches the ranges straight from YouTube (206 to a
    plain `Range` header with its own user agent), from this device, which
    is the address the URL is bound to.

 `YouTubeManifestComposer` then adds that playlist to YouTube's master as
 the audio rendition. The track is the video's own language when it has
 dubs, never a loudness-compressed (DRC) copy, EC-3 before AC-3.

 Before this, a web-yt-dlp backend did the same (its cookies were thought
 to be the gate); it is no longer asked.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation

/// A video's surround track as a playlist the master can name.
struct YouTubeSurroundAudio: Sendable, Equatable {
    var channels: Int
    /// RFC 6381 codec string for the HLS `CODECS` attribute (`ec-3`, `ac-3`).
    var codecs: String
    var bandwidth: Int
    var language: String?
    var playlistURL: URL
}

@MainActor
enum YouTubeSurround {
    private static let surroundKey = "youtube.surround"
    private static let legacySurroundKey = "youtube.backend.surround"

    /// Play 5.1 where the video has it. On unless turned off; an earlier
    /// choice made for the backend's surround carries over.
    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            return defaults.object(forKey: surroundKey) as? Bool
                ?? defaults.object(forKey: legacySurroundKey) as? Bool
                ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: surroundKey) }
    }

    /// The video's surround track served as an HLS playlist, once its URLs
    /// work; nil when it has none or any step fails (stereo stays).
    static func audio(for id: YouTubeVideoID) async -> YouTubeSurroundAudio? {
        let start = Date()
        do {
            let script = YouTubePlayerScript.shared
            let player = try await script.player()
            let tv = try await YouTubeInnertube.shared.tvAudioFormats(id, signatureTimestamp: player.signatureTimestamp)
            guard tv.status == "OK" else {
                AppLogger.youtube.info("No surround: the TV client answered \(tv.status, privacy: .public)")
                return nil
            }
            guard let format = pick(tv.formats) else {
                AppLogger.youtube.info("No surround: the video has no 5.1 track")
                return nil
            }
            guard let indexRange = format.indexRange, let initRange = format.initRange,
                  let stream = try await streamURL(for: format, player: player) else {
                AppLogger.youtube.error("No surround: itag \(format.itag, privacy: .public) has no usable URL or index")
                return nil
            }
            let wait = tv.availableAt.timeIntervalSinceNow
            AppLogger.youtube.info("Surround: \(format.channels, privacy: .public)-channel \(format.codecs, privacy: .public) (itag \(format.itag, privacy: .public)); YouTube's pre-roll holds it \(max(0, wait), format: .fixed(precision: 1), privacy: .public) s more")
            // A second's margin: googlevideo's clock and ours differ a little.
            if wait > -1 { try await Task.sleep(for: .seconds(wait + 1)) }

            let index = try await fetch(stream, range: indexRange)
            let segments = try SegmentIndex.segments(sidx: index, sidxOffset: indexRange.lowerBound)
            guard !segments.isEmpty else { throw SegmentIndex.Failure("no fragments") }
            let playlist = mediaPlaylist(uri: stream.absoluteString, initRange: initRange, segments: segments)
            guard let url = await LoopbackPlaylistServer.shared.publish(playlist) else { return nil }
            AppLogger.youtube.info("Surround ready after \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public) s: \(segments.count, privacy: .public) segments")
            return YouTubeSurroundAudio(
                channels: format.channels, codecs: format.codecs,
                bandwidth: SegmentIndex.peakBandwidth(segments) ?? format.bitrate ?? 384_000,
                language: format.language, playlistURL: url
            )
        } catch is CancellationError {
            return nil
        } catch {
            AppLogger.youtube.error("No surround: \(error.localizedDescription, privacy: .public) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    /// EC-3 before AC-3, the video's own language, never a DRC copy.
    static func pick(_ formats: [YouTubeTVAudio.Format]) -> YouTubeTVAudio.Format? {
        let surround = formats.filter { $0.channels > 2 && !$0.isDRC && ["ec-3", "ac-3"].contains($0.codecs) }
        let own = surround.filter(\.isDefaultTrack)
        return (own.isEmpty ? surround : own).min { rank($0) < rank($1) }
    }

    private static func rank(_ format: YouTubeTVAudio.Format) -> Int { format.codecs == "ec-3" ? 0 : 1 }

    /// The format's URL with its challenges answered.
    private static func streamURL(for format: YouTubeTVAudio.Format, player: YouTubePlayerScript.Player) async throws -> URL? {
        var base = format.url
        var signature: (value: String, parameter: String)?
        if base == nil, let cipher = format.signatureCipher {
            let fields = URLComponents(string: "?" + cipher)?.queryItems ?? []
            base = fields.first { $0.name == "url" }?.value
            if let s = fields.first(where: { $0.name == "s" })?.value {
                signature = (s, fields.first { $0.name == "sp" }?.value ?? "signature")
            }
        }
        // Everything but the answers stays byte for byte as YouTube sent it.
        guard let base, var components = URLComponents(string: base) else { return nil }
        var items = components.percentEncodedQueryItems ?? []
        let n = items.first { $0.name == "n" }?.value?.removingPercentEncoding
        let answers = try await YouTubePlayerScript.shared.solve(
            n: n.map { [$0] } ?? [], signatures: signature.map { [$0.value] } ?? [], for: player
        )
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
        }
        if let n {
            guard let solved = answers.n[n] else { throw YouTubePlayerScriptError.solverFailed("no n answer") }
            items = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: encoded(solved)) : $0 }
        }
        if let signature {
            guard let solved = answers.signatures[signature.value] else {
                throw YouTubePlayerScriptError.solverFailed("no signature answer")
            }
            items.append(URLQueryItem(name: signature.parameter, value: encoded(solved)))
        }
        components.percentEncodedQueryItems = items
        return components.url
    }

    private static func fetch(_ url: URL, range: ClosedRange<Int>) async throws -> Data {
        try YouTubeConsent.require()
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YouTubeInnertubeError.badResponse(http.statusCode)
        }
        return data
    }

    /// Audio-only VOD media playlist addressing one file by byte ranges.
    static func mediaPlaylist(uri: String, initRange: ClosedRange<Int>, segments: [SegmentIndex.Segment]) -> String {
        let target = Int((segments.map(\.duration).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, target))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(uri)\",BYTERANGE=\"\(initRange.count)@\(initRange.lowerBound)\"",
        ]
        for segment in segments {
            lines.append("#EXTINF:\(String(format: "%.5f", segment.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(uri)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A fragmented MP4's `sidx` box as HLS segments (ISO/IEC 14496-12 §8.16.3),
/// the same reading web-yt-dlp's backend did.
enum SegmentIndex {
    struct Segment: Equatable {
        var offset: Int
        var length: Int
        var duration: Double
    }

    struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { "The audio file's index can't be read: \(reason)." }
    }

    /// Fragments merged into segments of at least `targetSeconds` (the last
    /// may be shorter; a fragment is never split). `sidx` is the box's bytes,
    /// read from `sidxOffset` in the file; offsets returned are the file's.
    static func segments(sidx data: Data, sidxOffset: Int, targetSeconds: Double = 6) throws -> [Segment] {
        let bytes = [UInt8](data)
        func u32(_ at: Int) throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw Failure("truncated") }
            return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u64(_ at: Int) throws -> UInt64 { UInt64(try u32(at)) << 32 | UInt64(try u32(at + 4)) }

        let size = Int(try u32(0))
        guard bytes.count >= 8, String(decoding: bytes[4..<8], as: UTF8.self) == "sidx" else { throw Failure("not a sidx box") }
        guard size >= 8, size <= bytes.count else { throw Failure("box size \(size) for \(bytes.count) bytes") }
        let version = bytes[8]
        var p = 12
        p += 4 // reference_ID
        let timescale = Double(try u32(p)); p += 4
        guard timescale > 0 else { throw Failure("zero timescale") }
        let firstOffset: Int
        if version == 0 {
            p += 4 // earliest_presentation_time
            firstOffset = Int(try u32(p)); p += 4
        } else {
            p += 8
            firstOffset = Int(try u64(p)); p += 8
        }
        p += 2 // reserved
        guard p + 2 <= bytes.count else { throw Failure("truncated") }
        let count = Int(bytes[p]) << 8 | Int(bytes[p + 1]); p += 2
        guard p + count * 12 <= size else { throw Failure("reference table overruns the box") }

        var segments: [Segment] = []
        // first_offset counts from the first byte after the box.
        var offset = sidxOffset + size + firstOffset
        var current: Segment?
        for _ in 0..<count {
            let word = try u32(p)
            guard word >> 31 == 0 else { throw Failure("hierarchical index") }
            let length = Int(word & 0x7fff_ffff)
            let duration = Double(try u32(p + 4)) / timescale
            p += 12
            var segment = current ?? Segment(offset: offset, length: 0, duration: 0)
            segment.length += length
            segment.duration += duration
            offset += length
            if segment.duration >= targetSeconds {
                segments.append(segment)
                current = nil
            } else {
                current = segment
            }
        }
        if let current, current.length > 0 { segments.append(current) }
        return segments
    }

    /// The highest segment bitrate, bits a second: what HLS `BANDWIDTH` means.
    static func peakBandwidth(_ segments: [Segment]) -> Int? {
        let peak = segments.filter { $0.duration > 0 }.map { Double($0.length * 8) / $0.duration }.max()
        return peak.map { Int($0.rounded(.up)) }
    }
}

private extension CharacterSet {
    /// A query value's allowed characters: `&`, `=`, `+` and `?` escaped.
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
}

#endif
