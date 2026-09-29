/*
 Hypnos - Thumbnail Generator

 Memory-efficient thumbnail generation using CGImageSource.
 Uses ImageIO's thumbnail APIs to downsample during decoding,
 avoiding loading full-resolution images into memory.
 */

import AVFoundation
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

/// Memory-efficient thumbnail generator using ImageIO
actor ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    /// Default thumbnail size for gallery views
    static let defaultThumbnailSize: CGFloat = 400 // 2x for 200pt display

    /// Maximum concurrent thumbnail generation tasks
    private let maxConcurrentTasks = 4

    /// Semaphore to limit concurrent operations
    private let semaphore: DispatchSemaphore

    /// In-progress generation tasks to prevent duplicates
    private var inProgressTasks: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        semaphore = DispatchSemaphore(value: maxConcurrentTasks)
    }

    /// Video file extensions that require AVAssetImageGenerator for thumbnails
    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"
    ]

    /// Generate a thumbnail for a local file URL
    /// - Parameters:
    ///   - url: The local file URL
    ///   - maxSize: Maximum dimension for the thumbnail (default 400px)
    /// - Returns: A downsampled UIImage, or nil if generation failed
    func generateThumbnail(for url: URL, maxSize: CGFloat = defaultThumbnailSize) async -> UIImage? {
        // Check for in-progress task
        if let existingTask = inProgressTasks[url] {
            return await existingTask.value
        }

        // Use AVAssetImageGenerator for video files
        let isVideo = Self.videoExtensions.contains(url.pathExtension.lowercased())

        let task = Task<UIImage?, Never> {
            if isVideo {
                return await self.createVideoThumbnail(for: url, maxSize: maxSize)
            }
            return await withCheckedContinuation { continuation in
                // Use semaphore to limit concurrent operations
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    self.semaphore.wait()
                    defer { self.semaphore.signal() }

                    let thumbnail = self.createThumbnailSync(for: url, maxSize: maxSize)
                    continuation.resume(returning: thumbnail)
                }
            }
        }

        inProgressTasks[url] = task
        let result = await task.value
        inProgressTasks[url] = nil

        return result
    }

    /// Generate a thumbnail from a video file using AVAssetImageGenerator.
    /// WebM is unreadable by AVFoundation, so it's routed to the WebKit-based
    /// capture instead. Other formats AVFoundation can't open still return nil
    /// and the UI shows a generic video icon placeholder.
    private func createVideoThumbnail(for url: URL, maxSize: CGFloat) async -> UIImage? {
        // AVFoundation can't decode WebM — capture a frame via WebKit (the same
        // engine that plays it). Skip the AVAssetImageGenerator attempt entirely.
        // tvOS has no WebKit, so a WebM file there just falls through to the
        // placeholder below (AVAssetImageGenerator fails on it the same way).
        // macOS is excluded too — WebMThumbnailGenerator's offscreen-render
        // trick is UIWindow/UIWindowScene-specific (see its own gate).
        #if canImport(WebKit) && !os(macOS)
        if url.pathExtension.lowercased() == "webm" {
            return await WebMThumbnailGenerator.shared.generateThumbnail(for: url, maxSize: maxSize)
        }
        #endif

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)

        let times: [CMTime] = [CMTime(seconds: 1, preferredTimescale: 600), .zero]
        for time in times {
            do {
                let (cgImage, _) = try await generator.image(at: time)
                return UIImage(cgImage: cgImage)
            } catch {
                continue
            }
        }

        AppLogger.imageLoader.debug("Failed to create video thumbnail for: \(url.lastPathComponent, privacy: .private)")
        return nil
    }

    /// Synchronous thumbnail creation using CGImageSource
    private nonisolated func createThumbnailSync(for url: URL, maxSize: CGFloat) -> UIImage? {
        // autoreleasepool drains the intermediate CGImageSource and any
        // temporary Core Graphics buffers immediately, preventing transient
        // memory spikes when many thumbnails are generated in sequence.
        autoreleasepool {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                AppLogger.imageLoader.warning("Failed to create image source for thumbnail: \(url.lastPathComponent, privacy: .private)")
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]

            guard let thumbnailRef = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                options as CFDictionary
            ) else {
                AppLogger.imageLoader.warning("Failed to create thumbnail for: \(url.lastPathComponent, privacy: .private)")
                return nil
            }

            return UIImage(cgImage: thumbnailRef)
        }
    }

    /// Get image dimensions without loading the full image
    nonisolated func getImageDimensions(for url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }

        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return nil
        }

        // Check for orientation that swaps dimensions
        if let orientation = properties[kCGImagePropertyOrientation] as? Int {
            // Orientations 5-8 swap width and height
            if orientation >= 5 && orientation <= 8 {
                return CGSize(width: height, height: width)
            }
        }

        return CGSize(width: width, height: height)
    }

    /// Downsample an image to a target max dimension, returning an in-memory UIImage.
    /// Uses CGImageSource for memory-efficient decoding without loading the full image.
    nonisolated func downsampleImage(at url: URL, maxDimension: CGFloat) -> UIImage? {
        return createThumbnailSync(for: url, maxSize: maxDimension)
    }

    /// Downsample already-fetched encoded image bytes to a target max dimension.
    /// Decodes directly at thumbnail size via CGImageSource (no full-resolution
    /// decode) and runs under the shared concurrency limit, so a gallery full of
    /// cold thumbnails can't spawn unbounded decodes at once.
    func downsample(data: Data, maxSize: CGFloat = defaultThumbnailSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.semaphore.wait()
                defer { self.semaphore.signal() }
                continuation.resume(returning: self.downsampleSync(data: data, maxSize: maxSize))
            }
        }
    }

    private nonisolated func downsampleSync(data: Data, maxSize: CGFloat) -> UIImage? {
        autoreleasepool {
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]

            guard let thumbnailRef = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                options as CFDictionary
            ) else {
                return nil
            }

            return UIImage(cgImage: thumbnailRef)
        }
    }

    /// Check if a file is an animated GIF without loading the full image
    nonisolated func isAnimatedGIF(at url: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(imageSource) > 1
    }
}
