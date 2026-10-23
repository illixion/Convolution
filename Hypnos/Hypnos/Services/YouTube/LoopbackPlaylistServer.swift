/*
 Hypnos - serves composed HLS master playlists on 127.0.0.1

 A spliced master playlist (`YouTubeManifestComposer`) exists only in
 memory, and AVFoundation will not play an HLS master from a `file:` or
 `data:` URL. The alternative, an `AVAssetResourceLoaderDelegate` behind a
 custom scheme, would have to be attached at every place an `AVURLAsset` is
 made, RAVEMedia's stereo engine included. A loopback URL works everywhere a
 URL does: the native player, the stereo engine and the decode probe all
 open it unchanged.

 Only the master is served here; its variant and rendition URIs are
 absolute (YouTube's CDN, the backend), so the player fetches media from
 there directly. Loopback needs no Local Network permission, and
 `NSAllowsLocalNetworking` covers the plain-HTTP fetch.

 Playlists live for the process. A restored window's loopback URL is dead
 after a relaunch, which `YouTubeResolver.needsRefresh` treats like an
 expired YouTube URL: the window resolves the video again.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation
import Network
import os
import Synchronization

final class LoopbackPlaylistServer: Sendable {
    static let shared = LoopbackPlaylistServer()

    private let queue = DispatchQueue(label: "com.illixion.hypnos.loopback-playlists")
    private let state = Mutex<State>(State())

    private struct State {
        var listener: NWListener?
        var port: UInt16?
        var playlists: [String: String] = [:]
    }

    /// Publishes `playlist` and returns its URL, or nil when the listener
    /// can't start.
    func publish(_ playlist: String) async -> URL? {
        guard let port = await startIfNeeded() else { return nil }
        let name = UUID().uuidString
        state.withLock { $0.playlists[name] = playlist }
        return URL(string: "http://127.0.0.1:\(port)/\(name).m3u8")
    }

    func isLive(_ url: URL) -> Bool {
        playlist(at: url) != nil
    }

    /// The playlist served at `url`, if this launch published it.
    func playlist(at url: URL) -> String? {
        guard url.host == "127.0.0.1" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return state.withLock { $0.port == UInt16(url.port ?? 0) ? $0.playlists[name] : nil }
    }

    private func startIfNeeded() async -> UInt16? {
        if let port = state.withLock({ $0.port }) { return port }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let port: UInt16? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { newState in
                let value: UInt16?
                switch newState {
                case .ready: value = listener.port?.rawValue
                case .failed, .cancelled: value = nil
                default: return
                }
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: value)
            }
            listener.start(queue: queue)
        }
        guard let port else {
            listener.cancel()
            AppLogger.youtube.error("Loopback playlist server failed to start")
            return nil
        }
        // A concurrent first publish may have won; keep its listener.
        let kept = state.withLock { state -> UInt16 in
            if let existing = state.port { return existing }
            state.listener = listener
            state.port = port
            return port
        }
        if kept != port { listener.cancel() }
        return kept
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let requestLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = requestLine.split(separator: " ")
            let isHead = parts.first == "HEAD"
            let path = parts.count > 1 ? String(parts[1]) : ""
            let name = (path.split(separator: "/").last.map(String.init) ?? "")
                .replacingOccurrences(of: ".m3u8", with: "")
            let body = self.state.withLock { $0.playlists[name] }

            let response: Data
            if let body {
                let bytes = Data(body.utf8)
                var head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\n"
                head += "Content-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                response = Data(head.utf8) + (isHead ? Data() : bytes)
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

#endif
