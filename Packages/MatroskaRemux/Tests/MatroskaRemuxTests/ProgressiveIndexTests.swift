import Foundation
import Testing
@testable import MatroskaRemux

/// A server's file without Cues: indexed by hopping from cluster to
/// cluster, in the background, with the same segments Cues would give.
@Suite("Indexing a server's file without Cues")
struct ProgressiveIndexTests {
    /// Fixtures whose clusters start at keyframes (ffmpeg's and mkvmerge's
    /// layouts both), so hopping finds every keyframe Cues list.
    static let fixtures = [
        "h264-bframes-aac.mkv", "two-audio.mkv", "ac3-51.mkv", "eac3-51.mkv", "vp9-opus.webm", "hevc-hdr10.mkv",
        "laced-xiph-mp3.mkv", "laced-ebml-aac.mkv", "flac.mkv", "mp3.mkv", "alac.mkv", "av1-opus.mkv",
    ]

    @Test(arguments: fixtures)
    func hoppedIndexMatchesCues(_ name: String) async throws {
        let data = try Fixtures.data(name)
        let cued = try await RemuxSession.open(source: DataByteSource(data))
        let counting = CountingSource(DataByteSource(try CueRemoval.voidingCues(data)))
        let hopped = try await RemuxSession.open(source: counting)
        try await hopped.waitUntilIndexed()
        #expect(hopped.index.boundaries == cued.index.boundaries)
        #expect(hopped.index.endTime == cued.index.endTime)
        #expect(!hopped.summary.scannedClusters)
        try await SessionComparison.expectSameOutput(hopped, cued)
    }

    @Test func remoteLiveStreamIsHopped() async throws {
        let scanned = try await Fixtures.open("live.webm")
        let hopped = try await RemuxSession.open(source: RemoteLike(try Fixtures.source("live.webm")))
        try await hopped.waitUntilIndexed()
        #expect(scanned.summary.scannedClusters)
        #expect(hopped.index.boundaries == scanned.index.boundaries)
        // No Duration: the end comes from the last cluster's frames, as a
        // scan finds it.
        #expect(hopped.index.endTime == scanned.index.endTime)
        try await SessionComparison.expectSameOutput(hopped, scanned)
    }

    /// ffmpeg's layout: a keyframe's cluster opens with the audio stored
    /// ahead of it, and a cluster every 0.4 s more starts mid-GOP.
    @Test func ffmpegLayoutWithMidGOPClusters() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("ac3-51.mkv"))
        writer.audioAheadOfKeyframes = true
        writer.forcedClusterSeconds = 0.4
        let cued = try await RemuxSession.open(source: DataByteSource(writer.write()))
        writer.writesCues = false
        let data = writer.write()
        // The layout really is that: clusters that start with audio, and
        // more clusters than keyframes.
        let heads = try await Self.heads(data)
        #expect(heads.count > 2 * cued.index.boundaries.count)
        #expect(heads.contains { $0.firstVideo?.isKeyframe == true && $0.firstVideo!.time > $0.timestamp! })
        let hopped = try await RemuxSession.open(source: CountingSource(DataByteSource(data)))
        try await hopped.waitUntilIndexed()
        #expect(hopped.index.boundaries.map(\.time) == cued.index.boundaries.map(\.time))
        try await SessionComparison.expectSameOutput(hopped, cued)
    }

    @Test func blockGroupsAreHoppedToo() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("ac3-51.mkv"))
        writer.blockGroupTracks = [1, 2]
        let cued = try await RemuxSession.open(source: DataByteSource(writer.write()))
        writer.writesCues = false
        let hopped = try await RemuxSession.open(source: CountingSource(DataByteSource(writer.write())))
        try await hopped.waitUntilIndexed()
        // (Offsets differ by the SeekHead's Cues entry.)
        #expect(hopped.index.boundaries.map(\.time) == cued.index.boundaries.map(\.time))
        #expect(hopped.index.endTime == cued.index.endTime)
    }

    @Test func unknownSizeClustersAreDeclined() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("vp9-opus.webm"))
        writer.writesCues = false
        writer.unknownSizeClusters = true
        let data = writer.write()
        // Local: scanned as before.
        let local = try await RemuxSession.open(source: DataByteSource(data))
        #expect(local.summary.scannedClusters)
        await #expect(throws: RemuxError.declined("no Cues, clusters of unknown size, and the source is remote")) {
            _ = try await RemuxSession.open(source: CountingSource(DataByteSource(data)))
        }
    }

    /// A long file over a slow link: `open` hands out the first segments as
    /// an EVENT playlist, which grows, keeps what it listed, and ends.
    @Test func growingIndexIsAnEventPlaylist() async throws {
        let data = try await Self.longFile(minutes: 10)
        let source = CountingSource(DataByteSource(data), latency: .milliseconds(2))
        var options = RemuxOptions()
        options.indexWait = 0
        let session = try await RemuxSession.open(source: source, options: options)
        #expect(session.summary.indexing)
        #expect(abs(session.summary.durationSeconds - 600) < 1, "Info's Duration while indexing")
        let early = String(decoding: try await session.fetch("video.m3u8"), as: UTF8.self)
        #expect(early.contains("#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-START:TIME-OFFSET=0\n"))
        #expect(!early.contains("#EXT-X-ENDLIST"))
        let listed = session.segmentCount
        #expect(listed >= 3)
        #expect(!session.isIndexComplete)
        // A listed segment plays while the index grows.
        _ = try await session.fetch("video/0.m4s")
        _ = try await session.fetch("muxed/\(listed - 1).m4s")

        try await session.waitUntilIndexed()
        let final = String(decoding: try await session.fetch("video.m3u8"), as: UTF8.self)
        #expect(final.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(final.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        // What was listed is still listed, unchanged, with the same target.
        #expect(final.hasPrefix(early))
        // And the whole index is what a scan of the same file gives (a short
        // last segment could stay apart, had the one before been listed),
        // ending at Info's Duration.
        let scanned = try await RemuxSession.open(source: DataByteSource(data))
        #expect(Array(session.index.boundaries.prefix(scanned.index.boundaries.count)) == scanned.index.boundaries)
        #expect(session.segmentCount - scanned.segmentCount <= 1)
        #expect(session.index.endTime == 600_000)
    }

    /// What opening and playing a 10-minute server file costs: the head,
    /// the probe and a few hops before `open` returns; a small read per
    /// cluster for the index; and each segment's bytes once.
    @Test func openCostAndNoRepeats() async throws {
        let data = try await Self.longFile(minutes: 10)
        let source = CountingSource(DataByteSource(data), latency: .milliseconds(2))
        let clock = ContinuousClock()
        let started = clock.now
        let session = try await RemuxSession.open(source: source)
        let openTime = clock.now - started
        let atOpen = source.ranges
        try await session.waitUntilIndexed()
        let indexTime = clock.now - started
        let indexed = source.ranges
        let clusters = try await Self.heads(data).count

        for k in 0 ..< session.segmentCount {
            _ = try await session.data(at: "video/\(k).m4s")
            for track in session.summary.audio { _ = try await session.data(at: "audio-\(track.number)/\(k).m4s") }
        }
        let all = source.ranges
        let segmentReads = Array(all.dropFirst(indexed.count))
        let segmentBytes = segmentReads.reduce(Int64(0)) { $0 + Int64($1.count) }
        let indexBytes = indexed.reduce(Int64(0)) { $0 + Int64($1.count) }
        let repeated = all.reduce(Int64(0)) { $0 + Int64($1.count) } - StreamingTests.union(all)
        print("""
            10-minute file, \(data.count) bytes, \(clusters) clusters, 2 ms a request: \
            open \(openTime) (\(atOpen.count) requests, \(atOpen.reduce(0) { $0 + $1.count }) bytes, \
            \(session.summary.indexing ? "growing" : "complete")); \
            indexed in \(indexTime) (\(indexed.count) requests, \(indexBytes) bytes); \
            segments \(segmentReads.count) requests, \(segmentBytes) bytes; \(repeated) bytes read twice
            """)
        // Open: the head, the probe's first read, and the hops to the first
        // segments; it doesn't wait out `indexWait` for an index that won't
        // be done by then.
        #expect(openTime < .seconds(1))
        // One read per cluster for the index, under a hundred bytes each
        // (these clusters start with their keyframe).
        let hops = indexed.dropFirst(2)
        #expect(hops.count <= clusters + 2)
        #expect(hops.reduce(0) { $0 + $1.count } <= 100 * clusters)
        // Every segment's bytes are read once; nothing is read twice but the
        // cluster heads the index read (0.4 % of this low-bitrate file, 22 KB
        // clusters).
        #expect(segmentBytes == StreamingTests.union(segmentReads))
        #expect(repeated <= indexBytes)
        #expect(Double(repeated) < 0.005 * Double(data.count))
    }

    /// Four chains of hops at once, joined where each reaches the next
    /// one's first cluster: the same index, in a fraction of the time.
    @Test func chainsGiveTheSameIndexSooner() async throws {
        let data = try await Self.longFile(minutes: 10)
        let scanned = try await RemuxSession.open(source: DataByteSource(data))
        var options = RemuxOptions()
        options.indexWait = 0
        options.indexChains = 1
        let clock = ContinuousClock()
        var started = clock.now
        let one = try await RemuxSession.open(source: CountingSource(DataByteSource(data), latency: .milliseconds(2)),
                                              options: options)
        try await one.waitUntilIndexed()
        let sequential = clock.now - started
        options.indexChains = 4
        options.clustersPerIndexChain = 50
        let source = CountingSource(DataByteSource(data), latency: .milliseconds(2))
        started = clock.now
        let four = try await RemuxSession.open(source: source, options: options)
        try await four.waitUntilIndexed()
        let parallel = clock.now - started
        print("600 clusters, 2 ms a request: one chain \(sequential), four \(parallel)")
        #expect(parallel < sequential / 2)
        for session in [one, four] {
            #expect(Array(session.index.boundaries.prefix(scanned.index.boundaries.count)) == scanned.index.boundaries)
            #expect(session.index.endTime == 600_000)
        }
        #expect(four.index.boundaries == one.index.boundaries)
        // Each cluster's head is read once: no chain hops past another's start.
        let clusters = try await Self.heads(data).count
        #expect(source.ranges.count <= clusters + 3 + 3)
    }

    /// A probe that takes bytes inside a frame for a Cluster starts a chain
    /// that goes nowhere; the chain before it hops past and on.
    @Test func strayClusterIDsInFramesAreHoppedPast() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("h264-bframes-aac.mkv"))
        let base = writer.frames
        writer.frames = []
        for copy in 0 ..< 67 {
            writer.frames += base.map { frame in
                var frame = frame
                frame.timestamp += Int64(copy) * 9000
                // A Cluster ID, a size that fits, a Timestamp: what a probe
                // looks for, inside every video frame.
                if frame.track == 1, frame.data.count > 64 {
                    frame.data.replaceSubrange(40 ..< 52, with: [0x1F, 0x43, 0xB6, 0x75, 0x90, 0xE7, 0x81, 0x00,
                                                                  0xA3, 0x85, 0x81, 0x00])
                }
                return frame
            }
        }
        writer.duration = 603_000
        writer.writesCues = false
        let data = writer.write()
        let scanned = try await RemuxSession.open(source: DataByteSource(data))
        var options = RemuxOptions()
        options.clustersPerIndexChain = 50
        let hopped = try await RemuxSession.open(source: CountingSource(DataByteSource(data)), options: options)
        try await hopped.waitUntilIndexed()
        #expect(hopped.index.boundaries == scanned.index.boundaries)
        // The probes did find the stray IDs.
        let header = try await MatroskaHeaderReader.read(DataByteSource(data))
        let first = try #require(try await Self.heads(data).first)
        let seeds = await ProgressiveIndexing.seeds(after: first.end, clusterBytes: first.end - first.position,
                                                    contentEnd: Int64(data.count), source: DataByteSource(data),
                                                    options: options)
        let positions = Set(try await Self.heads(data).map(\.position))
        #expect(seeds.count == 3)
        #expect(seeds.contains { !positions.contains($0) })
        _ = header
    }

    // MARK: - Helpers

    /// Every cluster head of `data`, hopped.
    static func heads(_ data: Data) async throws -> [ClusterHead] {
        let source = DataByteSource(data)
        let header = try await MatroskaHeaderReader.read(source)
        let video = try #require(header.tracks.first { $0.kind == .video }).number
        var hopper = ClusterHopper(source: source, start: try #require(header.firstClusterPosition),
                                   limit: Int64(data.count), videoTrack: video)
        var heads: [ClusterHead] = []
        while case .cluster(let head) = try await hopper.next() { heads.append(head) }
        return heads
    }

    /// `h264-bframes-aac.mkv` (9 s, a keyframe a second) repeated to
    /// `minutes`, without Cues.
    static func longFile(minutes: Int) async throws -> Data {
        let base = try await MatroskaTestWriter.load(try Fixtures.data("h264-bframes-aac.mkv"))
        var writer = base
        writer.frames = []
        let copies = minutes * 60 / 9 + 1
        for copy in 0 ..< copies {
            writer.frames += base.frames.map { frame in
                var frame = frame
                frame.timestamp += Int64(copy) * 9000
                return frame
            }
        }
        writer.duration = Double(minutes * 60) * 1000
        writer.frames = writer.frames.filter { $0.timestamp < Int64(minutes * 60) * 1000 }
        writer.writesCues = false
        return writer.write()
    }
}

/// Comparing two sessions' output.
enum SessionComparison {
    /// Every playlist, init and media segment of `a` equals `b`'s.
    static func expectSameOutput(_ a: RemuxSession, _ b: RemuxSession) async throws {
        #expect(a.segmentCount == b.segmentCount)
        var paths = ["video.m3u8", "muxed.m3u8", "video/init.mp4", "muxed/init.mp4"]
        for track in b.summary.audio { paths += ["audio-\(track.number).m3u8", "audio-\(track.number)/init.mp4"] }
        for k in 0 ..< b.segmentCount {
            paths += ["video/\(k).m4s", "muxed/\(k).m4s"] + b.summary.audio.map { "audio-\($0.number)/\(k).m4s" }
        }
        for path in paths {
            let left = try await a.fetch(path), right = try await b.fetch(path)
            #expect(left == right, "\(path) differs")
        }
    }
}

/// Matroska files with their Cues gone.
enum CueRemoval {
    /// `data` with its Cues element overwritten by a Void of the same
    /// length: what the reader sees of a file whose Cues were never written.
    static func voidingCues(_ data: Data) throws -> Data {
        var bytes = [UInt8](data)
        var reader = EBMLReader(bytes)
        _ = reader.next() // EBML header
        let next = reader.next()
        let segment = try #require(next)
        var position = segment.bodyStart
        var voided = 0
        while let (id, idLength) = EBML.id(bytes, at: position, end: bytes.count),
              let (size, sizeLength) = EBML.size(bytes, at: position + idLength, end: bytes.count), let size {
            let length = idLength + sizeLength + Int(size)
            if id == MatroskaID.cues {
                try #require(length >= 9)
                bytes[position] = 0xEC
                bytes[position + 1] = 0x01
                for i in 0 ..< 7 { bytes[position + 2 + i] = UInt8((UInt64(length - 9) >> (8 * UInt64(6 - i))) & 0xFF) }
                voided += 1
            }
            position += length
        }
        try #require(voided == 1, "no Cues to void")
        return Data(bytes)
    }
}
