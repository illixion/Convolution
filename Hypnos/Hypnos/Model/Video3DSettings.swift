/*
 Hypnos - Video 3D Settings

 Model for storing user-selected 3D conversion settings per video.
 */

import Foundation
import RAVEMedia

/// User-configurable settings for 3D video conversion
struct Video3DSettings: Codable, Equatable, Hashable {
    /// The stereoscopic format (SBS, HSBS, OU, HOU)
    let format: StereoscopicFormat

    /// Whether the left/right eyes are swapped in the source video
    let eyesReversed: Bool

    /// Horizontal field of view in degrees (typically 90)
    let horizontalFieldOfView: Float

    /// Horizontal disparity adjustment for depth (typically 0-400)
    let horizontalDisparityAdjustment: Float

    /// Default settings for a given format
    static func defaults(for format: StereoscopicFormat) -> Video3DSettings {
        Video3DSettings(
            format: format,
            eyesReversed: false,
            horizontalFieldOfView: 90.0,
            horizontalDisparityAdjustment: 200.0
        )
    }

    /// Create settings from a GalleryVideo's tag-detected properties
    static func from(video: GalleryVideo) -> Video3DSettings? {
        guard let format = video.stereoscopicFormat else { return nil }
        return Video3DSettings(
            format: format,
            eyesReversed: video.eyesReversed,
            horizontalFieldOfView: 90.0,
            horizontalDisparityAdjustment: 200.0
        )
    }

    /// How this video packs its eyes, for live playback in the stereo pump.
    var packedLayout: RAVEPackedStereoLayout {
        format.packedLayout(eyesReversed: eyesReversed)
    }

    /// Generate a cache key component from all settings
    /// This ensures different settings produce different cache entries
    var cacheKey: String {
        let eyeFlag = eyesReversed ? "r" : "n"
        let fov = Int(horizontalFieldOfView)
        let disp = Int(horizontalDisparityAdjustment)
        return "\(format.rawValue)_\(eyeFlag)_\(fov)_\(disp)"
    }
}
