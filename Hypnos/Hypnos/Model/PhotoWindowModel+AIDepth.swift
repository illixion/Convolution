/*
 Hypnos - Photo Window Model: AI 3D

 AI 3D shows the photo as a mesh displaced by the real-time depth model's map
 (`AIDepthPhotoView`): one inference and one RealityKit mesh, the cheap
 alternative to "RealityKit 3D" (`ImagePresentationComponent`), which takes
 seconds and a large memory spike to generate.

 A sibling viewing mode to Diorama and the RealityKit 3D modes, engaged from
 the 3D menu and mutually exclusive with them and with background removal
 (whose cut-out is cropped to the subject, so the depth map no longer lines
 up). Unlike Diorama it follows the user across gallery navigation: it's
 cheap enough to keep on.

 The depth map is shared with the "3D Depth" thumbnail cache, keyed by the
 image's thumbnail URL, so a picture already seen in that grid style engages
 without running the model, and one viewed here appears in 3D in the grid.
 */

import DebugTrace
import Foundation
import ImageIO
import RAVEMedia
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    /// Whether a real-time depth model is installed to run AI 3D.
    var isAIDepthAvailable: Bool {
        ThumbnailDepthEstimator.shared.isModelAvailable
    }

    /// The 3D menu's AI 3D item.
    func toggleAIDepth() async {
        recordInteraction()
        await setAIDepthMode(!isAIDepthMode)
    }

    /// Set AI 3D explicitly. Turning it on leaves the RealityKit 3D modes,
    /// Diorama and background removal first.
    func setAIDepthMode(_ on: Bool, trackChange: Bool = true) async {
        guard on else {
            exitAIDepthMode()
            if trackChange { await trackViewingMode(.mono) }
            return
        }
        guard !isAIDepthMode, !isAnimatedImage else { return }
        if is3DMode || desiredViewingMode != .mono {
            await switchToViewingMode(.mono, trackChange: false)
        }
        // Not through setDioramaMode(false): that records 2D as this image's
        // remembered mode, and AI 3D is about to record itself.
        isDioramaMode = false
        if backgroundRemovalState == .removed {
            restoreOriginalBackground()
        }
        if backgroundRemovalState != .original {
            clearBackgroundRemovalState()
        }
        let url = imageURL
        guard await ensureAIDepthLoaded(), imageURL == url else { return }
        // Another mode may have been picked while the depth was being made.
        guard !is3DMode, desiredViewingMode == .mono, !isDioramaMode,
              backgroundRemovalState == .original else { return }
        isAIDepthMode = true
        if trackChange { await trackViewingMode(.aiDepth) }
    }

    /// Leave AI 3D without recording anything: the caller is switching to
    /// another mode, which records itself.
    func exitAIDepthMode() {
        guard isAIDepthMode || aiDepthSource != nil else { return }
        isAIDepthMode = false
        // The depth map is small and stays for a quick return; the decoded
        // picture is up to 16 MB of CPU memory and goes.
        aiDepthSource = nil
    }

    /// Decode the mesh's picture and find or make the depth map. Returns
    /// whether both are ready for the current image.
    @discardableResult
    func ensureAIDepthLoaded() async -> Bool {
        if aiDepthSource != nil, aiDepthMap != nil { return true }
        if let running = aiDepthTask { return await running.value }
        guard let data = currentImageData else {
            AppLogger.photoWindow.warning("No image data available for AI 3D")
            return false
        }
        let url = imageURL
        let depthKey = image.thumbnailURL
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            self.isProcessingAIDepth = true
            defer { self.isProcessingAIDepth = false }
            let source = await Task.detached(priority: .userInitiated) {
                Self.decodeAIDepthSource(data, maxPixelSize: 2048)
            }.value
            guard !Task.isCancelled, self.imageURL == url, let source else { return false }
            var map = self.aiDepthMap
            if map == nil {
                map = await ThumbnailDioramaCache.shared.cachedOrDiskDepth(for: depthKey)?.map
            }
            if map == nil {
                let start = Date()
                map = await ThumbnailDioramaCache.shared.depth(for: depthKey) { UIImage(cgImage: source) }?.map
                if map != nil {
                    AppLogger.photoWindow.info("AI 3D depth in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
                }
            }
            guard !Task.isCancelled, self.imageURL == url, let map else {
                if !Task.isCancelled { AppLogger.photoWindow.warning("AI 3D has no depth for this image") }
                return false
            }
            self.aiDepthSource = source
            self.aiDepthMap = map
            return true
        }
        aiDepthTask = task
        let loaded = await task.value
        aiDepthTask = nil
        return loaded
    }

    /// Clear the in-memory AI 3D state. Called when switching to a different
    /// image and on cleanup.
    func clearAIDepthState() {
        aiDepthTask?.cancel()
        aiDepthTask = nil
        aiDepthSource = nil
        aiDepthMap = nil
        isProcessingAIDepth = false
        isAIDepthMode = false
    }

    /// Oriented, downsampled decode. The thumbnail API applies the EXIF
    /// orientation (`CreateThumbnailWithTransform`), unlike a plain
    /// `CGImageSourceCreateImageAtIndex`.
    nonisolated static func decodeAIDepthSource(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
