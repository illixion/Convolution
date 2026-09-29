/*
 Hypnos - Disk Video Cache

 Persistent cache for converted MV-HEVC stereoscopic videos.
 Avoids re-downloading and re-converting videos that have already been processed.
 The system can automatically clean this directory when storage is low.
 Size accounting and LRU eviction live in the shared LRUDiskCache engine, with
 the cap derived from device storage by CacheBudget; evicting a video also
 removes its metadata sidecar, and reservations let an in-flight download's
 expected bytes count against the cap so room is made before the file lands.
 */

import DebugTrace
import Foundation

/// Metadata about a cached video
struct CachedVideoMetadata: Codable {
    let videoId: String
    let originalURL: String
    let stereoscopicFormat: String
    let sourceWidth: Int
    let sourceHeight: Int
    let duration: TimeInterval
    let fileSize: Int64
    let cachedDate: Date
}

actor DiskVideoCache {
    static let shared = DiskVideoCache()

    nonisolated private static let cacheDirectoryURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("VideoCache", isDirectory: true)
    }()
    nonisolated private static let metadataDirectoryURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("VideoCacheMetadata", isDirectory: true)
    }()

    private let engine: LRUDiskCache
    private let metadataDirectory = DiskVideoCache.metadataDirectoryURL
    private let fileManager = FileManager.default

    /// Expected bytes of downloads/conversions currently in flight, keyed by
    /// caller-chosen token. Counted against the cap by the engine so a large
    /// incoming video starts making room before it lands.
    private let reservations = ReservationBook()

    private init() {
        let engine = LRUDiskCache(
            directory: Self.cacheDirectoryURL,
            domain: .videos,
            log: AppLogger.videoCache
        )
        // Evicting a video drops its metadata sidecar too.
        let metadataDir = Self.metadataDirectoryURL
        engine.companionURLs = { videoURL in
            [metadataDir.appendingPathComponent("\(videoURL.deletingPathExtension().lastPathComponent).json")]
        }
        let reservations = self.reservations
        engine.pendingBytes = { reservations.total() }
        self.engine = engine

        try? fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        LRUDiskCache.excludeFromBackup(metadataDirectory)
    }

    /// Thread-safe pending-bytes ledger (read by the engine's eviction pass).
    private final class ReservationBook: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [String: Int64] = [:]

        func set(_ token: String, _ value: Int64) {
            lock.lock()
            bytes[token] = value
            lock.unlock()
        }

        func remove(_ token: String) {
            lock.lock()
            bytes.removeValue(forKey: token)
            lock.unlock()
        }

        func total() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return bytes.values.reduce(0, +)
        }
    }

    // MARK: - Reservations

    /// Announce an incoming video's expected size (e.g. from Content-Length)
    /// so eviction accounts for it before the file is written. Triggers an
    /// immediate budget check to start making room.
    func reserveCapacity(token: String, expectedBytes: Int64) {
        guard expectedBytes > 0 else { return }
        reservations.set(token, expectedBytes)
        engine.evictIfNeeded()
    }

    /// Release a reservation (after the save lands, or on failure/cancel).
    func releaseReservation(token: String) {
        reservations.remove(token)
    }

    // MARK: - Keys

    /// Generate a cache key from video ID and format
    private func cacheKey(videoId: String, format: String) -> String {
        "\(videoId)_\(format)"
    }

    /// Get the file URL for a cached video
    private func cacheFileURL(videoId: String, format: String) -> URL {
        engine.directory.appendingPathComponent("\(cacheKey(videoId: videoId, format: format)).mov")
    }

    /// Get the metadata file URL for a cached video
    private func metadataFileURL(videoId: String, format: String) -> URL {
        metadataDirectory.appendingPathComponent("\(cacheKey(videoId: videoId, format: format)).json")
    }

    // MARK: - Lookup

    /// Check if a converted video is cached
    func isCached(videoId: String, format: String) -> Bool {
        fileManager.fileExists(atPath: cacheFileURL(videoId: videoId, format: format).path)
    }

    /// Get the cached video URL if available
    func getCachedVideoURL(videoId: String, format: String) -> URL? {
        let fileURL = cacheFileURL(videoId: videoId, format: format)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Update access time for LRU tracking
        engine.touch(fileURL)
        return fileURL
    }

    /// Get metadata for a cached video
    func getMetadata(videoId: String, format: String) -> CachedVideoMetadata? {
        let metadataURL = metadataFileURL(videoId: videoId, format: format)

        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedVideoMetadata.self, from: data)
    }

    // MARK: - Store

    /// Save a converted video to the cache (copying the source file).
    @discardableResult
    func saveVideo(from sourceURL: URL, videoId: String, format: String, metadata: CachedVideoMetadata) throws -> URL {
        try store(sourceURL: sourceURL, videoId: videoId, format: format, metadata: metadata, move: false)
    }

    /// Move a converted video to the cache (more efficient than copy).
    @discardableResult
    func moveVideoToCache(from sourceURL: URL, videoId: String, format: String, metadata: CachedVideoMetadata) throws -> URL {
        try store(sourceURL: sourceURL, videoId: videoId, format: format, metadata: metadata, move: true)
    }

    private func store(
        sourceURL: URL, videoId: String, format: String, metadata: CachedVideoMetadata, move: Bool
    ) throws -> URL {
        let destinationURL = cacheFileURL(videoId: videoId, format: format)
        let metadataURL = metadataFileURL(videoId: videoId, format: format)

        // Remove existing file if present
        let replaced = engine.sizeOnDisk(of: destinationURL)
        try? fileManager.removeItem(at: destinationURL)
        try? fileManager.removeItem(at: metadataURL)

        if move {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        // Save metadata
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL)

        engine.noteWrite(at: destinationURL, replacing: replaced)
        AppLogger.videoCache.info("Cached video\(move ? " (moved)" : "", privacy: .public): \(videoId, privacy: .private) (\(format, privacy: .public))")
        return destinationURL
    }

    // MARK: - Remove

    /// Remove a specific video from cache
    func removeVideo(videoId: String, format: String) {
        let fileURL = cacheFileURL(videoId: videoId, format: format)
        let metadataURL = metadataFileURL(videoId: videoId, format: format)

        engine.noteRemoval(bytes: engine.sizeOnDisk(of: fileURL))
        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    /// Remove all cached versions of a video (all formats and settings combinations)
    /// Used when 3D settings change and we need to re-convert
    func removeAllCachedVersions(videoId: String) {
        // Scan cache directory for any files starting with videoId_
        let prefix = "\(videoId)_"

        // Remove from video cache
        if let cacheContents = try? fileManager.contentsOfDirectory(at: engine.directory, includingPropertiesForKeys: nil) {
            for fileURL in cacheContents where fileURL.lastPathComponent.hasPrefix(prefix) {
                engine.noteRemoval(bytes: engine.sizeOnDisk(of: fileURL))
                try? fileManager.removeItem(at: fileURL)
                AppLogger.videoCache.info("Removed cached video: \(fileURL.lastPathComponent)")
            }
        }

        // Remove from metadata cache
        if let metadataContents = try? fileManager.contentsOfDirectory(at: metadataDirectory, includingPropertiesForKeys: nil) {
            for fileURL in metadataContents where fileURL.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    /// Clear entire cache
    func clearCache() {
        engine.clear()
        try? fileManager.removeItem(at: metadataDirectory)
        try? fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        LRUDiskCache.excludeFromBackup(metadataDirectory)
    }

    /// Re-check the budget (preset change) and evict if over.
    func enforceBudget() {
        engine.evictIfNeeded()
    }

    /// Get cache statistics
    func getCacheStats() -> (fileCount: Int, totalSize: Int64) {
        engine.stats()
    }

    /// List all cached videos
    func listCachedVideos() -> [CachedVideoMetadata] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return contents.compactMap { url -> CachedVideoMetadata? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? decoder.decode(CachedVideoMetadata.self, from: data)
        }
    }
}
