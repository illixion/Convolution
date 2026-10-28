import Foundation
import Testing
@testable import MatroskaRemux

/// Subtitle tracks: listed with their flags, read near a time through the
/// Cues without touching the video, or collected from the segments parsed.
@Suite("Subtitles")
struct SubtitleTests {
    /// The AAC track's priming (1024 samples at 44.1 kHz) puts the file's
    /// zero this far into the remux's timeline.
    static let priming = 1024.0 / 44100

    @Test func reopeningMidFileKeepsVideoAndSubtitleTimeline() async throws {
        // Keyframes intentionally do not fall on six-second boundaries.
        // A server remux restarted here must not rebase the next segment
        // or its captions to a new, estimated timeline.
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("subtitles.mkv"))
        for i in writer.frames.indices {
            writer.frames[i].timestamp = writer.frames[i].timestamp * 237 / 100
        }
        if let duration = writer.duration { writer.duration = duration * 2.37 }
        let data = writer.write()
        let uninterrupted = try await RemuxSession.open(source: DataByteSource(data))
        #expect(uninterrupted.segmentCount > 1)
        // Establish what straight-through playback produces.
        let video = try await uninterrupted.allSegments("video")
        let captions = try await uninterrupted.subtitleBlocks(track: 3, from: 0, through: 60).blocks
        #expect(captions.count == 3)
        for (cue, seconds) in zip(captions, [2.37, 7.11, 11.85]) {
            #expect(abs(cue.start - seconds - Self.priming) < 0.001)
        }
        // Fresh decoder/session, middle segment first, then backwards and
        // forwards. Neither request order nor session lifetime changes PTS.
        for _ in 0 ..< 3 {
            let resumed = try await RemuxSession.open(source: DataByteSource(data))
            for index in Array((0 ..< resumed.segmentCount).reversed()) + [0, resumed.segmentCount - 1] {
                let actual = try MP4Read.segment(await resumed.fetch("video/\(index).m4s"))
                let expected = try MP4Read.segment(video[index])
                #expect(actual.runs.first?.baseDecodeTime == expected.runs.first?.baseDecodeTime)
                #expect(actual.runs.first?.samples.map(\.compositionOffset)
                        == expected.runs.first?.samples.map(\.compositionOffset))
            }
            let reread = try await resumed.subtitleBlocks(track: 3, from: 0, through: 60).blocks
            #expect(reread.map(\.start) == captions.map(\.start))
            #expect(reread.map(\.data) == captions.map(\.data))
        }
    }

    @Test func listsTracksWithTheirFlags() async throws {
        let session = try await Fixtures.open("subtitles.mkv")
        let tracks = session.subtitleTracks
        #expect(tracks.map(\.number) == [3, 4, 5])
        #expect(tracks.map(\.format) == [.subRip, .ass, .pgs])
        #expect(tracks.map(\.language) == ["en", "fr", "de"])
        #expect(tracks.map(\.name) == ["English", nil, nil])
        #expect(tracks.map(\.isForced) == [false, true, false])
        #expect(tracks.map(\.isHearingImpaired) == [false, false, true])
        #expect(tracks.allSatisfy { $0.isIndexed && $0.unsupportedReason == nil })
        // Subtitles stay out of the HLS.
        #expect(!session.masterPlaylist.contains("SUBTITLES"))
    }

    @Test func readsBlocksNearATimeWithoutTheVideo() async throws {
        let counting = CountingSource(try Fixtures.source("subtitles.mkv"))
        let session = try await RemuxSession.open(source: counting)
        let opened = counting.ranges.count
        let (blocks, revision) = try await session.subtitleBlocks(track: 3, from: 2.5, through: 4.5)
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(String(decoding: block.data, as: UTF8.self) == "Two")
        #expect(abs(block.start - (3 + Self.priming)) < 0.001)
        #expect(abs((block.duration ?? 0) - 1) < 0.001)
        #expect(revision == 1)
        let reads = counting.ranges.dropFirst(opened)
        #expect(reads.count <= 2)
        #expect(reads.reduce(0) { $0 + $1.count } < 16 << 10)
        #expect(await session.bytesRead == 0)

        // Asking again reads nothing new.
        let again = try await session.subtitleBlocks(track: 3, from: 2.5, through: 4.5)
        #expect(again.revision == revision)
        #expect(counting.ranges.count == opened + reads.count)
    }

    @Test func everyFormatReadsAsTheFileHasIt() async throws {
        let session = try await Fixtures.open("subtitles.mkv")
        let srt = try await session.subtitleBlocks(track: 3, from: 0, through: 60).blocks
        // mkvmerge stores SubRip's line breaks as CRLF.
        #expect(srt.map { String(decoding: $0.data, as: UTF8.self) } == ["One <i>italic</i>", "Two", "Three\r\nlines"])
        #expect(srt.map { (($0.duration ?? 0) * 10).rounded() / 10 } == [1, 1, 1.5])

        let ass = try await session.subtitleBlocks(track: 4, from: 0, through: 60).blocks
        #expect(ass.count == 2)
        #expect(String(decoding: ass[0].data, as: UTF8.self).hasSuffix(",Default,,0,0,0,,{\\i1}Un{\\i0}\\Ndeux, trois"))
        #expect(abs(ass[1].start - (4 + Self.priming)) < 0.001)

        // PGS: a display set per block, the first segment a composition.
        let pgs = try await session.subtitleBlocks(track: 5, from: 0, through: 60).blocks
        #expect(pgs.map { ($0.start - Self.priming).rounded() } == [2, 3, 6, 7])
        #expect(pgs.allSatisfy { $0.data.first == 0x16 })
    }

    @Test func unindexedTracksFillFromTheSegmentsParsed() async throws {
        let session = try await Fixtures.open("subtitles-unindexed.mkv")
        #expect(session.subtitleTracks.map(\.isIndexed) == [false, false])
        #expect(try await session.subtitleBlocks(track: 3, from: 0, through: 60).blocks.isEmpty)
        for k in 0 ..< session.segmentCount { _ = try await session.data(at: "video/\(k).m4s") }
        let (blocks, revision) = try await session.subtitleBlocks(track: 3, from: 0, through: 60)
        // zlib undone.
        #expect(blocks.map { String(decoding: $0.data, as: UTF8.self) } == ["One <i>italic</i>", "Two", "Three\r\nlines"])
        #expect(revision == 3)
        #expect(try await session.subtitleBlocks(track: 4, from: 0, through: 60).blocks.count == 2)
        // Parsing again adds nothing.
        _ = try await session.data(at: "muxed/0.m4s")
        #expect(try await session.subtitleBlocks(track: 3, from: 0, through: 60).revision == revision)
    }

    @Test func aFileStartingLaterPlaysFromZero() async throws {
        // Everything 7 s later, as in a file cut from a recording: the
        // player's clock still starts at 0, and so do the remux and its
        // subtitles.
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("subtitles.mkv"))
        for i in writer.frames.indices { writer.frames[i].timestamp += 7000 }
        let session = try await RemuxSession.open(source: DataByteSource(writer.write()))
        let video = try #require(try MP4Read.segment(await session.fetch("video/0.m4s")).runs.first)
        #expect(Double(video.baseDecodeTime) / 120_000 < 0.05)
        let (blocks, _) = try await session.subtitleBlocks(track: 3, from: 0, through: 60)
        #expect(abs((blocks.first?.start ?? -1) - (1 + Self.priming)) < 0.001)
    }

    @Test func unsupportedTracksAreListedNotRead() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("subtitles.mkv"))
        let index = try #require(writer.tracks.firstIndex { $0.number == 5 })
        writer.tracks[index].codecID = "S_VOBSUB"
        let session = try await RemuxSession.open(source: DataByteSource(writer.write()))
        let track = try #require(session.subtitleTracks.first { $0.number == 5 })
        #expect(track.format == .unsupported)
        #expect(track.unsupportedReason == "S_VOBSUB")
        _ = try await session.data(at: "video/0.m4s")
        #expect(try await session.subtitleBlocks(track: 5, from: 0, through: 60).blocks.isEmpty)
    }
}
