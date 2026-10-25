/*
 Hypnos - opening a slideshow's model

 What a slideshow needs when its window opens, for both the slideshow window
 (`RemoteViewerWindowView`) and tvOS's full-screen slideshow
 (`TVSlideshowView`): the window's profile, the source the play button
 parked for it, profile changes merged back, and the app told about it.
 */

import DebugTrace
import Foundation

extension RemoteViewerModel {
    /// A started model for `windowValue`'s profile, or nil when the profile
    /// is gone. `resolutionCap` bounds the profile's picture sizes (a TV
    /// shows 4K at most); with `allows3D` false every profile plays flat.
    static func open(for windowValue: RemoteViewerWindowValue, appModel: AppModel, windowSize: CGSize,
                     resolutionCap: Int = .max, allows3D: Bool = true) -> RemoteViewerModel? {
        // The gallery or video slideshow profile this window was opened for.
        guard let config = appModel.remoteViewerConfig(id: windowValue.configId) else {
            AppLogger.remoteViewer.error("No config found for id \(windowValue.configId.uuidString, privacy: .public)")
            return nil
        }

        let model = RemoteViewerModel(config: config)
        model.globalAdjustments = appModel.globalVisualAdjustments
        model.reduceMotion = appModel.effectiveReduceMotion
        // Per-profile slideshow resolution caps fall back to the slideshow
        // defaults, which themselves default to 4096px.
        let resolved2D = min(config.maxImageResolution2D ?? appModel.slideshowMaxImageResolution2D, resolutionCap)
        let resolved3D = allows3D
            ? min(config.maxImageResolution3D ?? appModel.slideshowMaxImageResolution3D, resolutionCap)
            : resolved2D
        let mode3D: Slideshow3DMode = allows3D ? config.slideshow3DMode : .off
        model.maxImageResolution = resolved2D
        model.maxImageResolution3D = resolved3D
        model.slideshow3DMode = mode3D
        model.updateWindowAspectRatio(windowSize)

        // The play button parks the live source in a transient override right
        // before opening the window.
        if let videoOverride = appModel.pendingVideoSlideshowSource,
           appModel.videoSlideshowConfig?.id == config.id {
            appModel.pendingVideoSlideshowSource = nil
            model.contentProvider = VideoSlideshowContentProvider(
                videoSource: videoOverride.videoSource,
                filter: videoOverride.filter
            )
        } else if let override = appModel.pendingGallerySlideshowSource {
            appModel.pendingGallerySlideshowSource = nil
            model.contentProvider = GalleryContentProvider(
                imageSource: override.imageSource,
                filter: override.filter
            )
        } else {
            // No override: a window group restored this slideshow at
            // launch, long after the source that started it was handed
            // over. The app-wide source and filter is the closest thing to
            // what it was showing.
            model.contentProvider = GalleryContentProvider(
                imageSource: appModel.imageSource,
                filter: appModel.currentFilter
            )
        }

        model.onConfigChanged = { [appModel] updatedConfig in
            // `updatedConfig` is this window's snapshot from when it opened
            // plus whatever the ornament just changed. Merge the viewer-owned
            // display fields onto whatever the profile looks like now, so two
            // windows of one profile don't revert each other's changes.
            guard var current = appModel.remoteViewerConfig(id: updatedConfig.id) else {
                appModel.persistRemoteViewerConfig(updatedConfig)
                return
            }
            current.applyViewerDisplaySettings(from: updatedConfig)
            appModel.persistRemoteViewerConfig(current)
        }

        model.windowValue = windowValue
        appModel.registerRemoteViewerWindow(configId: config.id, windowValue: windowValue)
        appModel.registerRemoteViewerModel(model)
        model.useRAVESlideshowForLocalContent(
            mode3D: mode3D.raveMode,
            maxImageResolution2D: resolved2D,
            maxImageResolution3D: resolved3D
        )
        model.start()
        return model
    }
}
