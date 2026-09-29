/*
 Hypnos - Photo Window Model: Memory Management

 Extension for memory pressure handling: idle downscale, scene phase tracking,
 and lightweight display transitions.
 */

import DebugTrace
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    // MARK: - Scene Phase Handling

    /// Handle a scenePhase transition for this window.
    /// Starts an inactivity timer when leaving active, restores on return.
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        AppLogger.photoWindow.info(
            "[\(self.displayName, privacy: .private(mask: .hash))] scenePhase: \(Self.phaseLabel(oldPhase), privacy: .public) → \(Self.phaseLabel(newPhase), privacy: .public)"
        )

        if newPhase == .active {
            isInActiveRoom = true
            backgroundedSince = nil

            // Window became visible again — cancel any pending downscale and restore
            scenePhaseIdleTask?.cancel()
            scenePhaseIdleTask = nil

            if isIdleDownscaled {
                AppLogger.photoWindow.info("[\(self.displayName, privacy: .private(mask: .hash))] Restoring from scene-phase idle downscale")
                Task {
                    await restoreFromIdleDownscale()
                }
            }
        } else if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
            isInActiveRoom = false
            backgroundedSince = Date()

            // Window moved to another room — start inactivity timer
            scheduleScenePhaseIdleDownscale()
        }
    }

    /// Schedule an idle downscale after the timeout period
    func scheduleScenePhaseIdleDownscale() {
        scenePhaseIdleTask?.cancel()
        scenePhaseIdleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.scenePhaseIdleTimeout))
            } catch {
                return // Cancelled — window became active again
            }

            guard let self, !Task.isCancelled else { return }
            guard !self.isIdleDownscaled, !self.isRestoringFromIdle else { return }

            AppLogger.photoWindow.info("[\(self.displayName, privacy: .private(mask: .hash))] Idle downscaling after scene-phase timeout")
            await self.releaseMemoryForIdleDownscale()
            await self.applyIdleDownscaleThumbnail()
        }
    }

    static func phaseLabel(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    // MARK: - Memory Pressure Idle Downscale

    /// Aggressively downscale this window to thumbnail resolution to free memory.
    /// Called by AppModel's LRU memory pressure system. Ignores resolution overrides
    /// since crash prevention is more important than user preferences.
    /// Phase 1: Release all heavy in-memory resources without allocating anything new.
    func releaseMemoryForIdleDownscale() async {
        guard !isIdleDownscaled, !isRestoringFromIdle else { return }

        // Animated content is displayed by WebKit (raw GIF / WASM APNG / cached
        // <img>-video), which already pauses and offloads offscreen work, and it
        // has no idle-restore path — releasing its backing data here would blank
        // it with no way back. Leave animated windows to WebKit's own lifecycle.
        guard !isAnimatedImage else { return }

        AppLogger.photoWindow.info("Releasing memory for idle downscale")

        // Snapshot current enhancement state so restore can skip the full
        // auto-restore pipeline and directly reload from cache
        hadBackgroundRemoval = backgroundRemovalState == .removed
        had3DMode = is3DMode
        hadAutoEnhance = currentAdjustments.isAutoEnhanced

        // If in 3D mode, release RealityKit textures (GPU memory)
        if is3DMode {
            // Cancel any in-progress 3D generation first (RealityKit crashes otherwise)
            if let task = generateTask {
                task.cancel()
                await task.value
                generateTask = nil
            }
            spatial3DImage = nil
            spatial3DImageState = .notGenerated
            pendingGenerate3D = false
            contentEntity.components.remove(ImagePresentationComponent.self)
            is3DMode = false
        }

        // Clear background removal caches
        clearBackgroundRemovalState()

        // Release shared texture cache reference
        if let cacheKey = displayTextureCacheKey {
            SharedTextureCache.shared.release(key: cacheKey)
            displayTextureCacheKey = nil
        }

        // Release raw image data (can be reloaded from disk cache)
        currentImageData = nil

        // Release GPU textures and CPU display images to free memory
        displayTexture = nil
        displayImage = nil
        autoEnhancedDisplayTexture = nil
        preAutoEnhanceDisplayTexture = nil
        originalDisplayTexture = nil
        backgroundRemovedTexture = nil
        autoEnhancedBackgroundRemovedTexture = nil

        isIdleDownscaled = true
    }

    /// Phase 2: Load a small thumbnail so the window shows a recognizable preview
    /// instead of blank. Called after `releaseMemoryForIdleDownscale()` has freed
    /// memory from all targeted windows first.
    func applyIdleDownscaleThumbnail() async {
        guard isIdleDownscaled else { return }
        // Animated images and windows with no display don't need a thumbnail
        guard !isAnimatedImage else { return }

        let thumbnailDim = Self.idleDownscaleDimension

        // Try the pre-generated thumbnail cache first (tiny HEIC files, no decode of full image)
        if let cached = await ThumbnailCache.shared.loadThumbnail(for: imageURL) {
            displayImage = cached
            imageAspectRatio = cached.size.width / cached.size.height
            currentDisplayMaxDimension = thumbnailDim
            return
        }

        // Fall back to CGImageSource downsample from the disk-cached full-res file
        guard let sourceURL = await resolveSourceFileURL() else { return }

        let image = await Task.detached { [sourceURL, thumbnailDim] in
            ThumbnailGenerator.shared.downsampleImage(at: sourceURL, maxDimension: thumbnailDim)
        }.value

        if let image {
            displayImage = image
            imageAspectRatio = image.size.width / image.size.height
            currentDisplayMaxDimension = thumbnailDim
        }
    }

    /// Restore this window from idle-downscaled state to proper resolution.
    /// Called when the user interacts with a previously downscaled window.
    func restoreFromIdleDownscale() async {
        guard isIdleDownscaled else { return }

        AppLogger.photoWindow.info("[\(self.displayName, privacy: .private(mask: .hash))] Restoring window from idle downscale")
        isRestoringFromIdle = true
        isIdleDownscaled = false
        currentDisplayMaxDimension = 0

        // Don't set isLoadingDetailImage — that triggers the ornament
        // show/auto-hide cycle via PhotoDisplayView's onChange observer.
        // Idle restore is not a user-initiated open.

        // Update interaction time so this window isn't the oldest LRU target
        // if memory pressure fires during the restore
        lastInteractionTime = Date()

        let windowSize = lastWindowSize ?? appModel.mainWindowSize

        // Reload raw data without triggering the full auto-restore pipeline.
        // We use the saved pre-downscale state to restore enhancements directly.
        await loadImageDataForDetail(url: imageURL, autoRestore: false)

        if had3DMode {
            // Re-activate 3D mode without the full activate3DMode() flow
            // (which calls recordInteraction, clearBackgroundRemovalState, etc.)
            is3DMode = true
            pendingGenerate3D = true
            // RealityView's init closure will consume pendingGenerate3D
        } else if hadBackgroundRemoval && hadAutoEnhance {
            // Combined state: restore bg removal with auto-enhance active
            currentAdjustments.isAutoEnhanced = true
            if let cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL) {
                await applyCachedBackgroundRemovalFromURL(cachedURL)
            } else {
                await loadDisplayImage(for: windowSize)
            }
        } else if hadBackgroundRemoval {
            // Load background-removed image directly from disk cache (URL-based for efficiency)
            if let cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL) {
                await applyCachedBackgroundRemovalFromURL(cachedURL)
            } else {
                // Cache miss — fall back to standard 2D load
                await loadDisplayImage(for: windowSize)
            }
        } else if hadAutoEnhance {
            // Load base display image first, then re-apply auto-enhance
            currentAdjustments.isAutoEnhanced = false
            await loadDisplayImage(for: windowSize)
            await toggleAutoEnhance()
        } else if !isAnimatedImage {
            // Standard 2D image — just reload at correct resolution
            await loadDisplayImage(for: windowSize)
        }

        // Restore flip state
        if appModel.rememberImageEnhancements, !is3DMode {
            let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: imageURL)
            if wasFlipped {
                isImageFlipped = true
            }
        }

        isRestoringFromIdle = false
    }

    // MARK: - Lightweight Display Transition

    /// Transition from RealityKit to lightweight SwiftUI display.
    /// Called when memory warning triggers lightweight mode.
    func switchToLightweightDisplay() async {
        guard !isAnimatedImage else { return }

        // If 3D generation is in progress, wait for it to finish before
        // removing the component (RealityKit crashes otherwise)
        if let task = generateTask {
            task.cancel()
            await task.value
            generateTask = nil
        }

        // Release RealityKit resources immediately to free memory
        spatial3DImage = nil
        spatial3DImageState = .notGenerated
        pendingGenerate3D = false
        contentEntity.components.remove(ImagePresentationComponent.self)
        is3DMode = false
        clearBackgroundRemovalState()

        // Reset display dimension so loadDisplayImage doesn't early-exit
        currentDisplayMaxDimension = 0

        // Load lightweight display image
        isLoadingDetailImage = true
        if let windowSize = lastWindowSize {
            await loadDisplayImage(for: windowSize)
        }
    }
}
