/*
 MatroskaRemux - where the bytes come from

 Everything the remuxer reads goes through `ByteSource`: an async read of a
 byte range plus the total length. That keeps I/O out of the core, so the
 same session works over a local file, an authenticated HTTP range request
 (the app's `RemoteByteSource`, which needs the app's credential registry)
 or bytes in memory (tests).

 Reads are by absolute offset and may come from several tasks at once (the
 player fetches a video and an audio segment together), so a source must be
 safe to call concurrently.
 */

import Foundation

public protocol ByteSource: Sendable {
    /// Total length in bytes; nil when the source can't say (a live stream).
    func length() async throws -> Int64?
    /// The bytes in `range`. Shorter only where the source ends.
    func read(_ range: Range<Int64>) async throws -> Data
    /// True for a source that is cheap to read end to end (a local file):
    /// a file without Cues may then be indexed by scanning its clusters.
    var isLocal: Bool { get }
}

public extension ByteSource {
    var isLocal: Bool { false }
}

/// Bytes already in memory.
public struct DataByteSource: ByteSource {
    public let data: Data
    public let isLocal = true

    public init(_ data: Data) { self.data = data }

    public func length() async throws -> Int64? { Int64(data.count) }

    public func read(_ range: Range<Int64>) async throws -> Data {
        let lower = Int(max(0, min(range.lowerBound, Int64(data.count))))
        let upper = Int(max(Int64(lower), min(range.upperBound, Int64(data.count))))
        return data.subdata(in: data.startIndex + lower ..< data.startIndex + upper)
    }
}

/// A local file, read with positioned reads under a lock (a `FileHandle`'s
/// offset is shared state).
public final class FileByteSource: ByteSource, @unchecked Sendable {
    public let url: URL
    public let isLocal = true
    private let handle: FileHandle
    private let lock = NSLock()
    private let size: Int64

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        size = Int64(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    public func length() async throws -> Int64? { size }

    public func read(_ range: Range<Int64>) async throws -> Data {
        let lower = max(0, min(range.lowerBound, size))
        let upper = max(lower, min(range.upperBound, size))
        guard upper > lower else { return Data() }
        return try lock.withLock {
            try handle.seek(toOffset: UInt64(lower))
            return try handle.read(upToCount: Int(upper - lower)) ?? Data()
        }
    }
}
