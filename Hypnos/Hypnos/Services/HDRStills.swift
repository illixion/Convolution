/*
 Hypnos - HDR Stills

 HDR photos (an iPhone's gain-map HEIC, an ISO 21496 gain map, a PQ or HLG
 still) decode to extended-range linear colour, where 1.0 is SDR white and
 the brightest highlight sits at the image's content headroom (often 4-8x).

 No API reports the display's headroom, so it was measured in a photo
 window on the device (2026-10-27, `photoHDRTest`): small dots keep getting
 brighter up to about 3-4x SDR white, and window-filling bars stop at about
 2.5-3x (a brightness limiter). Oneiros's immersive test found one stop
 (compositor-metal4-backend.md), which may be a different path. Highlights are
 tone mapped down to `targetHeadroom` with Core Image's headroom tone map,
 which keeps everything well below the peak as it was. SDR photos decode
 exactly as before.

 `photoHDR` (default on) and `photoHDRHeadroom` are UserDefaults keys the
 debug server sets for A/B checks on the device. The decode and tone map
 themselves are RAVEMedia's `RAVEHDRStill`, shared with the other apps.
 */

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import RAVEMedia

enum HDRStills {
    static let enabledKey = "photoHDR"
    static let headroomKey = "photoHDRHeadroom"

    /// Off only when the debug server has turned it off.
    static var isEnabled: Bool {
        HypnosDefaults.store.object(forKey: enabledKey) as? Bool ?? true
    }

    /// How far above SDR white the display goes, as a multiple of it.
    static var targetHeadroom: Float {
        let stored = HypnosDefaults.store.float(forKey: headroomKey)
        return stored >= 1 ? stored : 2.5
    }

    /// Options asking ImageIO for the HDR rendition (gain map applied, PQ/HLG
    /// expanded). An SDR source decodes to the same pixels as without it.
    static func decodeOptions(_ options: [CFString: Any]) -> [CFString: Any] {
        guard isEnabled else { return options }
        return RAVEHDRStill.decodeOptions(options)
    }

    /// True when an enabled HDR decode will apply a gain map to `source`.
    static func hasGainMap(_ source: CGImageSource) -> Bool {
        guard isEnabled else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    /// The headroom `image` will be shown with: 1 for SDR, otherwise its own
    /// headroom capped at the display's.
    static func displayHeadroom(of image: CGImage) -> Float {
        let content = Float(image.contentHeadroom)
        guard isEnabled, content > 1 else { return 1 }
        return min(content, targetHeadroom)
    }

    /// `image` as Core Image input, its highlights brought within the
    /// display's headroom. Nil for an SDR image (use it as it is).
    static func toneMapped(_ image: CGImage) -> (image: CIImage, headroom: Float)? {
        guard isEnabled else { return nil }
        return RAVEHDRStill.toneMapped(image, headroom: targetHeadroom)
    }

    /// `toneMapped` baked into a half-float, extended linear P3 bitmap, for
    /// consumers that take a CGImage (AI 3D). Its headroom travels beside it:
    /// a rendered CGImage no longer reports one.
    static func toneMappedImage(_ image: CGImage) -> (image: CGImage, headroom: Float)? {
        guard isEnabled, let baked = RAVEHDRStill.toneMappedImage(image, headroom: targetHeadroom) else { return nil }
        return (baked.image, baked.headroom)
    }
}
