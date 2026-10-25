/*
 Hypnos - a small HTTP server on 127.0.0.1, for media the app makes itself

 AVFoundation plays HLS from a URL, not from memory: a master playlist
 composed in the app, or a Matroska file remuxed to HLS on the fly, has to
 be fetched over HTTP. An `AVAssetResourceLoaderDelegate` behind a custom
 scheme would have to be attached everywhere an `AVURLAsset` is made
 (RAVEMedia's stereo engine included); a loopback URL works everywhere a URL
 does, unchanged: the native player, the stereo engine, the decode probe.

 Two kinds of content:

 - Text playlists published once and kept for the process
   (`publishPlaylist`), at `/<uuid>.m3u8`. YouTube's composed masters
   (`LoopbackPlaylistServer`, sideload builds only) are these.
 - Routes: everything under `/<prefix>/` answered by a handler, on demand.
   Each Matroska remux session is one (`MatroskaRemuxService`).

 GET and HEAD, single byte ranges (206, and 416 for a range past the end),
 concurrent connections, one request per connection. Loopback needs no Local
 Network permission, and the plain-HTTP fetch is covered by
 `NSAllowsLocalNetworking` (Info.plist), which permits loopback.

 The port is chosen once per launch. A restored window's loopback URL is
 dead after a relaunch; callers keep the URL they came from (the original
 file, YouTube's video id) and resolve again.
 */

import DebugTrace
import Foundation
import Network
import os
import Synchronization

final class LoopbackHTTPServer: Sendable {
    static let shared = LoopbackHTTPServer()

    struct Response: Sendable {
        var status = 200
        var contentType: String
        var body: Data
    }

    /// Answers a path under a route's prefix (without the leading slash),
    /// or nil for 404.
    typealias Handler = @Sendable (_ path: String) async -> Response?

    /// Network.framework's callbacks; each request is answered in a Task, so
    /// a slow segment doesn't hold up the others.
    private let queue = DispatchQueue(label: "com.illixion.hypnos.loopback-http")
    private let state = Mutex<State>(State())

    private struct State {
        var listener: NWListener?
        var port: UInt16?
        var playlists: [String: String] = [:]
        var routes: [String: Handler] = [:]
    }

    // MARK: - Content

    /// Publishes `playlist` for the life of the process; nil when the
    /// listener can't start.
    func publishPlaylist(_ playlist: String) async -> URL? {
        guard let port = await startIfNeeded() else { return nil }
        let name = UUID().uuidString
        state.withLock { $0.playlists[name] = playlist }
        return URL(string: "http://127.0.0.1:\(port)/\(name).m3u8")
    }

    /// The playlist published at `url`, if this launch published it.
    func playlist(at url: URL) -> String? {
        guard url.host == "127.0.0.1" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return state.withLock { $0.port == UInt16(url.port ?? 0) ? $0.playlists[name] : nil }
    }

    /// Serves `handler` under `/<prefix>/`; returns that folder's URL.
    func register(prefix: String, handler: @escaping Handler) async -> URL? {
        guard let port = await startIfNeeded() else { return nil }
        state.withLock { $0.routes[prefix] = handler }
        return URL(string: "http://127.0.0.1:\(port)/\(prefix)/")
    }

    func unregister(prefix: String) {
        _ = state.withLock { $0.routes.removeValue(forKey: prefix) }
    }

    /// The route prefix a URL of this server falls under.
    func routePrefix(of url: URL) -> String? {
        guard url.host == "127.0.0.1", state.withLock({ $0.port }) == UInt16(url.port ?? 0) else { return nil }
        let prefix = url.pathComponents.dropFirst().first
        return prefix.flatMap { name in state.withLock { $0.routes[name] != nil } ? name : nil }
    }

    // MARK: - Listening

    private func startIfNeeded() async -> UInt16? {
        if let port = state.withLock({ $0.port }) { return port }
        guard let (listener, port) = await listen(on: .any) else {
            AppLogger.remux.error("Loopback server failed to start")
            return nil
        }
        // A concurrent first caller may have won; keep its listener.
        let kept = state.withLock { state -> UInt16 in
            if let existing = state.port { return existing }
            state.listener = listener
            state.port = port
            return port
        }
        if kept != port { listener.cancel() }
        return kept
    }

    private func listen(on port: NWEndpoint.Port) async -> (NWListener, UInt16)? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let ready: UInt16? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self, weak listener] newState in
                let value: UInt16?
                switch newState {
                case .ready: value = listener?.port?.rawValue
                case .failed, .cancelled: value = nil
                default: return
                }
                if resumed.withLock({ done in defer { done = true }; return !done }) {
                    continuation.resume(returning: value)
                } else if case .failed = newState, let self, let listener {
                    self.listenerFailed(listener)
                }
            }
            listener.start(queue: queue)
        }
        guard let ready else {
            listener.cancel()
            return nil
        }
        return (listener, ready)
    }

    /// A listener that fails after it was ready (the system can tear a
    /// suspended app's sockets down) is replaced on the same port, so the
    /// URLs already handed out keep working.
    private func listenerFailed(_ listener: NWListener) {
        guard let port = state.withLock({ $0.listener === listener ? $0.port : nil }) else { return }
        listener.cancel()
        AppLogger.remux.error("Loopback server stopped; restarting on its port")
        Task {
            guard let (replacement, _) = await listen(on: NWEndpoint.Port(rawValue: port) ?? .any) else {
                AppLogger.remux.error("Loopback server could not restart on its port")
                state.withLock { if $0.listener === listener { $0.listener = nil; $0.port = nil } }
                return
            }
            state.withLock { $0.listener = replacement }
        }
    }

    // MARK: - Requests

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    /// Reads up to the end of the request head, then answers it.
    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard error == nil, !isComplete, buffer.count < 64 * 1024 else { connection.cancel(); return }
                self.receiveRequest(connection, buffer: buffer)
                return
            }
            let request = Request(String(decoding: buffer, as: UTF8.self))
            Task {
                let response = await self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    struct Request {
        var method = ""
        var path = ""
        var range: String?

        init(_ head: String) {
            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            method = parts.first.map(String.init) ?? ""
            let target = parts.count > 1 ? String(parts[1]) : ""
            path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                if pair.count == 2, pair[0].lowercased() == "range" {
                    range = pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
    }

    private func respond(to request: Request) async -> Data {
        guard request.method == "GET" || request.method == "HEAD" else {
            return Self.head(status: 405, reason: "Method Not Allowed", fields: ["Allow": "GET, HEAD", "Content-Length": "0"])
        }
        let isHead = request.method == "HEAD"
        let components = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var response: Response?
        if components.count == 1, components[0].hasSuffix(".m3u8") {
            let name = String(components[0].dropLast(5))
            if let text = state.withLock({ $0.playlists[name] }) {
                response = Response(contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
            }
        } else if let prefix = components.first, let handler = state.withLock({ $0.routes[prefix] }) {
            response = await handler(components.dropFirst().joined(separator: "/"))
        }
        guard let response else {
            return Self.head(status: 404, reason: "Not Found", fields: ["Content-Length": "0"])
        }

        let total = response.body.count
        var fields = ["Content-Type": response.contentType, "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if let rangeHeader = request.range, response.status == 200 {
            guard let range = Self.byteRange(rangeHeader, total: total) else {
                fields["Content-Range"] = "bytes */\(total)"
                fields["Content-Length"] = "0"
                return Self.head(status: 416, reason: "Range Not Satisfiable", fields: fields)
            }
            fields["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
            fields["Content-Length"] = String(range.count)
            let head = Self.head(status: 206, reason: "Partial Content", fields: fields)
            return isHead ? head : head + response.body.subdata(in: range)
        }
        fields["Content-Length"] = String(total)
        let head = Self.head(status: response.status, reason: response.status == 200 ? "OK" : "Error", fields: fields)
        return isHead ? head : head + response.body
    }

    /// One byte range (`bytes=a-b`, `bytes=a-`, `bytes=-n`) within `total`;
    /// nil when it isn't satisfiable. Multiple ranges get the first.
    static func byteRange(_ header: String, total: Int) -> Range<Int>? {
        guard header.lowercased().hasPrefix("bytes="), total > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
            return max(0, total - suffix) ..< total
        }
        guard let start = Int(bounds[0]), start < total else { return nil }
        let end = bounds[1].isEmpty ? total - 1 : min(total - 1, Int(bounds[1]) ?? -1)
        return end >= start ? start ..< end + 1 : nil
    }

    private static func head(status: Int, reason: String, fields: [String: String]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }
}
