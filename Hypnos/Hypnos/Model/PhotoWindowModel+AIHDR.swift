import CoreGraphics
import DebugTrace
import Foundation

/// AI HDR: an SDR photo shown with a generated gain map (`GainMapHDR`).
/// The flat picture and AI 3D's source both decode through it, so the rest
/// of the HDR path (`HDRStills`) is the one real HDR photos take.
///
/// A per-image choice, like the other enhancements: an image without one
/// follows Settings → Photos → AI HDR (`AppModel.aiHDRByDefault`). RealityKit
/// 3D can't show it, so the toggle isn't offered there.
extension PhotoWindowModel {
    /// Turn AI HDR on or off for this image and redraw the picture.
    func toggleAIHDR() async {
        await setAIHDR(!aiHDREnabled)
    }

    func setAIHDR(_ enabled: Bool) async {
        guard enabled != aiHDREnabled, PlatformCapabilities.supportsAIHDR, !isRealityKitDisplay else { return }
        aiHDREnabled = enabled
        if appModel.rememberImageEnhancements {
            await ImageEnhancementTracker.shared.setAIHDR(url: imageURL, enabled: enabled, default: appModel.aiHDRByDefault)
        }
        guard !showsDebugPattern else { return }
        isProcessingAIHDR = true
        defer { isProcessingAIHDR = false }
        // Forget the texture's resolution so the load doesn't keep it as
        // "close enough"; it stays on screen until the new one is ready.
        if let key = displayTextureCacheKey {
            SharedTextureCache.shared.release(key: key)
            displayTextureCacheKey = nil
        }
        currentDisplayMaxDimension = 0
        await loadDisplayImage(for: lastWindowSize ?? appModel.mainWindowSize)
        if isAIDepthMode {
            aiDepthSourceDimension = 0
            await reloadAIDepthSourceIfNeeded()
        }
    }

    /// Take this image's own AI HDR choice, or the default. Called before its
    /// picture is first decoded, so nothing reloads.
    func restoreAIHDRPreference() async {
        guard PlatformCapabilities.supportsAIHDR else {
            aiHDREnabled = false
            return
        }
        let saved = appModel.rememberImageEnhancements
            ? await ImageEnhancementTracker.shared.aiHDR(url: imageURL) : nil
        aiHDREnabled = saved ?? appModel.aiHDRByDefault
    }

    /// `image` with its generated gain map, or nil when it is HDR already,
    /// transparent, gains nothing, or the model can't run.
    nonisolated static func aiHDRImage(from image: CGImage, key: String) -> CGImage? {
        guard let result = GainMapHDR.shared.hdrImage(from: image, key: key) else { return nil }
        if result.inferenceMilliseconds > 0 {
            AppLogger.photoWindow.info(
                "AI HDR gain map in \(Int(result.inferenceMilliseconds), privacy: .public) ms, headroom \(result.headroom, format: .fixed(precision: 2), privacy: .public)"
            )
        }
        return result.image
    }
}
