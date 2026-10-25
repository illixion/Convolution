import Foundation
import Testing
@testable import MatroskaRemux

/// A server file is read once: the bytes a segment read past its end are
/// not fetched again for the next segment, and an audio rendition that
/// trails its video doesn't read the segment's video again.
@Suite("Reading a server's file")
struct StreamingTests {
    @Test func recentReadsServeTheFrontOfARead() async throws {
        let bytes = Data((0 ..< 4096).map { UInt8($0 % 251) })
        let counting = CountingSource(DataByteSource(bytes))
        let source = RecentReadsSource(base: counting, tailLength: 1024, capacity: 4096)
        #expect(try await source.read(0 ..< 2048) == bytes.subdata(in: 0 ..< 2048))
        // Starts inside the last 1 KB of the first read: only the rest is fetched.
        #expect(try await source.read(1536 ..< 3000) == bytes.subdata(in: 1536 ..< 3000))
        // Starts before what was kept: fetched whole.
        #expect(try await source.read(100 ..< 200) == bytes.subdata(in: 100 ..< 200))
        #expect(counting.ranges == [0 ..< 2048, 2048 ..< 3000, 100 ..< 200])
    }

    @Test func everySegmentOfAServerFileReadsItsBytesOnce() async throws {
        for name in ["h264-bframes-aac.mkv", "two-audio.mkv", "vp9-opus.webm"] {
            let counting = CountingSource(try Fixtures.source(name))
            let session = try await RemuxSession.open(source: counting)
            let opened = counting.ranges.count
            for k in 0 ..< session.segmentCount {
                _ = try await session.data(at: "video/\(k).m4s")
                for track in session.summary.audio { _ = try await session.data(at: "audio-\(track.number)/\(k).m4s") }
                _ = try await session.data(at: "muxed/\(k).m4s")
            }
            let segmentReads = Array(counting.ranges.dropFirst(opened))
            let total = segmentReads.reduce(0) { $0 + $1.count }
            #expect(total == Self.union(segmentReads), "\(name): \(segmentReads)")
        }
    }

    @Test func audioTrailingItsVideoIsNotReadAgain() async throws {
        var options = RemuxOptions()
        options.cachedSegments = 1
        options.cachedBytes = 1
        let session = try await Fixtures.open("h264-bframes-aac.mkv", options: options)
        try #require(session.segmentCount >= 2)
        let audio = try #require(session.summary.audio.first).number
        _ = try await session.data(at: "video/0.m4s")
        _ = try await session.data(at: "video/1.m4s")
        let read = await session.bytesRead
        // Segment 0's parse is gone (one kept), its audio isn't.
        _ = try await session.data(at: "audio-\(audio)/0.m4s")
        #expect(await session.bytesRead == read)
        // Its video is.
        _ = try await session.data(at: "video/0.m4s")
        #expect(await session.bytesRead > read)
    }

    static func union(_ ranges: [Range<Int64>]) -> Int64 {
        var total: Int64 = 0
        var current: Range<Int64>?
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let open = current, range.lowerBound <= open.upperBound {
                current = open.lowerBound ..< max(open.upperBound, range.upperBound)
            } else {
                total += Int64(current?.count ?? 0)
                current = range
            }
        }
        return total + Int64(current?.count ?? 0)
    }
}

/// A source that isn't local, recording each range read from it, each
/// read taking `latency` (a server's round trip).
final class CountingSource: ByteSource, @unchecked Sendable {
    let base: any ByteSource
    let latency: Duration
    private let lock = NSLock()
    private var log: [Range<Int64>] = []

    init(_ base: any ByteSource, latency: Duration = .zero) {
        self.base = base
        self.latency = latency
    }

    var ranges: [Range<Int64>] { lock.withLock { log } }
    var isLocal: Bool { false }

    func length() async throws -> Int64? { try await base.length() }

    func read(_ range: Range<Int64>) async throws -> Data {
        if latency > .zero { try await Task.sleep(for: latency) }
        let data = try await base.read(range)
        lock.withLock { log.append(range.lowerBound ..< range.lowerBound + Int64(data.count)) }
        return data
    }
}
