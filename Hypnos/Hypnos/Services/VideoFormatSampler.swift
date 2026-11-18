/*
 Hypnos - frames for working out a video's format

 `VideoFormatAnalyzer` (Vergence) reads small greyscale pictures of the
 decoded frames; this takes them from the window's own player while it
 plays, through a video output of its own (several outputs on one item each
 get every frame), so it works for every source the native player opens:
 local files, servers, the on-device remux. A few frames a second or two
 apart, black ones skipped (an intro fades in). It also keeps one frame in
 colour, small, for the 3D panel's preview.
 */

import AVFoundation
import CoreGraphics
import CoreVideo
import DebugTrace
import QuartzCore
import VergenceApple
import VideoToolbox

@MainActor
enum VideoFormatSampler {
    struct Sample {
        var frames: [LumaPlane]
        /// The decoded frame's size in pixels.
        var frameSize: CGSize
        /// One frame in colour, its long side at most `previewSide`.
        var preview: CGImage?
    }

    /// The analysis pictures' long side.
    static let analysisSide = 512
    static let previewSide = 720

    /// Frames of what `player` plays: up to `count`, at least `spacing` of
    /// video apart, within `timeout`. A paused player gives the one frame on
    /// screen. Nil when no usable frame came.
    ///
    /// The player may have no item yet (a looping `AVQueuePlayer` gets its
    /// copies once the asset loads) and changes item at every loop seam, so
    /// the output follows whichever item is current.
    static func sample(_ player: AVPlayer, count: Int = 4, spacing: Double = 1.5,
                       timeout: Duration = .seconds(15)) async -> Sample? {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        var item: AVPlayerItem?
        defer { item?.remove(output) }

        var frames: [LumaPlane] = []
        var frameSize = CGSize.zero
        var previewBuffer: CVPixelBuffer?
        var lastTaken: Double?
        let deadline = ContinuousClock.now + timeout
        while frames.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return nil }
            if player.currentItem !== item {
                item?.remove(output)
                item = player.currentItem
                item?.add(output)
                lastTaken = nil
                continue
            }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            let seconds = time.seconds
            if let lastTaken, abs(seconds - lastTaken) < spacing {
                // A paused picture won't change: one frame is all there is.
                if player.rate == 0, !frames.isEmpty { break }
                continue
            }
            guard output.hasNewPixelBuffer(forItemTime: time) || (player.rate == 0 && frames.isEmpty),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            lastTaken = seconds
            guard let (plane, mean) = luma(of: buffer) else { continue }
            // Near black (a fade, a title card's background): no evidence.
            guard mean >= 12 else { continue }
            frames.append(plane)
            frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if previewBuffer == nil || frames.count == 2 { previewBuffer = buffer }
        }
        guard !frames.isEmpty else { return nil }
        let preview = previewBuffer.flatMap { previewImage(of: $0) }
        return Sample(frames: frames, frameSize: frameSize, preview: preview)
    }

    /// A BGRA frame as a greyscale picture whose long side is
    /// `analysisSide`, each pixel the mean of a 4×4 grid of samples in its
    /// area (the analyzer's matching wants an area average, not aliasing),
    /// and its mean level.
    private static func luma(of buffer: CVPixelBuffer) -> (LumaPlane, Double)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 16, height >= 16 else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let scale = min(1, Double(analysisSide) / Double(max(width, height)))
        let w = max(16, Int(Double(width) * scale)), h = max(16, Int(Double(height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        var total = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let grid = 4
        let stepX = Double(width) / Double(w), stepY = Double(height) / Double(h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var sum = 0
                for sy in 0 ..< grid {
                    let row = bytes + min(height - 1, Int((Double(y) + (Double(sy) + 0.5) / Double(grid)) * stepY)) * rowBytes
                    for sx in 0 ..< grid {
                        let p = row + min(width - 1, Int((Double(x) + (Double(sx) + 0.5) / Double(grid)) * stepX)) * 4
                        // BGRA: Rec. 709 luma, integer weights summing to 256.
                        sum += (Int(p[2]) * 54 + Int(p[1]) * 183 + Int(p[0]) * 19) >> 8
                    }
                }
                let value = sum / (grid * grid)
                pixels[y * w + x] = UInt8(value)
                total += value
            }
        }
        return (LumaPlane(width: w, height: h, pixels: pixels), Double(total) / Double(w * h))
    }

    private static func previewImage(of buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image else { return nil }
        let scale = min(1, CGFloat(previewSide) / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
