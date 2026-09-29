/*
 Hypnos - Disk Image Cache

 Persistent image cache using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Size accounting and LRU eviction live in the shared LRUDiskCache engine,
 with the cap derived from device storage by CacheBudget.
 */

import DebugTrace
import Foundation

actor DiskImageCache {
    static let shared = DiskImageCache()

    /// Exposed (nonisolated) so derived-render caches can check whether an
    /// original is still cached (orphan-first eviction) without an actor hop.
    nonisolated static let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("ImageCache", isDirectory: true)
    }()

    /// The engine's filename for a source URL — shared with the origin-key
    /// tagging in AutoEnhanceCache/BackgroundRemovalCache.
    nonisolated static func cacheKey(for url: URL) -> String {
        LRUDiskCache.sha256Key(url.absoluteString)
    }

    private let engine = LRUDiskCache(
        directory: DiskImageCache.cacheDirectory,
        domain: .images,
        log: AppLogger.diskCache
    )
    private let fileManager = FileManager.default

    private init() {}

    /// Get the file URL for a cached image
    private func cacheFileURL(for url: URL) -> URL {
        Self.cacheDirectory.appendingPathComponent(Self.cacheKey(for: url))
    }

    /// Return cached file URL if present
    func cachedFileURL(for url: URL) -> URL? {
        let fileURL = cacheFileURL(for: url)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Check if an image is cached
    func isCached(url: URL) -> Bool {
        fileManager.fileExists(atPath: cacheFileURL(for: url).path)
    }

    /// Load image data from disk cache
    func loadData(for url: URL) -> Data? {
        let fileURL = cacheFileURL(for: url)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Update access time for LRU tracking
        engine.touch(fileURL)

        // Use memory-mapped I/O: pages are loaded on demand and the kernel
        // can evict them without increasing dirty memory or triggering jetsam.
        return try? Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    /// Save image data to disk cache
    func saveData(_ data: Data, for url: URL) {
        let fileURL = cacheFileURL(for: url)
        let replaced = engine.sizeOnDisk(of: fileURL)

        do {
            try data.write(to: fileURL)
            engine.noteWrite(at: fileURL, replacing: replaced)
        } catch {
            AppLogger.diskCache.error("Failed to save data: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    /// Clear entire cache
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
}
