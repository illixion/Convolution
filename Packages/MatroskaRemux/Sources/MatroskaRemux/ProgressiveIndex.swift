/*
 MatroskaRemux - the index of a server's file without Cues, built while it
 plays

 A local file without Cues is scanned before `open` returns; a server's
 can't be (that would read all of it), so it is hopped over cluster by
 cluster (`ClusterHopper`), a few hundred bytes a cluster, in the
 background. `open` waits for the first few segments, and for the whole
 index too if it will be done within `RemuxOptions.indexWait` at the rate
 it is going (a 2-hour file is 1,500 to 3,600 clusters, a round trip each).

 An index finished before `open` returns is published as VOD, the same as
 one from Cues. One still growing is published as an EVENT playlist that
 starts at 0 (`Playlists`): AVPlayer reloads it every target duration, and
 plays a seek past what is listed once a reload lists it (measured on
 macOS 27);
 `EXT-X-ENDLIST` goes on when the index is done, and the player's duration
 turns from indefinite to the file's. A segment, once listed, never
 changes (`SegmentIndex.Builder` commits a boundary only once no later
 keyframe could move it), and the target duration stays what it was at
 `open` even if a later segment is longer (AVPlayer plays an over-long
 EVENT segment; measured).

 Reads go to the source directly, not through `RecentReadsSource`, whose
 kept tails are for the segments' reads. A failed read is retried a few
 times; an index that fails before `open` returns fails the open, one that
 fails after it stays as far as it got.
 */

import Foundation

/// A segment index that may still grow, shared by the session and its
/// indexing task.
final class SegmentIndexStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SegmentIndex
    private var isPublished = false
    private var failure: (any Error)?
    /// The index was complete when published: its playlists are VOD.
    private(set) var completeWhenPublished = true
    /// How far into the clusters the indexing is, 0 to 1.
    private var fraction = 0.0

    init(_ index: SegmentIndex) { value = index }

    var current: SegmentIndex { lock.withLock { value } }
    var error: (any Error)? { lock.withLock { failure } }
    var progress: Double { lock.withLock { fraction } }

    func noteProgress(_ progress: Double) { lock.withLock { fraction = progress } }

    func update(_ index: SegmentIndex) { lock.withLock { value = index } }

    func fail(_ error: any Error) { lock.withLock { failure = error } }

    /// The final index from `builder`; a short last segment joins the one
    /// before unless that one has been listed ending where it starts.
    func finish(_ builder: SegmentIndex.Builder, endTime: Int64, endPosition: Int64) {
        var builder = builder
        lock.withLock {
            value = builder.finish(endTime: endTime, endPosition: endPosition, mergesSliver: !isPublished,
                                   listed: value.boundaries.count)
        }
    }

    /// Marks the index as handed out and returns it as it stands.
    func publish() -> SegmentIndex {
        lock.withLock {
            isPublished = true
            completeWhenPublished = value.isComplete
            return value
        }
    }
}

enum ProgressiveIndexing {
    /// Starts indexing `video`'s keyframes from the first cluster, the
    /// first keyframe (found by `open`'s probe) being the first boundary.
    static func start(store: SegmentIndexStore, source: any ByteSource, header: MatroskaHeader, firstCluster: Int64,
                      firstKeyframe: SegmentIndex.Boundary, video: MatroskaTrack, options: RemuxOptions) -> Task<Void, Never> {
        Task {
            do {
                try await run(store: store, source: source, header: header, firstCluster: firstCluster,
                              firstKeyframe: firstKeyframe, video: video, options: options)
            } catch {
                store.fail(error)
            }
        }
    }

    private static func run(store: SegmentIndexStore, source: any ByteSource, header: MatroskaHeader,
                            firstCluster: Int64, firstKeyframe: SegmentIndex.Boundary, video: MatroskaTrack,
                            options: RemuxOptions) async throws {
        let contentEnd = header.contentEnd ?? Int64.max
        var builder = SegmentIndex.Builder(timestampScale: header.timestampScale)
        builder.add(firstKeyframe)
        store.update(builder.snapshot(endPosition: contentEnd))
        var lastVideoCluster: Int64?
        var lastTimestamp: Int64 = firstKeyframe.time
        func take(_ head: ClusterHead) {
            if let block = head.firstVideo {
                lastVideoCluster = head.position
                if block.isKeyframe { builder.add(.init(time: block.time, clusterPosition: head.position)) }
            }
            if let timestamp = head.timestamp {
                lastTimestamp = max(lastTimestamp, timestamp)
                builder.scanned(through: timestamp)
            }
            if builder.boundaries.count != store.current.boundaries.count {
                store.update(builder.snapshot(endPosition: contentEnd))
            }
        }

        // The first cluster, here: its size says whether more chains pay.
        var first = ClusterHopper(source: source, start: firstCluster, limit: contentEnd, videoTrack: video.number)
        var stoppedAt: Int64
        switch try await retrying({ try await first.next() }) {
        case .cluster(let head):
            take(head)
            let starts = [head.end] + (await seeds(after: head.end, clusterBytes: head.end - head.position,
                                                   contentEnd: contentEnd, source: source, options: options))
            let progress = ChainProgress(starts: starts, firstCluster: firstCluster, contentEnd: contentEnd, store: store)
            stoppedAt = try await withThrowingTaskGroup(of: Void.self) { group in
                var streams: [AsyncThrowingStream<ChainEvent, any Error>] = []
                for chain in starts.indices {
                    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChainEvent.self)
                    streams.append(stream)
                    group.addTask {
                        await hop(chain: chain, starts: starts, source: source, limit: contentEnd,
                                  video: video.number, progress: progress, events: continuation)
                    }
                }
                // Chain 0's clusters, then those of each chain it reaches.
                var events = streams[0].makeAsyncIterator()
                while true {
                    guard let event = try await events.next() else { throw CancellationError() }
                    switch event {
                    case .head(let head):
                        take(head)
                    case .joined(let chain):
                        events = streams[chain].makeAsyncIterator()
                    case .end(let position):
                        group.cancelAll()
                        return position
                    }
                }
            }
        case .end(let position):
            stoppedAt = position
        case .unknownSize:
            throw RemuxError.declined("no Cues, clusters of unknown size, and the source is remote")
        }

        // The end: Info's Duration when the clusters ran to the content's
        // end (it covers every track); otherwise, or without one, the last
        // video frame, read from the last cluster that has video.
        var end: Int64?
        if stoppedAt >= contentEnd, let duration = header.duration { end = Int64(duration.rounded()) }
        if end == nil, let position = lastVideoCluster {
            end = try await retrying {
                try await RemuxSession.lastFrameTime(source: source, header: header, from: position, video: video)
            }
        }
        let last = builder.boundaries.last?.time ?? firstKeyframe.time
        store.finish(builder, endTime: max(end ?? lastTimestamp, last + 1), endPosition: contentEnd)
    }

    // MARK: - Chains

    /// What a chain of hops reports, in order.
    private enum ChainEvent: Sendable {
        case head(ClusterHead)
        /// It reached the cluster chain `chain` started at: the clusters from
        /// there on are that chain's.
        case joined(Int)
        /// The data ends here.
        case end(Int64)
    }

    /// Hops from `starts[chain]` until it reaches a later chain's start, or
    /// the end. A start it passes without landing on (a probe that took
    /// stray bytes for a Cluster) is a chain nobody follows.
    private static func hop(chain: Int, starts: [Int64], source: any ByteSource, limit: Int64, video: UInt64,
                            progress: ChainProgress,
                            events: AsyncThrowingStream<ChainEvent, any Error>.Continuation) async {
        var later: [Int64: Int] = [:]
        for (index, start) in starts.enumerated() where index > chain { later[start] = index }
        var hopper = ClusterHopper(source: source, start: starts[chain], limit: limit, videoTrack: video)
        do {
            while true {
                try Task.checkCancellation()
                if let next = later[hopper.position] {
                    events.yield(.joined(next))
                    break
                }
                switch try await retrying({ try await hopper.next() }) {
                case .cluster(let head):
                    events.yield(.head(head))
                    progress.note(chain: chain, at: head.end)
                case .end(let position):
                    events.yield(.end(position))
                    events.finish()
                    return
                case .unknownSize:
                    throw RemuxError.declined("no Cues, clusters of unknown size, and the source is remote")
                }
            }
            events.finish()
        } catch {
            events.finish(throwing: error)
        }
    }

    /// Where more chains start: one probe read at each of up to three more
    /// offsets, each the first Cluster at or after it. Only for a file of
    /// many clusters (a 2-hour film has 1,500 to 3,600: seconds of round
    /// trips one after the other) that aren't large (a probe reads twice a
    /// cluster's length, and the segments read those bytes again).
    static func seeds(after start: Int64, clusterBytes: Int64, contentEnd: Int64, source: any ByteSource,
                      options: RemuxOptions = RemuxOptions()) async -> [Int64] {
        guard contentEnd < Int64.max, contentEnd > start, clusterBytes > 0, clusterBytes <= 1 << 20 else { return [] }
        let span = contentEnd - start
        let chains = Int(min(Int64(max(1, options.indexChains)),
                             max(1, span / clusterBytes / max(1, options.clustersPerIndexChain))))
        guard chains > 1 else { return [] }
        let length = Int(min(2 << 20, max(128 << 10, 2 * clusterBytes)))
        let found = await withTaskGroup(of: Int64?.self) { group in
            for r in 1 ..< chains {
                let offset = start + span * Int64(r) / Int64(chains)
                group.addTask { try? await findCluster(in: source, from: offset, length: length, limit: contentEnd) }
            }
            var seeds: [Int64] = []
            for await seed in group { if let seed { seeds.append(seed) } }
            return seeds
        }
        return Set(found).filter { $0 > start }.sorted()
    }

    /// The first Cluster at or after `offset` within `length` bytes: its ID,
    /// a size that fits the file, and a Timestamp as its first child (after
    /// the CRC-32 ffmpeg puts first in every cluster of a .mkv).
    static func findCluster(in source: any ByteSource, from offset: Int64, length: Int, limit: Int64) async throws -> Int64? {
        let bytes = [UInt8](try await source.read(offset ..< min(limit, offset + Int64(length))))
        var i = 0
        while i + 24 <= bytes.count {
            defer { i += 1 }
            guard bytes[i] == 0x1F, bytes[i + 1] == 0x43, bytes[i + 2] == 0xB6, bytes[i + 3] == 0x75,
                  let (size, sizeLength) = EBML.size(bytes, at: i + 4, end: bytes.count), let size,
                  offset + Int64(i + 4 + sizeLength) + Int64(size) <= limit else { continue }
            var child = i + 4 + sizeLength
            if bytes[child] == 0xBF, bytes[child + 1] == 0x84 { child += 6 }
            guard bytes[child] == 0xE7, let (timestampSize, _) = EBML.size(bytes, at: child + 1, end: bytes.count),
                  let timestampSize, (1 ... 8).contains(timestampSize) else { continue }
            return offset + Int64(i)
        }
        return nil
    }

    /// How far the chains are, for `open`'s guess at when the index is done.
    private final class ChainProgress: @unchecked Sendable {
        private let lock = NSLock()
        /// Bytes each chain has hopped over.
        private var covered: [Int64]
        private let starts: [Int64]
        /// The first cluster, hopped before the chains started.
        private let before: Int64
        private let total: Double
        private let store: SegmentIndexStore

        init(starts: [Int64], firstCluster: Int64, contentEnd: Int64, store: SegmentIndexStore) {
            self.starts = starts
            covered = starts.map { _ in 0 }
            before = starts[0] - firstCluster
            total = contentEnd < Int64.max ? Double(max(1, contentEnd - firstCluster)) : 0
            self.store = store
        }

        func note(chain: Int, at position: Int64) {
            guard total > 0 else { return }
            let fraction: Double = lock.withLock {
                covered[chain] = position - starts[chain]
                return Double(before + covered.reduce(0, +)) / total
            }
            store.noteProgress(min(1, fraction))
        }
    }

    /// A read retried after a short wait, up to four times: a server
    /// dropping one request mid-index shouldn't end it.
    private static func retrying<T>(_ body: () async throws -> T) async throws -> T {
        var delay = 0.25
        for _ in 0 ..< 3 {
            do {
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RemuxError {
                throw error
            } catch {
                try await Task.sleep(for: .seconds(delay))
                delay *= 2
            }
        }
        return try await body()
    }
}
