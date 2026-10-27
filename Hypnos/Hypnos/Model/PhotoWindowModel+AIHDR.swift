import CoreGraphics
import DebugTrace
import Foundation

/// AI HDR: an SDR photo shown with a generated gain map (`GainMapHDR`).
/// The flat picture and AI 3D's source both decode through it, so the rest
/// of the HDR path (`HDRStills`) is the one real HDR photos take.
extension PhotoWindowModel {
    /// Turn AI HDR on or off for this window and redraw the picture. The
    /// choice becomes the next window's default.
    func toggleAIHDR() async {
        await setAIHDR(!aiHDREnabled)
    }

    func setAIHDR(_ enabled: Bool) async {
        guard enabled != aiHDREnabled else { return }
        aiHDREnabled = enabled
        UserDefaults.standard.set(enabled, forKey: GainMapHDR.enabledKey)
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
