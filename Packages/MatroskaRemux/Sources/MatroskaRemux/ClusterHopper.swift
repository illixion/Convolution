/*
 MatroskaRemux - a file without Cues, indexed from cluster to cluster

 Every Cluster states its size, so the next one's position is known from
 its header: hopping reads a few hundred bytes per cluster, never a frame
 body, which is how a server's file without Cues is indexed without
 reading it.

 What a hop reads at each cluster: its Timestamp and its blocks' headers up
 to the first block of the video track, which says whether the cluster
 starts on a keyframe (the segment boundaries the index is cut at). Both
 muxers that matter start a cluster at each video keyframe, but put
 different things ahead of it (measured on ffmpeg 8 and mkvmerge 100):
 ffmpeg an audio block or two (1.5 KB of AC-3 at 384 kb/s), mkvmerge
 nothing, or an 8-frame audio lace (13 KB) ahead of a non-keyframe. So the
 first read's length follows what the last few clusters needed (64 B to
 4 KB), and a block ahead of the video that doesn't fit is hopped over by
 its size: a second small read where its header ends, not its body.

 Those heads are all the index reads, and the segments read them again
 with the rest of their clusters: 40 to 1,700 bytes a cluster, 0.1 % of a
 1080p film's bytes.

 A keyframe that isn't its cluster's first video block isn't found, which
 only makes segments longer: the boundaries are the keyframes found.
 A cluster of unknown size (a live MediaRecorder WebM) can't be hopped
 over; the caller is told and declines.
 */

import Foundation

struct ClusterHead: Sendable, Equatable {
    struct VideoBlock: Sendable, Equatable {
        /// In ticks.
        var time: Int64
        var isKeyframe: Bool
    }

    var position: Int64
    /// Where the next element starts.
    var end: Int64
    /// In ticks; nil when the cluster doesn't start with one.
    var timestamp: Int64?
    /// The cluster's first block of the video track, when its header was
    /// within reach (and the cluster has video).
    var firstVideo: VideoBlock?
}

struct ClusterHopper {
    enum Step: Equatable {
        case cluster(ClusterHead)
        /// The data ends here (the content's end, a short read, or bytes that
        /// aren't an element: a truncated or damaged file).
        case end(Int64)
        /// A cluster of unknown size at this offset.
        case unknownSize(Int64)
    }

    let source: any ByteSource
    /// Nothing at or past this offset is read.
    let limit: Int64
    let videoTrack: UInt64
    private(set) var position: Int64
    private(set) var requests = 0
    private(set) var bytesFetched: Int64 = 0

    /// Bytes read at a cluster's start.
    private(set) var window = 1024
    /// How far into each recent cluster its first video block's header ended.
    private var recentNeeds: [Int] = []
    /// Bytes read where a block ahead of the video ends.
    static let refill = 1024
    /// Reads per cluster before giving up on finding its video.
    static let maximumReads = 8

    private var buffer: [UInt8] = []
    private var bufferStart: Int64 = 0

    init(source: any ByteSource, start: Int64, limit: Int64, videoTrack: UInt64) {
        self.source = source
        self.limit = limit
        self.videoTrack = videoTrack
        position = start
    }

    private var bufferEnd: Int64 { bufferStart + Int64(buffer.count) }

    /// Makes `count` bytes from `offset` available (fewer where `end`
    /// comes first), reading `length` bytes from `offset` if they aren't;
    /// false when the source has less.
    private mutating func ensure(_ offset: Int64, _ count: Int, before end: Int64, reading length: Int) async throws -> Bool {
        let wanted = Int(min(Int64(count), end - offset))
        guard wanted > 0 else { return false }
        if offset >= bufferStart, offset + Int64(wanted) <= bufferEnd { return true }
        let upper = min(end, offset + Int64(max(length, wanted)))
        let data = try await source.read(offset ..< upper)
        requests += 1
        bytesFetched += Int64(data.count)
        buffer = [UInt8](data)
        bufferStart = offset
        return buffer.count >= wanted
    }

    private func index(_ offset: Int64) -> Int { Int(offset - bufferStart) }

    /// An element header at `offset` (in the buffer).
    private func header(at offset: Int64) -> (id: UInt32, size: UInt64?, length: Int)? {
        let i = index(offset)
        guard let (id, idLength) = EBML.id(buffer, at: i, end: buffer.count),
              let (size, sizeLength) = EBML.size(buffer, at: i + idLength, end: buffer.count) else { return nil }
        return (id, size, idLength + sizeLength)
    }

    /// The next cluster, or where the hopping stops.
    mutating func next() async throws -> Step {
        while position < limit {
            guard try await ensure(position, 12, before: limit, reading: window),
                  let (id, size, headerLength) = header(at: position) else { return .end(position) }
            let bodyStart = position + Int64(headerLength)
            if id == MatroskaID.cluster {
                guard let size else { return .unknownSize(position) }
                let end = bodyStart + Int64(size)
                let head = try await readHead(at: position, bodyStart: bodyStart, end: end)
                position = end
                return .cluster(head)
            }
            // Cues, Tags, Void… between clusters are stepped over.
            guard let size, MatroskaID.topLevel.contains(id) || id == MatroskaID.void || id == MatroskaID.crc32,
                  id != MatroskaID.segment, id != MatroskaID.ebml else { return .end(position) }
            position = bodyStart + Int64(size)
        }
        return .end(position)
    }

    private mutating func readHead(at start: Int64, bodyStart: Int64, end clusterEnd: Int64) async throws -> ClusterHead {
        var head = ClusterHead(position: start, end: clusterEnd, timestamp: nil, firstVideo: nil)
        let end = min(clusterEnd, limit)
        let firstRequest = requests
        var p = bodyStart
        while p < end, requests - firstRequest < Self.maximumReads {
            guard try await ensure(p, 12, before: end, reading: Self.refill),
                  let (id, sizeValue, headerLength) = header(at: p), let size = sizeValue else { break }
            let body = p + Int64(headerLength)
            switch id {
            case MatroskaID.clusterTimestamp:
                guard size <= 8, try await ensure(body, Int(size), before: end, reading: Self.refill) else { break }
                let i = index(body)
                head.timestamp = Int64(clamping: EBML.uint(buffer, i ..< i + Int(size)))
            case MatroskaID.simpleBlock:
                guard let block = try await blockHeader(at: body, length: Int(clamping: size), end: end) else { break }
                if block.track == videoTrack {
                    if let timestamp = head.timestamp {
                        head.firstVideo = .init(time: timestamp + block.relative, isKeyframe: block.flags & 0x80 != 0)
                    }
                    note(need: Int(body - start) + block.headerLength)
                    return head
                }
            case MatroskaID.blockGroup:
                if let video = try await groupVideoBlock(body: body, size: Int64(size), end: end) {
                    if let timestamp = head.timestamp {
                        head.firstVideo = .init(time: timestamp + video.relative, isKeyframe: video.isKeyframe)
                    }
                    note(need: Int(min(body + Int64(size), body + 64) - start))
                    return head
                }
            default:
                break
            }
            p = body + Int64(size)
        }
        return head
    }

    /// A Block's track, relative timestamp and flags.
    private mutating func blockHeader(at body: Int64, length: Int, end: Int64) async throws
        -> (track: UInt64, relative: Int64, flags: UInt8, headerLength: Int)? {
        guard try await ensure(body, min(length, 11), before: end, reading: Self.refill) else { return nil }
        let i = index(body)
        guard let (trackRaw, trackLength) = EBML.size(buffer, at: i, end: buffer.count), let track = trackRaw,
              length >= trackLength + 3, i + trackLength + 3 <= buffer.count else { return nil }
        let relative = Int64(Int16(bitPattern: UInt16(buffer[i + trackLength]) << 8 | UInt16(buffer[i + trackLength + 1])))
        return (track, relative, buffer[i + trackLength + 2], trackLength + 3)
    }

    /// A BlockGroup's Block, when it is the video's: keyframe unless the
    /// group has a ReferenceBlock (after the Block, so past its body).
    private mutating func groupVideoBlock(body: Int64, size: Int64, end clusterEnd: Int64) async throws
        -> (relative: Int64, isKeyframe: Bool)? {
        let end = min(body + size, clusterEnd)
        var q = body
        var video: Int64?
        var hasReference = false
        while q < end {
            guard try await ensure(q, 12, before: end, reading: Self.refill),
                  let (id, sizeValue, headerLength) = header(at: q), let childSize = sizeValue else { break }
            let childBody = q + Int64(headerLength)
            if id == MatroskaID.block {
                guard let block = try await blockHeader(at: childBody, length: Int(clamping: childSize), end: end),
                      block.track == videoTrack else { return nil }
                video = block.relative
            } else if id == MatroskaID.referenceBlock {
                hasReference = true
            }
            q = childBody + Int64(childSize)
        }
        return video.map { ($0, !hasReference) }
    }

    /// Sizes the next first read to what the last few clusters needed. A
    /// cluster that needed more than the largest first read (a long lace
    /// ahead of the video) needs a second read anyway, so it doesn't count.
    private mutating func note(need: Int) {
        recentNeeds.append(need)
        if recentNeeds.count > 4 { recentNeeds.removeFirst() }
        let largest = recentNeeds.filter { $0 <= Self.largestWindow }.max() ?? 0
        window = min(Self.largestWindow, max(64, largest + 32))
    }

    static let largestWindow = 4096
}
