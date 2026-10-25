/*
 MatroskaRemux - reading clusters into frames

 Streams Clusters from a byte offset, in file order, and yields each block's
 frames with their track, timestamp and keyframe flag. Ported from the
 Jellyfin plugin's `MatroskaPackets` (unknown-size Segment/Cluster, the
 cluster Timestamp, SimpleBlock and BlockGroup) and extended with:

 - lacing: Xiph, EBML and fixed-size. Laced frames share the block's one
   timestamp; the caller gives them their own from the codec's frame
   lengths;
 - BlockGroup's keyframe rule (no ReferenceBlock) and BlockDuration;
 - header stripping: the bytes a track's ContentCompression (algorithm 3)
   took off the front of every frame are put back;
 - an unknown-size Cluster ends at the next level-1 element, the way a live
   WebM (MediaRecorder output) is written;
 - Void and CRC-32 elements, and anything else unknown, are skipped;
 - tracks nobody asked for are skipped without copying their frames, and a
   header-only mode (for indexing a file without Cues) skips every body.
 */

import Foundation

struct MatroskaFrame {
    var track: UInt64
    /// The block's timestamp, in ticks; every frame of a lace has it.
    var blockTimestamp: Int64
    var laceIndex: Int
    var laceCount: Int
    var isKeyframe: Bool
    /// BlockDuration in ticks, when the block is in a BlockGroup that has one.
    var blockDuration: Int64?
    /// Empty in header-only mode.
    var data: [UInt8]
    /// Offset of the Cluster holding the block.
    var clusterPosition: Int64
    /// Offset of the block element.
    var position: Int64
}

/// Buffered reading from a source, in file order, with skipping.
struct ByteCursor {
    let source: any ByteSource
    /// Nothing at or past this offset is read.
    let limit: Int64
    var chunkSize: Int
    private(set) var buffer: [UInt8] = []
    private(set) var bufferStart: Int64
    var position: Int64
    private(set) var bytesFetched: Int64 = 0

    init(source: any ByteSource, start: Int64, limit: Int64, chunkSize: Int = 1 << 20) {
        self.source = source
        self.limit = limit
        self.chunkSize = chunkSize
        bufferStart = start
        position = start
    }

    var bufferEnd: Int64 { bufferStart + Int64(buffer.count) }
    var available: Int { Int(max(0, bufferEnd - position)) }

    /// Makes up to `count` bytes from `position` available; true when all
    /// `count` are.
    mutating func need(_ count: Int) async throws -> Bool {
        if bufferEnd - position >= count { return true }
        if position >= bufferEnd {
            buffer.removeAll(keepingCapacity: true)
            bufferStart = position
        } else if position > bufferStart {
            buffer.removeFirst(Int(position - bufferStart))
            bufferStart = position
        }
        while bufferEnd - position < count {
            let from = bufferEnd
            guard from < limit else { return false }
            let want = max(chunkSize, count - Int(bufferEnd - position))
            let to = min(limit, from + Int64(want))
            let data = try await source.read(from ..< to)
            guard !data.isEmpty else { return false }
            bytesFetched += Int64(data.count)
            buffer.append(contentsOf: data)
        }
        return true
    }

    func index(of offset: Int64) -> Int { Int(offset - bufferStart) }

    /// An element header at `position`, without consuming it.
    mutating func peekElement() async throws -> (id: UInt32, size: UInt64?, headerLength: Int)? {
        _ = try await need(12)
        let start = index(of: position)
        guard let (id, idLength) = EBML.id(buffer, at: start, end: buffer.count),
              let (size, sizeLength) = EBML.size(buffer, at: start + idLength, end: buffer.count) else { return nil }
        return (id, size, idLength + sizeLength)
    }

    func bytes(_ count: Int) -> ArraySlice<UInt8> {
        let start = index(of: position)
        return buffer[start ..< start + count]
    }
}

struct ClusterReader {
    enum Mode {
        /// Copy the frame's bytes.
        case frames
        /// Read only the block header (for indexing).
        case headers
    }

    var cursor: ByteCursor
    /// Tracks to deliver, and how; any other track's blocks are skipped.
    let modes: [UInt64: Mode]
    /// Header-stripping prefixes by track.
    let strippedHeaders: [UInt64: [UInt8]]

    private var clusterTimestamp: Int64 = 0
    private var clusterPosition: Int64 = -1
    private var clusterEnd: Int64?
    private var inCluster = false
    private var pending: [MatroskaFrame] = []

    init(source: any ByteSource, start: Int64, limit: Int64, chunkSize: Int = 1 << 20,
         modes: [UInt64: Mode], strippedHeaders: [UInt64: [UInt8]] = [:]) {
        cursor = ByteCursor(source: source, start: start, limit: limit, chunkSize: chunkSize)
        self.modes = modes
        self.strippedHeaders = strippedHeaders
    }

    /// Where the next element starts.
    var position: Int64 { cursor.position }
    var bytesFetched: Int64 { cursor.bytesFetched }
    /// The Cluster the reader is in, if any.
    var currentClusterPosition: Int64? { inCluster ? clusterPosition : nil }

    /// The next frame of a wanted track, or nil at the end of the data.
    mutating func next() async throws -> MatroskaFrame? {
        while true {
            if !pending.isEmpty { return pending.removeFirst() }
            guard try await step() else { return nil }
        }
    }

    /// Reads one element; false at the end.
    private mutating func step() async throws -> Bool {
        if inCluster, let end = clusterEnd, cursor.position >= end { inCluster = false }
        guard let (id, size, headerLength) = try await cursor.peekElement() else { return false }
        let start = cursor.position
        let bodyStart = start + Int64(headerLength)

        if !inCluster || (clusterEnd == nil && MatroskaID.topLevel.contains(id)) {
            inCluster = false
            switch id {
            case MatroskaID.cluster:
                inCluster = true
                clusterPosition = start
                clusterEnd = size.map { bodyStart + Int64($0) }
                clusterTimestamp = 0
                cursor.position = bodyStart
            case MatroskaID.segment:
                // A chained Segment: step into it.
                cursor.position = bodyStart
            default:
                guard let size else { return false } // an unknown-size element we can't skip
                cursor.position = bodyStart + Int64(size)
            }
            return true
        }

        guard let size else {
            // Only Cluster and Segment may have unknown sizes.
            throw RemuxError.malformed("unknown-size element \(String(id, radix: 16)) in a cluster")
        }
        let bodyLength = Int(size)
        switch id {
        case MatroskaID.clusterTimestamp:
            guard try await cursor.need(headerLength + bodyLength) else { return false }
            let i = cursor.index(of: bodyStart)
            clusterTimestamp = Int64(clamping: EBML.uint(cursor.buffer, i ..< i + bodyLength))
            cursor.position = bodyStart + Int64(bodyLength)
        case MatroskaID.simpleBlock:
            try await readBlock(bodyStart: bodyStart, length: bodyLength, simple: true, blockStart: start,
                                duration: nil, isKeyframe: nil)
            cursor.position = bodyStart + Int64(bodyLength)
        case MatroskaID.blockGroup:
            try await readBlockGroup(bodyStart: bodyStart, length: bodyLength, blockStart: start)
            cursor.position = bodyStart + Int64(bodyLength)
        default:
            cursor.position = bodyStart + Int64(bodyLength)
        }
        return true
    }

    private mutating func readBlockGroup(bodyStart: Int64, length: Int, blockStart: Int64) async throws {
        // The whole group in the buffer, then its Block, ReferenceBlock and
        // BlockDuration children read from there. (BlockGroups are rare for
        // large frames; muxers use SimpleBlocks for those.)
        cursor.position = blockStart
        guard try await cursor.need(Int(bodyStart - blockStart) + length) else { return }
        let buffer = cursor.buffer
        var p = cursor.index(of: bodyStart)
        let end = p + length
        var block: (start: Int64, length: Int)?
        var hasReference = false
        var duration: Int64?
        while p < end, let (id, idLength) = EBML.id(buffer, at: p, end: end),
              let (sizeRaw, sizeLength) = EBML.size(buffer, at: p + idLength, end: end), let size = sizeRaw {
            let childBody = p + idLength + sizeLength
            guard childBody + Int(size) <= end else { break }
            switch id {
            case MatroskaID.block:
                block = (cursor.bufferStart + Int64(childBody), Int(size))
            case MatroskaID.referenceBlock:
                hasReference = true
            case MatroskaID.blockDuration:
                duration = Int64(clamping: EBML.uint(buffer, childBody ..< childBody + Int(size)))
            default: break
            }
            p = childBody + Int(size)
        }
        guard let block else { return }
        try await readBlock(bodyStart: block.start, length: block.length, simple: false, blockStart: blockStart,
                            duration: duration, isKeyframe: !hasReference)
    }

    private mutating func readBlock(bodyStart: Int64, length: Int, simple: Bool, blockStart: Int64,
                                    duration: Int64?, isKeyframe: Bool?) async throws {
        cursor.position = bodyStart
        guard try await cursor.need(min(length, 16)) else { return }
        var i = cursor.index(of: bodyStart)
        guard let (trackRaw, trackLength) = EBML.size(cursor.buffer, at: i, end: cursor.buffer.count),
              let track = trackRaw, let mode = modes[track], length >= trackLength + 3 else { return }
        i += trackLength
        let relative = Int64(Int16(bitPattern: UInt16(cursor.buffer[i]) << 8 | UInt16(cursor.buffer[i + 1])))
        let flags = cursor.buffer[i + 2]
        i += 3
        let keyframe = isKeyframe ?? (flags & 0x80 != 0)
        let timestamp = clusterTimestamp + relative
        let lacing = (flags >> 1) & 3

        if mode == .headers {
            pending.append(MatroskaFrame(track: track, blockTimestamp: timestamp, laceIndex: 0, laceCount: 1,
                                         isKeyframe: keyframe, blockDuration: duration, data: [],
                                         clusterPosition: clusterPosition, position: blockStart))
            return
        }

        guard try await cursor.need(length) else { return }
        // Re-derive after `need`, which may have moved the buffer.
        let blockEnd = cursor.index(of: bodyStart) + length
        var p = cursor.index(of: bodyStart) + trackLength + 3
        let buffer = cursor.buffer
        var sizes: [Int] = []
        if lacing != 0 {
            guard p < blockEnd else { return }
            let count = Int(buffer[p]) + 1
            p += 1
            switch lacing {
            case 1: // Xiph
                for _ in 0 ..< count - 1 {
                    var size = 0
                    while p < blockEnd {
                        let byte = Int(buffer[p])
                        p += 1
                        size += byte
                        if byte != 255 { break }
                    }
                    sizes.append(size)
                }
            case 3: // EBML
                guard let (first, firstLength) = EBML.size(buffer, at: p, end: blockEnd), let first else { return }
                p += firstLength
                var size = Int(first)
                sizes.append(size)
                for _ in 1 ..< max(1, count - 1) where count > 2 {
                    guard let (delta, deltaLength) = EBML.signedVint(buffer, at: p, end: blockEnd) else { return }
                    p += deltaLength
                    size += Int(delta)
                    sizes.append(size)
                }
            default: // fixed
                let each = (blockEnd - p) / count
                sizes = Array(repeating: each, count: count - 1)
            }
            let used = sizes.reduce(0, +)
            guard used <= blockEnd - p, sizes.allSatisfy({ $0 >= 0 }) else { return }
            sizes.append(blockEnd - p - used)
        } else {
            sizes = [blockEnd - p]
        }
        let prefix = strippedHeaders[track] ?? []
        for (index, size) in sizes.enumerated() {
            pending.append(MatroskaFrame(track: track, blockTimestamp: timestamp, laceIndex: index,
                                         laceCount: sizes.count, isKeyframe: keyframe && index == 0,
                                         blockDuration: duration, data: prefix + buffer[p ..< p + size],
                                         clusterPosition: clusterPosition, position: blockStart))
            p += size
        }
    }
}
