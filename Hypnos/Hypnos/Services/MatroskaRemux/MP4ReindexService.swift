/*
 Hypnos - a server's MP4 with oversized chunks, played re-indexed

 Some files store a whole track as one chunk (a MainConcept export: 341
 frames in one 30 MB chunk). On visionOS 27 the native player stalls on
 such a file from a server in about a third of plays: it fetches the file
 in one request, counts only the first second or two as loaded and never
 asks again (Vision Pro, 2026-11-16; the same samples in 1-second chunks
 never stalled). `MP4Reindex` (MatroskaRemux) plans the same file with its
 chunks split; this serves that plan from `LoopbackHTTPServer` while the
 bytes stay on the server: the new `moov` from memory, everything else as
 ranges of the original, streamed through as the player reads them.

 `playURL(for:)` is the interface: a loopback URL to play in place of the
 original, or nil to play the original as it is (not an MP4, its chunks
 fine, anything the planner declines, a server without byte ranges). It
 reads the file's top-level box headers and its `moov`, which is why the
 window runs it alongside the decode probe rather than before it.

 Never stored as the video's URL, like the remux's: the loopback URL dies
 with the process, and a restored window resolves its original again.
 Plans are kept per source for the launch (the last few), and so are
 declines, so a re-resolve reads nothing.
 */

import DebugTrace
import Foundation
import MatroskaRemux
import Synchronization

final class MP4ReindexService: Sendable {
    static let shared = MP4ReindexService()

    private struct Entry: Sendable {
        let url: URL
        let plan: MP4Reindex.Plan
        var lastUse: Date
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var opening: [String: Task<URL?, Never>] = [:]
        /// Sources left as they are, and why.
        var declined: [String: String] = [:]
        /// Route prefix → source, for the loopback handler.
        var sources: [String: URL] = [:]
    }

    private let state = Mutex<State>(State())
    private static let maximumPlans = 8

    /// Formats that are certainly not ISO media: not worth a read.
    private static let otherContainers: Set<String> = [
        "mkv", "mk3d", "webm", "m3u8", "ts", "m2ts", "mts", "avi", "wmv", "asf", "flv", "mpg", "mpeg", "vob",
        "gif", "jpg", "jpeg", "png", "heic",
    ]

    /// Could `url` be a server's MP4 worth checking? Remote http(s), not a
    /// loopback URL of this app, and not named as another container.
    static func isCandidate(_ url: URL, fileName: String?) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", url.host != "127.0.0.1", url.host != "localhost" else { return false }
        for name in [fileName.map { ($0 as NSString).pathExtension }, url.pathExtension] {
            guard let ext = name?.lowercased(), !ext.isEmpty else { continue }
            if otherContainers.contains(ext) { return false }
        }
        return true
    }

    /// Why `url` plays as it is, if it was checked.
    func declineReason(for url: URL) -> String? {
        state.withLock { $0.declined[url.absoluteString] }
    }

    /// A loopback URL playing `url` re-indexed, or nil to play it as it is.
    func playURL(for url: URL, fileName: String?) async -> URL? {
        guard Self.isCandidate(url, fileName: fileName) else { return nil }
        let key = url.absoluteString
        enum Found { case ready(URL), declined, opening(Task<URL?, Never>), start(Task<URL?, Never>) }
        let found: Found = state.withLock { state in
            if let entry = state.entries[key], let prefix = state.sources.first(where: { $0.value == url })?.key,
               let base = Self.baseURL(prefix) {
                state.entries[key]?.lastUse = Date()
                _ = entry
                return .ready(base)
            }
            if state.declined[key] != nil { return .declined }
            if let task = state.opening[key] { return .opening(task) }
            let task = Task { await self.open(url) }
            state.opening[key] = task
            return .start(task)
        }
        switch found {
        case .ready(let base): return base.appending(path: "file.mp4")
        case .declined: return nil
        case .opening(let task), .start(let task): return await task.value
        }
    }

    private static let port = Mutex<Int?>(nil)

    private static func baseURL(_ prefix: String) -> URL? {
        port.withLock { $0 }.flatMap { URL(string: "http://127.0.0.1:\($0)/\(prefix)/") }
    }

    private func open(_ url: URL) async -> URL? {
        let key = url.absoluteString
        defer { state.withLock { _ = $0.opening.removeValue(forKey: key) } }
        let began = ContinuousClock.now
        let plan: MP4Reindex.Plan
        do {
            plan = try await MP4Reindex.plan(RemoteByteSource(url: url))
        } catch {
            let reason = (error as? MP4Reindex.Decline)?.description ?? (error as? RemoteByteSource.Failure)?.description ?? error.logCode
            state.withLock { $0.declined[key] = reason }
            if case MP4Reindex.Decline.chunksFine = error {} else if error is MP4Reindex.Decline {
                AppLogger.remux.debug("MP4 left as it is: \(reason, privacy: .public)")
            }
            return nil
        }
        let prefix = "reindex-\(UUID().uuidString.prefix(8).lowercased())"
        guard let base = await LoopbackHTTPServer.shared.register(prefix: prefix, streamed: { [weak self] _ in
            self?.resource(prefix: prefix)
        }) else {
            state.withLock { $0.declined[key] = "the loopback server didn't start" }
            return nil
        }
        Self.port.withLock { $0 = base.port }
        let evicted: [String] = state.withLock { state in
            state.entries[key] = Entry(url: url, plan: plan, lastUse: Date())
            state.sources[prefix] = url
            var evicted: [String] = []
            while state.entries.count > Self.maximumPlans,
                  let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                state.entries.removeValue(forKey: oldest.key)
                for (oldPrefix, source) in state.sources where source.absoluteString == oldest.key {
                    state.sources.removeValue(forKey: oldPrefix)
                    evicted.append(oldPrefix)
                }
            }
            return evicted
        }
        for old in evicted { LoopbackHTTPServer.shared.unregister(prefix: old) }
        let summary = plan.summary
        let elapsed = began.duration(to: .now)
        AppLogger.remux.info("Playing an MP4 re-indexed: \(summary.chunksBefore, privacy: .public) chunks → \(summary.chunksAfter, privacy: .public) (largest \(summary.largestChunkBytes >> 20, privacy: .public) MB, \(summary.longestChunkSeconds, format: .fixed(precision: 1), privacy: .public) s), offsets moved \(summary.offsetShift, privacy: .public) bytes, planned in \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000, privacy: .public) ms")
        return base.appending(path: "file.mp4")
    }

    private func resource(prefix: String) -> LoopbackHTTPServer.StreamedResource? {
        guard let (url, plan) = state.withLock({ state -> (URL, MP4Reindex.Plan)? in
            guard let url = state.sources[prefix], let entry = state.entries[url.absoluteString] else { return nil }
            state.entries[url.absoluteString]?.lastUse = Date()
            return (url, entry.plan)
        }) else { return nil }
        return LoopbackHTTPServer.StreamedResource(length: plan.length, contentType: "video/mp4") { range, write in
            for piece in plan.pieces(for: range) {
                switch piece {
                case .bytes(let data):
                    try await write(data)
                case .original(let source):
                    try await RemoteRangeStream.stream(url, range: source, to: write)
                }
            }
        }
    }
}

/// One range of a server's file, read with one request and handed on in
/// pieces as they arrive. The download is suspended while more than a few
/// megabytes wait to be written, so a player reading slowly holds back the
/// server instead of filling memory.
enum RemoteRangeStream {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    enum Failure: Error {
        case status(Int)
        case wrongRange
        case short
    }

    static func stream(_ url: URL, range: Range<Int64>, to write: @Sendable (Data) async throws -> Void) async throws {
        guard !range.isEmpty else { return }
        var request = MediaAuthorization.shared.request(for: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let pipe = Pipe()
        let task = session.dataTask(with: request)
        task.delegate = pipe
        pipe.task = task
        task.resume()
        defer { task.cancel() }
        var remaining = range.upperBound - range.lowerBound
        var skip: Int64 = 0
        var checked = false
        for try await event in pipe.events {
            switch event {
            case .response(let http):
                switch http.statusCode {
                case 206:
                    let header = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                    guard header.isEmpty || header.contains(" \(range.lowerBound)-") else { throw Failure.wrongRange }
                case 200:
                    // A server that ignores ranges: usable only from its start.
                    skip = range.lowerBound
                    guard skip == 0 else { throw Failure.wrongRange }
                default:
                    throw Failure.status(http.statusCode)
                }
                checked = true
            case .data(var data):
                guard checked else { throw Failure.status(0) }
                if skip > 0 {
                    let drop = Int(min(skip, Int64(data.count)))
                    data = data.subdata(in: data.startIndex + drop ..< data.endIndex)
                    skip -= Int64(drop)
                }
                if Int64(data.count) > remaining { data = data.prefix(Int(remaining)) }
                guard !data.isEmpty else { continue }
                pipe.consumed(data.count)
                try await write(data)
                remaining -= Int64(data.count)
                if remaining == 0 { return }
            }
        }
        if remaining > 0 { throw Failure.short }
    }

    /// The task's response and data as a stream, with the download suspended
    /// while too much waits.
    final class Pipe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        enum Event: Sendable {
            case response(HTTPURLResponse)
            case data(Data)
        }

        let events: AsyncThrowingStream<Event, Error>
        private let continuation: AsyncThrowingStream<Event, Error>.Continuation
        weak var task: URLSessionDataTask?
        private let lock = NSLock()
        private var waiting = 0
        private var suspended = false
        private static let high = 8 << 20
        private static let low = 2 << 20

        override init() {
            (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
            super.init()
        }

        func consumed(_ count: Int) {
            let resume = lock.withLock { () -> Bool in
                waiting -= count
                guard suspended, waiting < Self.low else { return false }
                suspended = false
                return true
            }
            if resume { task?.resume() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                continuation.finish(throwing: Failure.status(0))
                completionHandler(.cancel)
                return
            }
            continuation.yield(.response(http))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let suspend = lock.withLock { () -> Bool in
                waiting += data.count
                guard !suspended, waiting > Self.high else { return false }
                suspended = true
                return true
            }
            continuation.yield(.data(data))
            if suspend { dataTask.suspend() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}
