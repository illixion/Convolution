/*
 Hypnos - Auto Enhance Cache

 Persistent cache for auto-enhanced images using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Mirrors the BackgroundRemovalCache pattern for consistent behavior.
 Disk size accounting and LRU eviction live in the shared LRUDiskCache engine;
 entries whose original has left the disk image cache are evicted first (an
 enhanced render is useless without its source).
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

actor AutoEnhanceCache {
    static let shared = AutoEnhanceCache()

    private let engine: LRUDiskCache
    private let fileManager = FileManager.default
    private let heicCompressionQuality: CGFloat = 0.95

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let engine = LRUDiskCache(
            directory: caches.appendingPathComponent("AutoEnhanceCache", isDirectory: true),
            domain: .autoEnhance,
            log: AppLogger.diskCache,
            formatVersion: 1
        )
        // Prefer evicting renders whose original left the image cache.
        engine.evictsFirst = { fileURL in
            guard let originKey = LRUDiskCache.originKey(of: fileURL) else { return false }
            let original = DiskImageCache.cacheDirectory.appendingPathComponent(originKey)
            return !FileManager.default.fileExists(atPath: original.path)
        }
        self.engine = engine
    }

    // MARK: - Cache Key

    private func cacheKey(for url: URL) -> String {
        LRUDiskCache.sha256Key(url.absoluteString + ":autoEnhanced")
    }

    private func cacheFileURL(for url: URL) -> URL {
        engine.directory.appendingPathComponent(cacheKey(for: url) + ".heic")
    }

    // MARK: - Load / Save

    func isCached(url: URL) -> Bool {
        fileManager.fileExists(atPath: cacheFileURL(for: url).path)
    }

    func loadData(for url: URL) -> Data? {
        let fileURL = cacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }

        // Update access time for LRU tracking
        engine.touch(fileURL)

        return data
    }

    func saveImage(_ image: UIImage, for url: URL) {
        guard let heicData = encodeHeicData(from: image) else {
            AppLogger.diskCache.warning("Failed to encode auto-enhanced image as HEIC")
            return
        }

        let fileURL = cacheFileURL(for: url)
        let replaced = engine.sizeOnDisk(of: fileURL)
        do {
            try heicData.write(to: fileURL)
            tagOrigin(of: fileURL, for: url)
            engine.noteWrite(at: fileURL, replacing: replaced)
        } catch {
            AppLogger.diskCache.error("Failed to save auto-enhanced image: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    /// Link the entry to its source's image-cache key — but only when the
    /// original is actually in the disk image cache. Local files never are, so
    /// tagging them would mark every local render as an eviction-first orphan.
    private func tagOrigin(of fileURL: URL, for url: URL) {
        let originKey = DiskImageCache.cacheKey(for: url)
        let original = DiskImageCache.cacheDirectory.appendingPathComponent(originKey)
        guard fileManager.fileExists(atPath: original.path) else { return }
        LRUDiskCache.setOriginKey(originKey, for: fileURL)
    }

    // MARK: - Cache Management

    func clearCache() {
        engine.clear()
    }

    /// Re-check the budget (preset change) and evict if over.
    func enforceBudget() {
        engine.evictIfNeeded()
    }

    func getCacheStats() -> (fileCount: Int, totalSize: Int64) {
        engine.stats()
    }

    // MARK: - Private

    private func encodeHeicData(from image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }

        let orientation = cgImagePropertyOrientation(for: image.imageOrientation)
        // Preserve bit depth on encode: HEIC/HEVC Main10 supports 10-bit color.
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
}
