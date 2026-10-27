/*
 Hypnos - Photo Window Model: AI 3D

 AI 3D uses the shared stereo warp with the nearest content on the window
 and the background behind it. Full-size photos infer their own precise depth,
 guided by the selected pre-process model, independently of thumbnail caches.
 Resolution follows the normal viewer policy plus a stereo working-set bound.
 It remains mutually exclusive with RealityKit 3D, Diorama and background
 removal, and follows gallery navigation.
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
        RAVEStillDepthEstimator.shared.isModelAvailable
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
        aiDepthTask?.cancel()
        aiDepthTask = nil
        isProcessingAIDepth = false
        guard isAIDepthMode || aiDepthSource != nil else { return }
        isAIDepthMode = false
        // Release decoded colour; a later engage infers with the active model.
        aiDepthPresentationReady = false
        aiDepthSourceDimension = 0
        aiDepthSource = nil
        aiDepthHeadroom = 1
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
        let target = aiDepthTargetDimension()
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            self.isProcessingAIDepth = true
            defer { self.isProcessingAIDepth = false }
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decodeAIDepthSource(data, maxPixelSize: target)
            }.value
            guard !Task.isCancelled, self.imageURL == url, let decoded else { return false }
            let source = decoded.image
            // Full-size photos never borrow depth inferred from a thumbnail.
            let map = await RAVEStillDepthEstimator.shared.depth(for: source, photoQuality: true)
            guard !Task.isCancelled, self.imageURL == url, let map else {
                if !Task.isCancelled { AppLogger.photoWindow.warning("AI 3D has no depth for this image") }
                return false
            }
            self.aiDepthSourceDimension = target
            self.aiDepthPresentationReady = false
            self.aiDepthSource = source
            self.aiDepthHeadroom = decoded.headroom
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
        aiDepthPresentationReady = false
        aiDepthSourceDimension = 0
        aiDepthSource = nil
        aiDepthHeadroom = 1
        aiDepthMap = nil
        isProcessingAIDepth = false
        isAIDepthMode = false
    }

    /// Respect the normal viewer target first, then bound the stereo working set.
    func aiDepthTargetDimension() -> Int {
        var width = Int(nativeImageDimensions?.width ?? 8192)
        var height = Int(nativeImageDimensions?.height ?? 8192)
        if let data = currentImageData,
           let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? width
            height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? height
        }
        let requested = displayTargetDimension(nativeMaxDimension: CGFloat(max(width, height)))
        return StillStereoResolution.longSide(width: width, height: height, requested: Double(requested))
    }

    func reloadAIDepthModelIfNeeded() async {
        guard isAIDepthMode, let source = aiDepthSource else { return }
        let url = imageURL
        let map = await RAVEStillDepthEstimator.shared.depth(for: source, photoQuality: true)
        guard !Task.isCancelled, isAIDepthMode, imageURL == url, let map else { return }
        aiDepthMap = map
    }

    /// The existing resize debounce and resolution controls both enter here.
    /// Reuse the depth estimate: changing colour resolution doesn't change its UVs.
    func reloadAIDepthSourceIfNeeded() async {
        guard isAIDepthMode, !showsDebugPattern, let data = currentImageData else { return }
        let target = aiDepthTargetDimension()
        let ratio = Double(target) / Double(max(aiDepthSourceDimension, 1))
        guard target < aiDepthSourceDimension || ratio >= 1.2 else { return }
        let url = imageURL
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodeAIDepthSource(data, maxPixelSize: target)
        }.value
        guard !Task.isCancelled, isAIDepthMode, imageURL == url,
              aiDepthTargetDimension() == target, let decoded else { return }
        aiDepthSourceDimension = target
        aiDepthSource = decoded.image
        aiDepthHeadroom = decoded.headroom
    }

    /// Oriented, downsampled decode. An HDR photo comes back tone mapped to
    /// the display's headroom (`HDRStills`), with that headroom; SDR is 1.
    nonisolated static func decodeAIDepthSource(_ data: Data, maxPixelSize: Int) -> (image: CGImage, headroom: Float)? {
        guard let image = MetalImageRenderer.downsampledImage(from: data, maxDimension: CGFloat(maxPixelSize))?.cgImage else {
            return nil
        }
        return HDRStills.toneMappedImage(image) ?? (image, 1)
    }
}
