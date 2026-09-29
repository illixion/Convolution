/*
 Hypnos - Thumbnail Diorama Cache

 Two-tier cache of (foreground, backdrop) pairs generated from gallery
 thumbnails for the gaze-driven Apple-TV-style parallax effect.

 - Tier 1: in-memory NSCache for hot scrollback.
 - Tier 2: HEIC pair on disk (`Caches/ThumbnailDioramas/<sha>.{fg,bg}.heic`)
   so the foreground appears in the same frame as the base thumbnail on
   subsequent app launches instead of popping in after a Vision pass.

 Disk namespace is distinct from `BackgroundRemovalCache` (which stores
 full-resolution diorama variants), so the two never collide despite
 sharing the source image URL.

 Generation runs through `BackgroundRemover` (actor) which naturally
 serializes the Vision pipeline across callers.
 */

import CommonCrypto
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

@MainActor
final class ThumbnailDioramaCache {
    static let shared = ThumbnailDioramaCache()

    final class Pair: @unchecked Sendable {
        let foreground: UIImage
        let backdrop: UIImage
        init(foreground: UIImage, backdrop: UIImage) {
            self.foreground = foreground
            self.backdrop = backdrop
        }
    }

    private let cache: NSCache<NSURL, Pair> = {
        let c = NSCache<NSURL, Pair>()
        c.totalCostLimit = 80 * 1024 * 1024 // ~80 MB of decoded thumbnail diorama bitmaps
        return c
    }()
    private var inFlight: [URL: Task<Pair?, Never>] = [:]
    private var diskLoads: [URL: Task<Pair?, Never>] = [:]

    /// Shared LRU engine (thread-safe) — the disk tier is written from
    /// detached tasks. Budget-derived cap, incremental size tracking.
    nonisolated private static let engine = LRUDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ThumbnailDioramas", isDirectory: true),
        domain: .thumbnailDioramas,
        log: AppLogger.diskCache,
        formatVersion: 1
    )

    nonisolated private static var cacheDirectory: URL { engine.directory }

    /// Disk stats / budget re-check for the Settings cache manager.
    nonisolated static func getCacheStats() -> (fileCount: Int, totalSize: Int64) { engine.stats() }
    nonisolated static func enforceBudget() { engine.evictIfNeeded() }

    private init() {}

    func cached(for url: URL) -> Pair? {
        cache.object(forKey: url as NSURL)
    }

    /// Look up `url` in memory and, if missing, on disk. Never invokes
    /// Vision. Populates the in-memory cache on a disk hit so subsequent
    /// scrollbacks are synchronous.
    /// A disk pair whose long edge exceeds `maxPixelSize` counts as a miss,
    /// so it gets regenerated from a capped source and overwritten.
    func cachedOrDisk(for url: URL, maxPixelSize: CGFloat? = nil) async -> Pair? {
        if let mem = cache.object(forKey: url as NSURL) { return mem }
        if let existing = diskLoads[url] { return await existing.value }

        let task = Task.detached(priority: .userInitiated) { () -> Pair? in
            guard let pair = Self.loadPairFromDisk(for: url) else { return nil }
            if let maxPixelSize {
                let fg = pair.foreground
                guard max(fg.size.width, fg.size.height) * fg.scale <= maxPixelSize else { return nil }
            }
            return pair
        }
        diskLoads[url] = Task { await task.value }
        let pair = await task.value
        diskLoads.removeValue(forKey: url)
        if let pair {
            let cost = approximateByteCount(pair.foreground) + approximateByteCount(pair.backdrop)
            cache.setObject(pair, forKey: url as NSURL, cost: cost)
        }
        return pair
    }

    /// Get or generate a thumbnail diorama pair for `url`. The `source`
    /// closure is only invoked on a cache miss with no in-flight task, so
    /// callers can pass an already-loaded thumbnail UIImage cheaply.
    func dioramaPair(for url: URL, source: () -> UIImage?) async -> Pair? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }
        guard let sourceImage = source() else { return nil }

        let task = Task { @MainActor [weak self] () -> Pair? in
            do {
                let result = try await BackgroundRemover.shared.generateDioramaPair(from: sourceImage)
                guard let fg = result.foreground, let bg = result.backdrop else { return nil }
                let pair = Pair(foreground: fg, backdrop: bg)
                let cost = approximateByteCount(fg) + approximateByteCount(bg)
                self?.cache.setObject(pair, forKey: url as NSURL, cost: cost)
                Task.detached(priority: .utility) {
                    Self.savePairToDisk(pair, for: url)
                }
                return pair
            } catch {
                AppLogger.backgroundRemover.warning("Thumbnail diorama generation failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight.removeValue(forKey: url)
        return result
    }

    func cancel(for url: URL) {
        inFlight[url]?.cancel()
        inFlight.removeValue(forKey: url)
    }

    func clearCache() {
        cache.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        diskLoads.values.forEach { $0.cancel() }
        diskLoads.removeAll()
        Self.engine.clear()
    }

    // MARK: - Disk persistence

    nonisolated private static func diskKey(for url: URL) -> String {
        let urlString = url.absoluteString + ":thumbnailDiorama"
        let data = Data(urlString.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func diskURLs(for url: URL) -> (foreground: URL, backdrop: URL) {
        let key = diskKey(for: url)
        return (
            cacheDirectory.appendingPathComponent(key + ".fg.heic"),
            cacheDirectory.appendingPathComponent(key + ".bg.heic")
        )
    }

    nonisolated private static func loadPairFromDisk(for url: URL) -> Pair? {
        let (fgURL, bgURL) = diskURLs(for: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: fgURL.path), fm.fileExists(atPath: bgURL.path) else {
            return nil
        }
        guard let fgData = try? Data(contentsOf: fgURL, options: .mappedIfSafe),
              let bgData = try? Data(contentsOf: bgURL, options: .mappedIfSafe),
              let fgImage = UIImage(data: fgData),
              let bgImage = UIImage(data: bgData) else {
            return nil
        }
        // Touch mtime for LRU.
        engine.touch(fgURL)
        engine.touch(bgURL)
        return Pair(foreground: fgImage, backdrop: bgImage)
    }

    nonisolated private static func savePairToDisk(_ pair: Pair, for url: URL) {
        let (fgURL, bgURL) = diskURLs(for: url)
        guard let fgData = encodeHeicData(from: pair.foreground),
              let bgData = encodeHeicData(from: pair.backdrop) else {
            return
        }
        let replacedFg = engine.sizeOnDisk(of: fgURL)
        let replacedBg = engine.sizeOnDisk(of: bgURL)
        do {
            try fgData.write(to: fgURL)
            engine.noteWrite(at: fgURL, replacing: replacedFg)
            try bgData.write(to: bgURL)
            engine.noteWrite(at: bgURL, replacing: replacedBg)
        } catch {
            AppLogger.diskCache.warning("Failed to persist thumbnail diorama: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    nonisolated private static func encodeHeicData(from image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

}

private func approximateByteCount(_ image: UIImage) -> Int {
    guard let cg = image.cgImage else { return 0 }
    return cg.width * cg.height * (cg.bitsPerPixel / 8)
}
