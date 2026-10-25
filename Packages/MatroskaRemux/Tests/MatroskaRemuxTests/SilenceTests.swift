/*
 The frames that fill audio gaps decode to silence: each codec's silent
 frame, eight in a row in an MP4 with the track's own sample entry, decoded
 by AVFoundation on the Mac, and a track that starts late, whose lead-in
 used to be a copy of its first frame (a blip of the soundtrack).
 */

#if canImport(AVFoundation) && os(macOS)

import AVFoundation
import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Silence in audio gaps", .serialized)
struct SilenceTests {
    /// One fixture per codec the remux carries.
    static let fixtures = [
        "h264-bframes-aac.mkv", "two-audio.mkv", "ac3-51.mkv", "eac3-51.mkv", "vp9-opus.webm", "flac.mkv",
        "alac.mkv", "mp3.mkv", "laced-xiph-mp3.mkv",
    ]

    @Test(arguments: fixtures)
    func silentFramesDecodeToSilence(_ name: String) async throws {
        let session = try await Fixtures.open(name)
        for plan in session.audio {
            #expect(plan.placeholderIsSilent, "\(plan.codecName) has a silent frame")
            let decoded = try await Self.decode(plan.placeholder, count: 8, plan: plan)
            #expect(decoded.samples > 0, "\(plan.codecName) decodes")
            #expect(decoded.peak == 0, "\(plan.codecName): peak \(decoded.peak)")
        }
    }

    /// AAC LC, AC-3 and E-AC-3 in their channel layouts, made up: a silent
    /// frame follows the configuration, so each layout is its own bitstream.
    @Test func everyChannelLayoutDecodesToSilence() async throws {
        // AAC LC, 48 kHz, channel configurations 1 to 7 (and HE-AAC stereo).
        var ascs: [[UInt8]] = (1 ... 7).map { [0x11, UInt8(0x80 | $0 << 3)] }
        ascs.append([0x2B, 0x11, 0x88, 0x00]) // AOT 5 (SBR): 24 kHz LC core, stereo, 48 kHz out
        for asc in ascs {
            let config = try #require(AACConfig(asc: asc, channelsHint: 2))
            let frame = try #require(SilentFrame.aac(config), "AAC \(asc)")
            let outputRate = config.objectType == 5 ? 2 * config.sampleRate : config.sampleRate
            let entry = SampleEntries.audio("mp4a", channels: config.channels, sampleSize: 16, sampleRate: outputRate) { w in
                SampleEntries.esds(&w, objectType: 0x40, decoderSpecificInfo: config.asc)
            }
            let decoded = try await Self.decode(frame, count: 8, frameSamples: config.frameLength,
                                                sampleRate: config.sampleRate, entry: entry)
            #expect(decoded.samples > 0 && decoded.peak == 0, "AAC \(asc): \(decoded)")
        }
        // AC-3 at 48 kHz, 384 kb/s, every channel mode, with and without LFE.
        for acmod in 0 ..< 8 {
            for lfe in [false, true] {
                var w = BitWriter()
                w.write(0x0B77, bits: 16)
                w.write(0, bits: 16)
                w.write(0, bits: 2) // 48 kHz
                w.write(28, bits: 6) // 384 kb/s
                w.write(8, bits: 5)
                w.write(0, bits: 3)
                w.write(acmod, bits: 3)
                if acmod & 1 != 0, acmod != 1 { w.write(0, bits: 2) }
                if acmod & 4 != 0 { w.write(0, bits: 2) }
                if acmod == 2 { w.write(0, bits: 2) }
                w.write(lfe ? 1 : 0, bits: 1)
                w.write(0, bits: 16)
                let syncframe = try #require(AC3Syncframe(w.bytes))
                let frame = try #require(SilentFrame.ac3(syncframe))
                #expect(frame.count == 1536)
                #expect(AC3Syncframe(frame).map { [$0.acmod, $0.lfeon ? 1 : 0] } == [acmod, lfe ? 1 : 0])
                let entry = SampleEntries.audio("ac-3", channels: syncframe.channels, sampleSize: 16, sampleRate: 48000) {
                    $0.box("dac3", payload: syncframe.dac3)
                }
                let decoded = try await Self.decode(frame, count: 8, frameSamples: 1536, sampleRate: 48000, entry: entry)
                #expect(decoded.samples > 0 && decoded.peak == 0, "AC-3 acmod \(acmod) lfe \(lfe): \(decoded)")
            }
        }
        // E-AC-3 at 48 kHz, six blocks, 256 kb/s: mono, stereo, 5.1.
        for (acmod, lfe) in [(1, false), (2, false), (7, true)] {
            var w = BitWriter()
            w.write(0x0B77, bits: 16)
            w.write(0, bits: 5) // strmtyp, substreamid
            w.write(1024 / 2 - 1, bits: 11)
            w.write(0, bits: 2) // 48 kHz
            w.write(3, bits: 2) // six blocks
            w.write(acmod, bits: 3)
            w.write(lfe ? 1 : 0, bits: 1)
            w.write(16, bits: 5)
            w.write(31, bits: 5)
            w.write(0, bits: 4) // compre, mixmdate, infomdate, addbsie
            w.write(0, bits: 64)
            let header = w.bytes + [UInt8](repeating: 0, count: 1024 - w.bytes.count)
            let info = try #require(EAC3Info(header))
            let frame = try #require(SilentFrame.eac3(info, firstFrame: header))
            #expect(frame.count == 1024)
            #expect(EAC3Info(frame)?.channels == info.channels)
            let entry = SampleEntries.audio("ec-3", channels: info.channels, sampleSize: 16, sampleRate: 48000) {
                $0.box("dec3", payload: info.dec3)
            }
            let decoded = try await Self.decode(frame, count: 8, frameSamples: 1536, sampleRate: 48000, entry: entry)
            #expect(decoded.samples > 0 && decoded.peak == 0, "E-AC-3 acmod \(acmod) lfe \(lfe): \(decoded)")
        }
    }

    /// A track that starts 2 s after the video: its lead-in sample decodes
    /// to silence, not to the track's first frame (here a 330 Hz tone).
    /// AVAssetReader puts decoded audio end to end whatever a sample's
    /// duration, so the lead-in is the first frame's worth of PCM (an AAC
    /// output frame comes from that frame and the one before it).
    @Test func lateTrackLeadsInWithSilence() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("h264-bframes-aac.mkv"))
        writer.frames = writer.frames.filter { $0.track != 2 || $0.timestamp >= 2000 }
        let session = try await RemuxSession.open(source: DataByteSource(writer.write()))
        let first = try #require(try MP4Read.segment(await session.fetch("audio-2/0.m4s")).runs.first?.samples.first)
        #expect(Double(first.duration) / 44100 > 1.9, "the lead-in covers the first 2 s")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remux-\(UUID().uuidString)-late.mp4")
        try await session.concatenated("audio-2").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = try await Self.samples(AVURLAsset(url: url))
        #expect(pcm.count > 3 * 1024)
        #expect(pcm.prefix(1024).map { abs(Int($0)) }.max() == 0, "the lead-in is silent")
        #expect((pcm.dropFirst(2048).prefix(4096).map { abs(Int($0)) }.max() ?? 0) > 1000, "then the tone")
    }

    /// Every decoded sample, in order.
    static func samples(_ asset: AVURLAsset) async throws -> [Int16] {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            bytes.withUnsafeBytes { samples += $0.bindMemory(to: Int16.self) }
        }
        return samples
    }

    // MARK: - Decoding

    struct Decoded: CustomStringConvertible {
        var samples: Int
        var peak: Int
        var description: String { "\(samples) samples, peak \(peak)" }
    }

    /// `frame` `count` times as one track's samples, decoded to 16-bit PCM.
    static func decode(_ frame: [UInt8], count: Int, plan: AudioPlan) async throws -> Decoded {
        try await decode(frame, count: count, frameSamples: plan.samples(in: frame), sampleRate: plan.sampleRate,
                         entry: plan.sampleEntry)
    }

    static func decode(_ frame: [UInt8], count: Int, frameSamples: Int, sampleRate: Int, entry: [UInt8]) async throws -> Decoded {
        var file = Data(FragmentWriter.initSegment(handler: .audio, timescale: UInt32(sampleRate), language: "und",
                                                   sampleEntry: entry))
        let samples = (0 ..< count).map { _ in
            FragmentSample(duration: UInt32(frameSamples), isSync: true, data: frame)
        }
        file.append(FragmentWriter.mediaSegment(sequenceNumber: 1, runs: [
            TrackRun(trackID: 1, fragment: Fragment(baseDecodeTime: 0, samples: samples), compositionOffsets: false),
        ]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).mp4")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffers = try await pcm(AVURLAsset(url: url))
        return Decoded(samples: buffers.reduce(0) { $0 + $1.count }, peak: buffers.map(\.peak).max() ?? 0)
    }

    struct Buffer {
        var time: Double
        var count: Int
        var peak: Int
    }

    static func pcm(_ asset: AVURLAsset) async throws -> [Buffer] {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading(), "\(reader.error.map { "\($0)" } ?? "")")
        var buffers: [Buffer] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                        dataPointerOut: &pointer)
            var peak = 0
            if let pointer {
                pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { values in
                    for i in 0 ..< length / 2 { peak = max(peak, abs(Int(values[i]))) }
                }
            }
            buffers.append(Buffer(time: CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                                  count: CMSampleBufferGetNumSamples(buffer), peak: peak))
        }
        #expect(reader.status == .completed, "\(reader.error.map { "\($0)" } ?? "")")
        return buffers
    }
}

#endif
