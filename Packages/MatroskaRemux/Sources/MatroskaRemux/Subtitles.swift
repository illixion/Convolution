/*
 MatroskaRemux - a file's subtitle tracks, read near the playhead

 Subtitles don't go into the HLS: the app draws them itself (its players
 own their pictures, and a stereo picture needs them in both eyes), so a
 session hands it each track's blocks, timed on the remux's timeline, which
 is the player's clock.

 They are read like the video, a little at a time and never the whole
 file. mkvmerge and ffmpeg put every subtitle block in the Cues (a cue point
 per block, with CueRelativePosition), so the blocks near the playhead are
 read on their own, a few kilobytes each, wherever they sit in the file.
 Without that index a track gets the blocks of the segments the player
 fetches (every parse keeps the subtitle blocks it passes), which covers
 what plays; both feed the same store.
 */

import Foundation

public struct MatroskaSubtitleTrack: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        /// S_TEXT/UTF8: SubRip text, the cue's lines with <i>/<b> tags.
        case subRip
        /// S_TEXT/ASS or SSA: a Dialogue line's fields after its times.
        case ass
        /// S_TEXT/WEBVTT, WebM's D_WEBVTT: a WebVTT cue's payload.
        case webVTT
        /// S_HDMV/PGS: a display set's segments, without the .sup headers.
        case pgs
        case unsupported
    }

    public var number: UInt64
    public var codecID: String
    public var format: Format
    /// BCP 47; nil when undetermined.
    public var language: String?
    public var name: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// Every block is in the Cues with its place in its cluster, so blocks
    /// near any time can be read alone.
    public var isIndexed: Bool
    /// Why it can't be shown, when it can't (a format, an encryption).
    public var unsupportedReason: String?

    static func format(of codecID: String) -> Format {
        switch codecID {
        case "S_TEXT/UTF8", "S_TEXT/ASCII": .subRip
        case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA": .ass
        case "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS": .webVTT
        case "S_HDMV/PGS": .pgs
        default: .unsupported
        }
    }
}

public struct SubtitleBlock: Sendable, Equatable {
    /// Seconds on the remux's timeline.
    public var start: Double
    /// Seconds; nil when the block doesn't say (PGS runs until its next).
    public var duration: Double?
    /// The block's frame as the codec defines it (decompressed).
    public var data: [UInt8]
}

/// A subtitle block as a parse or an indexed read found it, before timing.
struct RawSubtitle: Sendable {
    var ticks: Int64
    var durationTicks: Int64?
    var data: [UInt8]
}

/// What a session knows of one subtitle track.
struct SubtitleStore {
    struct Key: Hashable {
        var ticks: Int64
        var data: [UInt8]
    }

    var blocks: [Key: RawSubtitle] = [:]
    /// Grows with every block added.
    var revision = 0
    /// Indexes into the track's cue points read or being read.
    var requested = Set<Int>()

    mutating func add(_ subtitle: RawSubtitle) {
        let key = Key(ticks: subtitle.ticks, data: subtitle.data)
        guard blocks[key] == nil else { return }
        blocks[key] = subtitle
        revision += 1
    }
}

enum SubtitleReading {
    /// Bytes read for a block before its size is known; text blocks fit.
    static let firstRead = 4096
    /// Reads in flight at once for one call.
    static let concurrency = 6

    /// The block a cue point names, read alone: the cluster's header for
    /// where its body starts (merged into one read when the block is near
    /// it), then the block.
    static func read(_ cue: CuePoint, track: MatroskaTrack, from source: any ByteSource) async throws -> RawSubtitle? {
        guard let relative = cue.relativePosition else { return nil }
        let cluster = cue.clusterPosition
        // A cluster header is 5–12 bytes: ID, then a size of 1–8.
        var head: [UInt8]
        let near = relative < 64 << 10
        head = [UInt8](try await source.read(cluster ..< cluster + 12 + (near ? relative + Int64(firstRead) : 0)))
        guard let (id, idLength) = EBML.id(head, at: 0, end: head.count), id == MatroskaID.cluster,
              let (_, sizeLength) = EBML.size(head, at: idLength, end: head.count) else { return nil }
        let blockStart = cluster + Int64(idLength + sizeLength) + relative
        var bytes: [UInt8]
        var offset: Int
        if near {
            bytes = head
            offset = Int(blockStart - cluster)
        } else {
            bytes = [UInt8](try await source.read(blockStart ..< blockStart + Int64(firstRead)))
            offset = 0
        }
        guard let (elementID, elementIDLength) = EBML.id(bytes, at: offset, end: bytes.count),
              let (sizeRaw, sizeLength) = EBML.size(bytes, at: offset + elementIDLength, end: bytes.count),
              let size = sizeRaw, size < 16 << 20 else { return nil }
        let bodyStart = offset + elementIDLength + sizeLength
        let bodyEnd = bodyStart + Int(size)
        if bodyEnd > bytes.count {
            let from = blockStart + Int64(bytes.count - offset)
            bytes += try await source.read(from ..< blockStart + Int64(bodyEnd - offset))
            guard bodyEnd <= bytes.count else { return nil }
        }
        let parsed: (block: Range<Int>, duration: Int64?)?
        switch elementID {
        case MatroskaID.simpleBlock: parsed = (bodyStart ..< bodyEnd, nil)
        case MatroskaID.blockGroup: parsed = blockGroup(bytes, bodyStart ..< bodyEnd)
        default: parsed = nil
        }
        guard let parsed, let payload = payload(bytes, parsed.block, track: track.number) else { return nil }
        guard let data = decoded(Array(bytes[payload]), track: track) else { return nil }
        return RawSubtitle(ticks: cue.time, durationTicks: parsed.duration, data: data)
    }

    /// A BlockGroup's Block and BlockDuration.
    static func blockGroup(_ bytes: [UInt8], _ body: Range<Int>) -> (block: Range<Int>, duration: Int64?)? {
        var p = body.lowerBound
        var block: Range<Int>?
        var duration: Int64?
        while p < body.upperBound, let (id, idLength) = EBML.id(bytes, at: p, end: body.upperBound),
              let (sizeRaw, sizeLength) = EBML.size(bytes, at: p + idLength, end: body.upperBound), let size = sizeRaw {
            let childBody = p + idLength + sizeLength
            guard childBody + Int(size) <= body.upperBound else { break }
            switch id {
            case MatroskaID.block: block = childBody ..< childBody + Int(size)
            case MatroskaID.blockDuration: duration = Int64(clamping: EBML.uint(bytes, childBody ..< childBody + Int(size)))
            default: break
            }
            p = childBody + Int(size)
        }
        return block.map { ($0, duration) }
    }

    /// A Block's frame: after its track number, timestamp and flags. Nil for
    /// another track's block or a laced one (subtitles aren't laced).
    static func payload(_ bytes: [UInt8], _ block: Range<Int>, track: UInt64) -> Range<Int>? {
        guard let (numberRaw, numberLength) = EBML.size(bytes, at: block.lowerBound, end: block.upperBound),
              numberRaw == track, block.count >= numberLength + 3 else { return nil }
        let flags = bytes[block.lowerBound + numberLength + 2]
        guard (flags >> 1) & 3 == 0 else { return nil }
        return block.lowerBound + numberLength + 3 ..< block.upperBound
    }

    /// The frame as the codec wrote it: a stripped header put back, zlib
    /// undone. Nil when it can't be.
    static func decoded(_ frame: [UInt8], track: MatroskaTrack) -> [UInt8]? {
        var frame = track.strippedHeader + frame
        for encoding in track.contentEncodings.sorted(by: { $0.order > $1.order }) where encoding.scope & 1 != 0 {
            switch (encoding.type, encoding.compressionAlgorithm) {
            case (0, 3): continue // the stripped header, put back above
            case (0, 0): guard let inflated = inflate(frame) else { return nil }
                frame = inflated
            default: return nil
            }
        }
        return frame
    }

    /// zlib (RFC 1950) data inflated: Foundation's zlib is the raw DEFLATE
    /// inside, after the two-byte header.
    static func inflate(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 2, data[0] & 0x0F == 8 else { return nil }
        let raw = Data(data[2...])
        guard let inflated = try? (raw as NSData).decompressed(using: .zlib) else { return nil }
        return [UInt8](inflated as Data)
    }

    /// Why a track's blocks can't be read, if they can't.
    static func unreadableEncoding(_ track: MatroskaTrack) -> String? {
        for encoding in track.contentEncodings {
            if encoding.type == 1 { return "encrypted" }
            if encoding.type == 0, encoding.compressionAlgorithm != 0, encoding.compressionAlgorithm != 3 {
                return "compressed"
            }
        }
        return nil
    }
}

extension Array {
    /// The first index whose element satisfies `predicate`, which is false
    /// and then true along the array (a binary search); `count` if none.
    func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
