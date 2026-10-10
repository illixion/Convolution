/*
 Hypnos - MV-HEVC conversion settings for a library video

 The converter is Vergence's (VergenceApple); these build its config from a
 `GalleryVideo` and the user's 3D settings.
 */

#if !os(tvOS)
import RAVEMedia

extension MVHEVCConversionConfig {
    /// Create config from video properties
    static func from(
        video: GalleryVideo,
        format: StereoscopicFormat,
        frameRate: Double = 30.0
    ) -> MVHEVCConversionConfig {
        let sourceWidth = video.sourceWidth ?? 3840
        let sourceHeight = video.sourceHeight ?? 1080

        let (perEyeWidth, perEyeHeight) = format.perEyeDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        return MVHEVCConversionConfig(
            format: format,
            outputWidth: perEyeWidth,
            outputHeight: perEyeHeight,
            frameRate: frameRate,
            eyesReversed: video.eyesReversed
        )
    }

    /// Create config from video and custom 3D settings
    static func from(
        video: GalleryVideo,
        settings: Video3DSettings,
        frameRate: Double = 30.0
    ) -> MVHEVCConversionConfig {
        let sourceWidth = video.sourceWidth ?? 3840
        let sourceHeight = video.sourceHeight ?? 1080

        let (perEyeWidth, perEyeHeight) = settings.format.perEyeDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        return MVHEVCConversionConfig(
            format: settings.format,
            outputWidth: perEyeWidth,
            outputHeight: perEyeHeight,
            frameRate: frameRate,
            horizontalFieldOfView: settings.horizontalFieldOfView,
            horizontalDisparityAdjustment: settings.horizontalDisparityAdjustment,
            eyesReversed: settings.eyesReversed
        )
    }
}
#endif
