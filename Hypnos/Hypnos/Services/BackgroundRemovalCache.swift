/*
 Hypnos - Background Removal Cache

 Persistent cache for background-removed images using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Separate from DiskImageCache to allow independent cache management.
 Disk size accounting and LRU eviction live in the shared LRUDiskCache engine;
 entries whose original has left the disk image cache are evicted first (a
 background-removed render is useless without its source).
 */

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
import UniformTypeIdentifiers

actor BackgroundRemovalCache {
    static let shared = BackgroundRemovalCache()

    private let engine: LRUDiskCache
    private var cacheDirectory: URL { engine.directory }
    private let fileManager = FileManager.default
    private let heicCompressionQuality: CGFloat = 0.95

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let engine = LRUDiskCache(
            directory: caches.appendingPathComponent("BackgroundRemovalCache", isDirectory: true),
            domain: .backgroundRemoval,
            log: AppLogger.diskCache,
            // v1 clears the pre-`f748109` background-removal output (cropped to
            // the subject bbox), which otherwise loads stale and mis-sizes the
            // viewer window.
            formatVersion: 1
        )
        // Prefer evicting renders whose original left the image cache.
        engine.evictsFirst = { fileURL in
            guard let originKey = LRUDiskCache.originKey(of: fileURL) else { return false }
            let original = DiskImageCache.cacheDirectory.appendingPathComponent(originKey)
            return !FileManager.default.fileExists(atPath: original.path)
        }
        self.engine = engine

        Task { [self] in
            await migrateLegacyCacheIfNeeded()
        }
    }

    /// Generate a cache key from a URL with background removal suffix.
    /// When `isAutoEnhanced` is true, the key includes an additional suffix
    /// so regular and auto-enhanced variants are stored as separate cache entries.
    private func cacheKey(for url: URL, isAutoEnhanced: Bool = false) -> String {
        var urlString = url.absoluteString + ":backgroundRemoved"
        if isAutoEnhanced {
            urlString += ":autoEnhanced"
        }
        return LRUDiskCache.sha256Key(urlString)
    }

    /// Get the file URL for a cached background-removed image
    private func cacheFileURL(for url: URL, isAutoEnhanced: Bool = false) -> URL {
        let key = cacheKey(for: url, isAutoEnhanced: isAutoEnhanced)
        return cacheDirectory.appendingPathComponent(key + ".heic")
    }

    /// Legacy cache file URL (pre-HEIC migration, no extension)
    private func legacyCacheFileURL(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key)
    }

    /// Link an entry to its source's image-cache key — but only when the
    /// original is actually in the disk image cache. Local files never are, so
    /// tagging them would mark every local render as an eviction-first orphan.
    private func tagOrigin(of fileURL: URL, for url: URL) {
        let originKey = DiskImageCache.cacheKey(for: url)
        let original = DiskImageCache.cacheDirectory.appendingPathComponent(originKey)
        guard fileManager.fileExists(atPath: original.path) else { return }
        LRUDiskCache.setOriginKey(originKey, for: fileURL)
    }

    /// Return cached file URL if present
    func cachedFileURL(for url: URL, isAutoEnhanced: Bool = false) -> URL? {
        let fileURL = cacheFileURL(for: url, isAutoEnhanced: isAutoEnhanced)
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        // Legacy fallback only applies to regular (non-enhanced) variant
        if !isAutoEnhanced {
            let legacyURL = legacyCacheFileURL(for: url)
            return fileManager.fileExists(atPath: legacyURL.path) ? legacyURL : nil
        }

        return nil
    }

    /// Check if a background-removed image is cached
    func isCached(url: URL, isAutoEnhanced: Bool = false) -> Bool {
        return cachedFileURL(for: url, isAutoEnhanced: isAutoEnhanced) != nil
    }

    /// Load background-removed image data from disk cache
    func loadData(for url: URL, isAutoEnhanced: Bool = false) -> Data? {
        let fileURL = cacheFileURL(for: url, isAutoEnhanced: isAutoEnhanced)

        if fileManager.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                return nil
            }

            // Update access time for LRU tracking
            engine.touch(fileURL)

            if let migratedData = migrateDataToHeicIfNeeded(data, destinationURL: fileURL) {
                return migratedData
            }

            return data
        }

        // Legacy fallback only for regular variant
        guard !isAutoEnhanced else { return nil }

        let legacyURL = legacyCacheFileURL(for: url)
        guard fileManager.fileExists(atPath: legacyURL.path),
              let legacyData = try? Data(contentsOf: legacyURL, options: .mappedIfSafe) else {
            return nil
        }

        if let migratedData = migrateLegacyDataToHeic(legacyData, legacyURL: legacyURL, destinationURL: fileURL) {
            return migratedData
        }

        // Update access time for LRU tracking on legacy entry
        engine.touch(legacyURL)

        return legacyData
    }

    /// Save background-removed image to disk cache as HEIC
    func saveImage(_ image: UIImage, for url: URL, isAutoEnhanced: Bool = false) {
        let fileURL = cacheFileURL(for: url, isAutoEnhanced: isAutoEnhanced)

        guard let heicData = encodeHeicData(from: image) else {
            AppLogger.diskCache.warning("Failed to encode background-removed image as HEIC")
            return
        }

        write(heicData, to: fileURL, taggingOriginFor: url)
    }

    /// Save background-removed image data to disk cache (re-encodes to HEIC)
    func saveData(_ data: Data, for url: URL) {
        guard let image = UIImage(data: data) else {
            AppLogger.diskCache.warning("Failed to decode background-removed image data for HEIC re-encode")
            return
        }

        saveImage(image, for: url)
    }

    /// Shared write path: replaces atomically for size accounting, tags the
    /// origin link, and lets the engine evict if now over budget.
    private func write(_ data: Data, to fileURL: URL, taggingOriginFor url: URL) {
        let replaced = engine.sizeOnDisk(of: fileURL)
        do {
            try data.write(to: fileURL)
            tagOrigin(of: fileURL, for: url)
            engine.noteWrite(at: fileURL, replacing: replaced)
        } catch {
            AppLogger.diskCache.error("Failed to save background-removal cache entry: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    // MARK: - Diorama Foreground (uncropped)

    /// Cache key for the uncropped foreground variant used by diorama mode.
    /// Distinct namespace from the standard cropped variant — separate file.
    private func dioramaCacheFileURL(for url: URL) -> URL {
        let key = LRUDiskCache.sha256Key(url.absoluteString + ":dioramaForeground")
        return cacheDirectory.appendingPathComponent(key + ".heic")
    }

    /// Whether an uncropped foreground for `url` is on disk.
    func isDioramaForegroundCached(url: URL) -> Bool {
        fileManager.fileExists(atPath: dioramaCacheFileURL(for: url).path)
    }

    /// Load the uncropped foreground HEIC bytes for `url`, or nil.
    func loadDioramaForegroundData(for url: URL) -> Data? {
        let fileURL = dioramaCacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        engine.touch(fileURL)
        return data
    }

    /// Persist an uncropped foreground (full-frame, transparent background)
    /// to the cache. Used when diorama mode generates the foreground.
    func saveDioramaForeground(_ image: UIImage, for url: URL) {
        guard let heicData = encodeHeicData(from: image) else {
            AppLogger.diskCache.warning("Failed to encode diorama foreground as HEIC")
            return
        }
        write(heicData, to: dioramaCacheFileURL(for: url), taggingOriginFor: url)
    }

    /// Cache file URL for the diorama backdrop variant — original image with
    /// the subject region heavily blurred, used as the backdrop layer so the
    /// floating foreground doesn't reveal a doubled silhouette behind it.
    private func dioramaBackdropCacheFileURL(for url: URL) -> URL {
        let key = LRUDiskCache.sha256Key(url.absoluteString + ":dioramaBackdrop")
        return cacheDirectory.appendingPathComponent(key + ".heic")
    }

    func isDioramaBackdropCached(url: URL) -> Bool {
        fileManager.fileExists(atPath: dioramaBackdropCacheFileURL(for: url).path)
    }

    func loadDioramaBackdropData(for url: URL) -> Data? {
        let fileURL = dioramaBackdropCacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        engine.touch(fileURL)
        return data
    }

    func saveDioramaBackdrop(_ image: UIImage, for url: URL) {
        guard let heicData = encodeHeicData(from: image) else {
            AppLogger.diskCache.warning("Failed to encode diorama backdrop as HEIC")
            return
        }
        write(heicData, to: dioramaBackdropCacheFileURL(for: url), taggingOriginFor: url)
    }

    // MARK: - Cache Management

    /// Clear entire background removal cache
    func clearCache() {
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

    // MARK: - HEIC Encoding and Migration

    private func encodeHeicData(from image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil
        ) else {
            return nil
        }

        let orientation = cgImagePropertyOrientation(for: image.imageOrientation)
        // Preserve bit depth on encode: HEIC/HEVC Main10 supports 10-bit color.
        // Without this, deep-color sources (16-bit JXL upscaler output, etc.)
        // are silently flattened to 8-bit in the cache and stay 8-bit on reload.
        let isDeep = cgImage.bitsPerComponent > 8
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: heicCompressionQuality,
            kCGImagePropertyOrientation: orientation.rawValue
        ]
        if isDeep {
            properties[kCGImagePropertyDepth] = 10
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func cgImagePropertyOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private func isHeicData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            return false
        }

        return type == UTType.heic.identifier || type == UTType.heif.identifier
    }

    private func migrateDataToHeicIfNeeded(_ data: Data, destinationURL: URL) -> Data? {
        guard !isHeicData(data) else { return nil }
        guard let image = UIImage(data: data),
              let heicData = encodeHeicData(from: image) else {
            return nil
        }

        let replaced = engine.sizeOnDisk(of: destinationURL)
        do {
            try heicData.write(to: destinationURL)
            engine.noteWrite(at: destinationURL, replacing: replaced)
            return heicData
        } catch {
            AppLogger.diskCache.warning("Failed to migrate background-removed image to HEIC: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    private func migrateLegacyDataToHeic(_ data: Data, legacyURL: URL, destinationURL: URL) -> Data? {
        guard let image = UIImage(data: data),
              let heicData = encodeHeicData(from: image) else {
            return nil
        }

        do {
            try heicData.write(to: destinationURL)
            engine.noteWrite(at: destinationURL)
            engine.noteRemoval(bytes: engine.sizeOnDisk(of: legacyURL))
            try? fileManager.removeItem(at: legacyURL)
            return heicData
        } catch {
            AppLogger.diskCache.warning("Failed to migrate legacy background removal cache: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    private func migrateLegacyCacheIfNeeded() async {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for fileURL in contents {
            if fileURL.pathExtension.lowercased() == "heic" {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { continue }

            let destinationURL = cacheDirectory.appendingPathComponent(fileURL.lastPathComponent + ".heic")
            if migrateLegacyDataToHeic(data, legacyURL: fileURL, destinationURL: destinationURL) != nil {
                continue
            }
        }
    }
}
