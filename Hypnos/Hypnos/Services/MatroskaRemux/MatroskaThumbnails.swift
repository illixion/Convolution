/*
 Hypnos - thumbnails of MKV and WebM files

 AVAssetImageGenerator can't open Matroska, so a local MKV's grid cell
 stayed a placeholder (WebM had WebKit's offscreen capture on iOS and
 visionOS only), and so did a Nextcloud MKV or WebM whenever the server
 renders no preview for it (it needs its movie preview provider and
 ffmpeg). `MatroskaRemux.VideoStill` makes the smallest MP4 with one
 keyframe a tenth of the way in (at most ten minutes): the video's init
 segment and one fragment. AVAssetImageGenerator opens that from a
 temporary file. A server's file is read in a few ranges (the head and
 Cues, the keyframe's cluster start and the keyframe: under 1 MB for a
 1080p film), with the credential every AVFoundation read uses
 (`RemoteByteSource`).

 This is the fallback when the normal path fails: `ThumbnailGenerator`
 (local files) and `ImageLoader.loadMatroskaThumbnail` (a server's video
 without a preview). Stash makes its own thumbnails and is never asked.
 At most two run at once: a grid asks for a screenful together. A file the
 remux declines (VP8 in the App Store edition, say) isn't read again for the
 rest of the launch. The sideload edition decodes a VP8 keyframe with FFmpeg
 (`MatroskaRemuxService.videoDecoding`), straight to the image, no MP4.
 */

import AVFoundation
import CoreMedia
import CoreGraphics
import DebugTrace
import Foundation
import MatroskaRemux
import Synchronization
import VideoToolbox

enum MatroskaThumbnails {
    /// Worth trying for this file: by its name (a grid asks for hundreds,
    /// so nothing is read to find out).
    static func handles(_ url: URL, fileName: String? = nil) -> Bool {
        guard url.isFileURL || url.scheme == "http" || url.scheme == "https" else { return false }
        return [fileName.map { ($0 as NSString).pathExtension }, url.pathExtension].contains {
            ["mkv", "mk3d", "webm"].contains($0?.lowercased() ?? "")
        }
    }

    /// A frame of the video at `url`, fitting `maxSize`, or nil.
    static func image(for url: URL, maxSize: CGFloat) async -> CGImage? {
        guard !declined.withLock({ $0.contains(url.absoluteString) }) else { return nil }
        await gate.acquire()
        defer { Task { await gate.release() } }
        let started = ContinuousClock.now
        let still: VideoStill
        do {
            let source: any ByteSource = url.isFileURL ? try FileByteSource(url: url) : RemoteByteSource(url: url)
            still = try await VideoStill.make(source: source, videoDecoding: MatroskaRemuxService.videoDecoding)
        } catch let error as RemuxError {
            AppLogger.imageLoader.debug("No Matroska still: \(error.description, privacy: .public)")
            _ = declined.withLock { $0.insert(url.absoluteString) }
            return nil
        } catch {
            AppLogger.imageLoader.warning("Matroska still failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
        if let image = still.image {
            AppLogger.imageLoader.debug("""
                Matroska thumbnail decoded at \(still.seconds, format: .fixed(precision: 1), privacy: .public) s: \
                \(still.reads, privacy: .public) reads, \(still.bytesRead, privacy: .public) bytes
                """)
            return fitted(image, maxSize: maxSize)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try still.mp4.write(to: file)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSize, height: maxSize)
            let image = try await generator.image(at: .zero).image
            let elapsed = (ContinuousClock.now - started).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            AppLogger.imageLoader.debug("""
                Matroska thumbnail from \(still.seconds, format: .fixed(precision: 1), privacy: .public) s in: \
                \(still.reads, privacy: .public) reads, \(still.bytesRead, privacy: .public) bytes, \
                \(milliseconds, privacy: .public) ms
                """)
            return image
        } catch {
            // visionOS plays VP9 from HLS but finds no track in a VP9 MP4 file
            // (AVErrorNoSourceTrack, measured 2026-11-18), so every local
            // VP9 WebM stayed a blank cell: the keyframe through
            // VideoToolbox instead, the decoder the remux checks for.
            if let image = decodedKeyframe(still) {
                AppLogger.imageLoader.debug("Matroska thumbnail decoded at \(still.seconds, format: .fixed(precision: 1), privacy: .public) s with VideoToolbox (\(error.logCode, privacy: .public) from the MP4)")
                return fitted(image, maxSize: maxSize)
            }
            AppLogger.imageLoader.warning("Matroska still didn't decode: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    /// The still's keyframe decoded by VideoToolbox from its MP4 sample
    /// entry, or nil.
    private static func decodedKeyframe(_ still: VideoStill) -> CGImage? {
        guard !still.sampleEntry.isEmpty, !still.keyframe.isEmpty else { return nil }
        var format: CMVideoFormatDescription?
        let made = still.sampleEntry.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianImageDescriptionData: base, size: still.sampleEntry.count,
                stringEncoding: CFStringBuiltInEncodings.UTF8.rawValue, flavor: .isoFamily,
                formatDescriptionOut: &format)
        }
        guard made == noErr, let format else { return nil }

        var block: CMBlockBuffer?
        let length = still.keyframe.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = still.keyframe.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: length)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }

        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                           decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        let result = DecodedFrame()
        _ = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            var decoded: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &decoded)
            result.image.withLock { $0 = decoded }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return result.image.withLock { $0 }
    }

    /// The decoder's output, handed from its callback.
    private final class DecodedFrame: @unchecked Sendable {
        let image = Mutex<CGImage?>(nil)
    }

    /// A decoded keyframe scaled to fit `maxSize` (AVAssetImageGenerator
    /// does that for the MP4 stills).
    private static func fitted(_ image: CGImage, maxSize: CGFloat) -> CGImage {
        let scale = min(1, maxSize / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static let gate = Gate(permits: 2)
    private static let declined = Mutex<Set<String>>([])

    /// A counting semaphore for async callers.
    private actor Gate {
        private var permits: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(permits: Int) { self.permits = permits }

        func acquire() async {
            if permits > 0 {
                permits -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                permits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
}
