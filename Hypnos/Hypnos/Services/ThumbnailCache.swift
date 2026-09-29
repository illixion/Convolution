/*
 Hypnos - Thumbnail Cache

 Dedicated cache for generated thumbnails with disk persistence.
 Uses file modification time to invalidate stale thumbnails.
 Optimized for small images to minimize memory usage.
 Disk size accounting and LRU eviction live in the shared LRUDiskCache engine.
 */

import DebugTrace
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let engine: LRUDiskCache
    private let fileManager = FileManager.default

    /// Memory cache for recently accessed thumbnails (much smaller than full image cache)
    private var memoryCache = NSCache<NSString, UIImage>()

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        engine = LRUDiskCache(
            directory: caches.appendingPathComponent("ThumbnailCache", isDirectory: true),
            domain: .thumbnails,
            log: AppLogger.diskCache,
            formatVersion: 1
        )

        // Configure memory cache for thumbnails (small images, more count)
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB for memory
    }

    /// Generate a cache key that includes file modification time
    /// This invalidates cached thumbnails when the source file changes
    ///
    /// `variant` separates entries that render the same URL differently. The
    /// unlabelled entries written before uncropped thumbnails existed are
    /// center-cropped squares, so uncropped ones live under their own label
    /// instead of being mistaken for them.
    private func cacheKey(for url: URL, variant: String? = nil) -> String {
        var keyString = url.absoluteString
        if let variant { keyString += "#\(variant)" }

        // Include modification time for local files to detect changes
        if url.isFileURL,
           let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let modDate = attrs[.modificationDate] as? Date {
            keyString += "_\(Int(modDate.timeIntervalSince1970))"
        }

        return LRUDiskCache.sha256Key(keyString)
    }

    /// Get the file URL for a cached thumbnail
    private func cacheFileURL(for url: URL, variant: String? = nil) -> URL {
        engine.directory.appendingPathComponent(cacheKey(for: url, variant: variant) + ".heic")
    }

    /// Load a cached thumbnail
    /// - Parameter url: The source image URL
    /// - Returns: The cached thumbnail UIImage, or nil if not cached
    func loadThumbnail(for url: URL, variant: String? = nil) -> UIImage? {
        let key = cacheKey(for: url, variant: variant)

        // Check memory cache first
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        let fileURL = cacheFileURL(for: url, variant: variant)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let image = UIImage(data: data) else {
            return nil
        }

        // Update access time for LRU
        engine.touch(fileURL)

        // Restore to memory cache
        memoryCache.setObject(image, forKey: key as NSString, cost: data.count)

        return image
    }

    /// Save a thumbnail to cache
    /// - Parameters:
    ///   - image: The thumbnail image to cache
    ///   - url: The source image URL (used as key)
    func saveThumbnail(_ image: UIImage, for url: URL, variant: String? = nil) {
        let key = cacheKey(for: url, variant: variant)

        // Save to memory cache
        // Estimate cost as width * height * 4 bytes per pixel
        let cost = Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        // Save to disk as HEIC (supports alpha, smaller than JPEG/PNG)
        let fileURL = cacheFileURL(for: url, variant: variant)
        guard let cgImage = image.cgImage else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        if data.length > 0 {
            let replaced = engine.sizeOnDisk(of: fileURL)
            do {
                try data.write(to: fileURL)
                engine.noteWrite(at: fileURL, replacing: replaced)
            } catch {
                AppLogger.diskCache.error("Failed to save thumbnail: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }

    /// Check if a thumbnail is cached (memory or disk)
    func isCached(for url: URL) -> Bool {
        let key = cacheKey(for: url)

        // Check memory first
        if memoryCache.object(forKey: key as NSString) != nil {
            return true
        }

        // Check disk
        return fileManager.fileExists(atPath: cacheFileURL(for: url).path)
    }

    /// Clear only the in-memory thumbnail cache, preserving disk cache.
    /// Called during early memory pressure to reduce dirty memory quickly.
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// Clear entire thumbnail cache
    func clearCache() {
        memoryCache.removeAllObjects()
        engine.clear()
    }

    /// Re-check the budget (preset change) and evict if over.
    func enforceBudget() {
        engine.evictIfNeeded()
    }

    /// Get cache statistics
    func getCacheStats() -> (fileCount: Int, totalSize: Int64) {
        engine.stats()
    }
}
