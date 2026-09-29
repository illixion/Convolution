/*
 Hypnos - Disk Animated HEVC Cache

 Persistent cache for HEVC conversions of animated stills — both animated GIF
 and animated JPEG XL. Both formats convert to the same HEVC .mp4 so playback,
 caching, and budget accounting are unified in one place. Uses Apple's Caches
 directory (the system can clean it when storage is low). Size accounting and
 LRU eviction live in the shared LRUDiskCache engine.
 */

import DebugTrace
import Foundation

actor DiskAnimatedHEVCCache {
    static let shared = DiskAnimatedHEVCCache()

    private let engine: LRUDiskCache
    private let fileManager = FileManager.default

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        engine = LRUDiskCache(
            // Directory name kept as-is for continuity. formatVersion 3 purges
            // the interim H.264 clips so they re-convert as HEVC (better
            // quality at the same bitrate — see AnimatedHEVCConverter).
            directory: caches.appendingPathComponent("GIFHEVCCache", isDirectory: true),
            domain: .gifHEVC,
            log: AppLogger.gifConverter,
            formatVersion: 3
        )
    }

    // MARK: - Cache Key

    private func cacheFileURL(for url: URL) -> URL {
        engine.directory.appendingPathComponent(LRUDiskCache.sha256Key(url.absoluteString) + ".mp4")
    }

    // MARK: - Public API

    /// Return cached file URL if present
    func cachedFileURL(for url: URL) -> URL? {
        let fileURL = cacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        // Update access time for LRU tracking
        engine.touch(fileURL)
        return fileURL
    }

    /// Move a converted .mp4 from a temporary location into the cache
    func saveFile(from tempURL: URL, for sourceURL: URL) {
        let destinationURL = cacheFileURL(for: sourceURL)
        let replaced = engine.sizeOnDisk(of: destinationURL)

        do {
            // Remove existing file if present (e.g. partial/corrupt)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            engine.noteWrite(at: destinationURL, replacing: replaced)
        } catch {
            AppLogger.gifConverter.error("Failed to save animated HEVC to cache: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
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
