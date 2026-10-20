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
import RAVEMedia
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
    /// Thumbnails Vision found no subject in. Not an error — a landscape or a
    /// pattern has nothing to lift out — but without remembering it each such
    /// tile would rerun Vision every time it scrolled back into view.
    private var withoutSubject: Set<URL> = []
    private var inFlight: [URL: Task<Pair?, Never>] = [:]
    private var diskLoads: [URL: Task<Pair?, Never>] = [:]

    /// A thumbnail's depth map for the "3D Depth" style, which `DepthTileView`
    /// turns into one displaced mesh. A class so NSCache can hold it.
    final class ThumbnailDepth: @unchecked Sendable {
        let map: StillDepthMap
        init(map: StillDepthMap) { self.map = map }
    }

    private let depthCache: NSCache<NSURL, ThumbnailDepth> = {
        let c = NSCache<NSURL, ThumbnailDepth>()
        c.totalCostLimit = 24 * 1024 * 1024 // ~200 KB per map
        return c
    }()
    /// Thumbnails the model returned nothing usable for.
    private var withoutDepth: Set<URL> = []

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
        if withoutSubject.contains(url) { return nil }
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
            } catch BackgroundRemover.BackgroundRemovalError.noMaskResults {
                self?.withoutSubject.insert(url)
                AppLogger.backgroundRemover.info("Thumbnail has no foreground subject; keeping it flat")
                return nil
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

    // MARK: - Depth

    func cachedDepth(for url: URL) -> ThumbnailDepth? {
        depthCache.object(forKey: url as NSURL)
    }

    /// Memory, then disk. Never runs the model.
    func cachedOrDiskDepth(for url: URL) async -> ThumbnailDepth? {
        if let mem = depthCache.object(forKey: url as NSURL) { return mem }
        let map = await Task.detached(priority: .userInitiated) { Self.loadDepthFromDisk(for: url) }.value
        guard let map else { return nil }
        return storeDepth(map, for: url)
    }

    /// Get or generate the depth map for `url`. Runs in the caller's task on
    /// purpose (no shared in-flight task, unlike the Vision pair): cancelling
    /// the cell's task is what pulls its request out of the estimator's queue
    /// before it reaches the model, which is the whole fast-scroll story.
    func depth(for url: URL, source: () -> UIImage?) async -> ThumbnailDepth? {
        if let cached = depthCache.object(forKey: url as NSURL) { return cached }
        if withoutDepth.contains(url) { return nil }
        guard let cgImage = source()?.cgImage else { return nil }
        guard let map = await RAVEStillDepthEstimator.shared.depth(for: cgImage) else {
            // Cancelled (scrolled away) or no model: both retry next time.
            if !Task.isCancelled, RAVEStillDepthEstimator.shared.isModelAvailable {
                withoutDepth.insert(url)
                AppLogger.backgroundRemover.warning("Thumbnail depth inference failed; keeping it flat")
            }
            return nil
        }
        Task.detached(priority: .utility) { Self.saveDepthToDisk(map, for: url) }
        return storeDepth(map, for: url)
    }

    private func storeDepth(_ map: StillDepthMap, for url: URL) -> ThumbnailDepth {
        let depth = ThumbnailDepth(map: map)
        depthCache.setObject(depth, forKey: url as NSURL, cost: map.values.count)
        return depth
    }

    func cancel(for url: URL) {
        inFlight[url]?.cancel()
        inFlight.removeValue(forKey: url)
    }

    func clearCache() {
        cache.removeAllObjects()
        withoutSubject.removeAll()
        depthCache.removeAllObjects()
        withoutDepth.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        diskLoads.values.forEach { $0.cancel() }
        diskLoads.removeAll()
        Self.engine.clear()
    }

    // MARK: - Disk persistence

    nonisolated private static func diskKey(for url: URL) -> String {
        let urlString = url.absoluteString + ":thumbnailDiorama:uncropped"
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

    // MARK: - Depth disk persistence and masks

    /// Stored as the 8-bit map: a few tens of KB of lossless PNG.
    nonisolated private static func depthDiskURL(for url: URL) -> URL {
        let data = Data((url.absoluteString + ":thumbnailDepth:v1").utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return cacheDirectory.appendingPathComponent(hash.map { String(format: "%02x", $0) }.joined() + ".depth.png")
    }

    nonisolated private static func saveDepthToDisk(_ map: StillDepthMap, for url: URL) {
        guard let image = grayImage(map.values, width: map.width, height: map.height) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        let fileURL = depthDiskURL(for: url)
        let replaced = engine.sizeOnDisk(of: fileURL)
        do {
            try (data as Data).write(to: fileURL)
            engine.noteWrite(at: fileURL, replacing: replaced)
        } catch {
            AppLogger.diskCache.warning("Failed to persist thumbnail depth: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    nonisolated private static func loadDepthFromDisk(for url: URL) -> StillDepthMap? {
        let fileURL = depthDiskURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        engine.touch(fileURL)
        let width = image.width, height = image.height
        var values = [UInt8](repeating: 0, count: width * height)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? StillDepthMap(width: width, height: height, values: values) : nil
    }

    nonisolated private static func grayImage(_ values: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(values) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
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
