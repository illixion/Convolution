/*
 Hypnos - Shared Media Cache

 Manages temporary storage of files received via the share sheet.
 Files are cached in Library/Caches/SharedMedia/ for window restoration.
 A UserDefaults manifest tracks cache entries for orphan cleanup.
 */

import DebugTrace
import Foundation

actor SharedMediaCache {
    static let shared = SharedMediaCache()

    private let fileManager = FileManager.default
    private static let manifestKey = "sharedMediaManifest"

    struct ManifestEntry: Codable {
        let windowId: String
        let cachedFileName: String
        let mediaType: String
        let originalFileName: String
        let cachedDate: Date
    }

    private var cacheDirectory: URL {
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("SharedMedia", isDirectory: true)
    }

    /// Cache a shared file and return the cached URL and window ID
    func cacheSharedFile(
        from sourceURL: URL,
        mediaType: SharedMediaItem.SharedMediaType
    ) -> (cachedURL: URL, windowId: String)? {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Ensure cache directory exists
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let windowId = UUID().uuidString
        let originalFileName = sourceURL.lastPathComponent
        let ext = sourceURL.pathExtension
        let cachedFileName = ext.isEmpty ? windowId : "\(windowId).\(ext)"
        let cachedURL = cacheDirectory.appendingPathComponent(cachedFileName)

        do {
            try fileManager.copyItem(at: sourceURL, to: cachedURL)
        } catch {
            AppLogger.sharedMedia.error("Failed to cache shared file: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }

        // Mark cache directory as excluded from backups
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableCacheDir = cacheDirectory
        try? mutableCacheDir.setResourceValues(resourceValues)

        // Update manifest
        let entry = ManifestEntry(
            windowId: windowId,
            cachedFileName: cachedFileName,
            mediaType: mediaType.rawValue,
            originalFileName: originalFileName,
            cachedDate: Date()
        )
        var manifest = loadManifest()
        manifest.append(entry)
        saveManifest(manifest)

        AppLogger.sharedMedia.info("Cached shared file: \(originalFileName) as \(cachedFileName, privacy: .public)")
        return (cachedURL, windowId)
    }

    /// Get the cached file URL for a window ID
    func getCachedFile(for windowId: String) -> URL? {
        let manifest = loadManifest()
        guard let entry = manifest.first(where: { $0.windowId == windowId }) else {
            return nil
        }
        let url = cacheDirectory.appendingPathComponent(entry.cachedFileName)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Remove cached file and manifest entry for a window ID
    func removeCachedFile(for windowId: String) {
        var manifest = loadManifest()
        guard let index = manifest.firstIndex(where: { $0.windowId == windowId }) else {
            return
        }
        let entry = manifest[index]
        let fileURL = cacheDirectory.appendingPathComponent(entry.cachedFileName)

        try? fileManager.removeItem(at: fileURL)
        manifest.remove(at: index)
        saveManifest(manifest)

        AppLogger.sharedMedia.info("Removed cached file for window: \(windowId, privacy: .public)")
    }

    /// Clean up orphaned cache entries on app launch
    func cleanupOrphanedEntries() {
        var manifest = loadManifest()
        let maxAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
        let now = Date()
        var removedCount = 0

        // Remove entries whose files no longer exist or are too old
        manifest.removeAll { entry in
            let fileURL = cacheDirectory.appendingPathComponent(entry.cachedFileName)
            let fileExists = fileManager.fileExists(atPath: fileURL.path)
            let isTooOld = now.timeIntervalSince(entry.cachedDate) > maxAge

            if !fileExists {
                AppLogger.sharedMedia.debug("Removing manifest entry for missing file: \(entry.cachedFileName, privacy: .public)")
                removedCount += 1
                return true
            }

            if isTooOld {
                try? fileManager.removeItem(at: fileURL)
                AppLogger.sharedMedia.debug("Removing expired cache entry: \(entry.cachedFileName, privacy: .public)")
                removedCount += 1
                return true
            }

            return false
        }

        saveManifest(manifest)

        // Delete untracked files in the cache directory
        let trackedFileNames = Set(manifest.map { $0.cachedFileName })
        if let contents = try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path) {
            for fileName in contents {
                if !trackedFileNames.contains(fileName) {
                    let fileURL = cacheDirectory.appendingPathComponent(fileName)
                    try? fileManager.removeItem(at: fileURL)
                    AppLogger.sharedMedia.debug("Deleted untracked cache file: \(fileName, privacy: .public)")
                    removedCount += 1
                }
            }
        }

        if removedCount > 0 {
            AppLogger.sharedMedia.info("Cleaned up \(removedCount, privacy: .public) orphaned cache entries")
        }
    }

    // MARK: - Manifest Persistence

    private func loadManifest() -> [ManifestEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.manifestKey),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveManifest(_ manifest: [ManifestEntry]) {
        if let data = try? JSONEncoder().encode(manifest) {
            UserDefaults.standard.set(data, forKey: Self.manifestKey)
        }
    }
}
