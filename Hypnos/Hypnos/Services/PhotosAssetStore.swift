/*
 Hypnos - Photos Asset Store

 Bridges `PHAsset` into an app that is URL-centric from top to bottom.

 Every loading path here — ImageLoader, MetalImageRenderer, ThumbnailGenerator,
 the disk caches, ImageEnhancementTracker — is addressed by `URL`. A PHAsset has
 no URL, so rather than teach each of those about Photos, an asset is addressed
 by a synthetic one:

     photos-asset:///<localIdentifier>

 That buys three things at once. The URL is stable across launches, because
 `localIdentifier` is; `MediaIdentity.persistentKey(for:)` already returns
 non-file URLs verbatim, so the identity story needs no special case; and
 `ImageEnhancementTracker`'s URL keying keeps working unchanged, so a Photos
 image remembers its viewing mode, flip and adjustments like any other.

 Bytes are produced on demand and cached as ordinary container files, so
 everything downstream sees a plain `file://` URL and behaves normally.

 The identifier goes in the PATH, not the host: a localIdentifier looks like
 `E1C0…-…/L0/001`, and putting that in the host position would silently split
 it across host and path.
 */

import AVFoundation
import DebugTrace
import Foundation
import Photos
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

enum PhotosAssetURL {
    static let scheme = "photos-asset"

    /// The synthetic URL addressing `localIdentifier`.
    static func url(forLocalIdentifier localIdentifier: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        // Assigning `path` percent-encodes what needs it and leaves the
        // identifier's own slashes as path separators, which round-trips.
        components.path = "/" + localIdentifier
        return components.url
    }

    /// The `PHAsset` local identifier inside a `photos-asset:///` URL, or nil.
    static func localIdentifier(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let path = url.path
        guard path.count > 1 else { return nil }
        return String(path.dropFirst())
    }

    /// Whether `url` addresses a Photos asset.
    static func isPhotosAsset(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }
}

// MARK: - Authorization

enum PhotosAuthorization {
    /// Current read authorization, without prompting.
    static var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Whether the library can be read at all. `.limited` counts: the user
    /// picked a subset and the app must work with exactly that subset rather
    /// than treating it as a denial. Getting that wrong hides a perfectly good
    /// limited library behind a permission screen, so the test lives here once
    /// and the views that hold a cached status call the overload.
    static func isReadable(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    /// Whether the library can be read at all, asked of the live status.
    static var isReadable: Bool {
        isReadable(status)
    }

    /// Requests read access, prompting only if the user has not decided yet.
    ///
    /// Deliberately `.readWrite` rather than `.addOnly`: the app reads the
    /// library and never adds to it, and `.addOnly` grants no read at all.
    @discardableResult
    static func request() async -> PHAuthorizationStatus {
        let current = status
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}

// MARK: - Asset byte store

/// Materializes Photos assets as container files so the URL-based loading
/// pipeline can consume them unchanged.
actor PhotosAssetStore {
    static let shared = PhotosAssetStore()

    private let imageManager = PHImageManager.default()

    /// Multiplier applied to a requested thumbnail size. See `thumbnail(for:maxSize:)`.
    private static let thumbnailOversample: CGFloat = 2

    /// Full-size exports live in Caches: they are reproducible from the
    /// library at any time, so losing them to a system purge costs only work,
    /// never data.
    private var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("PhotosAssets", isDirectory: true)
    }

    /// In-flight exports, so a grid that asks for the same asset from several
    /// cells performs one export rather than N.
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private init() {}

    /// Resolves a `photos-asset:///` URL to a readable local file URL,
    /// exporting the asset's original data on first use.
    ///
    /// Returns nil when the identifier no longer resolves (the user deleted the
    /// photo, or revoked access to it under `.limited`), which callers should
    /// treat exactly like a missing file.
    func fileURL(for assetURL: URL) async -> URL? {
        guard let identifier = PhotosAssetURL.localIdentifier(from: assetURL) else { return nil }

        if let existing = cachedFileURL(for: identifier) { return existing }

        if let running = inFlight[identifier] { return await running.value }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.export(identifier: identifier)
        }
        inFlight[identifier] = task
        let result = await task.value
        inFlight[identifier] = nil
        return result
    }

    /// A thumbnail straight from Photos, bypassing the full-size export.
    ///
    /// Grids ask for hundreds of these while scrolling; exporting originals to
    /// answer them would burn disk and time for pixels nobody sees at that size.
    func thumbnail(for assetURL: URL, maxSize: CGFloat) async -> UIImage? {
        guard let identifier = PhotosAssetURL.localIdentifier(from: assetURL),
              let asset = Self.asset(for: identifier) else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        // visionOS has no UIScreen and no single backing scale — content is
        // resampled per-window at a distance-dependent rate. Oversampling a
        // fixed amount keeps grid thumbnails crisp when a window is pulled
        // close, at a bounded memory cost.
        let target = CGSize(width: maxSize * Self.thumbnailOversample,
                            height: maxSize * Self.thumbnailOversample)

        // Photos calls the handler more than once — a fast degraded image,
        // then the real one — and does so on its own queue. Resuming a checked
        // continuation twice traps, so the guard has to be thread-safe rather
        // than a bare captured Bool.
        let gate = ResumeGate()
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                // The final callback always has degraded == false, including the
                // failure and cancellation cases, where `image` is nil.
                guard !degraded, gate.claim() else { return }
                continuation.resume(returning: image)
            }
        }
    }

    /// A URL AVFoundation can play for a Photos video asset.
    ///
    /// Most videos come back as an `AVURLAsset` pointing into the Photos
    /// library, which is readable while access is granted — that URL is handed
    /// back directly, so nothing is copied. Slow-motion and edited videos
    /// instead come back as an `AVComposition`, which has no URL at all; those
    /// are exported once into Caches.
    ///
    /// The returned URL is valid for this launch only. It is never used as an
    /// identity: `photos-asset:///<localIdentifier>` remains the stable key,
    /// and this is resolved fresh each time a window opens.
    func playableURL(for assetURL: URL) async -> URL? {
        guard let identifier = PhotosAssetURL.localIdentifier(from: assetURL),
              let asset = Self.asset(for: identifier) else { return nil }

        if let existing = cachedFileURL(for: identifier) { return existing }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud Photos originals
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let gate = ResumeGate()
        // AVAsset is not Sendable, so it rides across the continuation in a box
        // — the same shape as SendableTexture elsewhere in the app. Only one
        // task ever touches it, so the unchecked conformance is honest.
        let boxed: SendableAVAsset? = await withCheckedContinuation { continuation in
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard gate.claim() else { return }
                continuation.resume(returning: avAsset.map(SendableAVAsset.init(asset:)))
            }
        }

        guard let boxed else {
            AppLogger.localMedia.error("Photos video unavailable: \(identifier, privacy: .private(mask: .hash))")
            return nil
        }
        if let urlAsset = boxed.asset as? AVURLAsset {
            return urlAsset.url
        }
        return await exportComposition(boxed, identifier: identifier)
    }

    /// Writes a non-URL asset (slow-motion, edited) out to a playable file.
    private func exportComposition(_ boxed: SendableAVAsset, identifier: String) async -> URL? {
        let destination = cacheDirectory.appendingPathComponent(
            cacheFileName(for: identifier, extension: "mov")
        )
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)

        guard let session = AVAssetExportSession(
            asset: boxed.asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else { return nil }

        do {
            try await session.export(to: destination, as: .mov)
            return destination
        } catch {
            AppLogger.localMedia.error(
                "Photos video export failed for \(identifier, privacy: .private(mask: .hash)): \(error.localizedDescription) (\(error.logCode, privacy: .public))"
            )
            return nil
        }
    }

    /// Dimensions without decoding anything.
    nonisolated func pixelSize(for assetURL: URL) -> CGSize? {
        guard let identifier = PhotosAssetURL.localIdentifier(from: assetURL),
              let asset = Self.asset(for: identifier) else { return nil }
        return CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
    }

    /// Drops every exported file. Called from the cache settings section.
    func clear() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    func currentSizeBytes() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }

    // MARK: - Internals

    nonisolated static func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Local identifiers contain slashes and are not safe as filenames.
    private nonisolated func cacheFileName(for identifier: String, extension ext: String) -> String {
        let safe = identifier.replacingOccurrences(of: "/", with: "_")
        return "\(safe).\(ext)"
    }

    private func cachedFileURL(for identifier: String) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        let prefix = identifier.replacingOccurrences(of: "/", with: "_") + "."
        guard let match = entries.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) else {
            return nil
        }
        // Touch for LRU parity with the other disk caches.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: match.path)
        return match
    }

    private func export(identifier: String) async -> URL? {
        guard let asset = Self.asset(for: identifier) else {
            AppLogger.localMedia.error("Photos asset no longer resolves: \(identifier, privacy: .private(mask: .hash))")
            return nil
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // fetch from iCloud Photos if needed
        options.deliveryMode = .highQualityFormat
        options.version = .current              // honour user edits, not the original
        options.isSynchronous = false

        let payload: (data: Data, uti: String?)? = await withCheckedContinuation { continuation in
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (data, uti))
            }
        }

        guard let payload else {
            AppLogger.localMedia.error("Photos export produced no data: \(identifier, privacy: .private(mask: .hash))")
            return nil
        }

        let ext = Self.fileExtension(forUTI: payload.uti)
        let destination = cacheDirectory.appendingPathComponent(
            cacheFileName(for: identifier, extension: ext)
        )

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try payload.data.write(to: destination, options: .atomic)
            var mutable = cacheDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
            return destination
        } catch {
            AppLogger.localMedia.error(
                "Photos export failed to write \(identifier, privacy: .private(mask: .hash)): \(error.localizedDescription) (\(error.logCode, privacy: .public))"
            )
            return nil
        }
    }

    private nonisolated static func fileExtension(forUTI uti: String?) -> String {
        switch uti {
        case "public.png":                return "png"
        case "public.heic", "public.heif": return "heic"
        case "com.compuserve.gif":        return "gif"
        case "public.tiff":               return "tiff"
        case "org.webmproject.webp":      return "webp"
        default:                           return "jpg"
        }
    }
}

/// Carries a non-Sendable `AVAsset` across a continuation boundary. Only one
/// task ever holds it, so the unchecked conformance states a real invariant.
private struct SendableAVAsset: @unchecked Sendable {
    let asset: AVAsset
}

/// One-shot guard for a continuation resumed from a multi-callback API.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True exactly once, for the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
