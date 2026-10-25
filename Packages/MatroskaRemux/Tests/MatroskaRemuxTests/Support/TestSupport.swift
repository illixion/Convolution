/*
 Test support: the committed fixtures, what ffprobe counted in them, and a
 small reader for the MP4 the remuxer writes.
 */

import Foundation
import Testing
@testable import MatroskaRemux

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
                     "missing fixture \(name)")
    }

    static func source(_ name: String) throws -> FileByteSource {
        try FileByteSource(url: url(name))
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func open(_ name: String, options: RemuxOptions = RemuxOptions()) async throws -> RemuxSession {
        try await RemuxSession.open(source: source(name), options: options)
    }

    struct Stream: Decodable {
        var type: String
        var codec: String
        var packets: Int
    }

    /// ffprobe's view of each fixture (`make-fixtures.sh` writes it).
    static func expected(_ name: String) throws -> [Stream] {
        let data = try Data(contentsOf: url("expected.json"))
        let all = try JSONDecoder().decode([String: [Stream]].self, from: data)
        return try #require(all[name], "no expectations for \(name)")
    }

    /// Every fixture the remuxer should accept.
    static let playable = [
        "vp9-opus.webm", "h264-bframes-aac.mkv", "hevc-hdr10.mkv", "ac3-51.mkv", "eac3-51.mkv", "flac.mkv",
        "two-audio.mkv", "laced-xiph-mp3.mkv", "laced-ebml-aac.mkv", "live.webm", "av1-opus.mkv", "mp3.mkv",
        "alac.mkv",
    ]
}

/// What a media segment holds, read back.
struct SegmentReadback {
    struct Sample {
        var duration: UInt32
        var size: UInt32
        var flags: UInt32
        var compositionOffset: Int32
        var data: [UInt8]
        var isSync: Bool { flags & 0x0001_0000 == 0 }
    }

    struct Run {
        var trackID: UInt32
        var baseDecodeTime: UInt64
        var samples: [Sample]
        var endDecodeTime: UInt64 { baseDecodeTime + samples.reduce(0) { $0 + UInt64($1.duration) } }
    }

    var sequenceNumber: UInt32 = 0
    var runs: [Run] = []

    func runs(track: UInt32) -> [Run] { runs.filter { $0.trackID == track } }
}

enum MP4Read {
    struct Box {
        var type: String
        var range: Range<Int>
        var body: Range<Int>
    }

    static func boxes(_ bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let size = Int(u32(bytes, p))
            guard size >= 8, p + size <= range.upperBound else { break }
            let type = String(decoding: bytes[p + 4 ..< p + 8], as: UTF8.self)
            result.append(Box(type: type, range: p ..< p + size, body: p + 8 ..< p + size))
            p += size
        }
        return result
    }

    static func first(_ type: String, _ bytes: [UInt8], _ range: Range<Int>) -> Box? {
        boxes(bytes, range).first { $0.type == type }
    }

    static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }

    static func u64(_ b: [UInt8], _ p: Int) -> UInt64 { UInt64(u32(b, p)) << 32 | UInt64(u32(b, p + 4)) }

    /// A media segment's moof (one, as the remuxer writes them) and the
    /// samples its truns point at.
    static func segment(_ data: Data) throws -> SegmentReadback {
        let bytes = [UInt8](data)
        let top = boxes(bytes, 0 ..< bytes.count)
        let moof = try #require(top.first { $0.type == "moof" }, "segment without moof")
        #expect(top.map(\.type) == ["moof", "mdat"], "one moof and one mdat")
        var readback = SegmentReadback()
        for box in boxes(bytes, moof.body) {
            if box.type == "mfhd" { readback.sequenceNumber = u32(bytes, box.body.lowerBound + 4) }
            guard box.type == "traf" else { continue }
            let children = boxes(bytes, box.body)
            let tfhd = try #require(children.first { $0.type == "tfhd" })
            let tfdt = try #require(children.first { $0.type == "tfdt" })
            let trun = try #require(children.first { $0.type == "trun" })
            #expect(u32(bytes, tfhd.body.lowerBound) & 0xFFFFFF == 0x02_0000, "default-base-is-moof")
            var run = SegmentReadback.Run(trackID: u32(bytes, tfhd.body.lowerBound + 4),
                                          baseDecodeTime: bytes[tfdt.body.lowerBound] == 1
                                              ? u64(bytes, tfdt.body.lowerBound + 4)
                                              : UInt64(u32(bytes, tfdt.body.lowerBound + 4)),
                                          samples: [])
            let flags = u32(bytes, trun.body.lowerBound) & 0xFFFFFF
            let count = Int(u32(bytes, trun.body.lowerBound + 4))
            var q = trun.body.lowerBound + 8
            var offset = moof.range.lowerBound
            if flags & 0x1 != 0 { offset += Int(Int32(bitPattern: u32(bytes, q))); q += 4 }
            for _ in 0 ..< count {
                var sample = SegmentReadback.Sample(duration: 0, size: 0, flags: 0, compositionOffset: 0, data: [])
                if flags & 0x100 != 0 { sample.duration = u32(bytes, q); q += 4 }
                if flags & 0x200 != 0 { sample.size = u32(bytes, q); q += 4 }
                if flags & 0x400 != 0 { sample.flags = u32(bytes, q); q += 4 }
                if flags & 0x800 != 0 { sample.compositionOffset = Int32(bitPattern: u32(bytes, q)); q += 4 }
                sample.data = Array(bytes[offset ..< offset + Int(sample.size)])
                offset += Int(sample.size)
                run.samples.append(sample)
            }
            readback.runs.append(run)
        }
        return readback
    }

    struct TrackDescription {
        var trackID: UInt32
        var handler: String
        var timescale: UInt32
        var language: String
        /// The sample entry's four-character code.
        var entryType: String
        /// Child boxes of the sample entry, by type, with their bodies.
        var entryChildren: [String: [UInt8]]
        var sampleEntry: [UInt8]
    }

    /// The tracks an init segment declares.
    static func initSegment(_ data: Data) throws -> [TrackDescription] {
        let bytes = [UInt8](data)
        let moov = try #require(first("moov", bytes, 0 ..< bytes.count))
        var tracks: [TrackDescription] = []
        for trak in boxes(bytes, moov.body) where trak.type == "trak" {
            let tkhd = try #require(first("tkhd", bytes, trak.body))
            let mdia = try #require(first("mdia", bytes, trak.body))
            let mdhd = try #require(first("mdhd", bytes, mdia.body))
            let hdlr = try #require(first("hdlr", bytes, mdia.body))
            let minf = try #require(first("minf", bytes, mdia.body))
            let stbl = try #require(first("stbl", bytes, minf.body))
            let stsd = try #require(first("stsd", bytes, stbl.body))
            let entry = try #require(boxes(bytes, stsd.body.lowerBound + 8 ..< stsd.body.upperBound).first)
            let handler = String(decoding: bytes[hdlr.body.lowerBound + 8 ..< hdlr.body.lowerBound + 12], as: UTF8.self)
            // Children start after the visual (78 bytes) or audio (28, or
            // 44 for a QuickTime version 1 sound description) entry fields.
            var fields = handler == "vide" ? 78 : 28
            if handler == "soun", bytes[entry.body.lowerBound + 9] == 1 { fields = 44 }
            var children: [String: [UInt8]] = [:]
            for child in boxes(bytes, entry.body.lowerBound + fields ..< entry.body.upperBound) {
                children[child.type] = Array(bytes[child.body])
            }
            let packed = UInt16(bytes[mdhd.body.lowerBound + 20]) << 8 | UInt16(bytes[mdhd.body.lowerBound + 21])
            let language = String(decoding: [10, 5, 0].map { UInt8((packed >> $0) & 0x1F) + 0x60 }, as: UTF8.self)
            tracks.append(TrackDescription(trackID: u32(bytes, tkhd.body.lowerBound + 12), handler: handler,
                                           timescale: u32(bytes, mdhd.body.lowerBound + 12), language: language,
                                           entryType: entry.type, entryChildren: children,
                                           sampleEntry: Array(bytes[entry.range])))
        }
        return tracks
    }
}

struct MissingResource: Error, CustomStringConvertible {
    var path: String
    var description: String { "nothing at \(path)" }
}

extension RemuxSession {
    func fetch(_ path: String) async throws -> Data {
        guard let data = try await data(at: path)?.data else { throw MissingResource(path: path) }
        return data
    }

    /// Every resource of a rendition, fetched in order.
    func allSegments(_ rendition: String) async throws -> [Data] {
        var result: [Data] = []
        for k in 0 ..< segmentCount {
            result.append(try await fetch("\(rendition)/\(k).m4s"))
        }
        return result
    }

    /// Init plus every segment of a rendition, as one fragmented MP4 file.
    func concatenated(_ rendition: String) async throws -> Data {
        var file = try await fetch("\(rendition)/init.mp4")
        for segment in try await allSegments(rendition) { file.append(segment) }
        return file
    }
}
