import Foundation
import Testing
@testable import MatroskaRemux

/// Files rewritten from the fixtures into shapes no installed muxer writes,
/// each checked against the remux of the file it came from.
@Suite("Crafted Matroska")
struct CraftedFileTests {
    private func open(_ data: Data) async throws -> RemuxSession {
        try await RemuxSession.open(source: DataByteSource(data))
    }

    /// Every media segment and init segment of `a` equals `b`'s.
    private func expectSameOutput(_ a: RemuxSession, _ b: RemuxSession, compareInits: Bool = true) async throws {
        #expect(a.segmentCount == b.segmentCount)
        var paths: [String] = []
        for k in 0 ..< a.segmentCount {
            paths += ["video/\(k).m4s", "muxed/\(k).m4s"]
            paths += a.summary.audio.map { "audio-\($0.number)/\(k).m4s" }
        }
        if compareInits { paths += ["video/init.mp4", "muxed/init.mp4"] + a.summary.audio.map { "audio-\($0.number)/init.mp4" } }
        for path in paths {
            let left = try await a.fetch(path), right = try await b.fetch(path)
            #expect(left == right, "\(path) differs")
            if left != right, path.hasSuffix(".m4s") {
                let l = try MP4Read.segment(left), r = try MP4Read.segment(right)
                print("DIFF \(path): runs \(l.runs.map { "\($0.trackID):\($0.baseDecodeTime)+\($0.samples.count)" }) vs \(r.runs.map { "\($0.trackID):\($0.baseDecodeTime)+\($0.samples.count)" })")
            }
        }
    }

    @Test func headerStrippingIsUndone() async throws {
        let original = try Fixtures.data("ac3-51.mkv")
        var writer = try await MatroskaTestWriter.load(original)
        // mkvmerge used to strip AC-3's sync word, and with it any byte
        // every frame of a track shares (the top byte of an H.264 frame's
        // first NAL length).
        writer.strippedHeaders = [1: [0x00], 2: [0x0B, 0x77]]
        let crafted = try await open(writer.write())
        let header = try await MatroskaHeaderReader.read(DataByteSource(writer.write()))
        #expect(header.tracks.map(\.strippedHeader) == [[0x00], [0x0B, 0x77]])
        try await expectSameOutput(crafted, try await open(original))
    }

    @Test func blockGroupsAndFixedLacing() async throws {
        let original = try Fixtures.data("ac3-51.mkv")
        var writer = try await MatroskaTestWriter.load(original)
        writer.blockGroupTracks = [1]
        writer.fixedLacing = [2: 4]
        let data = writer.write()
        // The rewrite really is laced and grouped.
        let source = DataByteSource(data)
        let header = try await MatroskaHeaderReader.read(source)
        var reader = ClusterReader(source: source, start: header.firstClusterPosition!, limit: Int64(data.count),
                                   modes: [1: .frames, 2: .frames])
        var laced = 0, keyframes = 0, video = 0
        while let frame = try await reader.next() {
            if frame.track == 2, frame.laceCount > 1 { laced += 1 }
            if frame.track == 1 { video += 1; if frame.isKeyframe { keyframes += 1 } }
        }
        // 44.1 kHz AC-3 frames alternate between two sizes, so only some
        // neighbours can share a fixed-size lace.
        #expect(laced > 10)
        #expect(video == 125)
        #expect(keyframes == 5)
        try await expectSameOutput(try await open(data), try await open(original))
    }

    @Test func legacyAACCodecID() async throws {
        let original = try Fixtures.data("h264-bframes-aac.mkv")
        var writer = try await MatroskaTestWriter.load(original)
        writer.tracks[1].codecID = "A_AAC/MPEG4/LC"
        writer.tracks[1].codecPrivate = []
        let crafted = try await open(writer.write())
        #expect(crafted.summary.audio.first?.codecs == "mp4a.40.2")
        let entry = try #require(try MP4Read.initSegment(await crafted.fetch("audio-2/init.mp4")).first)
        // The synthesized AudioSpecificConfig: LC, 44.1 kHz, mono.
        let esds = try #require(entry.entryChildren["esds"])
        let decoderSpecificInfo: [UInt8] = [0x05, 0x80, 0x80, 0x80, 0x02, 0x12, 0x08]
        #expect((0 ... esds.count - decoderSpecificInfo.count).contains { Array(esds[$0 ..< $0 + decoderSpecificInfo.count]) == decoderSpecificInfo })
        try await expectSameOutput(crafted, try await open(original), compareInits: false)

        writer.tracks[1].codecID = "A_AAC/MPEG4/LC/SBR"
        let sbr = try await open(writer.write())
        #expect(sbr.summary.audio.first?.codecs == "mp4a.40.5")
    }

    @Test func dolbyVisionProfile8KeepsHEVC() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("hevc-hdr10.mkv"))
        // dvvC: version 1.0, profile 8, level 6, RPU + base layer, HDR10-compatible.
        let payload: [UInt8] = [1, 0, 0x10, 0x35, 0x10] + [UInt8](repeating: 0, count: 19)
        writer.tracks[0].blockAdditionMappings = [.init(idValue: nil, idType: 0x6476_7643, extraData: payload)]
        let session = try await open(writer.write())
        let entry = try #require(try MP4Read.initSegment(await session.fetch("video/init.mp4")).first)
        #expect(entry.entryType == "hvc1")
        #expect(entry.entryChildren["dvvC"] == payload)
        #expect(session.masterPlaylist.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        #expect(session.masterPlaylist.contains("CODECS=\"hvc1.2.4.L60.90,mp4a.40.2\""))
        #expect(session.summary.videoRange == "PQ")
    }

    @Test func dolbyVisionProfile5IsDVH1() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("hevc-hdr10.mkv"))
        // dvcC: profile 5, level 6, RPU + base layer, no compatible base.
        let payload: [UInt8] = [1, 0, 0x0A, 0x35, 0x00] + [UInt8](repeating: 0, count: 19)
        writer.tracks[0].blockAdditionMappings = [.init(idValue: nil, idType: 0x6476_6343, extraData: payload)]
        writer.tracks[0].video?.colour = nil
        let session = try await open(writer.write())
        let entry = try #require(try MP4Read.initSegment(await session.fetch("video/init.mp4")).first)
        #expect(entry.entryType == "dvh1")
        #expect(entry.entryChildren["dvcC"] == payload)
        #expect(session.summary.video.codecs == "dvh1.05.06")
        #expect(session.summary.videoRange == "PQ")
        #expect(!session.masterPlaylist.contains("SUPPLEMENTAL-CODECS"))
    }

    @Test func encryptedOrCompressedTracks() async throws {
        let original = try Fixtures.data("ac3-51.mkv")
        var encrypted = try await MatroskaTestWriter.load(original)
        var encryption = MatroskaTrack.ContentEncoding()
        encryption.type = 1
        encrypted.tracks[0].contentEncodings = [encryption]
        await #expect(throws: RemuxError.declined("video track is encrypted")) {
            _ = try await open(encrypted.write())
        }

        var zlib = try await MatroskaTestWriter.load(original)
        zlib.tracks[1].contentEncodings = [MatroskaTrack.ContentEncoding()] // algorithm 0: zlib
        await #expect(throws: RemuxError.declined("no playable audio (A_AC3)")) {
            _ = try await open(zlib.write())
        }
    }

    @Test func unsupportedAudioIsDroppedNotFatal() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("two-audio.mkv"))
        writer.tracks[2].codecID = "A_TRUEHD"
        let session = try await open(writer.write())
        #expect(session.summary.audio.map(\.number) == [2])
        #expect(session.summary.dropped.map(\.codecID) == ["A_TRUEHD"])
        #expect(!session.masterPlaylist.contains("audio-3"))
    }

    @Test func audioGapIsBridged() async throws {
        let original = try Fixtures.data("ac3-51.mkv")
        var writer = try await MatroskaTestWriter.load(original)
        // Drop 20 AC-3 frames (0.7 s) from the middle of the first segment.
        let audio = writer.frames.indices.filter { writer.frames[$0].track == 2 }
        let removed = Set(audio[40 ..< 60])
        writer.frames = writer.frames.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let session = try await open(writer.write())
        let segment = try MP4Read.segment(try await session.fetch("audio-2/0.m4s"))
        // One run; the frame before the gap lasts until the frame after it.
        #expect(segment.runs.count == 1)
        let run = try #require(segment.runs.first)
        #expect(run.samples.count == 124)
        #expect(run.samples[39].duration == 21 * 1536)
        #expect(run.samples.filter { $0.duration != 1536 }.count <= 2)
        let muxed = try MP4Read.segment(try await session.fetch("muxed/0.m4s"))
        #expect(muxed.runs.map(\.trackID) == [1, 2])
    }

    @Test func audioShorterThanVideoReachesTheEnd() async throws {
        // The MP3 track is 6 s, the video 8: the last segment's audio is
        // stretched to the video's end so the player's clock gets there.
        let session = try await Fixtures.open("laced-xiph-mp3.mkv")
        let last = session.segmentCount - 1
        let audio = try #require(try MP4Read.segment(await session.fetch("audio-2/\(last).m4s")).runs.first)
        let video = try #require(try MP4Read.segment(await session.fetch("video/\(last).m4s")).runs.first)
        let audioEnd = Double(audio.endDecodeTime) / 44100
        let videoEnd = Double(video.endDecodeTime) / 120_000
        #expect(abs(audioEnd - videoEnd) < 0.03, "audio ends at \(audioEnd), video at \(videoEnd)")
    }

    @Test func audioStartingLateIsLeadIn() async throws {
        // Audio from 2 s, video from 0: a placeholder sample covers the
        // first 2 s, so the player starts with the video.
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("h264-bframes-aac.mkv"))
        writer.frames = writer.frames.filter { $0.track != 2 || $0.timestamp >= 2000 }
        let session = try await open(writer.write())
        let run = try #require(try MP4Read.segment(await session.fetch("audio-2/0.m4s")).runs.first)
        let videoStart = try #require(try MP4Read.segment(await session.fetch("video/0.m4s")).runs.first).baseDecodeTime
        #expect(abs(Double(run.baseDecodeTime) / 44100 - Double(videoStart) / 120_000) < 0.001)
        #expect(Double(run.samples[0].duration) / 44100 > 1.9)
    }

    @Test func audioStoredBeforeItsSegmentIsFound() async throws {
        // Audio frames just after the 6 s boundary moved ahead of the
        // keyframe that starts the second segment, into the first
        // segment's clusters.
        let original = try Fixtures.data("h264-bframes-aac.mkv")
        var writer = try await MatroskaTestWriter.load(original)
        let keyframe = try #require(writer.frames.firstIndex { $0.track == 1 && $0.isKeyframe && $0.timestamp == 6000 })
        let early = writer.frames.enumerated().filter { $0.element.track == 2 && $0.element.timestamp >= 6000 && $0.element.timestamp < 6300 }
        #expect(early.count > 5)
        var frames = writer.frames.enumerated().filter { item in !early.contains { $0.offset == item.offset } }.map(\.element)
        let insertAt = try #require(frames.firstIndex { $0.track == 1 && $0.timestamp == writer.frames[keyframe].timestamp && $0.isKeyframe })
        frames.insert(contentsOf: early.map(\.element), at: insertAt)
        writer.frames = frames
        let crafted = try await open(writer.write())
        try await expectSameOutput(crafted, try await open(original))
    }
}
