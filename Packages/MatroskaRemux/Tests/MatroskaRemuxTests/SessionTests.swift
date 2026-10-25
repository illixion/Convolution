import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Remux sessions")
struct SessionTests {
    struct Expectation: Sendable, CustomTestStringConvertible {
        var file: String
        var videoEntry: String
        var codecs: String
        var range = "SDR"
        var audioEntries: [String]
        var audioCodecs: [String]
        var channels: [Int]
        var timescales: [UInt32]
        var testDescription: String { file }
    }

    static let expectations: [Expectation] = [
        .init(file: "vp9-opus.webm", videoEntry: "vp09", codecs: "vp09.00.11.08.00.02.02.02.00",
              audioEntries: ["Opus"], audioCodecs: ["Opus"], channels: [1], timescales: [48000]),
        .init(file: "h264-bframes-aac.mkv", videoEntry: "avc1", codecs: "avc1.64000C",
              audioEntries: ["mp4a"], audioCodecs: ["mp4a.40.2"], channels: [1], timescales: [44100]),
        .init(file: "hevc-hdr10.mkv", videoEntry: "hvc1", codecs: "hvc1.2.4.L60.90", range: "PQ",
              audioEntries: ["mp4a"], audioCodecs: ["mp4a.40.2"], channels: [1], timescales: [44100]),
        .init(file: "ac3-51.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: ["ac-3"], audioCodecs: ["ac-3"], channels: [6], timescales: [44100]),
        .init(file: "eac3-51.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: ["ec-3"], audioCodecs: ["ec-3"], channels: [6], timescales: [44100]),
        .init(file: "flac.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: ["fLaC"], audioCodecs: ["fLaC"], channels: [1], timescales: [22050]),
        .init(file: "two-audio.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: ["mp4a", "ac-3"], audioCodecs: ["mp4a.40.2", "ac-3"], channels: [1, 2],
              timescales: [44100, 44100]),
        .init(file: "laced-xiph-mp3.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: [".mp3"], audioCodecs: ["mp4a.40.34"], channels: [1], timescales: [44100]),
        .init(file: "laced-ebml-aac.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: ["mp4a"], audioCodecs: ["mp4a.40.2"], channels: [1], timescales: [44100]),
        .init(file: "live.webm", videoEntry: "vp09", codecs: "vp09.00.11.08.00.02.02.02.00",
              audioEntries: ["Opus"], audioCodecs: ["Opus"], channels: [1], timescales: [48000]),
        .init(file: "av1-opus.mkv", videoEntry: "av01", codecs: "av01.0.00M.08.0.110.02.02.02.0",
              audioEntries: ["Opus"], audioCodecs: ["Opus"], channels: [1], timescales: [48000]),
        .init(file: "mp3.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: [".mp3"], audioCodecs: ["mp4a.40.34"], channels: [1], timescales: [44100]),
        .init(file: "alac.mkv", videoEntry: "avc1", codecs: "avc1.64000B",
              audioEntries: ["alac"], audioCodecs: ["alac"], channels: [1], timescales: [22050]),
    ]

    /// Opens each fixture and checks what it declares: sample entries,
    /// CODECS, range, the audio renditions.
    @Test(arguments: expectations)
    func declares(_ expected: Expectation) async throws {
        let session = try await Fixtures.open(expected.file)
        let summary = session.summary
        #expect(summary.video.codecs.hasPrefix(expected.codecs), "\(summary.video.codecs)")
        #expect(summary.videoRange == expected.range)
        #expect(summary.audio.map(\.codecs) == expected.audioCodecs)
        #expect(summary.audio.map { $0.channels ?? 0 } == expected.channels)

        let video = try MP4Read.initSegment(try await session.fetch("video/init.mp4"))
        #expect(video.map(\.entryType) == [expected.videoEntry])
        #expect(video.first?.handler == "vide")
        for (i, track) in summary.audio.enumerated() {
            let audio = try MP4Read.initSegment(try await session.fetch("audio-\(track.number)/init.mp4"))
            #expect(audio.map(\.entryType) == [expected.audioEntries[i]])
            #expect(audio.first?.timescale == expected.timescales[i])
        }
        let muxed = try MP4Read.initSegment(try await session.fetch("muxed/init.mp4"))
        #expect(muxed.map(\.entryType) == [expected.videoEntry, expected.audioEntries[0]])
        #expect(muxed.map(\.trackID) == [1, 2])

        let master = session.masterPlaylist
        #expect(master.contains("CODECS=\"\(([summary.video.codecs] + Array(NSOrderedSet(array: expected.audioCodecs)) .map { "\($0)" }).joined(separator: ","))\""))
        #expect(master.contains("VIDEO-RANGE=\(expected.range)"))
        #expect(master.components(separatedBy: "#EXT-X-MEDIA:TYPE=AUDIO").count - 1 == expected.audioCodecs.count)
    }

    /// Every frame lands in exactly one segment, in order, with continuous
    /// decode times, and the counts match what ffprobe sees in the file.
    @Test(arguments: expectations)
    func segmentsCoverEveryFrame(_ expected: Expectation) async throws {
        let session = try await Fixtures.open(expected.file)
        let streams = try Fixtures.expected(expected.file)
        let videoPackets = try #require(streams.first { $0.type == "video" }).packets
        let audioPackets = streams.filter { $0.type == "audio" }.map(\.packets)

        // Video: sync first sample, decode times continuous and increasing.
        var videoSamples = 0
        var previousEnd: UInt64?
        var presentation: [Int64] = []
        for (k, data) in try await session.allSegments("video").enumerated() {
            let segment = try MP4Read.segment(data)
            #expect(segment.sequenceNumber == UInt32(k + 1))
            let run = try #require(segment.runs(track: 1).first)
            #expect(segment.runs.count == 1)
            #expect(run.samples.first?.isSync == true, "segment \(k) starts with a keyframe")
            if let previousEnd { #expect(run.baseDecodeTime == previousEnd, "video decode time continuous at \(k)") }
            previousEnd = run.endDecodeTime
            var decode = Int64(run.baseDecodeTime)
            for sample in run.samples {
                #expect(sample.duration > 0)
                presentation.append(decode + Int64(sample.compositionOffset))
                decode += Int64(sample.duration)
            }
            videoSamples += run.samples.count
        }
        #expect(videoSamples == videoPackets)
        #expect(Set(presentation).count == presentation.count, "no presentation time twice")
        #expect(presentation.min() ?? -1 >= 0)

        // Audio: every frame once; decode times exactly continuous across
        // segments (frame lengths from the codec, not from timestamps).
        for (i, track) in session.summary.audio.enumerated() {
            var samples = 0
            var end: UInt64?
            for (k, data) in try await session.allSegments("audio-\(track.number)").enumerated() {
                let segment = try MP4Read.segment(data)
                for run in segment.runs {
                    if let end, !run.samples.isEmpty {
                        #expect(run.baseDecodeTime == end, "audio \(track.number) continuous at segment \(k)")
                    }
                    if !run.samples.isEmpty { end = run.endDecodeTime }
                    samples += run.samples.count
                }
            }
            #expect(samples == audioPackets[i], "audio \(track.number) frames")
        }
    }

    @Test func boundariesAreKeyframesMerged() async throws {
        // A keyframe a second: 6 s segments, the 2 s rest its own segment.
        let session = try await Fixtures.open("vp9-opus.webm")
        #expect(session.index.boundaries.map(\.time) == [0, 6000])
        let playlist = try await session.fetch("video.m3u8")
        let text = String(decoding: playlist, as: UTF8.self)
        #expect(text.contains("#EXT-X-TARGETDURATION:6"))
        #expect(text.contains("#EXTINF:6.000000,\nvideo/0.m4s"))
        #expect(text.contains("#EXT-X-MAP:URI=\"video/init.mp4\""))
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func liveStreamIsIndexedByScanning() async throws {
        let session = try await Fixtures.open("live.webm")
        #expect(session.summary.scannedClusters)
        #expect(abs(session.summary.durationSeconds - 7) < 0.1)
        // A remote source without Cues is declined rather than scanned.
        await #expect(throws: RemuxError.declined("no Cues, and the source is remote")) {
            _ = try await RemuxSession.open(source: RemoteLike(try Fixtures.source("live.webm")))
        }
    }

    @Test func twoAudioRenditions() async throws {
        let session = try await Fixtures.open("two-audio.mkv")
        let master = session.masterPlaylist
        #expect(master.contains(#"NAME="Main Stereo",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="1",URI="audio-2.m3u8""#))
        #expect(master.contains(#"NAME="Commentaire",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio-3.m3u8""#))
        #expect(master.contains(#"AUDIO="audio""#))
        let english = try MP4Read.initSegment(try await session.fetch("audio-2/init.mp4"))
        let french = try MP4Read.initSegment(try await session.fetch("audio-3/init.mp4"))
        #expect(english.first?.language == "eng")
        #expect(french.first?.language == "fra")
        // The muxed fallback carries the default track.
        let muxed = try MP4Read.initSegment(try await session.fetch("muxed/init.mp4"))
        #expect(muxed.last?.entryType == "mp4a")
    }

    @Test func declines() async throws {
        await #expect(throws: RemuxError.declined("video codec V_VP8")) {
            _ = try await Fixtures.open("vp8-opus.webm")
        }
        await #expect(throws: RemuxError.declined("no playable audio (A_VORBIS)")) {
            _ = try await Fixtures.open("vp9-vorbis.webm")
        }
    }

    @Test func hdrSampleEntryCarriesColour() async throws {
        let session = try await Fixtures.open("hevc-hdr10.mkv")
        let video = try #require(try MP4Read.initSegment(await session.fetch("video/init.mp4")).first)
        // colr nclx: BT.2020 primaries, PQ, BT.2020 non-constant, limited.
        #expect(video.entryChildren["colr"] == Array("nclx".utf8) + [0, 9, 0, 16, 0, 9, 0])
        #expect(video.entryChildren["mdcv"] == [0x21, 0x34, 0x9B, 0xAA, 0x19, 0x96, 0x08, 0xFC, 0x8A, 0x48, 0x39, 0x08,
                                                 0x3D, 0x13, 0x40, 0x42, 0x00, 0x98, 0x96, 0x80, 0, 0, 0, 1])
        #expect(video.entryChildren["clli"] == [0x03, 0xE8, 0x01, 0x90])
        #expect(video.entryChildren["hvcC"] != nil)
    }

    @Test func vp9ConfigurationFromTheKeyframe() async throws {
        let session = try await Fixtures.open("vp9-opus.webm")
        let video = try #require(try MP4Read.initSegment(await session.fetch("video/init.mp4")).first)
        // vpcC v1: profile 0, level 1.1 (320×180 at 25 fps), 8-bit 4:2:0;
        // libvpx writes color_space unknown and the WebM has no Colour, so
        // primaries, transfer and matrix are all "unspecified".
        #expect(video.entryChildren["vpcC"] == [1, 0, 0, 0, 0, 11, 0x80, 2, 2, 2, 0, 0])
    }

    @Test func unknownPathsAreNil() async throws {
        let session = try await Fixtures.open("vp9-opus.webm")
        #expect(try await session.data(at: "video/99.m4s") == nil)
        #expect(try await session.data(at: "audio-9.m3u8") == nil)
        #expect(try await session.data(at: "../etc/passwd") == nil)
        #expect(session.resource(at: "audio-2/1.m4s") == .audioSegment(2, 1))
        #expect(session.resource(at: "muxed/0.m4s") == .muxedSegment(0))
    }

    @Test func outputIsDeterministic() async throws {
        let first = try await Fixtures.open("h264-bframes-aac.mkv")
        let second = try await Fixtures.open("h264-bframes-aac.mkv")
        for path in ["video/1.m4s", "audio-2/0.m4s", "muxed/1.m4s", "video/0.m4s"] {
            let a = try await first.data(at: path)?.data
            let b = try await second.data(at: path)?.data
            #expect(a == b, "\(path)")
            #expect(try await first.data(at: path)?.data == a, "\(path) again")
        }
    }
}

/// A file source that says it isn't local.
struct RemoteLike: ByteSource {
    let base: FileByteSource
    init(_ base: FileByteSource) { self.base = base }
    func length() async throws -> Int64? { try await base.length() }
    func read(_ range: Range<Int64>) async throws -> Data { try await base.read(range) }
    var isLocal: Bool { false }
}
