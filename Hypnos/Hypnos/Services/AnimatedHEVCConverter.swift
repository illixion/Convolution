/*
 Hypnos - Animated HEVC Converter

 Converts animated still data — animated GIF or the APNG produced by decoding
 an animated JPEG XL — to an .mp4 video for reliable multi-window playback on
 visionOS. Both formats are frame sequences that ImageIO reads via
 CGImageSource, so a single path serves both: frames are extracted and encoded
 with AVAssetWriter, preserving each frame's variable timing (read from the GIF
 or APNG per-frame delay dictionary).

 Codec is **HEVC**: it's far more efficient than H.264 at the same bitrate, so
 the cached clip stays much closer to the JPEG XL / GIF source (H.264 4:2:0 was
 a visible downgrade). Playback goes through the native video-in-`<img>` path
 (AnimatedImageWebView); if WebKit's `<img>`-video decode can't take HEVC the
 view falls back to the `<video>` player, which decodes it reliably on
 visionOS. Even frame dimensions are still enforced (the encoders prefer them),
 so odd source sizes are rounded down to even.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import DebugTrace
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

actor AnimatedHEVCConverter {
    static let shared = AnimatedHEVCConverter()

    enum ConversionError: Error, LocalizedError {
        case invalidGIFData
        case noFrames
        case pixelBufferCreationFailed
        case writerSetupFailed(String)
        case encodingFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidGIFData: return "Invalid animated image data"
            case .noFrames: return "Animated image contains no frames"
            case .pixelBufferCreationFailed: return "Failed to create pixel buffer"
            case .writerSetupFailed(let msg): return "Writer setup failed: \(msg)"
            case .encodingFailed(let msg): return "Encoding failed: \(msg)"
            case .cancelled: return "Conversion was cancelled"
            }
        }
    }

    private init() {}

    // MARK: - Public API

    /// Convert animated still data (GIF or APNG) to HEVC .mp4, returning a
    /// cached file URL. Returns immediately if the result is already cached.
    func convert(animatedData: Data, sourceURL: URL) async throws -> URL {
        // Check cache first
        if let cachedURL = await DiskAnimatedHEVCCache.shared.cachedFileURL(for: sourceURL) {
            AppLogger.gifConverter.debug("Cache hit for animated HEVC: \(sourceURL.lastPathComponent)")
            return cachedURL
        }

        AppLogger.gifConverter.info("Converting animated still to HEVC: \(sourceURL.lastPathComponent)")

        // Extract frames (CGImageSource handles both GIF and APNG)
        guard let imageSource = CGImageSourceCreateWithData(animatedData as CFData, nil) else {
            throw ConversionError.invalidGIFData
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0 else {
            throw ConversionError.noFrames
        }

        // Get dimensions from first frame
        guard let firstImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.noFrames
        }
        // The video encoders prefer even dimensions (4:2:0 chroma), and the
        // <img>-video decode path is stricter than <video>. Round down to even;
        // the ≤1px change is invisible and display aspect is driven separately.
        let width = firstImage.width - (firstImage.width % 2)
        let height = firstImage.height - (firstImage.height % 2)
        guard width > 0, height > 0 else { throw ConversionError.noFrames }

        // Create temporary output file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        do {
            try await encodeFrames(
                imageSource: imageSource,
                frameCount: frameCount,
                width: width,
                height: height,
                outputURL: tempURL
            )

            // Move to cache
            await DiskAnimatedHEVCCache.shared.saveFile(from: tempURL, for: sourceURL)

            guard let cachedURL = await DiskAnimatedHEVCCache.shared.cachedFileURL(for: sourceURL) else {
                throw ConversionError.encodingFailed("File not found in cache after save")
            }

            AppLogger.gifConverter.info("Animated HEVC conversion complete: \(frameCount, privacy: .public) frames, \(width, privacy: .public)x\(height, privacy: .public)")
            return cachedURL
        } catch {
            // Clean up temp file on error
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Encoding

    private func encodeFrames(
        imageSource: CGImageSource,
        frameCount: Int,
        width: Int,
        height: Int,
        outputURL: URL
    ) async throws {
        // Set up AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ConversionError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // HEVC Main (8-bit 4:2:0 — the source is already 8-bit RGBA, so
                // depth loses nothing). AVFoundation exposes no HEVC profile-
                // level constant; the encoder picks Main and AVAssetWriter tags
                // the .mp4 `hvc1`, which WebKit needs. Bitrate is generous
                // (hardware encode, short LRU-bounded loops) and B-frames stay
                // enabled for better quality per bit.
                AVVideoAverageBitRateKey: calculateBitrate(width: width, height: height),
                AVVideoQualityKey: 0.9,
            ] as [String: Any],
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let sourcePixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw ConversionError.writerSetupFailed("Cannot add video input to writer")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw ConversionError.writerSetupFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Encode each frame
        var presentationTime = CMTime.zero

        for frameIndex in 0..<frameCount {
            // Check for cancellation
            if Task.isCancelled {
                writerInput.markAsFinished()
                writer.cancelWriting()
                throw ConversionError.cancelled
            }

            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil) else {
                continue
            }

            let frameDuration = frameDuration(for: imageSource, at: frameIndex)

            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            guard let pixelBuffer = createPixelBuffer(from: cgImage, width: width, height: height) else {
                throw ConversionError.pixelBufferCreationFailed
            }

            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw ConversionError.encodingFailed(
                    "Failed to append frame \(frameIndex): \(writer.error?.localizedDescription ?? "unknown")"
                )
            }

            presentationTime = CMTimeAdd(presentationTime, frameDuration)
        }

        writerInput.markAsFinished()

        await writer.finishWriting()

        if writer.status == .failed {
            throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
    }

    // MARK: - Frame Timing

    private func frameDuration(for source: CGImageSource, at index: Int) -> CMTime {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]

        // Read the per-frame delay from whichever container dictionary is
        // present — GIF or APNG (an animated JXL is decoded to APNG upstream).
        var delay: Double = 0.1
        if let gifDict = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0.01 {
                delay = unclamped
            } else if let clamped = gifDict[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0.01 {
                delay = clamped
            }
        } else if let pngDict = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let unclamped = pngDict[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, unclamped > 0.01 {
                delay = unclamped
            } else if let clamped = pngDict[kCGImagePropertyAPNGDelayTime] as? Double, clamped > 0.01 {
                delay = clamped
            }
        }

        // Browser behavior: clamp very short delays to 0.1s
        if delay <= 0.01 {
            delay = 0.1
        }

        // Convert to CMTime with millisecond precision
        return CMTime(value: CMTimeValue(delay * 1000), timescale: 1000)
    }

    // MARK: - Pixel Buffer

    private func createPixelBuffer(from cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // Black background for GIF transparency
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw the frame scaled to fill
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }

    // MARK: - Bitrate

    private func calculateBitrate(width: Int, height: Int) -> Int {
        // Quality-first: these are short animated loops, the disk cache is
        // LRU-bounded, and the encode is hardware (VideoToolbox) — so there's
        // no speed or storage reason to skimp. Run the bitrate high enough that
        // HEVC is visually lossless for the 8-bit RGBA the GIF/APNG
        // intermediary carries.
        return max(8_000_000, width * height * 12)
    }
}
