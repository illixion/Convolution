/*
 DTS and TrueHD tracks decoded to ALAC renditions (`AudioTranscode.swift`),
 checked against FFmpeg's decoders (the FFmpegDecoders package; the decoding
 tests are skipped where it was built without them) and read back through
 AVFoundation on the Mac.

 The fixtures carry a different tone on each 5.1 channel (FL 500, FR 700,
 FC 300, LFE 60, SL 900, SR 1100 Hz; `make-fixtures.sh`), and span two
 segments, so a segment boundary is decoded on both sides.
 */

#if canImport(AVFoundation) && os(macOS)

import AVFoundation
import FFmpegDecoders
import Foundation
import Testing
@testable import MatroskaRemux

@Suite("DTS and TrueHD as ALAC", .serialized)
struct TranscodeTests {
    static let fixtures = ["dts-51.mkv", "truehd-51.mkv"]
    static var decoding: RemuxAudioDecoding { FFmpegRemuxDecoder.decoding }
    static var options: RemuxOptions {
        var options = RemuxOptions()
        options.audioDecoding = decoding
        return options
    }

    @Test(arguments: fixtures)
    func declinedWithoutADecoder(_ name: String) async throws {
        await #expect(throws: RemuxError.self) { _ = try await Fixtures.open(name) }
    }

    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: fixtures)
    func offeredAsALAC(_ name: String) async throws {
        let session = try await Fixtures.open(name, options: Self.options)
        let track = try #require(session.summary.audio.first)
        #expect(track.codecs == "alac")
        #expect(track.codec == (name.hasPrefix("dts") ? "DTS" : "TrueHD"))
        #expect(track.channels == 6)
        #expect(session.summary.dropped.isEmpty)
        #expect(session.masterPlaylist.contains("alac"))
        #expect(session.segmentCount > 1, "the fixture spans segment boundaries")
    }

    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: fixtures)
    func segmentsAreTheSameBytesEveryTime(_ name: String) async throws {
        let first = try await Fixtures.open(name, options: Self.options)
        let number = try #require(first.summary.audio.first).number
        let second = try await Fixtures.open(name, options: Self.options)
        // Out of order in the second session: no priming from a cache.
        for k in (0 ..< first.segmentCount).reversed() {
            let a = try #require(try await first.audioSegment(track: number, k))
            let b = try #require(try await second.audioSegment(track: number, k))
            #expect(a == b, "segment \(k)")
        }
    }

    /// The decoded rendition is the straight-through decode of the track,
    /// sample for sample, in ALAC's channel order (C L R Ls Rs LFE).
    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: fixtures)
    func decodesToTheTrackInALACOrder(_ name: String) async throws {
        let session = try await Fixtures.open(name, options: Self.options)
        let number = try #require(session.summary.audio.first).number
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcode-\(UUID().uuidString).mp4")
        try await session.concatenated("audio-\(number)").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        // Asked for in ALAC's own order (AVFoundation otherwise hands 5.1
        // back as L R C Ls Rs LFE).
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_D
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 6, AVSampleRateKey: 48000, AVChannelLayoutKey: layoutData,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var ours: [Int32] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                        dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Int32.self, capacity: length / 4) {
                ours += UnsafeBufferPointer(start: $0, count: length / 4).map { $0 >> 8 }
            }
        }
        #expect(reader.status == .completed)
        let channels = 6
        #expect(ours.count % channels == 0)

        // Against FFmpeg decoding the whole track straight through.
        let header = try await MatroskaHeaderReader.read(try Fixtures.source(name))
        let entry = try #require(header.tracks.first { $0.number == number })
        let frameData = try await Self.frames(of: number, in: name)
        let codec = try #require(FFmpegAudioCodec(matroskaCodecID: entry.codecID))
        let straight = try #require(FFmpegAudioDecoder(codec: codec, extradata: entry.codecPrivate))
        for frame in frameData { straight.feed(frame) }
        straight.finish()
        let order = try #require(AudioTranscode.alacOrder(for: FFmpegRemuxDecoder(straight).speakers))
        let reference: [Int32] = straight.withSamples { pcm in
            (0 ..< straight.frameCount).flatMap { i in order.map { pcm[i * channels + $0] } }
        }
        // Each channel's tone, in ALAC's order (C L R Ls Rs LFE): the
        // decoded track's own, and the fixture's.
        let frames = ours.count / channels
        for c in 0 ..< channels {
            let mine = Self.tone(ours, channel: c, frames: frames)
            #expect(mine == Self.tone(reference, channel: c, frames: reference.count / channels),
                    "channel \(c) carries \(mine) Hz")
            #expect(mine == [300, 500, 700, 900, 1100, 60][c])
        }

        let compared = min(reference.count, ours.count)
        #expect(compared > reference.count * 9 / 10)
        var mismatched = 0
        for i in 0 ..< compared where ours[i] != reference[i] { mismatched += 1 }
        #expect(mismatched == 0, "\(mismatched) of \(compared) samples differ")
    }

    /// The fixture tone strongest in one channel, over its middle half.
    static func tone(_ pcm: [Int32], channel: Int, frames: Int) -> Double {
        let samples = (frames / 4 ..< frames * 3 / 4).map { Double(pcm[$0 * 6 + channel]) }
        return [300.0, 500, 700, 60, 900, 1100].max { power(samples, $0) < power(samples, $1) }!
    }

    /// Goertzel power of one frequency at 48 kHz.
    static func power(_ samples: [Double], _ frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / 48000, coefficient = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s = x + coefficient * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2
    }

    /// A track's stored frames, in file order.
    static func frames(of track: UInt64, in name: String) async throws -> [[UInt8]] {
        let source = try Fixtures.source(name)
        let header = try await MatroskaHeaderReader.read(source)
        var reader = ClusterReader(source: source, start: try #require(header.firstClusterPosition),
                                   limit: header.contentEnd ?? Int64.max, chunkSize: 1 << 20,
                                   modes: [track: .frames], strippedHeaders: [:])
        var frames: [[UInt8]] = []
        while let frame = try await reader.next() {
            if frame.track == track { frames.append(frame.data) }
        }
        return frames
    }
}

#endif
