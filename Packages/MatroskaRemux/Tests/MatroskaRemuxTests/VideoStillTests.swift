/*
 A one-keyframe MP4 for thumbnails: AVAssetImageGenerator opens it from a
 file and gets the picture, for every codec the remux carries, with and
 without Cues, and a server's file is read in a few small ranges.
 */

#if canImport(AVFoundation) && os(macOS)

import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import MatroskaRemux

@Suite("Stills for thumbnails", .serialized)
struct VideoStillTests {
    init() {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    }

    /// The picture AVAssetImageGenerator makes of a still, written to a file.
    static func image(_ still: VideoStill) async throws -> CGImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mp4")
        try still.mp4.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: .zero).image
    }

    /// How much the picture varies: testsrc2's colour bars, not a flat frame.
    static func spread(_ image: CGImage) -> Int {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let lumas = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) + Int(pixels[$0 + 1]) + Int(pixels[$0 + 2]) }
        return (lumas.max() ?? 0) - (lumas.min() ?? 0)
    }

    @Test(arguments: AVFoundationTests.decodable + ["vp9-vorbis.webm"])
    func everyCodecMakesAPicture(_ name: String) async throws {
        let still = try await VideoStill.make(source: CountingSource(try Fixtures.source(name)))
        let image = try await Self.image(still)
        #expect(image.width == still.width && image.height == still.height, "\(image.width)x\(image.height)")
        #expect(Self.spread(image) > 100, "a real picture")
    }

    @Test func declinesWhatCantBeCarried() async throws {
        await #expect(throws: RemuxError.declined("video codec V_VP8")) {
            _ = try await VideoStill.make(source: try Fixtures.source("vp8-opus.webm"))
        }
    }

    /// A tenth of the way in, at a keyframe at or before it, no later than
    /// the cap; read in a few small ranges.
    @Test func aTenthInFromTheCues() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("h264-bframes-aac.mkv"))
        let base = writer.frames
        writer.frames = (0 ..< 67).flatMap { copy in
            base.map { frame in
                var frame = frame
                frame.timestamp += Int64(copy) * 9000
                return frame
            }
        }.filter { $0.timestamp < 600_000 }
        writer.duration = 600_000
        let data = writer.write()
        let source = CountingSource(DataByteSource(data), latency: .milliseconds(2))
        let still = try await VideoStill.make(source: source)
        #expect(still.seconds == 60, "keyframes every second: 10 % of 10 minutes")
        #expect(Self.spread(try await Self.image(still)) > 100)
        let bytes = source.ranges.reduce(0) { $0 + $1.count }
        print("still from Cues: \(source.ranges.count) reads, \(bytes) bytes of \(data.count)")
        #expect(source.ranges.count <= 6)
        #expect(bytes < 512 << 10)
        // The cap.
        let capped = try await VideoStill.make(source: DataByteSource(data), maximumSeconds: 30)
        #expect(capped.seconds == 30)
    }

    /// Without Cues: a probe at a tenth of the bytes, then hops to a cluster
    /// that starts with a keyframe.
    @Test func aTenthInWithoutCues() async throws {
        let data = try await ProgressiveIndexTests.longFile(minutes: 10)
        let source = CountingSource(DataByteSource(data), latency: .milliseconds(2))
        let still = try await VideoStill.make(source: source)
        #expect(abs(still.seconds - 60) < 10, "about a tenth in: \(still.seconds)")
        #expect(Self.spread(try await Self.image(still)) > 100)
        let bytes = source.ranges.reduce(0) { $0 + $1.count }
        print("still without Cues: \(source.ranges.count) reads, \(bytes) bytes of \(data.count)")
        #expect(source.ranges.count <= 8)
        #expect(bytes < 2 << 20)
        // A live WebM: no Cues, clusters of known size, no Duration.
        let live = try await VideoStill.make(source: RemoteLike(try Fixtures.source("live.webm")))
        #expect(Self.spread(try await Self.image(live)) > 100)
    }
}

#endif
