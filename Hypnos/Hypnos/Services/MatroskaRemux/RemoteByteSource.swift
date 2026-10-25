/*
 Hypnos - a server's file as a MatroskaRemux byte source

 HTTP range requests, authenticated the way every AVFoundation read in the
 app is (`MediaAuthorization.request(for:)`: Stash's api key, Nextcloud's
 Basic header), so a server that needs a credential serves the remuxer what
 it would serve the player.

 The first request asks for one byte and reads the file's length from
 Content-Range. A server that answers it with 200 instead of 206 doesn't do
 ranges; it would send the whole file for every segment, so the source
 refuses before reading the body, and the caller keeps its other fallbacks.
 */

import Foundation
import MatroskaRemux
import Synchronization

final class RemoteByteSource: ByteSource {
    enum Failure: Error, CustomStringConvertible {
        case status(Int)
        case noRanges
        case badRange

        var description: String {
            switch self {
            case .status(let code): "HTTP \(code)"
            case .noRanges: "the server ignores byte ranges"
            case .badRange: "the server answered a different range"
            }
        }
    }

    let url: URL
    private let session: URLSession
    private let knownLength = Mutex<Int64??>(nil)

    init(url: URL) {
        self.url = url
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit { session.finishTasksAndInvalidate() }

    func length() async throws -> Int64? {
        if let known = knownLength.withLock({ $0 }) { return known }
        var request = MediaAuthorization.shared.request(for: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        // Bytes, not data: a server that ignores the range would otherwise
        // send the whole file before this could say no.
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        guard http.statusCode == 206 else {
            throw http.statusCode == 200 ? Failure.noRanges : Failure.status(http.statusCode)
        }
        let total = Self.total(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
        knownLength.withLock { $0 = .some(total) }
        return total
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty else { return Data() }
        var request = MediaAuthorization.shared.request(for: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        switch http.statusCode {
        case 206:
            let header = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard header.isEmpty || header.contains(" \(range.lowerBound)-") else { throw Failure.badRange }
            return data
        case 416:
            return Data() // past the end
        case 200:
            // Only a whole-file answer to a range from 0 can be used.
            guard range.lowerBound == 0 else { throw Failure.noRanges }
            return data.prefix(Int(range.count))
        default:
            throw Failure.status(http.statusCode)
        }
    }

    /// "bytes 0-0/1234" → 1234; nil for "*".
    static func total(fromContentRange header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
