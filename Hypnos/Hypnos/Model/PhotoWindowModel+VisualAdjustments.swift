/*
 Hypnos - Photo Window Model: Visual Adjustments

 Extension for auto-enhance, brightness/contrast/saturation adjustments,
 and 3D adjustment preview system.
 */

import CoreImage
import DebugTrace
import ImageIO
import Metal
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    // MARK: - Visual Adjustment Methods

    /// Apply visual adjustments and persist to tracker.
    func applyAdjustments(_ adjustments: VisualAdjustments) {
        recordInteraction()
        currentAdjustments = adjustments
        Task { await trackAdjustments() }
    }

    /// Reset current per-image adjustments to defaults.
    func resetCurrentAdjustments() {
        recordInteraction()
        currentAdjustments = VisualAdjustments()
        if backgroundRemovalState == .removed {
            // Swap to regular bg-removed texture (auto-enhance is now off)
            if let regular = backgroundRemovedTexture {
                displayTexture = regular
                imageAspectRatio = CGFloat(regular.width) / CGFloat(regular.height)
            }
        } else if autoEnhancedDisplayTexture != nil {
            // Restore the non-enhanced display image
            autoEnhancedDisplayTexture = nil
            currentDisplayMaxDimension = 0
            if !is3DMode, !isAnimatedImage, let windowSize = lastWindowSize {
                Task { await loadDisplayImage(for: windowSize) }
            }
        }
        Task { await trackAdjustments() }
    }

    /// Toggle auto-enhance: applies CIImage auto-adjustment filters to generate
    /// an enhanced base image. Manual sliders (brightness/contrast/saturation) are
    /// applied as SwiftUI view modifiers on top of this base.
    /// When background removal is active, swaps between regular and auto-enhanced
    /// bg-removed variants instead of running the standard auto-enhance pipeline.
    func toggleAutoEnhance() async {
        recordInteraction()
        guard !isProcessingAutoEnhance else { return }

        // Special handling when background removal is active: swap between bg-removed variants
        if backgroundRemovalState == .removed {
            if currentAdjustments.isAutoEnhanced {
                // Turn off: swap to regular bg-removed texture
                if let regular = backgroundRemovedTexture {
                    displayTexture = regular
                    imageAspectRatio = CGFloat(regular.width) / CGFloat(regular.height)
                }
                currentAdjustments.isAutoEnhanced = false
                await trackAutoEnhanceState()
            } else {
                // Turn on: swap to auto-enhanced bg-removed texture
                if let enhanced = autoEnhancedBackgroundRemovedTexture {
                    // In-memory cache hit
                    displayTexture = enhanced
                    imageAspectRatio = CGFloat(enhanced.width) / CGFloat(enhanced.height)
                    currentAdjustments.isAutoEnhanced = true
                    await trackAutoEnhanceState()
                } else if let enhancedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL, isAutoEnhanced: true) {
                    // Disk cache hit — load and upload to GPU
                    isProcessingAutoEnhance = true
                    let targetDimension = backgroundRemovalTargetDimension()
                    let useLossy = appModel.useLossyTextureCompression
                    let sendable = await Task.detached { [enhancedURL, targetDimension, useLossy] () -> SendableTexture? in
                        guard let tex = MetalImageRenderer.shared?.createTexture(from: enhancedURL, maxDimension: targetDimension, useLossyCompression: useLossy) else { return nil }
                        return SendableTexture(texture: tex)
                    }.value
                    if let texture = sendable?.texture {
                        autoEnhancedBackgroundRemovedTexture = texture
                        displayTexture = texture
                        imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
                        currentAdjustments.isAutoEnhanced = true
                        await trackAutoEnhanceState()
                    }
                    isProcessingAutoEnhance = false
                } else {
                    // No cached enhanced variant (e.g. bg removal ran before this feature).
                    // Generate on-demand from the regular bg-removed cache.
                    await generateEnhancedBgRemovedVariant()
                }
            }

            // In 3D mode, reload the component with adjusted pixels
            reloadImagePresentationWithAdjustments()
            return
        }

        if currentAdjustments.isAutoEnhanced {
            // Turn off: restore original display image
            restoreFromAutoEnhance()
        } else {
            // Turn on: 3-tier cache lookup (in-memory → disk → on-demand)
            if let cached = autoEnhancedDisplayTexture {
                // Tier 1: in-memory (instant toggle-back)
                preAutoEnhanceDisplayTexture = displayTexture
                displayTexture = cached
                imageAspectRatio = CGFloat(cached.width) / CGFloat(cached.height)
                currentAdjustments.isAutoEnhanced = true
                await trackAutoEnhanceState()
            } else if let cachedData = await AutoEnhanceCache.shared.loadData(for: imageURL),
                      let cachedImage = UIImage(data: cachedData) {
                // Tier 2: persistent disk cache
                await applyDownscaledAutoEnhance(cachedImage)
            } else {
                // Tier 3: process from raw data and cache
                await performFullResolutionAutoEnhance()
            }
        }

        // In 3D mode, reload the component with adjusted pixels
        reloadImagePresentationWithAdjustments()
    }

    /// Apply auto-enhance from a full-resolution cached image (downscale for display).
    func applyDownscaledAutoEnhance(_ fullResImage: UIImage) async {
        isProcessingAutoEnhance = true

        let texture = await downscaleAndUploadTexture(fullResImage)

        autoEnhancedDisplayTexture = texture
        preAutoEnhanceDisplayTexture = displayTexture
        if !is3DMode, !isAnimatedImage, let texture {
            displayTexture = texture
            let w = CGFloat(texture.width)
            let h = CGFloat(texture.height)
            imageAspectRatio = w / h
        }
        currentAdjustments.isAutoEnhanced = true
        isProcessingAutoEnhance = false
        isLoadingDetailImage = false

        await trackAutoEnhanceState()
    }

    /// Generate the auto-enhanced bg-removed variant on-demand when it doesn't
    /// exist in cache (e.g. bg removal ran before this feature was added).
    func generateEnhancedBgRemovedVariant() async {
        // Load regular bg-removed image from disk cache
        guard let regularData = await BackgroundRemovalCache.shared.loadData(for: imageURL),
              let regularImage = UIImage(data: regularData),
              let cgImage = regularImage.cgImage else {
            AppLogger.photoWindow.warning("Cannot generate enhanced bg-removed variant: no cached regular image")
            return
        }

        isProcessingAutoEnhance = true

        let enhanced = await Task.detached { () -> UIImage? in
            let ciImage = CIImage(cgImage: cgImage)
            let result = Self.applyAutoAdjustmentFilters(to: ciImage)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let outputCG = context.createCGImage(result, from: result.extent) else { return nil }
            return UIImage(cgImage: outputCG, scale: regularImage.scale, orientation: regularImage.imageOrientation)
        }.value

        guard let enhanced else {
            isProcessingAutoEnhance = false
            return
        }

        // Cache the enhanced variant to disk
        await BackgroundRemovalCache.shared.saveImage(enhanced, for: imageURL, isAutoEnhanced: true)

        // Downscale and upload to GPU texture
        let texture = await downscaleAndUploadTexture(enhanced)
        autoEnhancedBackgroundRemovedTexture = texture

        if let texture {
            displayTexture = texture
            imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
        }
        currentAdjustments.isAutoEnhanced = true
        isProcessingAutoEnhance = false

        await trackAutoEnhanceState()
    }

    /// Process auto-enhancement from raw image data, cache result, and apply.
    func performFullResolutionAutoEnhance() async {
        guard let imageData = currentImageData,
              let ciImage = CIImage(data: imageData) else {
            return
        }

        isProcessingAutoEnhance = true

        let enhanced = await Task.detached { () -> UIImage? in
            let result = Self.applyAutoAdjustmentFilters(to: ciImage)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let cgImage = context.createCGImage(result, from: result.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value

        guard let enhanced else {
            isProcessingAutoEnhance = false
            isLoadingDetailImage = false
            return
        }

        // Cache full-resolution result to disk
        await AutoEnhanceCache.shared.saveImage(enhanced, for: imageURL)

        // Downscale and upload to GPU texture
        let texture = await downscaleAndUploadTexture(enhanced)

        autoEnhancedDisplayTexture = texture
        preAutoEnhanceDisplayTexture = displayTexture
        if !is3DMode, !isAnimatedImage, let texture {
            displayTexture = texture
            let w = CGFloat(texture.width)
            let h = CGFloat(texture.height)
            imageAspectRatio = w / h
        }
        currentAdjustments.isAutoEnhanced = true
        isProcessingAutoEnhance = false
        isLoadingDetailImage = false

        await trackAutoEnhanceState()
    }

    /// Restore the original (non-enhanced) display image.
    func restoreFromAutoEnhance() {
        currentAdjustments.isAutoEnhanced = false
        if let original = preAutoEnhanceDisplayTexture {
            displayTexture = original
            let w = CGFloat(original.width)
            let h = CGFloat(original.height)
            imageAspectRatio = w / h
        } else {
            // Edge case: no original stored (e.g. auto-restored on open)
            displayTexture = nil
            if let windowSize = lastWindowSize {
                isLoadingDetailImage = true
                Task { await loadDisplayImage(for: windowSize) }
            }
        }
        Task { await trackAutoEnhanceState() }
    }

    /// Persist auto-enhance state via viewing mode and adjustments trackers.
    func trackAutoEnhanceState() async {
        if backgroundRemovalState == .removed {
            if currentAdjustments.isAutoEnhanced {
                await trackViewingMode(.backgroundRemovedAutoEnhanced)
            } else {
                await trackViewingMode(.backgroundRemoved)
            }
        } else {
            if currentAdjustments.isAutoEnhanced {
                await trackViewingMode(.autoEnhanced)
            } else {
                await trackViewingMode(.mono)
            }
        }
        await trackAdjustments()
    }

    /// Reload auto-enhanced image at the current effective resolution (for window resize).
    func reloadAutoEnhancedAtCurrentResolution() async {
        guard currentAdjustments.isAutoEnhanced else { return }

        guard let cachedData = await AutoEnhanceCache.shared.loadData(for: imageURL),
              let fullResImage = UIImage(data: cachedData) else {
            AppLogger.photoWindow.warning("Cannot reload auto-enhanced image: no cached data")
            return
        }

        let texture = await downscaleAndUploadTexture(fullResImage)
        autoEnhancedDisplayTexture = texture
        displayTexture = texture
        if let texture {
            imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
        }
    }

    func clearAutoEnhanceState() {
        autoEnhancedDisplayTexture = nil
        preAutoEnhanceDisplayTexture = nil
        isProcessingAutoEnhance = false
    }

    // MARK: - 3D Adjustment Preview Pre-warm

    /// Pre-load a low-res thumbnail into `displayImage` while the
    /// adjustments popover is opening, before the user moves a slider.
    /// `reloadImagePresentationWithAdjustments` then has a populated
    /// fallback ready and can flip is3DMode synchronously on the first
    /// slider tick — without this, the async thumbnail load got starved
    /// of MainActor time during continuous slider drag and the live 2D
    /// preview only appeared after the user paused. No-op when 3D mode
    /// isn't active or the fallback is already set.
    func prewarmAdjustmentPreview() async {
        guard is3DMode, !isShowingAdjustmentPreview, displayImage == nil else { return }
        let url = imageURL
        let inMemory = currentImageData

        let sourceData: Data?
        if let inMemory {
            sourceData = inMemory
        } else if let sourceURL = await resolveSourceFileURL() {
            sourceData = try? Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } else {
            sourceData = nil
        }

        let thumbnail: UIImage?
        if let cached = await ThumbnailCache.shared.loadThumbnail(for: url) {
            thumbnail = cached
        } else if let sourceData {
            thumbnail = await Task.detached {
                guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else { return nil as UIImage? }
                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 400,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: cgImage)
            }.value
        } else {
            thumbnail = nil
        }

        // Bail if the user closed the popover or moved into 2D preview
        // while we were loading.
        guard is3DMode, !isShowingAdjustmentPreview else { return }
        displayImage = thumbnail
    }

    /// Drop the pre-warmed thumbnail when the popover closes without
    /// ever transitioning into the 2D preview phase. Once
    /// `isShowingAdjustmentPreview` has gone true the displayImage is
    /// owned by the regen path; don't touch it.
    func clearAdjustmentPreviewIfUnused() {
        guard is3DMode, !isShowingAdjustmentPreview else { return }
        displayImage = nil
    }

    // MARK: - 3D Adjustment Preview

    /// Reload the ImagePresentationComponent with visual adjustments applied via CIFilter.
    /// Called when adjustments change while in 3D mode. Switches to the lightweight 2D
    /// SwiftUI Image branch with a thumbnail so SwiftUI modifiers provide instant feedback.
    /// The expensive 3D recalculation runs after sliders settle for 2 seconds.
    func reloadImagePresentationWithAdjustments() {
        guard is3DMode || isShowingAdjustmentPreview else { return }

        // Opacity (and sharpen) don't get baked into the Spatial3DImage —
        // composition / shader time handles them on top of the rendered
        // RealityKit output. Skip the 2D-preview-then-regenerate dance
        // when nothing bake-relevant changed since the last commit so
        // dragging the opacity slider doesn't rebuild the depth map.
        let currentEffective = effectiveAdjustments
        if let lastBaked = lastBakedAdjustments,
           lastBaked.bakeRelevantEquals(currentEffective),
           !isShowingAdjustmentPreview {
            return
        }

        // Switch from 3D to 2D preview mode on first call.
        // This sets is3DMode = false so PhotoDisplayView renders the SwiftUI Image branch
        // (which already has .brightness/.contrast/.saturation modifiers) at the correct
        // window depth, avoiding z-fighting with ornaments.
        if !isShowingAdjustmentPreview {
            prePreviewSpatial3DState = spatial3DImageState
            isShowingAdjustmentPreview = true

            // Fast path: the popover-open prewarm has already populated
            // displayImage with a thumbnail. Flip into 2D mode
            // synchronously on this actor tick so the live preview
            // shows immediately — no async Task to be starved by the
            // continuous-drag MainActor traffic. The debounce + regen
            // setup below this block still runs.
            if displayImage != nil {
                // Flip to the 2D preview branch immediately for instant
                // feedback, but defer the component teardown until any
                // in-flight generate() has settled — destroying the
                // component mid-generation crashes in RealityKit's internal
                // progress callback. Rapid successive adjustments hit this:
                // the previous regen's generation is still running when the
                // next slider change re-enters the preview.
                is3DMode = false
                adjustmentPreviewTeardownTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.settleActiveGeneration()
                    guard self.isShowingAdjustmentPreview else { return }
                    self.contentEntity.components.remove(ImagePresentationComponent.self)
                    self.spatial3DImage = nil
                    self.spatial3DImageState = .notGenerated
                }
            } else {

            // Stage the preview thumbnail *before* flipping is3DMode so
            // the 2D branch has something to render the instant the
            // RealityView disappears — otherwise displayImage stays nil
            // for the duration of the thumbnail load and the window goes
            // blank, which is what the user sees on the first slider
            // change against a 3D image that hasn't been viewed in 2D
            // yet (no displayTexture on hand).
            let url = imageURL
            let imageData = currentImageData
            adjustmentPreviewTeardownTask = Task { @MainActor [weak self] in
                guard let self, self.isShowingAdjustmentPreview else { return }

                // Resolve a byte source for the thumbnail. Entering 3D
                // mode clears `currentImageData` to free CPU memory, so
                // mid-3D adjustment changes can't rely on the in-memory
                // path — fall back to the disk-cached source file the
                // same way the regen task below does. Without this
                // fallback the preview branch ended up with a nil
                // thumbnail and the window went blank for the duration
                // of the 2D preview phase.
                let sourceData: Data?
                if let inMemory = imageData {
                    sourceData = inMemory
                } else if let sourceURL = await self.resolveSourceFileURL() {
                    sourceData = try? Data(contentsOf: sourceURL, options: .mappedIfSafe)
                } else {
                    sourceData = nil
                }

                let thumbnail: UIImage?
                if let cached = await ThumbnailCache.shared.loadThumbnail(for: url) {
                    thumbnail = cached
                } else if let sourceData {
                    thumbnail = await Task.detached {
                        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else { return nil as UIImage? }
                        let options: [CFString: Any] = [
                            kCGImageSourceThumbnailMaxPixelSize: 400,
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil as UIImage? }
                        return UIImage(cgImage: cgImage)
                    }.value
                } else {
                    thumbnail = nil
                }

                guard self.isShowingAdjustmentPreview else { return }

                // Wait for any in-flight generate() before removing the
                // component below — removal mid-generation crashes in
                // RealityKit's progress callback.
                await self.settleActiveGeneration()
                guard self.isShowingAdjustmentPreview else { return }

                // Commit the transition atomically: 2D thumbnail in
                // place first, then tear down RealityKit and flip the
                // mode so PhotoDisplayView re-evaluates with the
                // fallback already populated.
                self.displayImage = thumbnail
                self.contentEntity.components.remove(ImagePresentationComponent.self)
                self.spatial3DImage = nil
                self.spatial3DImageState = .notGenerated
                self.is3DMode = false
            }
            } // close else (no pre-warmed thumbnail)
        }

        // Cancel any pending 3D reload and start a new debounce
        adjustments3DReloadTask?.cancel()
        adjustments3DReloadTask = Task { @MainActor [weak self] in
            // Wait for sliders to settle before the expensive 3D
            // recalculation. 0.5s is short enough to feel responsive
            // after the user lets go of a slider but long enough that
            // a continuous drag still coalesces into one regen.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.isShowingAdjustmentPreview else { return }

            // Wait for the preview-entry teardown (which itself waits out any
            // in-flight generate()) so the old component is fully released
            // before a replacement is installed — components.set() destroys
            // the old component just like removal and crashes mid-generation.
            if let teardown = self.adjustmentPreviewTeardownTask {
                await teardown.value
                self.adjustmentPreviewTeardownTask = nil
            }
            await self.settleActiveGeneration()
            guard !Task.isCancelled, self.isShowingAdjustmentPreview else { return }

            let adj = self.effectiveAdjustments
            let isIdentity = !adj.isModified || (!adj.isAutoEnhanced && adj.brightness == 0.0 && adj.contrast == 1.0 && adj.saturation == 1.0)

            if !isIdentity {
                // Pre-create the adjusted ImagePresentationComponent BEFORE switching
                // back to 3D mode, so the RealityView init finds it already set on the
                // entity and doesn't race with a second creation.
                //
                // Entering 3D mode releases `currentImageData` to free CPU
                // memory (see PhotoWindowModel+Spatial3D.swift). The regen
                // path needs the raw bytes to feed CIFilter, so reload
                // from the disk-cached file if the in-memory copy is gone.
                // Without this fallback, every adjustment in 3D mode falls
                // through to the RealityView's else branch which generates
                // a fresh Spatial3DImage from the original source URL —
                // wiping the adjustments and making further edits no-ops.
                let imageData: Data?
                if let cached = self.currentImageData {
                    imageData = cached
                } else if let sourceURL = await self.resolveSourceFileURL() {
                    imageData = try? Data(contentsOf: sourceURL, options: .mappedIfSafe)
                } else {
                    imageData = nil
                }
                guard let imageData, let ciImage = CIImage(data: imageData) else {
                    AppLogger.visualAdjustments.warning("No image data available for 3D adjustment reload")
                    return
                }

                let adjustedData = await Task.detached { () -> Data? in
                    var result = ciImage

                    if adj.isAutoEnhanced {
                        result = Self.applyAutoAdjustmentFilters(to: result)
                    }

                    // CIColorControls contrast is much more aggressive than SwiftUI's
                    // .contrast() modifier. Empirically: SwiftUI 2.00 ≈ CIFilter 1.12,
                    // SwiftUI 1.61 ≈ CIFilter 1.07. Remap by scaling the deviation from 1.0.
                    let remappedContrast = 1.0 + (adj.contrast - 1.0) * 0.12

                    let colorControls = CIFilter(name: "CIColorControls")!
                    colorControls.setValue(result, forKey: kCIInputImageKey)
                    colorControls.setValue(adj.brightness, forKey: kCIInputBrightnessKey)
                    colorControls.setValue(remappedContrast, forKey: kCIInputContrastKey)
                    colorControls.setValue(adj.saturation, forKey: kCIInputSaturationKey)
                    if let output = colorControls.outputImage { result = output }

                    let context = CIContext(options: [.useSoftwareRenderer: false])
                    guard let cgImage = context.createCGImage(result, from: result.extent) else { return nil }
                    return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
                }.value

                guard !Task.isCancelled, let adjustedData,
                      let imageSource = CGImageSourceCreateWithData(adjustedData as CFData, nil) else {
                    AppLogger.visualAdjustments.warning("Failed to create adjusted image for 3D reload")
                    return
                }

                do {
                    self.spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(imageSource: imageSource)
                    guard let spatial3DImage = self.spatial3DImage else { return }
                    let ipc = ImagePresentationComponent(spatial3DImage: spatial3DImage)
                    self.contentEntity.components.set(ipc)
                    if let aspectRatio = ipc.aspectRatio(for: .mono) {
                        self.imageAspectRatio = CGFloat(aspectRatio)
                    }
                    self.updateExperimentalSpatial3DTuning()
                } catch {
                    AppLogger.visualAdjustments.error("Failed to reload ImagePresentationComponent: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                    return
                }
            }

            // Determine whether to re-generate 3D after restoring the component.
            // .generating counts too: entering the preview mid-generation
            // cancels that generation, but the user clearly wanted 3D.
            let shouldRegenerate3D = self.prePreviewSpatial3DState == .generated
                || self.prePreviewSpatial3DState == .generating

            // Switch back to 3D mode — RealityView will be recreated.
            // For identity adjustments, the RealityView init calls createImagePresentationComponent().
            // For non-identity, the component is already set on contentEntity above.
            self.displayTexture = nil
            self.displayImage = nil
            self.isShowingAdjustmentPreview = false
            self.is3DMode = true
            self.pendingGenerate3D = shouldRegenerate3D
            // Record what was baked so subsequent opacity-only slider
            // movements short-circuit at the guard in
            // reloadImagePresentationWithAdjustments.
            self.lastBakedAdjustments = self.effectiveAdjustments
        }
    }

    // MARK: - Auto-Adjustment Filters (Deduplicated)

    /// Apply CIImage auto-adjustment filters to produce an enhanced image.
    /// Used by auto-enhance, enhanced bg-removed variant generation, and 3D adjustment reload.
    nonisolated static func applyAutoAdjustmentFilters(to ciImage: CIImage) -> CIImage {
        let filters = ciImage.autoAdjustmentFilters(options: [
            .enhance: true,
            .redEye: false
        ])
        var result = ciImage
        for filter in filters {
            filter.setValue(result, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                result = output
            }
        }
        return result
    }
}
