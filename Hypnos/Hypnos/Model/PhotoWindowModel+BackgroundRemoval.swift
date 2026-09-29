/*
 Hypnos - Photo Window Model: Background Removal

 Extension for background removal pipeline: toggle, full-resolution processing,
 cache loading, resolution reloading, and state management.
 */

import DebugTrace
import Foundation
import ImageIO
import Metal
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

extension PhotoWindowModel {

    // MARK: - Background Removal

    /// Decode the full-resolution source image for the Vision background-removal
    /// pass. Routes through `CGImageSource` (full-quality decode) rather than
    /// `UIImage(data:)`, which silently fails or degrades on certain codecs —
    /// notably JXL — for the same reason `MetalImageRenderer` avoids it. Falls
    /// back to `UIImage(data:)` only if the CGImageSource path can't produce an
    /// image, preserving prior behavior for formats it handled.
    func fullResolutionImageForBackgroundRemoval() -> UIImage? {
        guard let imageData = currentImageData else { return nil }
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil) {
            // kCGImageSourceCreateThumbnailWithTransform is deliberately absent:
            // it only affects the thumbnail API, so passing it to
            // CGImageSourceCreateImageAtIndex did nothing and left the decode
            // unrotated — while the UIImage(data:) fallback below DOES apply
            // orientation, so this returned differently oriented images
            // depending on which branch happened to succeed.
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: MetalImageRenderer.applyingOrientation(to: cgImage, from: source))
            }
        }
        return UIImage(data: imageData)
    }

    /// Toggle background removal: original -> remove, removing -> cancel, removed -> restore.
    func toggleBackgroundRemoval() async {
        recordInteraction()
        switch backgroundRemovalState {
        case .original:
            // Background removal is mutually exclusive with diorama and the
            // RealityKit 3D modes — they target different display pipelines
            // and mixing them produces a broken composite. Exit them first
            // before activating bg removal.
            if isDioramaMode {
                await setDioramaMode(false)
            }
            if is3DMode || desiredViewingMode != .mono {
                await switchToViewingMode(.mono)
            }
            // First check in-memory cache
            if let cached = backgroundRemovedTexture {
                originalDisplayTexture = displayTexture
                // Display the appropriate variant based on current auto-enhance state
                let showEnhanced = currentAdjustments.isAutoEnhanced
                let displayTex = showEnhanced ? (autoEnhancedBackgroundRemovedTexture ?? cached) : cached
                displayTexture = displayTex
                imageAspectRatio = CGFloat(displayTex.width) / CGFloat(displayTex.height)
                backgroundRemovalState = .removed
            } else {
                // Then check persistent cache (full-res version)
                if let cachedData = await BackgroundRemovalCache.shared.loadData(for: imageURL),
                   let cachedImage = UIImage(data: cachedData) {
                    // Downscale the full-res cached version for display
                    await applyDownscaledCachedBackgroundRemoval(cachedImage)
                } else {
                    // No cache, process the full-resolution image
                    await performFullResolutionBackgroundRemoval(isAutoDuringLoad: false)
                }
            }
        case .removing:
            backgroundRemovalTask?.cancel()
            backgroundRemovalTask = nil
            backgroundRemovalState = .original
            await trackViewingMode(currentAdjustments.isAutoEnhanced ? .autoEnhanced : .mono)
        case .removed:
            restoreOriginalBackground()
        }
    }

    /// Process background removal on the full-resolution image.
    /// Always uses the original image data for stable edge detection (not auto-enhanced).
    /// When auto-enhance is active, produces both regular and auto-enhanced variants
    /// using a single Vision pass (shared foreground mask). Otherwise only produces the regular variant.
    func performFullResolutionBackgroundRemoval(isAutoDuringLoad: Bool) async {
        // Always use original image data for stable edge detection. Decode via
        // CGImageSource so JXL (and other codecs UIImage(data:) mishandles)
        // restore correctly when the cached result is gone (e.g. reinstall).
        guard let fullResImage = fullResolutionImageForBackgroundRemoval() else {
            AppLogger.photoWindow.warning("No image data available for full-resolution background removal")
            return
        }

        backgroundRemovalState = .removing
        let showEnhanced = currentAdjustments.isAutoEnhanced

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let regular: UIImage?
                let autoEnhanced: UIImage?

                if showEnhanced {
                    // Generate both variants in one Vision pass (shared mask)
                    let result = try await BackgroundRemover.shared.removeBackgroundWithAutoEnhance(from: fullResImage)
                    regular = result.regular
                    autoEnhanced = result.autoEnhanced
                } else {
                    // Only generate the regular variant
                    regular = try await BackgroundRemover.shared.removeBackground(from: fullResImage)
                    autoEnhanced = nil
                }

                guard !Task.isCancelled else {
                    self.backgroundRemovalState = .original
                    return
                }

                if let regular {
                    // Cache variant(s)
                    await BackgroundRemovalCache.shared.saveImage(regular, for: self.imageURL)
                    if let autoEnhanced {
                        await BackgroundRemovalCache.shared.saveImage(autoEnhanced, for: self.imageURL, isAutoEnhanced: true)
                    }

                    // Downscale and upload to GPU texture(s). Keep the
                    // transparent margins — the bg-removed output is a
                    // full-frame canvas; cropping here would shrink it.
                    let regularTexture = await self.downscaleAndUploadTexture(regular, autoCropTransparentEdges: false)
                    self.backgroundRemovedTexture = regularTexture

                    if let autoEnhanced {
                        let enhancedTexture = await self.downscaleAndUploadTexture(autoEnhanced, autoCropTransparentEdges: false)
                        self.autoEnhancedBackgroundRemovedTexture = enhancedTexture
                    }

                    self.originalDisplayTexture = self.displayTexture

                    // Display the appropriate variant
                    let displayTex = showEnhanced ? (self.autoEnhancedBackgroundRemovedTexture ?? regularTexture) : regularTexture
                    self.displayTexture = displayTex
                    if let displayTex {
                        self.imageAspectRatio = CGFloat(displayTex.width) / CGFloat(displayTex.height)
                    }
                    self.backgroundRemovalState = .removed

                    await self.trackViewingMode(showEnhanced ? .backgroundRemovedAutoEnhanced : .backgroundRemoved)
                } else {
                    self.backgroundRemovalState = .original
                    AppLogger.photoWindow.warning("Background removal returned nil")
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.photoWindow.error("Background removal failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                    self.backgroundRemovalState = .original
                }
            }
        }
        backgroundRemovalTask = task
        await task.value
        backgroundRemovalTask = nil
        isLoadingDetailImage = false
    }

    /// Apply a downscaled version of a cached background-removed image.
    /// Only loads the auto-enhanced variant when auto-enhance is currently active.
    func applyDownscaledCachedBackgroundRemoval(_ fullResImage: UIImage) async {
        backgroundRemovalState = .removing

        let showEnhanced = currentAdjustments.isAutoEnhanced

        // Only load the auto-enhanced variant from cache when auto-enhance is active
        let enhancedImage: UIImage?
        if showEnhanced, let enhancedData = await BackgroundRemovalCache.shared.loadData(for: imageURL, isAutoEnhanced: true) {
            enhancedImage = UIImage(data: enhancedData)
        } else {
            enhancedImage = nil
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            // Downscale and upload regular variant. Preserve transparent
            // margins — the cached bg-removed image is a full-source-frame
            // canvas and cropping would collapse it to the subject bbox.
            let texture = await self.downscaleAndUploadTexture(fullResImage, autoCropTransparentEdges: false)

            guard !Task.isCancelled else {
                self.backgroundRemovalState = .original
                return
            }

            self.backgroundRemovedTexture = texture

            // Upload auto-enhanced variant only when needed
            if let enhancedImage {
                self.autoEnhancedBackgroundRemovedTexture = await self.downscaleAndUploadTexture(enhancedImage, autoCropTransparentEdges: false)
            }

            self.originalDisplayTexture = self.displayTexture

            // Display the appropriate variant based on current auto-enhance state
            let displayTex = showEnhanced ? (self.autoEnhancedBackgroundRemovedTexture ?? texture) : texture
            self.displayTexture = displayTex
            if let displayTex {
                self.imageAspectRatio = CGFloat(displayTex.width) / CGFloat(displayTex.height)
            }
            self.backgroundRemovalState = .removed

            await self.trackViewingMode(showEnhanced ? .backgroundRemovedAutoEnhanced : .backgroundRemoved)
        }
        backgroundRemovalTask = task
        await task.value
        backgroundRemovalTask = nil
        isLoadingDetailImage = false
    }

    /// Apply a cached background-removed image directly from a file URL.
    /// Uses CGImageSource downsampling → Metal texture upload, bypassing the
    /// intermediate Data → UIImage → downscale → texture pipeline for faster restore.
    /// Only loads the auto-enhanced variant when auto-enhance is currently active.
    func applyCachedBackgroundRemovalFromURL(_ cachedURL: URL) async {
        backgroundRemovalState = .removing

        let showEnhanced = currentAdjustments.isAutoEnhanced
        let targetDimension = backgroundRemovalTargetDimension()
        let useLossy = appModel.useLossyTextureCompression

        // Load regular variant. Keep transparent margins — the cached bg-removed
        // image is a full-source-frame canvas (see BackgroundRemover); cropping
        // them here re-collapses the frame to the subject bbox and shrinks the
        // window on restore for flat images with a small foreground mask.
        let sendable = await Task.detached { [cachedURL, targetDimension, useLossy] () -> SendableTexture? in
            guard let tex = MetalImageRenderer.shared?.createTexture(from: cachedURL, maxDimension: targetDimension, useLossyCompression: useLossy, autoCropTransparentEdges: false) else { return nil }
            return SendableTexture(texture: tex)
        }.value

        guard let texture = sendable?.texture else {
            backgroundRemovalState = .original
            isLoadingDetailImage = false
            return
        }

        backgroundRemovedTexture = texture

        // Only load the auto-enhanced variant when auto-enhance is active
        if showEnhanced, let enhancedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL, isAutoEnhanced: true) {
            let enhancedSendable = await Task.detached { [enhancedURL, targetDimension, useLossy] () -> SendableTexture? in
                guard let tex = MetalImageRenderer.shared?.createTexture(from: enhancedURL, maxDimension: targetDimension, useLossyCompression: useLossy, autoCropTransparentEdges: false) else { return nil }
                return SendableTexture(texture: tex)
            }.value
            autoEnhancedBackgroundRemovedTexture = enhancedSendable?.texture
        }

        originalDisplayTexture = displayTexture

        // Display the appropriate variant based on current auto-enhance state
        let displayTex = showEnhanced ? (autoEnhancedBackgroundRemovedTexture ?? texture) : texture
        displayTexture = displayTex
        imageAspectRatio = CGFloat(displayTex.width) / CGFloat(displayTex.height)
        backgroundRemovalState = .removed
        isLoadingDetailImage = false

        await trackViewingMode(showEnhanced ? .backgroundRemovedAutoEnhanced : .backgroundRemoved)
    }

    /// Reload the background-removed image at the current effective resolution.
    /// Fetches the correct variant (regular or auto-enhanced) from disk cache.
    func reloadBackgroundRemovedAtCurrentResolution() async {
        guard backgroundRemovalState == .removed else { return }

        let showEnhanced = currentAdjustments.isAutoEnhanced
        // Try the enhanced variant first if auto-enhance is active, fall back to regular
        var cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL, isAutoEnhanced: showEnhanced)
        if cachedURL == nil && showEnhanced {
            cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL)
        }
        guard let cachedURL else {
            AppLogger.photoWindow.warning("Cannot reload background-removed image: no cached file")
            return
        }

        let targetDimension = backgroundRemovalTargetDimension()
        let useLossy = appModel.useLossyTextureCompression
        let sendable = await Task.detached { [cachedURL, targetDimension, useLossy] () -> SendableTexture? in
            guard let tex = MetalImageRenderer.shared?.createTexture(from: cachedURL, maxDimension: targetDimension, useLossyCompression: useLossy, autoCropTransparentEdges: false) else { return nil }
            return SendableTexture(texture: tex)
        }.value

        guard let texture = sendable?.texture else { return }
        if showEnhanced {
            autoEnhancedBackgroundRemovedTexture = texture
        } else {
            backgroundRemovedTexture = texture
        }
        displayTexture = texture
        imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
    }

    func restoreOriginalBackground() {
        backgroundRemovalState = .original
        autoEnhancedBackgroundRemovedTexture = nil
        Task {
            await trackViewingMode(currentAdjustments.isAutoEnhanced ? .autoEnhanced : .mono)
        }

        if currentAdjustments.isAutoEnhanced {
            // Auto-enhance is still active — restore to the auto-enhanced (non-bg-removed) texture
            if let enhanced = autoEnhancedDisplayTexture {
                displayTexture = enhanced
                imageAspectRatio = CGFloat(enhanced.width) / CGFloat(enhanced.height)
            } else if let original = originalDisplayTexture {
                // originalDisplayTexture may already be the auto-enhanced version
                // (if auto-enhance was active when bg removal was toggled on)
                displayTexture = original
                imageAspectRatio = CGFloat(original.width) / CGFloat(original.height)
            } else {
                displayTexture = nil
                if let windowSize = lastWindowSize {
                    isLoadingDetailImage = true
                    Task { await loadDisplayImage(for: windowSize) }
                }
            }
        } else if let original = originalDisplayTexture {
            displayTexture = original
            imageAspectRatio = CGFloat(original.width) / CGFloat(original.height)
        } else {
            // Auto-restore case: originalDisplayTexture was nil because displayTexture hadn't loaded yet
            // when background removal ran. Clear displayTexture so PhotoDisplayView triggers a fresh load.
            displayTexture = nil
            if let windowSize = lastWindowSize {
                isLoadingDetailImage = true
                Task { await loadDisplayImage(for: windowSize) }
            }
        }
    }

    func clearBackgroundRemovalState() {
        backgroundRemovalTask?.cancel()
        backgroundRemovalTask = nil
        backgroundRemovalState = .original
        originalDisplayTexture = nil
        backgroundRemovedTexture = nil
        autoEnhancedBackgroundRemovedTexture = nil
    }
}
