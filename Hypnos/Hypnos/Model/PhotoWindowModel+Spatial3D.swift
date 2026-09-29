/*
 Hypnos - Photo Window Model: Spatial 3D

 Extension for 3D mode activation/deactivation, ImagePresentationComponent creation,
 spatial 3D generation, viewing mode switching, and resolution override.
 */

import DebugTrace
import Foundation
import ImageIO
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    // MARK: - 3D Auto-Restore Prompt

    /// Show the 3D restore prompt pill and schedule auto-dismissal after a timeout.
    /// Cancels any in-flight dismiss timer. No-op if the window is currently
    /// snapped to a surface — the pill is irrelevant for a wall-mounted view
    /// and would otherwise appear unexpectedly on device reboot, since
    /// restored windows start with `isSnapped == true`.
    func presentAutoRestorePrompt(immersive: Bool) {
        guard PlatformCapabilities.supportsSpatial3D, !isWindowSnapped else { return }

        autoRestoreImmersive = immersive
        showAutoRestorePrompt = true

        autoRestorePromptDismissTask?.cancel()
        autoRestorePromptDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoRestorePromptTimeout))
            guard !Task.isCancelled else { return }
            self?.showAutoRestorePrompt = false
            self?.autoRestorePromptDismissTask = nil
        }
    }

    /// Dismiss the 3D restore prompt immediately and cancel the auto-dismiss timer.
    func dismissAutoRestorePrompt() {
        autoRestorePromptDismissTask?.cancel()
        autoRestorePromptDismissTask = nil
        showAutoRestorePrompt = false
        autoRestoreForAnimated = false
    }

    /// Offer 3D via the pill for animated content, but only where the user's
    /// settings would otherwise have auto-generated 3D for a still image — so
    /// the pill appears exactly in place of the suppressed auto-3D, not on
    /// every animation. "Yes" activates 3D of the first frame explicitly.
    ///
    /// A remembered `.mono` for this image suppresses the offer: that's what
    /// the pill's "Never" writes (and what exiting 3D leaves), so a declined
    /// animation stays declined instead of re-offering on every open.
    func maybeOfferAnimated3DIfNeeded() async {
        guard isAnimatedImage, !isWindowSnapped, !is3DMode else { return }
        // "Never" (and exiting 3D) writes .mono unconditionally, so honor it
        // here regardless of rememberImageEnhancements — a decline must stick.
        if await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL) == .mono {
            return
        }
        let defaultIs3D = appModel.defaultImageViewingMode == .spatial3D
            || appModel.defaultImageViewingMode == .spatial3DImmersive
        var offer = defaultIs3D
        if !offer, appModel.rememberImageEnhancements, appModel.autoRestoreSpatial3D {
            let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
            let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)
            offer = wasConverted && (lastMode == .spatial3D || lastMode == .spatial3DImmersive)
        }
        guard offer else { return }
        autoRestoreForAnimated = true
        presentAutoRestorePrompt(immersive: appModel.defaultImageViewingMode == .spatial3DImmersive)
    }

    // MARK: - Generation Settling

    /// Cancel any in-flight spatial 3D generation and wait for it to actually
    /// finish. RealityKit's generate() ignores Swift cooperative cancellation
    /// and crashes (dangling component dereference in its internal progress
    /// callback) if the ImagePresentationComponent is removed or replaced
    /// while generation is still running — always await this before tearing
    /// down or swapping the component / spatial3DImage.
    func settleActiveGeneration() async {
        guard let task = generateTask else { return }
        task.cancel()
        await task.value
        // A new generation may have started while we were suspended —
        // only clear the reference if it's still the task we settled.
        if generateTask == task { generateTask = nil }
    }

    // MARK: - 3D Mode Activation

    /// Activate RealityKit 3D mode. Loads the full-resolution ImagePresentationComponent
    /// from the disk cache and releases the lightweight 2D display image.
    /// - Parameter generateImmediately: If true, RealityView will generate the 3D depth map
    ///   right after creating the component (used when the user explicitly taps "Generate 3D").
    func activate3DMode(generateImmediately: Bool = false, explicit: Bool = false) {
        // No spatial-3D conversion off visionOS; a remembered 3D mode stays 2D.
        guard PlatformCapabilities.supportsSpatial3D else { return }
        recordInteraction()
        // Auto paths never 3D animated content; an explicit user choice (the
        // pill / ornament) may, rendering the first frame in 3D.
        guard explicit || !isAnimatedImage, !is3DMode else { return }
        if backgroundRemovalState == .removed {
            restoreOriginalBackground()
        }
        clearBackgroundRemovalState()
        if isImageFlipped {
            isImageFlipped = false
            Task { await trackFlipState() }
        }
        is3DMode = true
        isLoadingDetailImage = true
        pendingGenerate3D = generateImmediately
        // RealityView's init closure will call createImagePresentationComponent()
    }

    /// Deactivate 3D mode and return to 2D display.
    /// When useRealityKitDisplay is set, toggles the RealityKit viewing mode back
    /// to mono instead of switching to the lightweight SwiftUI Image display.
    func deactivate3DMode() async {
        recordInteraction()
        guard is3DMode else { return }

        if useRealityKitDisplay {
            // Stay in RealityKit but directly switch viewing mode to mono
            guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
            guard ipc.viewingMode != .mono else { return }
            ipc.desiredViewingMode = .mono
            desiredViewingMode = .mono
            contentEntity.components.set(ipc)
            if let ar = ipc.aspectRatio(for: .mono) { imageAspectRatio = CGFloat(ar) }
            immersiveResizeTrigger += 1
            updateExperimentalSpatial3DTuning()
            await trackViewingMode(.mono)
            return
        }

        // If generation is in progress, we MUST wait for it to finish before
        // removing ImagePresentationComponent.
        await settleActiveGeneration()

        // Release 3D resources — safe now that generate() has completed
        spatial3DImage = nil
        spatial3DImageState = .notGenerated
        pendingGenerate3D = false
        contentEntity.components.remove(ImagePresentationComponent.self)
        is3DMode = false
        desiredViewingMode = .mono  // Reset to mono when exiting 3D entirely
        updateExperimentalSpatial3DTuning()
        isShowingAdjustmentPreview = false
        adjustments3DReloadTask?.cancel()
        lastBakedAdjustments = nil

        // Record that the user explicitly exited 3D so auto-restore doesn't re-enable it
        await trackViewingMode(.mono)

        // Reset display dimension so the 2D reload doesn't early-exit
        currentDisplayMaxDimension = 0

        // Return to the pre-3D display. Animated content has no 2D texture to
        // rebuild — clearing is3DMode alone returns PhotoDisplayView to the
        // animated (<img>/video) path — but createImagePresentationComponent
        // released the raw bytes when entering 3D, so reload them for the
        // raw-GIF / WASM-APNG branches that display from currentImageData.
        if isAnimatedImage {
            if currentImageData == nil {
                currentImageData = try? await ImageLoader.shared.loadRawData(from: imageURL)
            }
            isLoadingDetailImage = false
        } else if let windowSize = lastWindowSize {
            isLoadingDetailImage = true
            await loadDisplayImage(for: windowSize)
        }
    }

    // MARK: - Image Presentation Component

    /// Create the ImagePresentationComponent for the current image (3D mode only).
    /// Loads at full resolution from the disk cache.
    func createImagePresentationComponent() async {
        // If a component was already pre-created (e.g. with baked-in adjustments
        // by reloadImagePresentationWithAdjustments), keep it and skip recreation.
        if contentEntity.components[ImagePresentationComponent.self] != nil {
            inputPlaneEntity = Entity()
            if desiredViewingMode != .spatial3DImmersive {
                desiredViewingMode = .mono
            }
            updateExperimentalSpatial3DTuning()
            displayTexture = nil
            displayImage = nil
            isLoadingDetailImage = false
            return
        }

        // Reset state
        spatial3DImageState = .notGenerated
        spatial3DImage = nil
        contentEntity.components.remove(ImagePresentationComponent.self)
        inputPlaneEntity = Entity()

        // Animated content only reaches here when the user explicitly opted
        // into 3D via the pill (auto paths are guarded, and `is3DMode` is only
        // set for animated through activate3DMode(explicit:)). The first frame
        // is decoded from the source URL below like any still.
        guard !isAnimatedImage || is3DMode else {
            isLoadingDetailImage = false
            return
        }

        isLoadingDetailImage = true

        // Reuse a generated instance handed over by another window (pop-out)
        // instead of decoding and regenerating the same depth scene.
        if let claimed = claimHandoffSpatial3DImage() {
            spatial3DImage = claimed
            isLoadingDetailImage = false
            return
        }

        do {
            // Prefer a local file to avoid network when reopening, and because
            // ImagePresentationComponent and CGImageSource can only open one.
            // Falling back to imageURL preserves the remote-URL path.
            let sourceURL = await Self.localFileURL(for: imageURL) ?? imageURL

            // The spatial 3D source resolution is independent of the 2D display
            // resolution: the 2D cap governs the on-screen MTLTexture, while
            // this cap governs the source fed into RealityKit's Spatial3DImage.
            // 0 = no cap (use native resolution).
            let effectiveRes = effectiveSpatial3DMaxResolution
            if effectiveRes > 0,
               let downsampledData = Self.createDownsampledImageData(from: sourceURL, maxDimension: CGFloat(effectiveRes)),
               let downsampledSource = CGImageSourceCreateWithData(downsampledData as CFData, nil) {
                AppLogger.photoWindow.debug("3D conversion using downsampled source (max \(effectiveRes, privacy: .public)px)")
                spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(imageSource: downsampledSource)
                currentSpatial3DSourceDimension = effectiveRes
            } else {
                spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(contentsOf: sourceURL)
                currentSpatial3DSourceDimension = Int(max(nativeImageDimensions?.width ?? 0, nativeImageDimensions?.height ?? 0))
            }
        } catch {
            AppLogger.photoWindow.error("Unable to initialize spatial 3D image: \(error.localizedDescription) (\(error.logCode, privacy: .public))")

            // Enhanced error handling for network scenarios
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet:
                    AppLogger.photoWindow.error("No internet connection available.")
                case .timedOut:
                    AppLogger.photoWindow.error("Request timed out.")
                case .cannotFindHost:
                    AppLogger.photoWindow.error("Cannot find host.")
                default:
                    AppLogger.photoWindow.error("URL error code: \(urlError.code.rawValue, privacy: .public)")
                }
            }
            // Fall back to 2D rather than stranding the window in `is3DMode`
            // with no ImagePresentationComponent — PhotoDisplayView renders
            // the RealityView branch unconditionally on `is3DMode`, with no
            // failure fallback of its own, so a window left in that state is
            // permanently blank and non-interactive.
            is3DMode = false
            contentEntity.components.remove(ImagePresentationComponent.self)
            recordLoadFailure(loadFailureMessage(for: error), url: imageURL, error: error)
            return
        }

        guard let spatial3DImage else {
            AppLogger.photoWindow.warning("Spatial3DImage is nil.")
            is3DMode = false
            contentEntity.components.remove(ImagePresentationComponent.self)
            recordLoadFailure(
                loadFailureMessage(for: ImageLoaderError.decodeFailed),
                url: imageURL,
                error: ImageLoaderError.decodeFailed
            )
            return
        }

        let imagePresentationComponent = ImagePresentationComponent(spatial3DImage: spatial3DImage)
        contentEntity.components.set(imagePresentationComponent)
        // Initialize to mono unless already targeting immersive (e.g. auto-restore)
        if desiredViewingMode != .spatial3DImmersive {
            desiredViewingMode = .mono
        }
        if let aspectRatio = imagePresentationComponent.aspectRatio(for: .mono) {
            imageAspectRatio = CGFloat(aspectRatio)
        }
        updateExperimentalSpatial3DTuning()
        // Fresh Spatial3DImage from raw bytes — nothing has been baked
        // yet, so the implicit baseline is neutral. Opacity-only slider
        // movements before any other adjustment can short-circuit at the
        // regen guard.
        lastBakedAdjustments = VisualAdjustments()

        // Release CPU-side resources since RealityKit owns the GPU texture now.
        // The raw data can be reloaded from disk cache if needed (e.g. switching
        // back to 2D mode), but keeping it in RAM wastes dirty memory while the
        // GPU texture is resident.
        displayTexture = nil
        displayImage = nil
        currentImageData = nil

        isLoadingDetailImage = false
        // Note: Auto-generation is handled by PhotoWindowView after entity is added to scene
    }

    /// Creates downsampled JPEG data from an image URL for use with RealityKit's Spatial3DImage.
    /// Returns nil if the image is already within the max dimension or downsampling fails,
    /// allowing the caller to fall back to the full-resolution URL-based initializer.
    static func createDownsampledImageData(from url: URL, maxDimension: CGFloat) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        // Check native dimensions — skip downsampling if already within limit
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           max(width, height) <= maxDimension {
            return nil
        }

        // Downsample using CGImageSource thumbnail API (memory-efficient, no full decode)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
    }

    /// Called after the entity is added to the RealityKit scene to auto-generate spatial 3D
    func autoGenerateSpatial3DIfNeeded() async {
        await autoGenerateSpatial3DIfPreviouslyConverted()
    }

    // MARK: - Input Plane

    func ensureInputPlaneReady() {
        guard inputPlaneEntity.components[InputTargetComponent.self] == nil else { return }

        inputPlaneEntity = Entity()
        inputPlaneEntity.components.set(InputTargetComponent())
        inputPlaneEntity.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: SIMD3<Float>(1.0, 1.0, 0.01))],
                mode: .default,
                filter: .default
            )
        )
    }

    // MARK: - 3D Generation

    /// Generate spatial 3D image (depth map)
    func generateSpatial3DImage() async {
        recordInteraction()
        // If not in 3D mode yet, activate it first and let the RealityView
        // handle creation + generation after its init closure runs.
        // explicit: true because generation is only ever reached for animated
        // content through a deliberate user action (the ornament 3D menu or the
        // pill) — the auto paths all guard `!isAnimatedImage` — so activating
        // the first frame in 3D is exactly what was asked for.
        if !is3DMode {
            activate3DMode(generateImmediately: true, explicit: true)
            return
        }

        guard spatial3DImageState == .notGenerated else { return }
        guard let spatial3DImage else {
            AppLogger.photoWindow.warning("spatial3DImage is nil, cannot generate")
            return
        }
        guard var imagePresentationComponent = contentEntity.components[ImagePresentationComponent.self] else {
            AppLogger.photoWindow.warning("ImagePresentationComponent is missing from the entity.")
            return
        }

        // Set the desired viewing mode before generating so that it will trigger the
        // generation animation. Preserve .spatial3DImmersive if already set (e.g. when
        // the user clicked immersive or auto-restore targets immersive).
        imagePresentationComponent.desiredViewingMode = .spatial3D
        if desiredViewingMode != .spatial3DImmersive {
            desiredViewingMode = .spatial3D
        }
        contentEntity.components.set(imagePresentationComponent)
        updateExperimentalSpatial3DTuning()

        spatial3DImageState = .generating

        // Track the generation task so cleanup can wait for it
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Generate the Spatial3DImage scene.
                try await spatial3DImage.generate()

                // Check if cancelled (window closed during generation)
                guard !Task.isCancelled else {
                    self.spatial3DImageState = .notGenerated
                    return
                }

                self.spatial3DImageState = .generated

                // Determine if immersive mode is desired — either because the user
                // explicitly pressed the immersive button (desiredViewingMode) or
                // because auto-restore found a saved immersive preference in the tracker.
                var shouldBeImmersive = self.desiredViewingMode == .spatial3DImmersive
                if !shouldBeImmersive && self.appModel.rememberImageEnhancements {
                    let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: self.imageURL)
                    shouldBeImmersive = lastMode == .spatial3DImmersive
                }

                // Track that this image was converted
                await self.trackImageConverted()

                // Apply the final viewing mode (immersive or spatial3D)
                if shouldBeImmersive {
                    self.applyDesiredViewingMode(.spatial3DImmersive)
                    await self.trackViewingMode(.spatial3DImmersive)
                } else {
                    if let aspectRatio = imagePresentationComponent.aspectRatio(for: .spatial3D) {
                        self.imageAspectRatio = CGFloat(aspectRatio)
                    }
                    self.updateExperimentalSpatial3DTuning()
                    await self.trackViewingMode(.spatial3D)
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.photoWindow.error("Error generating spatial 3D image: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                    self.spatial3DImageState = .notGenerated
                }
            }
        }
        generateTask = task

        // Wait for generation to complete
        await task.value
        generateTask = nil
    }

    /// Whether the RealityKit component is currently showing spatial 3D (vs mono)
    var isViewingSpatial3D: Bool {
        if let viewingMode = contentEntity.components[ImagePresentationComponent.self]?.viewingMode {
            return viewingMode == .spatial3D || viewingMode == .spatial3DImmersive
        }
        return false
    }

    /// Whether the RealityKit component is currently showing immersive spatial 3D
    var isViewingSpatial3DImmersive: Bool {
        contentEntity.components[ImagePresentationComponent.self]?.viewingMode == .spatial3DImmersive
    }

    /// Current viewing mode of the ImagePresentationComponent
    var currentViewingMode: ImagePresentationComponent.ViewingMode? {
        contentEntity.components[ImagePresentationComponent.self]?.viewingMode
    }

    // MARK: - Resolution Override

    /// Apply a per-window resolution override and reload the display image.
    /// Pass nil to clear the override and revert to the global setting.
    func applyResolutionOverride(_ resolution: Int?) async {
        recordInteraction()
        resolutionOverride = resolution
        await trackResolutionOverride()
        guard !isAnimatedImage, !is3DMode else { return }

        if backgroundRemovalState == .removed {
            // Re-downscale the background-removed image at the new resolution
            await reloadBackgroundRemovedAtCurrentResolution()
            return
        }

        if currentAdjustments.isAutoEnhanced {
            // Re-downscale the auto-enhanced image at the new resolution
            await reloadAutoEnhancedAtCurrentResolution()
            return
        }

        guard backgroundRemovalState == .original else { return }

        // Reset current dimension to force reload
        currentDisplayMaxDimension = 0
        let windowSize = lastWindowSize ?? appModel.mainWindowSize
        await loadDisplayImage(for: windowSize)
    }

    /// Apply a per-window spatial 3D source resolution override and re-create
    /// the Spatial3DImage at the new resolution. Pass nil to clear and revert
    /// to the global `spatial3DMaxResolution` setting.
    func applySpatial3DResolutionOverride(_ resolution: Int?) async {
        recordInteraction()
        spatial3DResolutionOverride = resolution
        await trackSpatial3DResolutionOverride()
        guard is3DMode, !isAnimatedImage else { return }

        // Cancel any in-flight generation before tearing down the component —
        // generate() ignores cancellation and crashes if its target is removed.
        await settleActiveGeneration()

        // Tear down current 3D state and re-build at the new source resolution.
        contentEntity.components.remove(ImagePresentationComponent.self)
        spatial3DImage = nil
        spatial3DImageState = .notGenerated
        currentSpatial3DSourceDimension = 0

        await createImagePresentationComponent()
        await generateSpatial3DImage()
    }

    // MARK: - Viewing Mode Switching

    /// Switch directly to a specific viewing mode without cycling.
    /// If the image is still loading, the mode is queued and applied once loading finishes.
    /// - Parameter trackChange: When false, `ImageEnhancementTracker` is not
    ///   updated. Used by gallery navigation to keep the user inside an
    ///   active Fully Immersive session without writing immersive as the
    ///   remembered viewing mode for every image they tap through.
    func switchToViewingMode(_ mode: ImagePresentationComponent.ViewingMode, trackChange: Bool = true) async {
        // Only `.mono` exists off visionOS; every other mode needs the
        // RealityKit conversion this platform doesn't have.
        guard PlatformCapabilities.supportsSpatial3D || mode == .mono else { return }
        if isLoadingDetailImage {
            pendingViewingMode = mode
            desiredViewingMode = mode
            return
        }
        pendingViewingMode = nil
        // Any exit from .spatial3DImmersive (or fully-immersive routing)
        // releases the dedicated ImmersiveSpace so the PhotoDisplayView
        // observer dismisses it.
        if mode != .spatial3DImmersive { hostFullyImmersiveSpace = false }
        if mode == .mono {
            await deactivate3DMode()
        } else if mode == .spatial3D {
            if spatial3DImageState == .notGenerated {
                await generateSpatial3DImage()
                // generateSpatial3DImage already sets desiredViewingMode = .spatial3D
            } else {
                guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
                guard ipc.viewingMode != .spatial3D else { return }
                let wasImmersive = ipc.viewingMode == .spatial3DImmersive
                ipc.desiredViewingMode = .spatial3D
                desiredViewingMode = .spatial3D
                contentEntity.components.set(ipc)
                if let ar = ipc.aspectRatio(for: .spatial3D) { imageAspectRatio = CGFloat(ar) }
                if wasImmersive { immersiveResizeTrigger += 1 }
                updateExperimentalSpatial3DTuning()
                Task { await self.trackViewingMode(.spatial3D) }
            }
        } else if mode == .spatial3DImmersive {
            if appModel.fullyImmersive3DMode {
                // Only one Fully Immersive session at a time — the
                // ImmersiveSpace, the loan entity, and the head-pose
                // tracker are all singletons. Refuse silent activation
                // from a second photo window so the existing session
                // (and its placement / sticky-nav state) isn't clobbered.
                if let owner = appModel.immersiveLoanOwner, owner !== self {
                    AppLogger.photoWindow.info("Refusing Fully Immersive entry — another window already owns the immersive space")
                    desiredViewingMode = .spatial3D
                    return
                }
                // Route into the dedicated ImmersiveSpace instead of
                // expanding the windowed IPC. Keep the windowed entity at
                // .spatial3D (generating if needed) so the photo viewer
                // stays usable while the immersive presentation is open.
                if spatial3DImageState == .notGenerated {
                    desiredViewingMode = .spatial3D
                    await generateSpatial3DImage()
                }
                desiredViewingMode = .spatial3DImmersive
                // Flip the IPC component itself to immersive so the
                // ImmersiveSpace renders the new image at the immersive
                // viewing mode. The Spatial3DImmersiveView only applies
                // this on its initial make pass; gallery navigation
                // rebuilds the IPC underneath it and would otherwise
                // render the new image at .spatial3D until the user
                // closed and reopened the space.
                if var ipc = contentEntity.components[ImagePresentationComponent.self] {
                    ipc.desiredViewingMode = .spatial3DImmersive
                    contentEntity.components.set(ipc)
                }
                hostFullyImmersiveSpace = true
                if trackChange {
                    Task { await self.trackViewingMode(.spatial3DImmersive) }
                }
                return
            }
            if spatial3DImageState == .notGenerated {
                desiredViewingMode = .spatial3DImmersive
                await generateSpatial3DImage()
                applyDesiredViewingMode(.spatial3DImmersive)
                Task { await self.trackViewingMode(.spatial3DImmersive) }
            } else {
                guard let ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
                guard ipc.viewingMode != .spatial3DImmersive else { return }
                applyDesiredViewingMode(.spatial3DImmersive)
                Task { await self.trackViewingMode(.spatial3DImmersive) }
            }
        }
    }

    // MARK: - Experimental: Widen spatial3D viewing angle
    //
    // The Photos widget keeps the spatial scene readable from off-axis by
    // soft-tracking the user's head and recessing the image behind the glass.
    // We approximate that here by adding a low-blend BillboardComponent and a
    // small -Z offset, applied only in windowed .spatial3D mode. Tweak the
    // constants below if the rotation feels too aggressive or too subtle, or
    // if the inset makes the IPC clip oddly against the SwiftUI glass.
    //
    // Tradeoff: BillboardComponent rotates the entity that IPC renders into,
    // which may partially flatten IPC's view-dependent parallax. We need
    // hands-on evaluation to decide if the wider comfort cone is worth it.

    /// Blend factor for the experimental soft billboard (0 = no rotation, 1 = full).
    /// Applied only in windowed .spatial3D viewing mode.
    /// Disabled (0): rotation caused the image to clip into real-world walls at
    /// oblique angles and didn't actually clear IPC's off-axis blur.
    static let experimentalSpatial3DBillboardBlend: Float = 0.0

    /// Z offset (meters) applied behind the window glass for the spatial3D scene.
    /// Negative pushes the image away from the viewer. Disabled (0) for now.
    static let experimentalSpatial3DZInset: Float = 0.0

    /// Whether the experimental tuning should be active given the current state.
    /// Active only when there's an IPC present and we're in (or transitioning to)
    /// windowed spatial3D — not mono, not immersive.
    var shouldApplyExperimentalSpatial3DTuning: Bool {
        guard contentEntity.components[ImagePresentationComponent.self] != nil else { return false }
        return desiredViewingMode == .spatial3D
    }

    /// Apply or remove the experimental BillboardComponent on contentEntity
    /// based on the current viewing mode. The Z-inset is applied in the
    /// RealityView update closure (PhotoDisplayView) since that closure
    /// re-asserts contentEntity.position every frame. Both billboard and
    /// inset are currently disabled (constants set to 0) but the structure
    /// remains in case future tuning re-enables them.
    func updateExperimentalSpatial3DTuning() {
        if shouldApplyExperimentalSpatial3DTuning {
            var billboard = BillboardComponent()
            billboard.blendFactor = Self.experimentalSpatial3DBillboardBlend
            contentEntity.components.set(billboard)
        } else {
            contentEntity.components.remove(BillboardComponent.self)
        }
    }

    /// Ask the view layer to nudge the window's geometry so IPC re-anchors
    /// its off-axis blur calibration. Confirmed empirically as the only
    /// mechanism that clears the blur — IPC re-publishing alone doesn't
    /// trigger it, and head-pose tracking isn't available in the Shared
    /// Space (ARKit data providers require a Full Space on visionOS). The
    /// view layer fires this on tap and on scenePhase → .active. Skipped
    /// if IPC isn't actually in a spatial 3D viewing mode so we don't
    /// disrupt mono playback.
    func refreshSpatial3DCalibration() {
        guard let ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
        guard ipc.viewingMode == .spatial3D || ipc.viewingMode == .spatial3DImmersive else { return }
        calibrationNudgeTrigger &+= 1
    }

    /// Apply a viewing mode that was queued while the image was loading.
    func applyPendingViewingMode() async {
        guard let mode = pendingViewingMode else { return }
        pendingViewingMode = nil
        guard !isAnimatedImage else { return }
        await switchToViewingMode(mode)
    }

    /// Check if the current image was previously converted and auto-generate if so
    func autoGenerateSpatial3DIfPreviouslyConverted() async {
                guard appModel.rememberImageEnhancements, appModel.autoRestoreSpatial3D else { return }
                guard !isAnimatedImage,
              spatial3DImageState == .notGenerated else {
            return
        }

        // Respect the user's last-used mode for this image — unless the user's
        // default viewing mode is 3D, in which case a remembered `.mono` is
        // ignored so the default still wins for previously-toggled images.
        let defaultIs3D = appModel.defaultImageViewingMode == .spatial3D
            || appModel.defaultImageViewingMode == .spatial3DImmersive
        if !defaultIs3D,
           let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL),
           lastMode == .mono {
            AppLogger.photoWindow.debug("Skipping auto-generation; last mode was 2D")
            return
        }

        let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)
        if wasConverted {
            // Set desired mode before generation so the correct button shows the spinner
            let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
            if lastMode == .spatial3DImmersive {
                desiredViewingMode = .spatial3DImmersive
            }
            AppLogger.photoWindow.debug("Auto-generating spatial 3D for previously converted image")
            await generateSpatial3DImage()
        }
    }

    // MARK: - Viewing Mode Helper (Deduplicated)

    /// Apply a desired viewing mode to the ImagePresentationComponent, updating
    /// aspect ratio and immersive resize trigger as needed.
    func applyDesiredViewingMode(_ mode: ImagePresentationComponent.ViewingMode) {
        guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
        ipc.desiredViewingMode = mode
        desiredViewingMode = mode
        contentEntity.components.set(ipc)
        if let ar = ipc.aspectRatio(for: mode) { imageAspectRatio = CGFloat(ar) }
        if mode == .spatial3DImmersive { immersiveResizeTrigger += 1 }
        updateExperimentalSpatial3DTuning()
    }
}

// MARK: - Spatial 3D Handoff

extension PhotoWindowModel {

    /// Registry key for this image's spatial-3D instance — the same key on both
    /// sides of a handoff, so a window that has generated nothing yet can still
    /// look up what another window deposited.
    ///
    /// Keyed on the *effective cap*, not `currentSpatial3DSourceDimension`: an
    /// image smaller than the cap skips downsampling entirely and records its own
    /// native dimension, so keying on the actual dimension made every deposit
    /// from a sub-cap image unfindable. The cap is the better identity anyway —
    /// it is the input that decides the result.
    var spatial3DHandoffLookupKey: Spatial3DImageHandoff.Key {
        Spatial3DImageHandoff.Key(
            imageURL: imageURL.absoluteString,
            sourceDimension: effectiveSpatial3DMaxResolution
        )
    }

    /// Publish this window's generated instance so a window opened next can
    /// pick it up. Returns true when something was deposited.
    @discardableResult
    ///
    /// Waits out any in-flight generation first: depositing a half-generated
    /// instance would hand the next window an object RealityKit is still
    /// writing to.
    func depositSpatial3DForHandoff() async -> Bool {
        await settleActiveGeneration()

        guard spatial3DImageState == .generated, let spatial3DImage else {
            // The common case — most pop-outs are of 2D images.
            AppLogger.photoWindow.debug(
                "[Handoff] nothing to deposit state=\(String(describing: self.spatial3DImageState), privacy: .public)"
            )
            return false
        }

        let key = spatial3DHandoffLookupKey
        // The component's live mode, not `desiredViewingMode` — the latter can
        // still be pointing at a mode the component refused (e.g. a Fully
        // Immersive entry the owner guard turned down).
        let sourceMode = contentEntity.components[ImagePresentationComponent.self]?.viewingMode
            ?? desiredViewingMode
        AppLogger.photoWindow.debug(
            "[Handoff] depositing generated instance mode=\(String(describing: sourceMode), privacy: .public)"
        )

        Spatial3DImageHandoff.shared.deposit(
            key: key,
            image: spatial3DImage,
            aspectRatio: imageAspectRatio,
            viewingMode: sourceMode
        )
        return true
    }

    /// Try to adopt a handed-over instance for the image this window is opening.
    /// On success the component is installed already-generated, so no
    /// `generate()` ever runs here — device-confirmed, see the file header on
    /// `Spatial3DImageHandoff`.
    func claimHandoffSpatial3DImage() -> ImagePresentationComponent.Spatial3DImage? {
        let key = spatial3DHandoffLookupKey
        guard let claimed = Spatial3DImageHandoff.shared.claim(key: key) else { return nil }

        spatial3DHandoffKey = key

        // The generated state lives on the instance, not the component, so a
        // second component built from it starts out already generated.
        let supported = ImagePresentationComponent.supportedViewingModes(for: claimed.image)
        guard supported.contains(.spatial3D) else {
            // Nothing generated after all — release and fall back to the
            // normal decode + generate path rather than installing a component
            // that can only ever show mono.
            AppLogger.photoWindow.warning("[Handoff] claimed instance reports no spatial3D mode; falling back to generation")
            Spatial3DImageHandoff.shared.release(key: key)
            spatial3DHandoffKey = nil
            return nil
        }

        spatial3DImageState = .generated

        var component = ImagePresentationComponent(spatial3DImage: claimed.image)
        // Windowed 3D first even when the source was immersive: the immersive
        // switch needs this window to exist (and, in Fully Immersive, to win the
        // owner guard), so it is applied below once the make pass is over.
        component.desiredViewingMode = .spatial3D
        contentEntity.components.set(component)
        desiredViewingMode = .spatial3D
        if let aspect = component.aspectRatio(for: .spatial3D) ?? claimed.aspectRatio.map(Float.init) {
            imageAspectRatio = CGFloat(aspect)
        }

        updateExperimentalSpatial3DTuning()
        // Nothing has been baked into this instance's pixels by *this* window.
        lastBakedAdjustments = VisualAdjustments()
        displayTexture = nil
        displayImage = nil
        currentImageData = nil

        // Carry the source window's mode over. Deferred out of the RealityView
        // make pass, and routed through switchToViewingMode so the Fully
        // Immersive owner guard and tracker writes all still apply.
        if claimed.viewingMode == .spatial3DImmersive {
            Task { @MainActor [weak self] in
                await self?.switchToViewingMode(.spatial3DImmersive)
            }
        }

        AppLogger.photoWindow.debug(
            "[Handoff] adopted generated instance, no regeneration (sourceMode=\(String(describing: claimed.viewingMode), privacy: .public))"
        )
        return claimed.image
    }
}
