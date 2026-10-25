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

/// A server's file with the ends of its recent reads kept, so a read that
/// starts where an earlier one ended takes those bytes from memory.
///
/// That is how segments are read: a segment's parse reads a little past its
/// last cluster (audio stored after the next keyframe), and the next
/// segment's parse starts at that cluster; `open`'s probe reads the first
/// segment's start in small steps too. Without this, those bytes crossed the
/// network twice: 4 % of a 1080p file, 13 % of a UHD one (measured over HTTP).
/// Only the front of a read is served from memory; the rest is one request.
final class RecentReadsSource: ByteSource, @unchecked Sendable {
    let base: any ByteSource
    /// The most bytes kept from the end of one read.
    private let tailLength: Int
    /// The most bytes kept in all.
    private let capacity: Int
    private let lock = NSLock()
    /// Oldest first.
    private var kept: [(start: Int64, data: Data)] = []

    init(base: any ByteSource, tailLength: Int = 8 << 20, capacity: Int = 24 << 20) {
        self.base = base
        self.tailLength = tailLength
        self.capacity = capacity
    }

    var isLocal: Bool { base.isLocal }

    func length() async throws -> Int64? { try await base.length() }

    func read(_ range: Range<Int64>) async throws -> Data {
        var result = Data()
        var position = range.lowerBound
        while position < range.upperBound, let piece = keptBytes(at: position, before: range.upperBound) {
            result.append(piece)
            position += Int64(piece.count)
        }
        guard position < range.upperBound else { return result }
        let fetched = try await base.read(position ..< range.upperBound)
        keep(fetched, at: position)
        if result.isEmpty { return fetched }
        result.append(fetched)
        return result
    }

    /// Kept bytes from `position` on (up to `end`), if any piece holds it.
    private func keptBytes(at position: Int64, before end: Int64) -> Data? {
        lock.withLock {
            guard let index = kept.lastIndex(where: { $0.start <= position && position < $0.start + Int64($0.data.count) })
            else { return nil }
            let piece = kept[index]
            let from = Int(position - piece.start)
            let to = Int(min(end, piece.start + Int64(piece.data.count)) - piece.start)
            // Used again: now the newest.
            kept.remove(at: index)
            kept.append(piece)
            return piece.data.subdata(in: piece.data.startIndex + from ..< piece.data.startIndex + to)
        }
    }

    private func keep(_ data: Data, at start: Int64) {
        guard !data.isEmpty else { return }
        let count = min(data.count, tailLength)
        // A copy: a slice would hold on to the whole read (a UHD segment).
        let tail = data.subdata(in: data.endIndex - count ..< data.endIndex)
        lock.withLock {
            kept.append((start + Int64(data.count - count), tail))
            var total = kept.reduce(0) { $0 + $1.data.count }
            while total > capacity, kept.count > 1 {
                total -= kept.removeFirst().data.count
            }
        }
    }
}
