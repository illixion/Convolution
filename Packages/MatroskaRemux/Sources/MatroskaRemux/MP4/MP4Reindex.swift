/*
 MatroskaRemux - an MP4 whose chunks are too big to stream, re-indexed

 An MP4's samples are stored in chunks: runs of one track's samples, back to
 back in the media box, each listed once in the track's chunk-offset table
 (`stco`/`co64`), with `stsc` saying how many samples each holds. Muxers
 write a chunk every second or so. Some encoders (MainConcept, in a camera
 or editor export) write a whole track as one chunk: 341 frames, 30 MB.

 AVFoundation on visionOS 27 plays such a file from a server unreliably:
 it fetches the whole file in one request and then, in about a third of
 plays, counts only the first second or two of it as loaded, waits for
 more and never asks for it (Vision Pro, 2026-11-16: 3 of 10 plays of that
 file from a plain HTTP server stalled at 1.5-3.5 s; 0 of 10 with the same
 samples in 1-second chunks; the Mac's AVFoundation played both every
 time). A seek only gets another second or two.

 So a file with an oversized chunk is played re-indexed: the same bytes,
 with each oversized chunk split at sample boundaries into chunks of about
 a second. Only `stsc` and the chunk offsets change; no sample moves, and
 nothing is decoded or re-encoded. Every other box is kept byte for byte.
 The new `moov` is usually larger (one offset per new chunk): a `free` or
 `skip` box straight after it absorbs the growth when it is big enough (the
 file that stalled had 10 KB of skip), else every chunk after the `moov` is
 shifted by it, in every track. A `moov` after the media needs no shift.

 The result is a `Plan`: the re-indexed file as pieces, new header bytes
 and byte ranges of the original, which the app serves over loopback while
 the original stays where it is (`ByteSource`, so a server's file is read
 only where the player asks).

 Declined (nil), leaving the file as it is: no `moov` or two, a fragmented
 file (`moof`, `mvex`: no chunk tables to speak of), compact sample sizes
 (`stz2`), tables that disagree with each other or point outside the file,
 boxes that hold absolute file offsets of their own (`saio` for encrypted
 samples, `iloc` in a `meta` box), and a file whose chunks are fine.
 */

import Foundation

public enum MP4Reindex {
    /// When a chunk is oversized, and what it is split into.
    public struct Policy: Sendable {
        /// A chunk holding more bytes than this is split.
        public var maxChunkBytes: Int64
        /// Or one spanning more media time than this, in seconds.
        public var maxChunkSeconds: Double
        /// A split chunk ends at the sample that reaches either target.
        public var targetChunkBytes: Int64
        public var targetChunkSeconds: Double
        /// The largest `moov` read.
        public var maxMovieBytes: Int64

        public init(maxChunkBytes: Int64 = 8 << 20, maxChunkSeconds: Double = 4,
                    targetChunkBytes: Int64 = 2 << 20, targetChunkSeconds: Double = 1,
                    maxMovieBytes: Int64 = 64 << 20) {
            self.maxChunkBytes = maxChunkBytes
            self.maxChunkSeconds = maxChunkSeconds
            self.targetChunkBytes = targetChunkBytes
            self.targetChunkSeconds = targetChunkSeconds
            self.maxMovieBytes = maxMovieBytes
        }

        public static let standard = Policy()
    }

    /// The re-indexed file.
    public struct Plan: Sendable {
        public enum Piece: Sendable, Equatable {
            /// Bytes made here (the new `moov`, a shrunk `free`).
            case bytes(Data)
            /// A range of the original file, served as it is.
            case original(Range<Int64>)

            public var count: Int64 {
                switch self {
                case .bytes(let data): Int64(data.count)
                case .original(let range): range.upperBound - range.lowerBound
                }
            }
        }

        /// In file order; each starts where the one before ends.
        public let pieces: [Piece]
        public let length: Int64
        public let summary: Summary

        /// What serves `range` of the re-indexed file, in order: made bytes
        /// cut to the range, and ranges of the original.
        public func pieces(for range: Range<Int64>) -> [Piece] {
            var out: [Piece] = []
            var start: Int64 = 0
            for piece in pieces {
                let end = start + piece.count
                defer { start = end }
                let lower = max(range.lowerBound, start)
                let upper = min(range.upperBound, end)
                guard lower < upper else { continue }
                switch piece {
                case .bytes(let data):
                    let from = data.startIndex + Int(lower - start)
                    out.append(.bytes(data.subdata(in: from ..< from + Int(upper - lower))))
                case .original(let source):
                    out.append(.original(source.lowerBound + (lower - start) ..< source.lowerBound + (upper - start)))
                }
            }
            return out
        }
    }

    public struct Summary: Sendable, Equatable {
        public var tracks: Int
        /// Before and after, across every track.
        public var chunksBefore: Int
        public var chunksAfter: Int
        public var largestChunkBytes: Int64
        public var longestChunkSeconds: Double
        /// How far chunk offsets moved (0 when a free box or a trailing
        /// `moov` took the growth).
        public var offsetShift: Int64
        public var movieAtEnd: Bool
    }

    public enum Decline: Error, Equatable, CustomStringConvertible {
        case noLength
        case noMovie
        case fragmented
        case movieTooLarge
        case unsupported(String)
        case inconsistent(String)
        /// The chunks are fine: nothing to do.
        case chunksFine

        public var description: String {
            switch self {
            case .noLength: "the file's length is unknown"
            case .noMovie: "no movie box"
            case .fragmented: "a fragmented file"
            case .movieTooLarge: "the movie box is too large"
            case .unsupported(let what): "unsupported: \(what)"
            case .inconsistent(let what): "inconsistent tables: \(what)"
            case .chunksFine: "its chunks are fine"
            }
        }
    }

    /// The re-indexed file for `source`, or why there is none (`Decline`;
    /// `.chunksFine` for a file that needs nothing). Reads the top-level box
    /// headers and the `moov`, nothing else.
    public static func plan(_ source: any ByteSource, policy: Policy = .standard) async throws -> Plan {
        guard let length = try await source.length(), length > 16 else { throw Decline.noLength }
        let top = try await topLevelBoxes(source, length: length)
        let movies = top.filter { $0.type == "moov" }
        guard movies.count == 1, let movie = movies.first else { throw Decline.noMovie }
        if top.contains(where: { $0.type == "moof" }) { throw Decline.fragmented }
        guard movie.size <= policy.maxMovieBytes else { throw Decline.movieTooLarge }
        let movieBytes = [UInt8](try await source.read(movie.offset ..< movie.offset + movie.size))
        guard Int64(movieBytes.count) == movie.size else { throw Decline.inconsistent("short movie read") }
        return try plan(movieBytes: movieBytes, movie: movie, top: top, length: length, policy: policy)
    }

    // MARK: - Planning

    struct TopBox: Equatable {
        var type: String
        var offset: Int64
        var size: Int64
    }

    /// Top-level boxes, one 16-byte read each (at most 64 boxes).
    static func topLevelBoxes(_ source: any ByteSource, length: Int64) async throws -> [TopBox] {
        var boxes: [TopBox] = []
        var offset: Int64 = 0
        while offset < length, boxes.count < 64 {
            let head = [UInt8](try await source.read(offset ..< min(length, offset + 16)))
            guard head.count >= 8 else { throw Decline.inconsistent("truncated box header") }
            var size = Int64(be32(head, 0))
            let type = fourCC(head, 4)
            if size == 1 {
                guard head.count >= 16 else { throw Decline.inconsistent("truncated large box header") }
                size = Int64(bitPattern: be64(head, 8))
            } else if size == 0 {
                size = length - offset
            }
            guard size >= 8, offset + size <= length else { throw Decline.inconsistent("a box runs past the end") }
            boxes.append(TopBox(type: type, offset: offset, size: size))
            offset += size
        }
        guard offset == length else { throw Decline.unsupported("more than 64 top-level boxes") }
        return boxes
    }

    /// A parsed box of the `moov` tree: containers on the path to the
    /// sample tables have children, everything else is kept as raw bytes.
    final class Node {
        var type: String
        /// Header and body as read, for a node that isn't rebuilt.
        var raw: [UInt8]
        var children: [Node]?
        /// A container's bytes between its header and its first child (a
        /// full box's version and flags).
        var prefix: [UInt8] = []

        init(type: String, raw: [UInt8], children: [Node]? = nil) {
            self.type = type; self.raw = raw; self.children = children
        }

        func child(_ type: String) -> Node? { children?.first { $0.type == type } }

        func encoded() -> [UInt8] {
            guard let children else { return raw }
            var body = prefix
            for child in children { body += child.encoded() }
            let size = body.count + 8
            if size > Int(UInt32.max) {
                return [0, 0, 0, 1] + Array(type.utf8) + be64Bytes(UInt64(size + 8)) + body
            }
            return be32Bytes(UInt32(size)) + Array(type.utf8) + body
        }
    }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    static func parseNodes(_ b: [UInt8], from start: Int, to end: Int) throws -> [Node] {
        var nodes: [Node] = []
        var at = start
        while at < end {
            guard at + 8 <= end else { throw Decline.inconsistent("truncated box in the movie") }
            var size = Int(be32(b, at))
            let type = fourCC(b, at + 4)
            var header = 8
            if size == 1 {
                guard at + 16 <= end else { throw Decline.inconsistent("truncated box in the movie") }
                size = Int(clamping: be64(b, at + 8)); header = 16
            } else if size == 0 {
                size = end - at
            }
            guard size >= header, at + size <= end else { throw Decline.inconsistent("a box in the movie runs past its parent") }
            let node = Node(type: type, raw: Array(b[at ..< at + size]))
            if containers.contains(type) {
                node.children = try parseNodes(b, from: at + header, to: at + size)
            }
            nodes.append(node)
            at += size
        }
        return nodes
    }

    /// A track's tables, as numbers.
    struct Track {
        var stbl: Node
        var timescale: UInt32
        var sampleSizes: [UInt32]
        /// Sample deltas in decode order, one per sample.
        var sampleDeltas: [UInt32]
        /// (first chunk, samples per chunk, sample description index), 1-based chunks.
        var stsc: [(UInt32, UInt32, UInt32)]
        var chunkOffsets: [Int64]
        var usesCo64: Bool
    }

    /// One chunk of a track: where it starts, its samples, its description.
    struct Chunk: Equatable {
        var offset: Int64
        var firstSample: Int
        var sampleCount: Int
        var descriptionIndex: UInt32
    }

    static func plan(movieBytes: [UInt8], movie: TopBox, top: [TopBox], length: Int64, policy: Policy) throws -> Plan {
        guard fourCC(movieBytes, 4) == "moov" else { throw Decline.noMovie }
        let headerLength = be32(movieBytes, 0) == 1 ? 16 : 8
        let root = Node(type: "moov", raw: movieBytes)
        root.children = try parseNodes(movieBytes, from: headerLength, to: movieBytes.count)
        guard let children = root.children else { throw Decline.noMovie }
        if children.contains(where: { $0.type == "mvex" }) { throw Decline.fragmented }
        if containsILoc(children) { throw Decline.unsupported("a meta box with item locations") }

        let media = top.filter { $0.type == "mdat" }
        var tracks: [Track] = []
        for trak in children where trak.type == "trak" {
            guard let mdia = trak.child("mdia"), let minf = mdia.child("minf"), let stbl = minf.child("stbl") else {
                throw Decline.inconsistent("a track without sample tables")
            }
            tracks.append(try readTrack(stbl: stbl, mdhd: mdia.child("mdhd")))
        }
        guard !tracks.isEmpty else { throw Decline.inconsistent("no tracks") }

        // Every chunk, per track, checked against the file.
        var chunksBefore = 0
        var largest: Int64 = 0
        var longest = 0.0
        var plannedChunks: [[Chunk]] = []
        var needsWork = false
        for track in tracks {
            let chunks = try chunkList(track)
            chunksBefore += chunks.count
            for chunk in chunks {
                let bytes = byteCount(track, chunk)
                let end = chunk.offset + bytes
                guard chunk.offset >= 0, end <= length,
                      media.contains(where: { chunk.offset >= $0.offset && end <= $0.offset + $0.size }) || bytes == 0 else {
                    throw Decline.inconsistent("a chunk lies outside the media")
                }
                let seconds = duration(track, chunk)
                largest = max(largest, bytes)
                longest = max(longest, seconds)
                if chunk.sampleCount > 1, bytes > policy.maxChunkBytes || seconds > policy.maxChunkSeconds {
                    needsWork = true
                }
            }
            plannedChunks.append(chunks)
        }
        guard needsWork else { throw Decline.chunksFine }

        // Split the oversized chunks.
        var chunksAfter = 0
        for (index, track) in tracks.enumerated() {
            var split: [Chunk] = []
            for chunk in plannedChunks[index] {
                let bytes = byteCount(track, chunk)
                let seconds = duration(track, chunk)
                if chunk.sampleCount > 1, bytes > policy.maxChunkBytes || seconds > policy.maxChunkSeconds {
                    split += splitChunk(track, chunk, policy: policy)
                } else {
                    split.append(chunk)
                }
            }
            plannedChunks[index] = split
            chunksAfter += split.count
        }

        // Offsets after the movie move by the movie's growth, unless a free
        // box right after it can take it or the movie follows the media.
        let movieEnd = movie.offset + movie.size
        let movieAtEnd = !media.contains { $0.offset > movie.offset }
        let followingFree = top.first { $0.offset == movieEnd && ($0.type == "free" || $0.type == "skip") }

        func offsets(_ index: Int, shift: Int64) -> [Int64] {
            plannedChunks[index].map { $0.offset > movie.offset ? $0.offset + shift : $0.offset }
        }
        var shift: Int64 = 0
        var wide = tracks.map(\.usesCo64)
        var newMovie: [UInt8] = []
        var freeReplacement: [UInt8]?
        var settled = false
        // The shift depends on the movie's size, which depends on whether
        // the shifted offsets need co64: a few rounds settle it.
        for _ in 0 ..< 4 {
            for (index, track) in tracks.enumerated() {
                rewriteTables(track.stbl, chunks: plannedChunks[index], offsets: offsets(index, shift: shift), wide: wide[index])
            }
            newMovie = root.encoded()
            let growth = Int64(newMovie.count) - movie.size
            var newShift = growth
            freeReplacement = nil
            if movieAtEnd {
                newShift = 0
            } else if let free = followingFree, growth > 0, free.size == growth || free.size - growth >= 8 {
                newShift = 0
                let remaining = free.size - growth
                freeReplacement = remaining == 0 ? [] : be32Bytes(UInt32(remaining)) + Array("free".utf8)
                    + [UInt8](repeating: 0, count: Int(remaining - 8))
            }
            var widened = false
            for index in tracks.indices where !wide[index] && offsets(index, shift: newShift).contains(where: { $0 > Int64(UInt32.max) }) {
                wide[index] = true
                widened = true
            }
            if newShift == shift, !widened { settled = true; break }
            shift = newShift
        }
        guard settled else { throw Decline.inconsistent("the chunk offsets didn't settle") }

        var pieces: [Plan.Piece] = []
        if movie.offset > 0 { pieces.append(.original(0 ..< movie.offset)) }
        pieces.append(.bytes(Data(newMovie)))
        var resume = movieEnd
        if let free = followingFree, let freeReplacement {
            if !freeReplacement.isEmpty { pieces.append(.bytes(Data(freeReplacement))) }
            resume = free.offset + free.size
        }
        if resume < length { pieces.append(.original(resume ..< length)) }
        let total = pieces.reduce(Int64(0)) { $0 + $1.count }
        let reindexed = Plan(pieces: pieces, length: total, summary: Summary(
            tracks: tracks.count, chunksBefore: chunksBefore, chunksAfter: chunksAfter,
            largestChunkBytes: largest, longestChunkSeconds: longest, offsetShift: shift, movieAtEnd: movieAtEnd))

        // Every new chunk must land on its own bytes of the original.
        for (index, track) in tracks.enumerated() {
            for (chunk, offset) in zip(plannedChunks[index], offsets(index, shift: shift)) {
                let bytes = byteCount(track, chunk)
                guard bytes > 0 else { continue }
                guard reindexed.pieces(for: offset ..< offset + bytes) == [.original(chunk.offset ..< chunk.offset + bytes)] else {
                    throw Decline.inconsistent("a chunk doesn't map back to its bytes")
                }
            }
        }
        return reindexed
    }


    static func containsILoc(_ nodes: [Node]) -> Bool {
        for node in nodes {
            if node.type == "meta" || node.type == "udta" || node.type == "trak" {
                // Scan a meta box's children (ISO's has version and flags
                // first, QuickTime's doesn't) for iloc.
                let raw = node.raw
                for skip in [8, 12] where raw.count > skip {
                    if let children = try? parseNodes(raw, from: skip, to: raw.count),
                       children.contains(where: { $0.type == "iloc" || ($0.type == "meta" && containsILoc([$0])) }) {
                        return true
                    }
                }
            }
            if let children = node.children, containsILoc(children) { return true }
        }
        return false
    }

    static func readTrack(stbl: Node, mdhd: Node?) throws -> Track {
        guard let children = stbl.children else { throw Decline.inconsistent("empty sample tables") }
        if stbl.child("stz2") != nil { throw Decline.unsupported("compact sample sizes") }
        if stbl.child("saio") != nil || stbl.child("senc") != nil { throw Decline.unsupported("encrypted samples") }
        // The fields below are read at fixed places after an 8-byte header.
        if children.contains(where: { be32($0.raw, 0) == 1 }) { throw Decline.unsupported("a sample table with a 64-bit size") }
        guard let stsz = stbl.child("stsz"), let stsc = stbl.child("stsc"), let stts = stbl.child("stts") else {
            throw Decline.inconsistent("missing sample tables")
        }
        let co64 = stbl.child("co64")
        guard let stco = stbl.child("stco") ?? co64 else { throw Decline.inconsistent("no chunk offsets") }

        var timescale: UInt32 = 0
        if let mdhd {
            let b = mdhd.raw
            guard b.count >= 24 else { throw Decline.inconsistent("short mdhd") }
            timescale = b[8] == 1 ? be32(b, 28) : be32(b, 20)
        }
        guard timescale > 0 else { throw Decline.inconsistent("no media timescale") }

        // stsz: version/flags, uniform size, count, sizes.
        let sz = stsz.raw
        guard sz.count >= 20 else { throw Decline.inconsistent("short stsz") }
        let uniform = be32(sz, 12)
        let count = Int(be32(sz, 16))
        var sizes: [UInt32]
        if uniform != 0 {
            sizes = Array(repeating: uniform, count: count)
        } else {
            guard sz.count >= 20 + count * 4 else { throw Decline.inconsistent("short stsz") }
            sizes = (0 ..< count).map { be32(sz, 20 + $0 * 4) }
        }

        let tt = stts.raw
        guard tt.count >= 16 else { throw Decline.inconsistent("short stts") }
        let runs = Int(be32(tt, 12))
        guard tt.count >= 16 + runs * 8 else { throw Decline.inconsistent("short stts") }
        var deltas: [UInt32] = []
        deltas.reserveCapacity(count)
        for i in 0 ..< runs {
            let n = Int(be32(tt, 16 + i * 8)), delta = be32(tt, 20 + i * 8)
            guard deltas.count + n <= count else { throw Decline.inconsistent("stts covers more samples than stsz") }
            deltas += repeatElement(delta, count: n)
        }
        guard deltas.count == count else { throw Decline.inconsistent("stts and stsz disagree") }

        let sc = stsc.raw
        guard sc.count >= 16 else { throw Decline.inconsistent("short stsc") }
        let entries = Int(be32(sc, 12))
        guard sc.count >= 16 + entries * 12 else { throw Decline.inconsistent("short stsc") }
        let table = (0 ..< entries).map { (be32(sc, 16 + $0 * 12), be32(sc, 20 + $0 * 12), be32(sc, 24 + $0 * 12)) }

        let co = stco.raw
        guard co.count >= 16 else { throw Decline.inconsistent("short chunk offsets") }
        let chunkCount = Int(be32(co, 12))
        let wide = stco.type == "co64"
        guard co.count >= 16 + chunkCount * (wide ? 8 : 4) else { throw Decline.inconsistent("short chunk offsets") }
        let offsets = (0 ..< chunkCount).map { wide ? Int64(bitPattern: be64(co, 16 + $0 * 8)) : Int64(be32(co, 16 + $0 * 4)) }

        return Track(stbl: stbl, timescale: timescale, sampleSizes: sizes, sampleDeltas: deltas,
                     stsc: table, chunkOffsets: offsets, usesCo64: wide)
    }

    static func chunkList(_ track: Track) throws -> [Chunk] {
        guard let first = track.stsc.first, first.0 == 1 || track.chunkOffsets.isEmpty else {
            throw Decline.inconsistent("stsc doesn't start at the first chunk")
        }
        var chunks: [Chunk] = []
        chunks.reserveCapacity(track.chunkOffsets.count)
        var sample = 0
        var entry = 0
        for (index, offset) in track.chunkOffsets.enumerated() {
            let number = UInt32(index + 1)
            while entry + 1 < track.stsc.count, track.stsc[entry + 1].0 <= number { entry += 1 }
            let (_, perChunk, description) = track.stsc[entry]
            chunks.append(Chunk(offset: offset, firstSample: sample, sampleCount: Int(perChunk), descriptionIndex: description))
            sample += Int(perChunk)
        }
        guard sample == track.sampleSizes.count else { throw Decline.inconsistent("stsc and stsz disagree") }
        return chunks
    }

    static func byteCount(_ track: Track, _ chunk: Chunk) -> Int64 {
        track.sampleSizes[chunk.firstSample ..< chunk.firstSample + chunk.sampleCount].reduce(Int64(0)) { $0 + Int64($1) }
    }

    static func duration(_ track: Track, _ chunk: Chunk) -> Double {
        let ticks = track.sampleDeltas[chunk.firstSample ..< chunk.firstSample + chunk.sampleCount].reduce(UInt64(0)) { $0 + UInt64($1) }
        return Double(ticks) / Double(track.timescale)
    }

    /// `chunk` as consecutive chunks of about the target size: each ends at
    /// the sample that reaches either target.
    static func splitChunk(_ track: Track, _ chunk: Chunk, policy: Policy) -> [Chunk] {
        var out: [Chunk] = []
        var start = chunk.firstSample
        var offset = chunk.offset
        let end = chunk.firstSample + chunk.sampleCount
        let targetTicks = UInt64(max(0, policy.targetChunkSeconds) * Double(track.timescale))
        while start < end {
            var bytes: Int64 = 0
            var ticks: UInt64 = 0
            var sample = start
            repeat {
                bytes += Int64(track.sampleSizes[sample])
                ticks += UInt64(track.sampleDeltas[sample])
                sample += 1
            } while sample < end && bytes < policy.targetChunkBytes && ticks < targetTicks
            out.append(Chunk(offset: offset, firstSample: start, sampleCount: sample - start,
                             descriptionIndex: chunk.descriptionIndex))
            offset += bytes
            start = sample
        }
        return out
    }

    /// Replaces the track's `stsc` and chunk offsets in place in its `stbl`.
    static func rewriteTables(_ stbl: Node, chunks: [Chunk], offsets: [Int64], wide: Bool) {
        var runs: [(UInt32, UInt32, UInt32)] = []
        for (index, chunk) in chunks.enumerated() {
            let entry = (UInt32(index + 1), UInt32(chunk.sampleCount), chunk.descriptionIndex)
            if let last = runs.last, last.1 == entry.1, last.2 == entry.2 { continue }
            runs.append(entry)
        }
        var stsc: [UInt8] = [0, 0, 0, 0] + be32Bytes(UInt32(runs.count))
        for run in runs { stsc += be32Bytes(run.0) + be32Bytes(run.1) + be32Bytes(run.2) }
        var co: [UInt8] = [0, 0, 0, 0] + be32Bytes(UInt32(offsets.count))
        for offset in offsets { co += wide ? be64Bytes(UInt64(offset)) : be32Bytes(UInt32(offset)) }

        guard var children = stbl.children else { return }
        let stscNode = Node(type: "stsc", raw: be32Bytes(UInt32(stsc.count + 8)) + Array("stsc".utf8) + stsc)
        let coType = wide ? "co64" : "stco"
        let coNode = Node(type: coType, raw: be32Bytes(UInt32(co.count + 8)) + Array(coType.utf8) + co)
        if let index = children.firstIndex(where: { $0.type == "stsc" }) { children[index] = stscNode }
        if let index = children.firstIndex(where: { $0.type == "stco" || $0.type == "co64" }) { children[index] = coNode }
        stbl.children = children
    }

    // MARK: - Bytes

    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func be64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4)) }

    static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(decoding: b[i ..< i + 4], as: UTF8.self)
    }
}

func be32Bytes(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

func be64Bytes(_ value: UInt64) -> [UInt8] { be32Bytes(UInt32(value >> 32)) + be32Bytes(UInt32(value & 0xFFFF_FFFF)) }

/// The re-indexed file as a byte source (for tests and tools; the app
/// streams the pieces itself).
public struct ReindexedByteSource: ByteSource {
    public let plan: MP4Reindex.Plan
    public let original: any ByteSource

    public init(plan: MP4Reindex.Plan, original: any ByteSource) {
        self.plan = plan
        self.original = original
    }

    public var isLocal: Bool { original.isLocal }

    public func length() async throws -> Int64? { plan.length }

    public func read(_ range: Range<Int64>) async throws -> Data {
        var data = Data()
        for piece in plan.pieces(for: range) {
            switch piece {
            case .bytes(let bytes): data.append(bytes)
            case .original(let source): data.append(try await original.read(source))
            }
        }
        return data
    }
}
