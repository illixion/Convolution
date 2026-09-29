/*
 Hypnos - Photo Window Model: UI Controls

 Extension for UI interaction methods: share sheet, auto-hide timers, and image flip.
 */

import DebugTrace
import Foundation
import SwiftUI

extension PhotoWindowModel {

    // MARK: - Share

    func shareImage() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        let url = image.fullSizeURL
        // Prefer server filename (has correct extension), fall back to title
        let shareName = image.fileName ?? image.title

        // Anything already backed by a local file — a local file, a Photos
        // asset, or a cached remote image — shares straight from it.
        //
        // A Photos asset needs this explicitly: loadRawData below resolves the
        // asset internally but returns its bytes without populating
        // DiskImageCache, so the lookup after it would find nothing and the
        // share would silently do nothing at all.
        if let localURL = await Self.localFileURL(for: url) {
            presentShareSheet(url: ShareSheetHelper.prepareShareFile(from: localURL, title: shareName, originalURL: url))
            return
        }

        // Download the full-res image (also caches to disk)
        do {
            _ = try await ImageLoader.shared.loadRawData(from: url)
            if let cachedURL = await DiskImageCache.shared.cachedFileURL(for: url) {
                presentShareSheet(url: ShareSheetHelper.prepareShareFile(from: cachedURL, title: shareName, originalURL: url))
            }
        } catch {
            AppLogger.photoWindow.error("Failed to download image for sharing: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    func presentShareSheet(url: URL) {
        cancelAutoHideTimer()
        shareFileURL = url
    }

    // MARK: - UI Auto-Hide

    func startAutoHideTimer() {
        recordInteraction()
        cancelAutoHideTimer()

        guard appModel.autoHideDelay > 0 else { return }
        guard !hasOpenPopover else { return }
        // While the Fully Immersive space is hosted, the photo window is
        // the user's only controls surface — keep its ornament pinned so
        // the Exit affordance never auto-hides out of reach.
        guard !hostFullyImmersiveSpace else { return }

        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            if !Task.isCancelled, !self.hasOpenPopover, !self.isLoadingDetailImage {
                isUIHidden = true
                // Schedule window controls to hide 1.5 seconds later
                scheduleWindowControlsHiding()
            }
        }
    }

    func scheduleWindowControlsHiding() {
        windowControlsHideTask?.cancel()
        windowControlsHideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                isWindowControlsHidden = true
            }
        }
    }

    func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
        isWindowControlsHidden = false
    }

    func toggleUIVisibility() {
        recordInteraction()
        isUIHidden.toggle()
        isWindowControlsHidden = false
        if !isUIHidden {
            startAutoHideTimer()
        }
    }

    // MARK: - Image Flip

    /// Toggle the flip state and persist it via the enhancement tracker.
    func toggleFlip() {
        recordInteraction()
        isImageFlipped.toggle()
        Task {
            await trackFlipState()
        }
    }
}
