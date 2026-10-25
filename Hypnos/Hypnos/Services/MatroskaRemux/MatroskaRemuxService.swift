/*
 Hypnos - Matroska and WebM played natively, remuxed to HLS on the device

 AVFoundation decodes what MKV and WebM files hold (H.264, HEVC, VP9 with
 the supplemental decoder `HypnosApp.init` registers, AV1 where the chip has
 it; AAC, AC-3, E-AC-3, Opus, FLAC…) but can't open the container: VP9+Opus
 WebM fails with -11828 (-11850 over HTTP) while the same streams in MP4 or
 fMP4 HLS play. So a file the native player refuses is offered to
 `MatroskaRemux`: the file's own clusters cut at its keyframes and muxed to
 fragmented-MP4 HLS segment by segment, served from `LoopbackHTTPServer`.
 Lossless and instant: no re-encoding, nothing written to disk, a seek
 fetches one segment's bytes. Ahead of WebKit (which loses HDR, spatial audio
 and the native player's features) and of Stash's server transcode.

 `playlistURL(for:)` is the whole interface: a loopback URL that plays, or
 nil to keep the caller's existing fallback. Nil when:
 - the file isn't Matroska (a cheap guess from the name, then the EBML
   magic in its first bytes);
 - the remuxer declines it (VP8, Vorbis-only audio, an encrypted track, a
   server file without Cues whose clusters have no sizes…, see
   `RemuxError`);
 - the device has no decoder for the video (`canDecode`, which asks
   VideoToolbox with the remux's own sample entry: AV1 on a chip without
   it, VP9 before the supplemental decoder is registered);
 - AVFoundation won't open the result (the decode probe).

 Never stored as the video's URL: windows are restored after a relaunch,
 when this URL is dead; the original is what they keep (`VideoWindowModel`'s
 `remuxedStreamURL` sits beside it like `resolvedPhotosStreamURL`).

 HDR. A player that can't present HDR (`AVPlayer.eligibleForHDRPlayback`
 false: an SDR display or TV) refuses an HLS master whose video is PQ or HLG
 outright, VIDEO-RANGE stated or not (CoreMedia -17223 / -12927, measured on
 a Mac on an SDR display), though it plays the same picture from a media
 playlist, tone-mapped. Such a device gets the session's muxed playlist:
 video and the default audio track in one stream, without the audio menu.

 Sessions are kept per source URL (the last few), so a re-resolve, a Quality
 switch back to Original or a second window reuses one; declines are
 remembered for the launch so a file isn't re-read on every resolve.
 */

import AVFoundation
import CoreMedia
import DebugTrace
import Foundation
import MatroskaRemux
import Synchronization
import VideoToolbox

final class MatroskaRemuxService: Sendable {
    static let shared = MatroskaRemuxService()

    enum Form: Sendable {
        /// The master, or the muxed playlist on a device that can't present
        /// this file's HDR.
        case automatic
        case master
        case muxed
    }

    private struct Entry: Sendable {
        let prefix: String
        let session: RemuxSession
        let baseURL: URL
        var lastUse: Date
        /// Its parsed segments were let go while nobody played it.
        var idleTrimmed = false
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var opening: [String: Task<Entry?, Never>] = [:]
        var declined: Set<String> = []
    }

    private let state = Mutex<State>(State())
    private static let maximumSessions = 6

    // MARK: - Candidates

    /// Containers that are certainly not Matroska: not worth a byte read.
    private static let otherContainers: Set<String> = [
        "mp4", "m4v", "mov", "qt", "m3u8", "ts", "m2ts", "mts", "avi", "wmv", "asf", "flv", "3gp", "mpg", "mpeg",
        "vob", "gif", "jpg", "jpeg", "png", "heic",
    ]

    /// Could `url` (or the file it was named after) be Matroska? Extensions
    /// decide when they say; an extensionless stream URL (Stash's
    /// `/scene/<id>/stream`) is a maybe, settled by the first bytes.
    static func isCandidate(_ url: URL, fileName: String?) -> Bool {
        guard url.isFileURL || url.scheme == "http" || url.scheme == "https" else { return false }
        if url.host == "127.0.0.1", LoopbackHTTPServer.shared.routePrefix(of: url) != nil { return false }
        for name in [fileName.map { ($0 as NSString).pathExtension }, url.pathExtension] {
            guard let ext = name?.lowercased(), !ext.isEmpty else { continue }
            if ["mkv", "mk3d", "webm"].contains(ext) { return true }
            if otherContainers.contains(ext) { return false }
        }
        return true
    }

    // MARK: - Sessions

    /// A loopback HLS URL that plays `source` natively, or nil (not
    /// Matroska, declined, no decoder, or the player refuses it).
    func playlistURL(for source: URL, fileName: String? = nil, form: Form = .automatic) async -> URL? {
        guard Self.isCandidate(source, fileName: fileName) else { return nil }
        let key = source.absoluteString
        if let entry = state.withLock({ state -> Entry? in
            state.entries[key]?.lastUse = .now
            return state.entries[key]
        }) {
            return Self.url(for: entry, form: form)
        }
        let task: Task<Entry?, Never>? = state.withLock { state in
            if state.declined.contains(key) { return nil }
            if let task = state.opening[key] { return task }
            let task = Task { await self.open(source, key: key) }
            state.opening[key] = task
            return task
        }
        guard let task, let entry = await task.value else { return nil }
        return Self.url(for: entry, form: form)
    }

    /// The open session remuxing `source` (the URL `playlistURL(for:)` was
    /// given), for the subtitle tracks inside the file.
    func session(for source: URL) -> RemuxSession? {
        state.withLock { $0.entries[source.absoluteString]?.session }
    }

    private static func url(for entry: Entry, form: Form) -> URL {
        let muxed: Bool = switch form {
        case .master: false
        case .muxed: true
        case .automatic: entry.session.summary.videoRange != "SDR" && !AVPlayer.eligibleForHDRPlayback
        }
        return entry.baseURL.appendingPathComponent(muxed ? "muxed.m3u8" : "master.m3u8")
    }

    private func open(_ source: URL, key: String) async -> Entry? {
        let entry = await makeEntry(source, key: key)
        state.withLock { state in
            state.opening[key] = nil
            if let entry {
                state.entries[key] = entry
            }
        }
        if entry != nil { evictIfNeeded() }
        return entry
    }

    private func makeEntry(_ source: URL, key: String) async -> Entry? {
        let started = ContinuousClock.now
        let bytes: any ByteSource
        do {
            bytes = source.isFileURL ? try FileByteSource(url: source) : RemoteByteSource(url: source)
        } catch {
            AppLogger.remux.error("Can't read the file: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
        let session: RemuxSession
        do {
            session = try await RemuxSession.open(source: bytes)
        } catch let error as RemuxError {
            if error != .notMatroska {
                AppLogger.remux.info("Not remuxed: \(error.description, privacy: .public)")
            }
            decline(key)
            return nil
        } catch let failure as RemoteByteSource.Failure {
            AppLogger.remux.info("Not remuxed: \(failure.description, privacy: .public)")
            if case .noRanges = failure { decline(key) }
            return nil
        } catch {
            // Network trouble: worth another try later, so not remembered.
            AppLogger.remux.error("Remux open failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }

        let summary = session.summary
        guard Self.canDecode(sampleEntry: session.videoSampleEntry) else {
            AppLogger.remux.info("Not remuxed: no decoder for \(summary.video.codec, privacy: .public) (\(summary.video.codecs, privacy: .public)) on this device")
            decline(key)
            return nil
        }

        let prefix = "remux-" + UUID().uuidString.prefix(8).lowercased()
        let handler: LoopbackHTTPServer.Handler = { [weak self] path in
            self?.touch(key)
            do {
                guard let (data, type) = try await session.data(at: path) else { return nil }
                return LoopbackHTTPServer.Response(contentType: type, body: data)
            } catch {
                AppLogger.remux.error("Segment \(path, privacy: .public) failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                return LoopbackHTTPServer.Response(status: 502, contentType: "text/plain", body: Data())
            }
        }
        guard let base = await LoopbackHTTPServer.shared.register(prefix: prefix, handler: handler) else { return nil }
        let entry = Entry(prefix: prefix, session: session, baseURL: base, lastUse: .now, idleTrimmed: false)

        // The player's own answer, on the form this device will play.
        let probeURL = Self.url(for: entry, form: .automatic)
        guard await NativeVideoDecodeProbe.canPlayNatively(url: probeURL, timeout: 15) else {
            AppLogger.remux.error("Remuxed \(summary.video.codec, privacy: .public) isn't playable here; keeping the fallback")
            LoopbackHTTPServer.shared.unregister(prefix: prefix)
            decline(key)
            return nil
        }

        let audio = summary.audio.map { "\($0.codec) \($0.channels ?? 0)ch" }.joined(separator: ", ")
        let dropped = summary.dropped.map { "\($0.codecID) (\($0.reason))" }.joined(separator: ", ")
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        AppLogger.remux.info("""
            Remuxing \(summary.docType, privacy: .public) \(summary.video.codec, privacy: .public) \
            \(summary.width, privacy: .public)x\(summary.height, privacy: .public) \(summary.videoRange, privacy: .public), \
            audio [\(audio, privacy: .public)], dropped [\(dropped, privacy: .public)], \
            \(summary.segmentCount, privacy: .public) segments\(summary.scannedClusters ? " (scanned)" : summary.indexing ? " so far (indexing)" : "", privacy: .public), \
            ready in \(milliseconds, privacy: .public) ms\(probeURL.lastPathComponent == "muxed.m3u8" ? ", muxed for an SDR display" : "", privacy: .public)
            """)
        return entry
    }

    private func decline(_ key: String) {
        _ = state.withLock { $0.declined.insert(key) }
    }

    /// Notes a request for `key`'s session, and lets the sessions nobody
    /// has asked anything of for a minute drop their parsed segments (each
    /// holds up to 64 MB of them for the renditions still to come).
    private func touch(_ key: String) {
        let idle: [RemuxSession] = state.withLock { state in
            state.entries[key]?.lastUse = .now
            state.entries[key]?.idleTrimmed = false
            let cutoff = Date.now.addingTimeInterval(-60)
            var idle: [RemuxSession] = []
            for (other, entry) in state.entries where other != key && !entry.idleTrimmed && entry.lastUse < cutoff {
                state.entries[other]?.idleTrimmed = true
                idle.append(entry.session)
            }
            return idle
        }
        for session in idle { Task { await session.dropCache() } }
    }

    /// Past the limit, the least recently used sessions stop being served.
    private func evictIfNeeded() {
        let evicted: [Entry] = state.withLock { state in
            guard state.entries.count > Self.maximumSessions else { return [] }
            let old = state.entries.sorted { $0.value.lastUse < $1.value.lastUse }
                .prefix(state.entries.count - Self.maximumSessions)
            for (key, _) in old { state.entries[key] = nil }
            return old.map(\.value)
        }
        for entry in evicted { LoopbackHTTPServer.shared.unregister(prefix: entry.prefix) }
    }

    // MARK: - Decoders

    /// Whether VideoToolbox has a decoder for this sample entry: a
    /// decompression session made from the remux's own format description.
    static func canDecode(sampleEntry: Data) -> Bool {
        var description: CMVideoFormatDescription?
        let status = sampleEntry.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianImageDescriptionData: base, size: sampleEntry.count,
                stringEncoding: CFStringBuiltInEncodings.UTF8.rawValue, flavor: .isoFamily,
                formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return false }
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                                   decoderSpecification: nil, imageBufferAttributes: nil,
                                                   outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return created == noErr
    }
}
