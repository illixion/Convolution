/*
 Test support: a session served over HTTP on 127.0.0.1, the way the app's
 `LoopbackHTTPServer` serves it, so AVFoundation reads the HLS itself (its
 playlists, renditions and media selection) rather than a file.

 One request per connection, GET only, no ranges: what AVFoundation asks of
 an HLS server.
 */

#if canImport(Network)

import Foundation
import Network
@testable import MatroskaRemux

final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-test-server")
    let session: RemuxSession

    private init(session: RemuxSession, listener: NWListener) {
        self.session = session
        self.listener = listener
    }

    /// Starts serving `session` at http://127.0.0.1:<port>/.
    static func start(_ session: RemuxSession) async throws -> (server: LoopbackServer, base: URL) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = LoopbackServer(session: session, listener: listener)
        listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            /// True the first time only.
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
        return (server, URL(string: "http://127.0.0.1:\(port)/")!)
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { receive(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = String(target.dropFirst().split(separator: "?").first ?? "")
            Task { [session] in
                let found = try? await session.data(at: path)
                var response = "HTTP/1.1 \(found == nil ? "404 Not Found" : "200 OK")\r\n"
                response += "Content-Type: \(found?.contentType ?? "text/plain")\r\n"
                response += "Content-Length: \(found?.data.count ?? 0)\r\nConnection: close\r\n\r\n"
                var bytes = Data(response.utf8)
                if let found { bytes.append(found.data) }
                connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

#endif
