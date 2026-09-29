/*
 Hypnos - Photo Window Model: Gallery Navigation

 Extension for gallery image navigation, lazy loading pagination, and rating/counter updates.
 */

import DebugTrace
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    // MARK: - Gallery Navigation

    /// Switch to displaying a different image, releasing previous resources and loading new ones.
    func switchToImage(_ newImage: GalleryImage) async {
        let oldImageURL = imageURL
        // Capture whether the user is currently inside a Fully Immersive
        // session so we can drop them back into immersive on the new
        // image without writing it into ImageEnhancementTracker — the
        // immersive preference shouldn't follow every image they tap.
        let wasHostingFullyImmersive = hostFullyImmersiveSpace
        image = newImage
        imageURL = newImage.fullSizeURL
        // Drop the previous image's failure before the new load starts, so a
        // dead image doesn't leave its error card up over its successor.
        loadFailure = nil
        isLoadingDetailImage = true

        // Update pop-out window tracking so saved window groups capture the current image
        if let windowValue = popOutWindowValue {
            appModel.updatePopOutWindowImage(windowValueId: windowValue.id, oldImageURL: oldImageURL, newImage: newImage)
        }

        // Wait for any in-progress generation to finish before removing the
        // component. RealityKit crashes if we remove ImagePresentationComponent
        // while generate() is still running internally.
        if let task = generateTask {
            task.cancel()
            await task.value
            generateTask = nil
        }

        // Release shared texture cache reference for the old image
        if let cacheKey = displayTextureCacheKey {
            SharedTextureCache.shared.release(key: cacheKey)
            displayTextureCacheKey = nil
        }

        // Release all previous image resources
        spatial3DImageState = .notGenerated
        spatial3DImage = nil
        isAnimatedGIF = false
        isAnimatedWebP = false
        isAnimatedWebVisual = false
        isAnimatedJXL = false
        animatedImgPlaybackFailed = false
        animatedConversionTask?.cancel()
        animatedConversionTask = nil
        currentImageData = nil
        animatedImageSourceURL = nil
        animatedHEVCURL = nil
        displayTexture = nil
        displayImage = nil
        nativeImageDimensions = nil
        currentDisplayMaxDimension = 0
        isLoadingDisplayImage = false
        contentEntity.components.remove(ImagePresentationComponent.self)
        clearAutoEnhanceState()
        clearBackgroundRemovalState()
        clearDioramaState()

        is3DMode = false
        desiredViewingMode = .mono
        isImageFlipped = false
        resolutionOverride = nil
        spatial3DResolutionOverride = nil
        currentSpatial3DSourceDimension = 0
        currentAdjustments = VisualAdjustments()
        isShowingAdjustmentPreview = false
        adjustments3DReloadTask?.cancel()
        // Dismiss any lingering 3D restore prompt from the previous image.
        // If the new image also has a cached 3D state, autoRestorePreviousEnhancement
        // will re-present the prompt with a fresh timer.
        dismissAutoRestorePrompt()

        if appModel.rememberImageEnhancements {
            let savedOverride = await ImageEnhancementTracker.shared.resolutionOverride(url: newImage.fullSizeURL)
            if savedOverride != nil {
                resolutionOverride = savedOverride
            }
            let savedS3DOverride = await ImageEnhancementTracker.shared.spatial3DResolutionOverride(url: newImage.fullSizeURL)
            if savedS3DOverride != nil {
                spatial3DResolutionOverride = savedS3DOverride
            }
            let savedSize = await ImageEnhancementTracker.shared.windowSize(url: newImage.fullSizeURL)
            savedWindowSize = savedSize
            if let savedSize {
                lastWindowSize = savedSize
            }
        } else {
            savedWindowSize = nil
        }

        await loadImageDataForDetail(url: newImage.fullSizeURL)

        if !isAnimatedImage && !useRealityKitDisplay {
            // Fall back to the main window size rather than skipping the load:
            // `loadDisplayImage` is what clears `isLoadingDetailImage` on this
            // path, so bailing out here would leave the window stuck loading.
            await loadDisplayImage(for: lastWindowSize ?? appModel.mainWindowSize)
        }

        if appModel.rememberImageEnhancements, !is3DMode {
            let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: newImage.fullSizeURL)
            if wasFlipped {
                isImageFlipped = true
            }
        }

        await restoreAdjustments()
        await applyPendingViewingMode()

        await applyDefaultViewingModeIfNeeded()

        // Re-enter Fully Immersive 3D for the new image if the previous
        // image was being viewed that way. Skip tracking so the user's
        // per-image last-viewing-mode preference is left untouched.
        if wasHostingFullyImmersive && appModel.fullyImmersive3DMode && !isAnimatedImage {
            await switchToViewingMode(.spatial3DImmersive, trackChange: false)
        }
    }

    /// Navigate to next image in gallery
    func nextGalleryImage() async {
        recordInteraction()
        guard hasNextGalleryImage else { return }
        currentGalleryIndex += 1

        // Trigger prefetch if approaching end
        checkAndLoadMoreIfNeeded()

        let nextImage = galleryImages[currentGalleryIndex]
        await switchToImage(nextImage)
    }

    /// Navigate to previous image in gallery
    func previousGalleryImage() async {
        recordInteraction()
        guard hasPreviousGalleryImage else { return }
        currentGalleryIndex -= 1
        let prevImage = galleryImages[currentGalleryIndex]
        await switchToImage(prevImage)
    }

    /// Check if there's a next image in gallery
    var hasNextGalleryImage: Bool {
        currentGalleryIndex + 1 < galleryImages.count
    }

    /// Check if there's a previous image in gallery
    var hasPreviousGalleryImage: Bool {
        currentGalleryIndex > 0
    }

    /// Current position in gallery (1-indexed for display)
    var currentGalleryPosition: Int {
        currentGalleryIndex + 1
    }

    /// Total images in gallery
    var galleryImageCount: Int {
        galleryImages.count
    }

    // MARK: - Viewer Lazy Loading

    /// Populate galleryImages with the local source's flat scan so prev/next
    /// can navigate across local files. Relocates `currentGalleryIndex` to
    /// the current image's position within the fetched list.
    func loadInitialLocalGallery() async {
        do {
            let result = try await imageSource.fetchImages(page: 0, pageSize: pageSize, filter: nil)
            let startingURL = imageURL

            if let idx = result.images.firstIndex(where: { $0.fullSizeURL == startingURL }) {
                galleryImages = result.images
                currentGalleryIndex = idx
            } else {
                // Current image wasn't on the first page (e.g. first page
                // doesn't include it due to sort order). Keep it pinned at
                // the front so the UI still has a valid selection and let
                // `checkAndLoadMoreIfNeeded` pull more pages on demand.
                var images = result.images
                images.insert(image, at: 0)
                galleryImages = images
                currentGalleryIndex = 0
            }
            hasMorePages = result.hasMore
            currentPage = 1
        } catch {
            AppLogger.photoWindow.error("Failed to load local gallery: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    /// Load more images using the snapshotted filter
    func loadMoreImages() async {
        guard !isLoadingMoreImages && hasMorePages else { return }

        isLoadingMoreImages = true
        defer { isLoadingMoreImages = false }

        do {
            let result = try await imageSource.fetchImages(page: currentPage, pageSize: pageSize, filter: snapshotFilter)
            galleryImages.append(contentsOf: result.images)
            hasMorePages = result.hasMore
            currentPage += 1
            AppLogger.photoWindow.debug("Loaded \(result.images.count, privacy: .public) more images for window, total: \(self.galleryImages.count, privacy: .public)")
        } catch {
            AppLogger.photoWindow.error("Failed to load more images for window: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    /// Check if more images should be loaded based on current position
    func checkAndLoadMoreIfNeeded() {
        let remaining = galleryImages.count - currentGalleryIndex - 1
        if remaining <= prefetchThreshold && hasMorePages && !isLoadingMoreImages {
            Task {
                await loadMoreImages()
            }
        }
    }

    // MARK: - Rating & O Counter

    func updateImageRating(stashId: String, rating100: Int?) async throws {
        try await appModel.updateImageRating(stashId: stashId, rating100: rating100)
        // Update local state
        image.rating100 = rating100
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].rating100 = rating100
        }
    }

    func incrementImageOCounter(stashId: String) async throws {
        try await appModel.incrementImageOCounter(stashId: stashId)
        // Sync from appModel's updated value
        if let updated = appModel.galleryImages.first(where: { $0.stashId == stashId }) {
            image.oCounter = updated.oCounter
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = image.oCounter
        }
    }

    func decrementImageOCounter(stashId: String) async throws {
        try await appModel.decrementImageOCounter(stashId: stashId)
        if let updated = appModel.galleryImages.first(where: { $0.stashId == stashId }) {
            image.oCounter = updated.oCounter
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = image.oCounter
        }
    }
}
