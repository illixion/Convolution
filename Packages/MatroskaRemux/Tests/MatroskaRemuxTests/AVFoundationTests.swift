/*
 What AVFoundation makes of the remux, on the Mac: each fixture's muxed
 rendition (init plus every segment, as one fragmented MP4) opened as an
 asset, its format descriptions read, and every video and audio frame
 decoded. The HLS path itself (playlists, renditions, seeking, audio
 switching) is exercised end to end by the app's `-RemuxHarness`.
 */

#if canImport(AVFoundation) && os(macOS)

import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import MatroskaRemux

@Suite("AVFoundation decodes the remux", .serialized)
struct AVFoundationTests {
    @MainActor
    @Test func hlsPauseAndDecoderReplacementKeepThePlayhead() async throws {
        let session = try await Fixtures.open("subtitles.mkv")
        let (server, base) = try await LoopbackServer.start(session)
        defer { server.stop() }
        let url = base.appendingPathComponent("master.m3u8")
        let player = AVPlayer()
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil) }
        for _ in 0 ..< 3 {
            // Discard the decoder, then reopen at a non-keyframe position,
            // as after an interruption that takes the decoder away.
            let item = AVPlayerItem(url: url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            player.replaceCurrentItem(with: item)
            for _ in 0 ..< 100 where item.status == .unknown {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(item.status == .readyToPlay)
            let target = CMTime(seconds: 3.4, preferredTimescale: 600)
            #expect(await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero))
            #expect(abs(player.currentTime().seconds - target.seconds) < 0.05)
            player.play()
            var displayed = CMTime.invalid
            for _ in 0 ..< 60 {
                let now = player.currentTime()
                if output.hasNewPixelBuffer(forItemTime: now),
                   output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &displayed) != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(displayed.isNumeric)
            #expect(abs(displayed.seconds - player.currentTime().seconds) < 0.2)
            player.pause()
            let paused = player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(300))
            #expect(abs(player.currentTime().seconds - paused) < 0.05)
            player.play()
            try await Task.sleep(for: .milliseconds(300))
            #expect(player.currentTime().seconds > paused + 0.1, "resume must advance without rebuilding the stream")
            #expect(player.currentTime().seconds - paused < 0.7, "resume must not jump to another segment")
            player.pause()
        }
    }

    init() {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    }

    static var decodable: [String] {
        Fixtures.playable.filter { $0 != "av1-opus.mkv" || VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remux-\(UUID().uuidString)-\(name).mp4")
        try data.write(to: url)
        return url
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }

    /// Decodes every sample of a track; returns (sample buffers' sample
    /// count, presentation times of video frames).
    private func decode(_ asset: AVURLAsset, _ track: AVAssetTrack, video: Bool) async throws -> (count: Int, times: [Double]) {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
               AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        #expect(reader.startReading(), "\(reader.error.map { "\($0)" } ?? "")")
        var count = 0
        var times: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            count += video ? (CMSampleBufferGetImageBuffer(buffer) != nil ? 1 : 0) : CMSampleBufferGetNumSamples(buffer)
            if video { times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds) }
        }
        #expect(reader.status == .completed, "\(reader.error.map { "\($0)" } ?? "")")
        return (count, times)
    }

    @Test(arguments: decodable)
    func decodesEveryFrame(_ name: String) async throws {
        let session = try await Fixtures.open(name)
        let url = try write(try await session.concatenated("muxed"), name)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))

        let streams = try Fixtures.expected(name)
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let video = try await decode(asset, videoTrack, video: true)
        #expect(video.count == streams.first { $0.type == "video" }?.packets, "every video frame decodes")
        #expect(video.times == video.times.sorted(), "frames come out in presentation order")

        // Audio: the decoded PCM covers the frames muxed (the decoder may
        // trim an encoder's priming at the start, at most a couple of frames).
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audio = try await decode(asset, audioTrack, video: false)
        // What the frames decode to: each sample's duration, but a sample
        // stretched over a gap (the last, where audio is shorter than the
        // video) counts as one frame, the most common length.
        var durations: [Int] = []
        for data in try await session.allSegments("muxed") {
            for run in try MP4Read.segment(data).runs(track: 2) { durations += run.samples.map { Int($0.duration) } }
        }
        let typical = Dictionary(grouping: durations, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? 0
        let muxedSamples = durations.reduce(0) { $0 + min($1, typical) }
        #expect(audio.count > 0)
        #expect(abs(audio.count - muxedSamples) <= 3 * 1536, "decoded \(audio.count) of \(muxedSamples) samples")
    }

    @Test func hdrFormatDescription() async throws {
        let session = try await Fixtures.open("hevc-hdr10.mkv")
        let url = try write(try await session.concatenated("video"), "hdr")
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(Self.fourCC(CMFormatDescriptionGetMediaSubType(description)) == "hvc1")
        let extensions = try #require(CMFormatDescriptionGetExtensions(description) as? [String: Any])
        #expect(extensions[kCVImageBufferTransferFunctionKey as String] as? String == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(extensions[kCVImageBufferColorPrimariesKey as String] as? String == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil)
        #expect(extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil)
        #expect(extensions["BitsPerComponent"] as? Int == 10)
    }

    @Test func dolbyVisionFormatDescription() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("hevc-hdr10.mkv"))
        let payload: [UInt8] = [1, 0, 0x10, 0x35, 0x10] + [UInt8](repeating: 0, count: 19)
        writer.tracks[0].blockAdditionMappings = [.init(idValue: nil, idType: 0x6476_7643, extraData: payload)]
        let session = try await RemuxSession.open(source: DataByteSource(writer.write()))
        let url = try write(try await session.concatenated("video"), "dv")
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let extensions = try #require(CMFormatDescriptionGetExtensions(description) as? [String: Any])
        let atoms = try #require(extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any])
        #expect(atoms["dvvC"] != nil, "CoreMedia keeps the Dolby Vision configuration")
        #expect(atoms["hvcC"] != nil)
    }

    @Test func audioGapStillDecodes() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("ac3-51.mkv"))
        let audio = writer.frames.indices.filter { writer.frames[$0].track == 2 }
        let removed = Set(audio[40 ..< 60])
        writer.frames = writer.frames.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let session = try await RemuxSession.open(source: DataByteSource(writer.write()))
        let url = try write(try await session.concatenated("muxed"), "gap")
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let decoded = try await decode(asset, track, video: false)
        // Every frame decodes; the bridged gap is the player's to fill.
        #expect(decoded.count >= 124 * 1536 - 3 * 1536, "decoded \(decoded.count)")
    }
}

#endif
