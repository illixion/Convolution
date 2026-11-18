/*
 VP8 re-encoded (`VideoTranscode.swift`) and Vorbis decoded to ALAC
 (`AudioTranscode.swift`, `Vorbis.swift`), with FFmpeg's decoders (the
 FFmpegDecoders package; the decoding tests are skipped where it was built
 without them), read back through AVFoundation on the Mac.

 The fixture (`make-fixtures.sh`) is 6 s of VP8 with alt-ref frames, 25 fps,
 a keyframe every 2 s, and a 440 Hz Vorbis tone from FFmpeg's encoder (which
 writes long blocks only): two segments.
 */

#if canImport(AVFoundation) && os(macOS)

import AVFoundation
import FFmpegDecoders
import Foundation
import Testing
@testable import MatroskaRemux

@Suite("VP8 and Vorbis", .serialized)
struct VP8VorbisTests {
    static let name = "vp8-vorbis.webm"
    static var decodes: Bool {
        FFmpegRemuxVideoDecoder.decoding.decodes("V_VP8") && FFmpegRemuxDecoder.decoding.decodes("A_VORBIS")
    }

    static var options: RemuxOptions {
        var options = RemuxOptions()
        options.audioDecoding = FFmpegRemuxDecoder.decoding
        options.videoDecoding = FFmpegRemuxVideoDecoder.decoding
        return options
    }

    @Test func vorbisPacketLengths() async throws {
        let header = try await MatroskaHeaderReader.read(try Fixtures.source(Self.name))
        let track = try #require(header.tracks.first { $0.codecID == "A_VORBIS" })
        let setup = try #require(VorbisSetup(codecPrivate: track.codecPrivate))
        #expect(setup.sampleRate == 44100)
        #expect(setup.channels == 2)
        // FFmpeg's encoder: one block size.
        #expect(setup.blockSizes == (2048, 2048))
        #expect(!setup.modeIsLong.isEmpty)
        // Half a block per packet adds up to the track's length, give or
        // take a block.
        let frames = try await TranscodeTests.frames(of: track.number, in: Self.name)
        let total = frames.reduce(0) { $0 + setup.samples(in: $1) }
        #expect(abs(total - 6 * 44100) <= 2048, "\(total) samples")
    }

    /// A setup header's mode list, read back from its end: written LSB
    /// first after some codebook-like bytes, as libvorbis does.
    @Test(arguments: [[false, true], [true], [false, true, true, false, true]])
    func vorbisModes(_ modes: [Bool]) throws {
        var bits: [Bool] = []
        func put(_ value: Int, _ count: Int) { for i in 0 ..< count { bits.append(value >> i & 1 == 1) } }
        for byte in [0x83, 0x42, 0x11, 0xF0, 0x5A, 0x00, 0xFF, 0x07] { put(byte, 8) }
        put(1, 3) // stray bits before the list
        put(modes.count - 1, 6)
        for (i, long) in modes.enumerated() {
            put(long ? 1 : 0, 1)
            put(0, 16)
            put(0, 16)
            put(i % 2, 8) // mapping
        }
        put(1, 1) // framing
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, bit) in bits.enumerated() where bit { bytes[i / 8] |= 1 << (i % 8) }
        #expect(VorbisSetup.modes(setup: bytes) == modes)

        // A packet's mode bits pick its block.
        let bitsPerMode = modes.count <= 1 ? 0 : Int.bitWidth - (modes.count - 1).leadingZeroBitCount
        let setup = VorbisSetup(sampleRate: 48000, channels: 2, blockSizes: (256, 2048), modeIsLong: modes)
        for (mode, long) in modes.enumerated() {
            #expect(bitsPerMode <= 7)
            #expect(setup.samples(in: [UInt8(mode << 1), 0]) == (long ? 1024 : 128))
        }
        #expect(setup.samples(in: [1, 0]) == 0, "a header packet")
    }

    @Test func declinedWithoutDecoders() async throws {
        await #expect(throws: RemuxError.declined("video codec V_VP8")) { _ = try await Fixtures.open(Self.name) }
        await #expect(throws: RemuxError.declined("video codec V_VP8")) {
            _ = try await VideoStill.make(source: try Fixtures.source(Self.name))
        }
    }

    @Test(.enabled(if: decodes))
    func offeredAsHEVCAndALAC() async throws {
        let session = try await Fixtures.open(Self.name, options: Self.options)
        let summary = session.summary
        #expect(summary.video.codec == "VP8 as HEVC" || summary.video.codec == "VP8 as H.264")
        #expect(summary.video.codecs.hasPrefix("hvc1.") || summary.video.codecs.hasPrefix("avc1."))
        #expect(summary.width == 320 && summary.height == 180)
        let audio = try #require(summary.audio.first)
        #expect(audio.codec == "Vorbis")
        #expect(audio.codecs == "alac")
        #expect(audio.channels == 2)
        #expect(summary.dropped.isEmpty)
        #expect(session.segmentCount >= 2)
        #expect(session.masterPlaylist.contains("alac"))
    }

    /// Every frame decodes, each segment starts with a keyframe and decodes
    /// on its own (a seek lands on any of them), in presentation order.
    @Test(.enabled(if: decodes))
    func everySegmentDecodesOnItsOwn() async throws {
        let session = try await Fixtures.open(Self.name, options: Self.options)
        let initSegment = try await session.fetch("video/init.mp4")
        var total = 0
        for k in (0 ..< session.segmentCount).reversed() {
            let segment = try await session.fetch("video/\(k).m4s")
            let run = try #require(try MP4Read.segment(segment).runs.first)
            #expect(run.samples.first?.isSync == true, "segment \(k) starts with a keyframe")
            #expect(run.samples.dropFirst().allSatisfy { !$0.isSync })
            let frames = try await Self.decodeVideo(initSegment + segment)
            #expect(frames.count == run.samples.count, "segment \(k): \(frames.count) of \(run.samples.count)")
            #expect(frames.times == frames.times.sorted())
            #expect(frames.distinct > 1, "segment \(k)'s pictures move")
            total += frames.count
            // Asked for again, the same bytes (kept).
            #expect(try await session.fetch("video/\(k).m4s") == segment)
        }
        // testsrc2 at 25 fps for 6 s; alt-ref frames show nothing.
        #expect(total == 150)
    }

    /// The whole file, muxed, plays: video and the decoded Vorbis tone.
    @Test(.enabled(if: decodes))
    func muxedPlaysWithTheTone() async throws {
        let session = try await Fixtures.open(Self.name, options: Self.options)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp8-\(UUID().uuidString).mp4")
        try await session.concatenated("muxed").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var left: [Double] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                        dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Int32.self, capacity: length / 4) { samples in
                for i in stride(from: 0, to: length / 4, by: 2) { left.append(Double(samples[i])) }
            }
        }
        #expect(reader.status == .completed)
        #expect(abs(Double(left.count) / 44100 - 6) < 0.1, "\(Double(left.count) / 44100) s of audio")
        // 440 Hz throughout, not silence: in each second.
        for second in 0 ..< 5 {
            let window = Array(left[(second * 44100 + 4410) ..< ((second + 1) * 44100)])
            let tone = Self.power(window, 440), off = Self.power(window, 1000)
            #expect(tone > 1000 * off, "second \(second)")
            #expect(window.map(abs).max() ?? 0 > 1e7, "second \(second) is loud")
        }
    }

    @Test(.enabled(if: decodes))
    func vp9WithVorbisPlays() async throws {
        let session = try await Fixtures.open("vp9-vorbis.webm", options: Self.options)
        #expect(session.summary.audio.first?.codec == "Vorbis")
        #expect(session.summary.video.codec.hasPrefix("VP9"))
    }

    @Test(.enabled(if: decodes))
    func stillIsTheDecodedKeyframe() async throws {
        let still = try await VideoStill.make(source: try Fixtures.source(Self.name),
                                              videoDecoding: FFmpegRemuxVideoDecoder.decoding)
        #expect(still.mp4.isEmpty)
        let image = try #require(still.image)
        #expect(image.width == 320 && image.height == 180)
        #expect(VideoStillTests.spread(image) > 100, "a real picture")
    }

    // MARK: - Helpers

    static func decodeVideo(_ data: Data) async throws -> (count: Int, times: [Double], distinct: Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp8-\(UUID().uuidString).mp4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        var sums = Set<Int>()
        while let buffer = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(buffer) else { continue }
            times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            var sum = 0
            for row in Swift.stride(from: 0, to: CVPixelBufferGetHeightOfPlane(image, 0), by: 4) {
                for x in Swift.stride(from: 0, to: CVPixelBufferGetWidthOfPlane(image, 0), by: 4) {
                    sum &+= Int(base[row * stride + x]) &* (x + 1)
                }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            sums.insert(sum)
        }
        #expect(reader.status == .completed, "\(reader.error.map { "\($0)" } ?? "")")
        return (times.count, times, sums.count)
    }

    /// Goertzel power of one frequency at 44.1 kHz.
    static func power(_ samples: [Double], _ frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / 44100, coefficient = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s = x + coefficient * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2
    }
}

#endif
