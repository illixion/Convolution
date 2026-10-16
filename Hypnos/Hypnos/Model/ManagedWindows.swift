/*
 Hypnos - Managed Window Descriptors

 Describes each of the app's scenes to RAVEUI's window manager: what it is
 called in the Windows tab, and how to recreate it. The registry, the summon
 mechanics and the manager UI all live in `RAVEUI`; this file is only the app's
 half — its labels and its fresh-identity clones.

 Recreation is what makes Summon work. A summoned window is not recalled, it is
 recycled: its scene is destroyed and an equivalent one opened at the user (see
 RAVEWindowManager.swift for why a recall is the wrong move on visionOS 27).
 Cloning under a **new** window id is what lets the dismiss and the open be
 issued in the same turn without the fresh window matching the dying scene.
 */

import Foundation
import RAVEUI

#if os(visionOS)

// MARK: - Fresh-identity clones

extension PhotoWindowValue {
    /// Same image under a fresh window identity. `wasPushed` is dropped — a
    /// recreated window has no originating gallery window to pop back to, so it
    /// takes the standalone chrome (gallery button) instead.
    func recreated() -> PhotoWindowValue {
        var value = PhotoWindowValue(image: image, wasPushed: false)
        value.restoredSize = restoredSize
        return value
    }
}

extension VideoWindowValue {
    /// Same video and 3D state under a fresh window identity (see
    /// `PhotoWindowValue.recreated`).
    func recreated() -> VideoWindowValue {
        var value = VideoWindowValue(
            video: video,
            galleryVideos: galleryVideos,
            stereoscopicOverride: stereoscopicOverride,
            video3DSettings: video3DSettings,
            pseudo3DEnabled: pseudo3DEnabled,
            pseudo3DSettings: pseudo3DSettings,
            wasPushed: false
        )
        value.restoredSize = restoredSize
        return value
    }
}

extension RemoteViewerWindowValue {
    /// Same profile under a fresh window identity.
    func recreated() -> RemoteViewerWindowValue {
        var value = RemoteViewerWindowValue(configId: configId)
        value.restoredSize = restoredSize
        return value
    }
}

// MARK: - Descriptors

enum ManagedWindows {
    @MainActor
    static func main(_ windowId: UUID) -> RAVEManagedWindow {
        .value(
            id: "main",
            windowId,
            label: RAVEWindowLabel(title: "Gallery", systemImage: "square.grid.2x2"),
            recreate: { _ in UUID() }
        )
    }

    @MainActor
    static func photo(_ value: PhotoWindowValue) -> RAVEManagedWindow {
        .value(
            id: "photo-detail",
            value,
            label: RAVEWindowLabel(
                title: "Photo",
                subtitle: value.image.title ?? value.image.fileName
                    ?? value.image.fullSizeURL.lastPathComponent,
                systemImage: "photo"
            ),
            recreate: { $0.recreated() }
        )
    }

    @MainActor
    static func video(_ value: VideoWindowValue) -> RAVEManagedWindow {
        .value(
            id: "video-detail",
            value,
            label: RAVEWindowLabel(
                title: "Video",
                subtitle: value.video.title ?? value.video.streamURL.lastPathComponent,
                systemImage: "play.rectangle"
            ),
            recreate: { $0.recreated() }
        )
    }

    /// Shared media has no separable window identity — the item *is* the value
    /// the scene is keyed by — so this one reopens verbatim and waits for the
    /// old scene to disconnect first.
    @MainActor
    static func sharedPhoto(_ item: SharedMediaItem) -> RAVEManagedWindow {
        .value(
            id: "shared-photo",
            item,
            label: RAVEWindowLabel(
                title: "Shared Photo",
                subtitle: item.originalFileName,
                systemImage: "square.and.arrow.down"
            )
        )
    }

    @MainActor
    static func remoteViewer(_ value: RemoteViewerWindowValue, appModel: AppModel) -> RAVEManagedWindow {
        .value(
            id: "remote-viewer",
            value,
            label: RAVEWindowLabel(
                title: "Slideshow",
                subtitle: appModel.remoteViewerConfig(id: value.configId)?.name,
                systemImage: "play.square.stack"
            ),
            recreate: { $0.recreated() }
        )
    }

    @MainActor
    static func console() -> RAVEManagedWindow {
        .singleton(id: "console", label: RAVEWindowLabel(title: "Console", systemImage: "terminal"))
    }

    @MainActor
    static func gpuMemory() -> RAVEManagedWindow {
        .singleton(id: "gpu-memory", label: RAVEWindowLabel(title: "GPU Memory", systemImage: "memorychip"))
    }

    @MainActor
    static func videoAdjustments() -> RAVEManagedWindow {
        .singleton(
            id: "video-adjustments",
            label: RAVEWindowLabel(title: "Adjustments", systemImage: "slider.horizontal.3")
        )
    }
}

#endif
