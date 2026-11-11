/*
 Hypnos - Music section: cover art, decoded once and kept.

 Every tile, row, the Now Playing cover, the Mini Player and the visualizer ask here, so a cover that has been
 seen is on screen on the first frame of the next view that wants it (no placeholder flash when a grid scrolls
 back, a list re-sorts, or Now Playing opens) and a cover that has not been seen fades in when it arrives.
 */

import CoreGraphics
import Foundation
import ImageIO

/// A decoded image to hand between actors. CGImage is immutable.
final class MusicImage: @unchecked Sendable {
    let cgImage: CGImage
    init(_ cgImage: CGImage) { self.cgImage = cgImage }
    var pixelCost: Int { cgImage.width * cgImage.height * 4 }
}

@MainActor
final class MusicArtworkStore {
    static let shared = MusicArtworkStore()

    private let plain = NSCache<NSURL, MusicImage>()
    private var plainTasks: [URL: Task<MusicImage?, Never>] = [:]

    private init() {
        // Covers are a few hundred pixels square; this holds several hundred of them and gives way under pressure.
        plain.totalCostLimit = 96 * 1_048_576
    }

    /// The cover if it has been loaded already; never waits.
    func cachedImage(for url: URL) -> MusicImage? { plain.object(forKey: url as NSURL) }

    /// The cover at `url`, from memory or the network. Concurrent requests for one cover share a download.
    func image(for url: URL) async -> MusicImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let task = plainTasks[url] { return await task.value }
        let task = Task<MusicImage?, Never> {
            // Decoding is real work: keep it off the main actor whatever the caller's isolation.
            let result = await Task.detached(priority: .userInitiated) { await Self.download(url) }.value
            if let result { self.plain.setObject(result, forKey: url as NSURL, cost: result.pixelCost) }
            self.plainTasks[url] = nil
            return result
        }
        plainTasks[url] = task
        return await task.value
    }

    /// Fetch and decode off the main actor. A cancelled or failed fetch is just no image: the tile keeps its glyph.
    private nonisolated static func download(_ url: URL) async -> MusicImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return MusicImage(image)
    }

    func removeAll() {
        plain.removeAllObjects()
    }
}
