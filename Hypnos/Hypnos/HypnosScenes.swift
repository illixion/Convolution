//
//  HypnosScenes.swift
//  Hypnos
//
//  The visionOS app's windows as one `Scene`, so they can be declared by this app and by Nexus,
//  which runs the app beside others as a module of one process (`~/Projects/Nexus`,
//  docs/nexus-module.md). The immersive spaces are not here: this app declares its own
//  (HypnosApp.swift), and in Nexus the cinema's and the photo viewer's content is mounted into the
//  host's shared space instead.
//

#if os(visionOS)

import DebugTrace
import DebugTraceServer
import DebugTraceUI
import RAVESupport
import RAVEUI
import SwiftUI

struct HypnosWindows: Scene {
    let appModel: AppModel

    @SceneBuilder
    var body: some Scene {
        // Main gallery window — WindowGroup allows multiple instances.
        // UUID identity ensures each openWindow call creates a new window.
        WindowGroup("Convolution", id: HypnosSceneID.main, for: UUID.self) { $windowId in
            // Main windows are managed too (inside `MainWindowView`): the app
            // opens several, and one parked in another room is exactly what the
            // Windows tab is for. Each tab lists every main window but its own.
            MainWindowView(appModel: appModel, windowId: windowId)
                .handleIncomingMediaURLs(appModel: appModel)
                .raveSupportWelcome(RAVESupportConfig(appName: "Convolution", appID: "com.illixion.hypnos"))
                .debugApprovalPrompts()
        } defaultValue: {
            UUID()
    }
    .defaultSize(width: 1200, height: 800)
    .raveWindowPushPlacement(id: HypnosSceneID.main)
    .windowResizability(.contentMinSize)
    .windowStyle(.plain)
    #if NEXUS_MODULE
    // Nexus's Home is the scene shown at launch.
    .defaultLaunchBehavior(.suppressed)
    #else
    .defaultLaunchBehavior(.presented)
    #endif

    // Individual photo window - supports multiple pop-out instances
    WindowGroup(id: HypnosSceneID.photoDetail, for: PhotoWindowValue.self) { $windowValue in
        if let windowValue = windowValue {
            PhotoWindowView(windowValue: windowValue, appModel: appModel, onSizeSettled: { size in
                $windowValue.wrappedValue?.restoredSize = RAVECodableSize(size)
            })
                .environment(appModel)
                .captureOpenWindowAction()
                .handleIncomingMediaURLs(appModel: appModel)
                .debugApprovalPrompts()
                .manageWindow(ManagedWindows.photo(windowValue))
                .raveWindowPushHost(sceneID: HypnosSceneID.photoDetail, value: windowValue)
        }
    }
    .windowStyle(.plain)
    .defaultSize(width: 1200, height: 900)
    .raveWindowPushPlacement(id: HypnosSceneID.photoDetail)
    .defaultLaunchBehavior(.suppressed)

    // Individual video window - pop-out video player
    WindowGroup(id: HypnosSceneID.videoDetail, for: VideoWindowValue.self) { $windowValue in
        if let windowValue, windowValue.video.opensInFilmPlayer {
            LocalDiscHandoffView(video: windowValue.video)
                .environment(appModel)
        } else if let windowValue = windowValue {
            VideoWindowView(windowValue: windowValue, appModel: appModel)
                .environment(appModel)
                .captureOpenWindowAction()
                .handleIncomingMediaURLs(appModel: appModel)
                .debugApprovalPrompts()
                .manageWindow(ManagedWindows.video(windowValue))
                .raveWindowPushHost(sceneID: HypnosSceneID.videoDetail, value: windowValue)
        }
    }
    .windowStyle(.plain)
    .defaultSize(width: 1200, height: 700)
    .raveWindowPushPlacement(id: HypnosSceneID.videoDetail)
    .defaultLaunchBehavior(.suppressed)

    // Shared photo viewer - opens when image is shared to the app
    WindowGroup(id: HypnosSceneID.sharedPhoto, for: SharedMediaItem.self) { $item in
        if let item = item {
            SharedPhotoWindowView(item: item, appModel: appModel)
                .environment(appModel)
                .captureOpenWindowAction()
                .handleIncomingMediaURLs(appModel: appModel)
                .manageWindow(ManagedWindows.sharedPhoto(item))
        }
    }
    .windowStyle(.plain)
    .defaultSize(width: 1200, height: 900)
    .defaultLaunchBehavior(.suppressed)

    // Shared videos are routed to the "video-detail" scene above (rich
    // pipeline: native-Metal playback, fake-3D, adjustments). The old flat
    // "shared-video" group is gone — nothing opened it, and a second
    // WindowGroup taking the same `SharedMediaItem` payload made scene
    // restoration ambiguous between it and "shared-photo".

    // Pop-out debug console window (singleton)
    Window("Console", id: HypnosSceneID.console) {
        ConsoleWindowView()
            .environment(appModel)
            .captureOpenWindowAction()
            .handleIncomingMediaURLs(appModel: appModel)
            .manageWindow(ManagedWindows.console())
    }
    .defaultSize(width: 900, height: 600)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.suppressed)

    // GPU memory monitor window (singleton)
    Window("GPU Memory", id: HypnosSceneID.gpuMemory) {
        GPUMemoryMonitorView()
            .environment(appModel)
            .captureOpenWindowAction()
            .handleIncomingMediaURLs(appModel: appModel)
            .manageWindow(ManagedWindows.gpuMemory())
    }
    .defaultSize(width: 500, height: 350)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.suppressed)

    // Video adjustments — standalone, repositionable window for the active
    // video window's Adjustments (avoids overlapping the fake-3D video).
    Window("Adjustments", id: HypnosSceneID.videoAdjustments) {
        VideoAdjustmentsWindowView()
            .environment(appModel)
            .captureOpenWindowAction()
            .handleIncomingMediaURLs(appModel: appModel)
            .manageWindow(ManagedWindows.videoAdjustments())
    }
    .defaultSize(width: 380, height: 640)
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)

    // Slideshow of the app's own pictures or videos. The scene id keeps its
    // original spelling: visionOS restores open windows by it.
    WindowGroup(id: HypnosSceneID.remoteViewer, for: RemoteViewerWindowValue.self) { $windowValue in
        if let windowValue = windowValue {
            RemoteViewerWindowView(windowValue: windowValue, onSizeSettled: { size in
                $windowValue.wrappedValue?.restoredSize = RAVECodableSize(size)
            })
                .environment(appModel)
                .captureOpenWindowAction()
                .handleIncomingMediaURLs(appModel: appModel)
                .manageWindow(ManagedWindows.remoteViewer(windowValue, appModel: appModel))
                // Structural floor. This view's root is a GeometryReader,
                // which has no intrinsic size and greedily accepts whatever
                // it's proposed — during restoration of a window the
                // compositor hasn't placed yet, that proposal can be the
                // 10x10 default. Without a minimum the window collapses to
                // nothing, and the size write-back then persists the
                // collapsed geometry. The main window group has had this
                // floor all along; the viewer was the one scene without it.
                .frame(
                    minWidth: RemoteViewerWindowView.minimumWindowSize.width,
                    minHeight: RemoteViewerWindowView.minimumWindowSize.height
                )
        }
    }
    .windowStyle(.plain)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1400, height: 900)
    .defaultLaunchBehavior(.suppressed)

    // The debug server's "Allow debug access?" / "Allow code changes?"
    // prompt, in a window of its own: the system alert it would otherwise
    // use attaches to the frontmost window, where a 3D video's content
    // stands in front of it and hides it.
#if !NEXUS_MODULE
    DebugApprovalWindow()
#endif

    // Film player: picture plus Atmos objects as spatial sources around
    // this window (Settings → Developer → Film Player). Opened with a
    // loaded film, so it never restores on its own.
    Window("Film Player", id: FilmPlayerView.windowID) {
        FilmPlayerView()
            .environment(appModel)
            .raveWindowPushHost(sceneID: FilmPlayerView.windowID)
    }
    .windowStyle(.plain)
    .defaultSize(width: 1280, height: 720)
    .raveWindowPushPlacement(id: FilmPlayerView.windowID)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    // Debug: the film's picture through Apple's renderers, beside the
    // film player (the `filmCompare` debug command).
    // The music mini player: a small glass panel to park beside other windows.
    Window("Mini Player", id: MusicMiniPlayerWindowView.windowID) {
        MusicMiniPlayerWindowView()
    }
    .windowStyle(.plain)
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    Window("Picture Compare", id: PictureCompare.windowID) {
        PictureCompareView()
    }
    .windowStyle(.plain)
    .defaultSize(width: 1280, height: 580)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    Window("Sound and Picture", id: FilmAdjustmentsView.windowID) {
        FilmAdjustmentsView()
    }
    .defaultSize(width: 900, height: 640)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    }
}

/// Wrapper view for the main window that handles shared media URLs
struct MainWindowView: View {
    let appModel: AppModel
    /// The scene's presented value. Unreachable as nil in practice — the group
    /// declares a `defaultValue` — but the binding is optional, so the window
    /// manager needs an identity that survives body re-evaluation either way:
    /// a fresh `UUID()` per evaluation would leave Close addressing a value no
    /// scene holds.
    let windowId: UUID?
    @State private var fallbackWindowId = UUID()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environment(appModel)
            .raveRetainedWindowContent(sceneID: HypnosSceneID.main, value: windowId ?? fallbackWindowId)
            .frame(minWidth: 320, maxWidth: 3000, minHeight: 320, maxHeight: 3000)
            .registerAsMainWindow()
            .manageWindow(ManagedWindows.main(windowId ?? fallbackWindowId))
            // Park the live gallery hierarchy while a viewer is open. Return
            // reattaches it to a fresh shell at the user, preserving the grid.
            .raveWindowPushHost(sceneID: HypnosSceneID.main, value: windowId ?? fallbackWindowId)
            .onAppear {
                RAVEWindowSessionRegistry.shared.openWindow = openWindow
            }
    }
}
#endif
