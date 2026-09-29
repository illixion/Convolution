/*
 Hypnos - Async Image Loader

 Actor-based image loader with caching to prevent duplicate requests.
 Supports both static images and animated GIFs.
 */

import DebugTrace
import ImageIO
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Wrapper class to store image data in NSCache
final class CachedImageData: NSObject, @unchecked Sendable {
    let image: UIImage
    let data: Data

    init(image: UIImage, data: Data) {
        self.image = image
        self.data = data
    }
}

/// Failures the loader reports to callers instead of a silent `nil`, so a
/// viewer window can tell "the server refused this image" apart from "there was
/// nothing to load" and surface a retry rather than spinning forever.
enum ImageLoaderError: LocalizedError {
    case httpStatus(Int)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        case .decodeFailed:
            return "This image's data couldn't be decoded. It may be corrupted."
        }
    }
}

actor ImageLoader {
    static let shared = ImageLoader()

    /// Image downloads run on a session with bounded timeouts rather than
    /// `URLSession.shared`, whose default `timeoutIntervalForResource` is seven
    /// days: a Stash server that accepts the connection and then stalls would
    /// otherwise hold a viewer window in its loading state effectively forever.
    /// `timeoutIntervalForRequest` is the inactivity budget between bytes, so a
    /// slow-but-progressing transfer is not penalised; the resource timeout is
    /// the ceiling on the whole download.
    nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        // No URLCache: `.default` otherwise inherits `URLCache.shared`, a
        // disk-backed cache that survives relaunch. A transient server-side
        // failure (e.g. Stash failing to generate a thumbnail) can come back
        // as a cacheable 200 with a broken/empty body; the OS cache then
        // replays that same broken response for every future request to the
        // URL — including after a relaunch and even once the server is
        // serving the real thumbnail again — since nothing here ever primes
        // a `Cache-Control`/ETag revalidation. DiskImageCache/ThumbnailCache
        // already provide our own on-disk cache, gated on a successful
        // decode, so the OS-level cache is pure downside here.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// An authenticated request for a remote media URL, with this loader's
    /// no-OS-cache policy restated on the request itself.
    ///
    /// A hand-built `URLRequest` carries its own `.useProtocolCachePolicy`
    /// default, so whether the session configuration's
    /// `requestCachePolicy` still wins is ambiguous in a way `data(from:)`
    /// never was. `urlCache` being nil already makes this moot — there is no
    /// cache to serve a stale body from — so this is belt and braces for the
    /// reasons the session comment above spells out.
    private nonisolated static func remoteRequest(for url: URL) -> URLRequest {
        var request = MediaAuthorization.shared.request(for: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private var cache = NSCache<NSURL, CachedImageData>()
    private var inProgressTasks: [URL: Task<CachedImageData?, Error>] = [:]
    /// In-flight dedupe for decode-free raw-data fetches, so a prefetch
    /// fan-out (many cells requesting overlapping ranges) coalesces instead of
    /// issuing duplicate network loads for the same URL.
    private var inProgressDataTasks: [URL: Task<Data?, Error>] = [:]

    private init() {
        // Configure cache limits (costs reflect true decoded image sizes)
        cache.countLimit = 20
        cache.totalCostLimit = 512 * 1024 * 1024 // 512 MB
    }

    /// Estimate the actual in-memory cost of a cached image (decoded pixels + compressed data)
    private nonisolated func estimatedMemoryCost(image: UIImage, data: Data) -> Int {
        let pixelCost: Int
        if let cgImage = image.cgImage {
            pixelCost = cgImage.width * cgImage.height * 4
        } else {
            pixelCost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        return pixelCost + data.count
    }

    /// Normalize an image by redrawing it to avoid Core Graphics decoding issues
    /// with certain 24-bit image formats (rdar://143602439). Preserves bit depth
    /// — UIGraphicsImageRenderer would flatten 16-bit sources to 8-bit.
    private nonisolated func normalizeImage(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else {
            return image
        }

        return autoreleasepool {
            guard let redrawn = CGImageDeepColor.redraw(cgImage) else {
                return image
            }
            return UIImage(cgImage: redrawn, scale: image.scale, orientation: image.imageOrientation)
        }
    }


    // MARK: - Photos assets

    /// Maps a `photos-asset:///` URL to the container file backing it, and
    /// passes every other URL through untouched.
    ///
    /// Called at the top of each loading entry point so the machinery below —
    /// which branches on `isFileURL` — sees an ordinary local file and needs no
    /// knowledge of Photos.
    private func resolvingPhotosAsset(_ url: URL) async -> URL? {
        guard PhotosAssetURL.isPhotosAsset(url) else { return url }
        return await PhotosAssetStore.shared.fileURL(for: url)
    }

    /// Load an image from a URL, using cache if available
    /// - Parameter url: The URL to load the image from
    /// - Returns: The loaded image, or nil if loading failed
    func loadImage(from url: URL) async throws -> UIImage? {
        guard let url = await resolvingPhotosAsset(url) else { return nil }
        // Check memory cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.image
        }

        // Handle local file URLs directly
        if url.isFileURL {
            let result = try await loadLocalImageWithData(from: url)
            return result?.image
        }

        // Check disk cache for remote URLs
        if let diskData = await DiskImageCache.shared.loadData(for: url),
           let rawImage = UIImage(data: diskData) {
            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)
            // Restore to memory cache
            let cachedData = CachedImageData(image: image, data: diskData)
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: diskData))
            return image
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            return try await existingTask.value?.image
        }

        // Start new load task for remote URLs
        let task = Task<CachedImageData?, Error> { [self] in
            let (data, response) = try await Self.session.data(for: Self.remoteRequest(for: url))

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let rawImage = UIImage(data: data) else {
                return nil
            }

            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache in memory
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

            // Cache to disk
            await DiskImageCache.shared.saveData(data, for: url)

            return cachedData
        }

        inProgressTasks[url] = task

        defer {
            inProgressTasks[url] = nil
        }

        return try await task.value?.image
    }

    /// Load image data from a URL, using cache if available
    /// - Parameter url: The URL to load the image from
    /// - Returns: The raw image data, or nil if loading failed
    func loadImageData(from url: URL) async throws -> Data? {
        guard let url = await resolvingPhotosAsset(url) else { return nil }
        // Check memory cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.data
        }

        // Handle local file URLs directly
        if url.isFileURL {
            let result = try await loadLocalImageWithData(from: url)
            return result?.data
        }

        // Check disk cache for remote URLs
        if let diskData = await DiskImageCache.shared.loadData(for: url),
           let rawImage = UIImage(data: diskData) {
            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)
            // Restore to memory cache
            let cachedData = CachedImageData(image: image, data: diskData)
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: diskData))
            return diskData
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            return try await existingTask.value?.data
        }

        // Start new load task for remote URLs
        let task = Task<CachedImageData?, Error> { [self] in
            let (data, response) = try await Self.session.data(for: Self.remoteRequest(for: url))

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let rawImage = UIImage(data: data) else {
                return nil
            }

            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache in memory
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

            // Cache to disk
            await DiskImageCache.shared.saveData(data, for: url)

            return cachedData
        }

        inProgressTasks[url] = task

        defer {
            inProgressTasks[url] = nil
        }

        return try await task.value?.data
    }

    /// Load ONLY the raw Data for a URL without decoding to UIImage.
    /// Avoids the expensive normalizeImage() allocation for cases where
    /// only the bytes are needed (e.g. GIF detection).
    /// - Parameter bypassCache: Skip the memory/disk cache reads and always hit
    ///   the network. Used by the Settings "Test Connection" check, where a
    ///   previously-cached good thumbnail would otherwise mask a since-broken
    ///   credential (e.g. a Stash API key whose signature no longer verifies)
    ///   by silently serving the old bytes instead of re-authenticating.
    ///   Successful fetches are still written to disk cache as usual.
    func loadRawData(from url: URL, bypassCache: Bool = false) async throws -> Data? {
        guard let url = await resolvingPhotosAsset(url) else { return nil }
        // Check memory cache first (if already loaded, return cached data)
        if !bypassCache, let cached = cache.object(forKey: url as NSURL) {
            return cached.data
        }

        // Handle local file URLs directly (memory-mapped to reduce dirty memory)
        if url.isFileURL {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }

        // Check disk cache for remote URLs
        if !bypassCache, let diskData = await DiskImageCache.shared.loadData(for: url) {
            return diskData
        }

        // Coalesce concurrent network fetches for the same URL.
        if let existingTask = inProgressDataTasks[url] {
            return try await existingTask.value
        }

        // Download without decoding to UIImage
        let task = Task<Data?, Error> {
            let (data, response) = try await Self.session.data(for: Self.remoteRequest(for: url))

            // Report a refusal as an error rather than a silent nil: the photo
            // viewer needs to tell "server said no" apart from "nothing to
            // load" so it can show the failure instead of loading forever.
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ImageLoaderError.httpStatus(httpResponse.statusCode)
            }

            // A 2xx status doesn't guarantee a real image — an unauthenticated
            // request against a Stash instance with login enabled 302s to
            // /login, and URLSession follows that automatically, so this task
            // sees a 200 carrying the login page's HTML rather than an error
            // status. Stash can also answer with a broken/placeholder body,
            // or a truncated one from a dropped connection, while still
            // saying 200. Unlike the full UIImage(data:)-decoding loaders,
            // this path skips decoding for speed, so without a real check a
            // bad response would get written to DiskImageCache and served
            // back on every future load — including after a relaunch, and
            // even once the server starts returning the real image again —
            // since disk-cache reads never revalidate against the network.
            //
            // CGImageSourceCreateWithData alone does NOT reject this: it
            // lazily wraps the bytes and returns non-nil for arbitrary data,
            // including plain HTML (verified — an ImageIO source built from a
            // Stash login page reports 0 images and nil properties, but is
            // still non-nil itself). Checking the image count is what
            // actually asks "did this decode to a real image."
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else {
                return nil
            }

            // Cache to disk only (skip memory cache since we're not decoding)
            await DiskImageCache.shared.saveData(data, for: url)

            return data
        }

        inProgressDataTasks[url] = task
        defer { inProgressDataTasks[url] = nil }
        return try await task.value
    }

    /// Load both image and data from a URL, using cache if available
    /// - Parameter url: The URL to load the image from
    /// - Returns: A tuple of (UIImage, Data), or nil if loading failed
    func loadImageWithData(from url: URL) async throws -> (image: UIImage, data: Data)? {
        guard let url = await resolvingPhotosAsset(url) else { return nil }
        // Check memory cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return (cached.image, cached.data)
        }

        // Handle local file URLs directly
        if url.isFileURL {
            return try await loadLocalImageWithData(from: url)
        }

        // Check disk cache for remote URLs
        if let diskData = await DiskImageCache.shared.loadData(for: url),
           let rawImage = UIImage(data: diskData) {
            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)
            // Restore to memory cache
            let cachedData = CachedImageData(image: image, data: diskData)
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: diskData))
            return (image, diskData)
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            if let result = try await existingTask.value {
                return (result.image, result.data)
            }
            return nil
        }

        // Start new load task for remote URLs
        let task = Task<CachedImageData?, Error> { [self] in
            let (data, response) = try await Self.session.data(for: Self.remoteRequest(for: url))

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let rawImage = UIImage(data: data) else {
                return nil
            }

            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache in memory
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

            // Cache to disk
            await DiskImageCache.shared.saveData(data, for: url)

            return cachedData
        }

        inProgressTasks[url] = task

        defer {
            inProgressTasks[url] = nil
        }

        if let result = try await task.value {
            return (result.image, result.data)
        }
        return nil
    }

    /// Load image from a local file URL
    private func loadLocalImageWithData(from url: URL) async throws -> (image: UIImage, data: Data)? {
        // Memory-mapped read: pages loaded on demand, kernel can evict without
        // increasing dirty memory or triggering jetsam pressure.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        guard let rawImage = UIImage(data: data) else {
            AppLogger.imageLoader.warning("Failed to create UIImage from local file: \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        // Normalize the image to avoid Core Graphics decoding issues
        let image = normalizeImage(rawImage)

        // Cache in memory (but not to disk since it's already local)
        let cachedData = CachedImageData(image: image, data: data)
        cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

        return (image, data)
    }

    /// Clear the image cache (both memory and disk, including background removal cache)
    func clearCache() async {
        cache.removeAllObjects()
        await DiskImageCache.shared.clearCache()
        await BackgroundRemovalCache.shared.clearCache()
    }

    /// Clear only the in-memory cache, preserving disk cache
    func clearMemoryCache() {
        cache.removeAllObjects()
    }

    /// Remove a specific image from cache
    func removeFromCache(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    // MARK: - Thumbnail Loading (Memory Efficient)

    /// Load a thumbnail for display in gallery views
    /// Uses memory-efficient downsampling for local files
    /// - Parameters:
    ///   - url: The image URL
    ///   - maxSize: Maximum thumbnail dimension (default 400px for 2x display)
    /// - Returns: A downsampled UIImage suitable for thumbnails
    func loadThumbnail(from url: URL, maxSize: CGFloat = ThumbnailGenerator.defaultThumbnailSize) async -> UIImage? {
        if PhotosAssetURL.isPhotosAsset(url) {
            return await PhotosAssetStore.shared.thumbnail(for: url, maxSize: maxSize)
        }
        // For local files, use the efficient thumbnail system
        if url.isFileURL {
            return await loadLocalThumbnail(from: url, maxSize: maxSize)
        }

        // For remote URLs, use the regular loading (they're already thumbnails from server)
        return try? await loadImage(from: url)
    }

    /// Load a thumbnail with data (for animated GIF detection)
    /// - Parameters:
    ///   - url: The image URL
    ///   - maxSize: Maximum thumbnail dimension
    /// - Returns: Tuple of (thumbnail image, original data for GIF detection)
    func loadThumbnailWithData(from url: URL, maxSize: CGFloat = ThumbnailGenerator.defaultThumbnailSize) async -> (image: UIImage, data: Data, isAnimatedGIF: Bool)? {
        // Ask Photos for a thumbnail directly rather than exporting the
        // original: a grid asks for hundreds of these while scrolling, and the
        // full-size bytes would be decoded and thrown away at cell size.
        if PhotosAssetURL.isPhotosAsset(url) {
            guard let image = await PhotosAssetStore.shared.thumbnail(for: url, maxSize: maxSize),
                  let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            return (image, data, false)
        }
        // For local files, use efficient thumbnail loading
        if url.isFileURL {
            // Check if it's an animated GIF first (without loading full image)
            let isAnimated = ThumbnailGenerator.shared.isAnimatedGIF(at: url)

            if isAnimated {
                // For animated GIFs, we need the full data for playback
                // But we can still be memory-efficient by not caching the full image
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    return nil
                }
                // Create a small preview image for non-animated display
                if let thumbnail = await loadLocalThumbnail(from: url, maxSize: maxSize) {
                    return (thumbnail, data, true)
                }
                return nil
            } else {
                // For static images, use efficient thumbnail
                if let thumbnail = await loadLocalThumbnail(from: url, maxSize: maxSize) {
                    // We don't need the original data for static thumbnails
                    // Return empty data since it won't be used
                    return (thumbnail, Data(), false)
                }
                return nil
            }
        }

        // For remote URLs, use existing loading
        if let result = try? await loadImageWithData(from: url) {
            let isAnimated = result.data.isAnimatedGIF
            return (result.image, result.data, isAnimated)
        }
        return nil
    }

    /// Load a remote thumbnail and cache the final result in ThumbnailCache for fast reload.
    /// This avoids the expensive normalizeImage() path on every scroll-back.
    /// - Parameters:
    ///   - url: The remote thumbnail URL
    ///   - maxSize: When set, downsample to this max dimension straight from the
    ///     encoded bytes (no full-resolution decode), so large grids hold small
    ///     bitmaps. When nil, the full-resolution image is used (legacy behavior).
    ///   - crop: Optional transform to apply before caching (e.g. crop to square or 16:9)
    /// - Returns: The cached thumbnail UIImage
    func loadRemoteThumbnailCached(from url: URL, maxSize: CGFloat? = nil, crop: ((UIImage) -> UIImage)? = nil) async -> UIImage? {
        if PhotosAssetURL.isPhotosAsset(url) {
            let target = maxSize ?? ThumbnailGenerator.defaultThumbnailSize
            guard let image = await PhotosAssetStore.shared.thumbnail(for: url, maxSize: target) else { return nil }
            return crop.map { $0(image) } ?? image
        }
        // Check ThumbnailCache first (fast memory cache, then HEIC disk)
        // The cache is keyed by URL alone, so an entry written by an uncapped
        // caller can be the full original; a capped caller regenerates it
        // instead of holding that bitmap.
        if let cached = await ThumbnailCache.shared.loadThumbnail(for: url),
           maxSize.map({ Self.pixelLongEdge(of: cached) <= $0 }) ?? true {
            return cached
        }

        let base: UIImage
        if let maxSize,
           let data = try? await loadRawData(from: url),
           let downsampled = await ThumbnailGenerator.shared.downsample(data: data, maxSize: maxSize) {
            // Downsample directly from bytes — skips the full decode + normalize.
            base = downsampled
        } else {
            // Full load (memory cache → disk cache → network + normalizeImage).
            // Also the fallback if the raw-data/downsample path failed.
            guard let image = try? await loadImage(from: url) else {
                return nil
            }
            // Still honour the cap, or the cache check above would reject
            // this entry and refetch it on every visit.
            base = maxSize.map { Self.fitting(image, maxPixelSize: $0) } ?? image
        }

        // Apply crop transform if provided
        let thumbnail = crop?(base) ?? base

        // Store in ThumbnailCache for fast future reloads
        await ThumbnailCache.shared.saveThumbnail(thumbnail, for: url)

        return thumbnail
    }

    private nonisolated static func pixelLongEdge(of image: UIImage) -> CGFloat {
        max(image.size.width, image.size.height) * image.scale
    }

    private nonisolated static func fitting(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage {
        let longEdge = pixelLongEdge(of: image)
        guard longEdge > maxPixelSize else { return image }
        let factor = maxPixelSize / longEdge
        let pixelSize = CGSize(
            width: (image.size.width * image.scale * factor).rounded(),
            height: (image.size.height * image.scale * factor).rounded()
        )
        #if os(macOS)
        // No `UIGraphicsImageRenderer` on macOS; `NSImage`'s own
        // lock-focus-and-draw is the equivalent redraw-at-a-new-size idiom.
        let resized = NSImage(size: pixelSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: pixelSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        #endif
    }

    /// Load thumbnail for a local file using memory-efficient downsampling
    private func loadLocalThumbnail(from url: URL, maxSize: CGFloat) async -> UIImage? {
        // Check thumbnail cache first
        if let cached = await ThumbnailCache.shared.loadThumbnail(for: url) {
            return cached
        }

        // Generate thumbnail using efficient downsampling
        guard let thumbnail = await ThumbnailGenerator.shared.generateThumbnail(for: url, maxSize: maxSize) else {
            AppLogger.imageLoader.warning("Failed to generate thumbnail for: \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        // Cache the generated thumbnail
        await ThumbnailCache.shared.saveThumbnail(thumbnail, for: url)

        return thumbnail
    }
}
