/*
 Hypnos - App Entry Point

 Vision Pro app for viewing photos with 2D to 3D spatial conversion, and its
 iPhone/iPad counterpart.

 The scene graph is the one thing the two platforms cannot share: visionOS
 gets a window per viewer plus two immersive spaces, iOS gets a single window
 whose `IOSRootView` layers the same viewers as full-screen covers (see
 `IOSWindowRouter`). Everything below the scene roots is common code.
 */

import DebugTrace
import DebugTraceServer
import DebugTraceUI
import RAVEMedia
import RAVESupport
import RAVEUI
import SwiftUI

import VideoToolbox

@main
struct HypnosApp: App {
    @State private var appModel: AppModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #else
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    /// Written out rather than left to a property initializer so the UI-testing
    /// overrides land *before* `AppModel.init` reads UserDefaults. A default
    /// value expression is evaluated ahead of the initializer body, so
    /// `appModel = AppModel()` as a default would win the race.
    init() {
        // Before anything logs. The bundle id comes first (it is
        // com.illixion.hypnos.debug in local builds); the rest are the
        // subsystems RAVEFilm, RAVEDeviceSetup and RAVESpatialAudio log under.
        let subsystems = [AppLogger.subsystem, "com.illixion.hypnos", "com.illixion.rave", "com.illixion.ravesdk"]
        DebugTrace.configure(.init(subsystems: subsystems.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }))
        DebugTraceServer.startIfRequested()
        FilmDebugEndpoints.register()
        VideoPlayerDebugEndpoints.register()
        OnScreenTextDebugEndpoints.register()
        PhotoStereoDebugEndpoints.register()
        InterpolationDebugEndpoints.register()
        #if DEBUG
        UITestingConfiguration.applyIfNeeded()
        DevJellyfinSignIn.performIfRequested()
        #endif
        #if DEBUG && os(macOS)
        LibraryHarness.runIfRequested()
        MusicHarness.runIfRequested()
        MusicPlaybackHarness.runIfRequested()
        #endif
        // Sideload builds: CoreRE reads some renderer overrides only once, when
        // its MXI manager starts, so they go in before anything RealityKit does.
        #if HYPNOS_PRIVATE_API && os(visionOS)
        PrivateSpatial3DTuningStore.installAtLaunch()
        #endif
        _appModel = State(initialValue: AppModel())
        // HDR photos decode off the main actor to the screen's headroom,
        // which is read on it: once now, then by every photo view.
        RAVEDisplayHeadroom.refresh()
        // Reconnects downloads that ran while the app was closed.
        LibraryDownloads.shared.start()
        #if DEBUG && os(macOS)
        LibraryDownloadHarness.runIfRequested()
        #endif
        // AVFoundation only decodes VP9/AV1 once the app opts in to the
        // supplemental decoders, and Stash/Jellyfin sources are commonly
        // WebM/VP9 (the original file, or a server transcode). Once, at
        // launch, matching TVLab/FilmLabTV/YouTubeLab.swift's spike. On every
        // platform: YouTube's HLS master is VP9 above 1080p and for all of
        // its HDR, and without this visionOS refused those variants
        // (AVFoundation -11848), so a 1440p pick fell through to WebKit
        // (2026-10-25; it used to be registered on tvOS and macOS only).
        if #available(tvOS 26.2, macOS 26.0, iOS 26.2, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
        #if DEBUG && os(macOS)
        RemuxHarness.runIfRequested()
        #endif
    }

    var body: some Scene {
        #if os(visionOS)
        visionOSScenes
        #elseif os(tvOS)
        tvOSScenes
        #elseif os(macOS)
        macOSScenes
        #else
        iOSScenes
        #endif
    }

    // MARK: - iOS

    #if os(iOS)
    private var iOSScenes: some Scene {
        // One window. With `UIApplicationSupportsMultipleScenes` on, iPadOS can
        // still open several instances of it side by side; each is a complete
        // gallery with its own cover stack.
        WindowGroup("Convolution", id: HypnosSceneID.main) {
            IOSRootView(appModel: appModel)
                .raveSupportWelcome(RAVESupportConfig(appName: "Convolution", appID: "com.illixion.hypnos"))
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSScenes: some Scene {
        // One window, like iOS — but a completely different root (see
        // Views/TV/TVRootView.swift and Hypnos/CLAUDE.md "tvOS"), not
        // `IOSRootView`'s cover-stack-over-a-touch-gallery shape.
        WindowGroup("Convolution", id: HypnosSceneID.main) {
            TVRootView(appModel: appModel)
                .raveSupportWelcome(RAVESupportConfig(appName: "Convolution", appID: "com.illixion.hypnos"))
        }
    }
    #endif

    // MARK: - visionOS

    #if os(visionOS)
    @SceneBuilder
    private var visionOSScenes: some Scene {
        HypnosWindows(appModel: appModel)

        // Every immersive space leaves a system environment (Mount Hood and
        // the rest) as it is rather than closing it (visionOS 26): mixed
        // spaces show around it, and the wearer is back in it after a full one.
        //
        // Mixed immersive space for the "Fully Immersive 3D" photo viewer mode.
        // Opened by PhotoDisplayView when AppModel.fullyImmersive3DMode is on
        // and the user enters Immersive 3D; passes the source image URL via
        // the standard ImmersiveSpace value channel.
        ImmersiveSpace(id: "Spatial3DImmersiveSpace", for: Spatial3DImmersiveValue.self) { value in
            if let value = value.wrappedValue {
                Spatial3DImmersiveView(value: value)
                    .environment(appModel)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .immersiveEnvironmentBehavior(.coexist)

        // The players' cinema: the film's object audio around the wearer's
        // head and, for Big Screen, a picture on a screen further and larger
        // than a window may go (see Views/Cinema/Cinema.swift).
        RAVEViewerHUDScene()

        ImmersiveSpace(id: Cinema.spaceID) {
            CinemaSpaceView().environment(appModel)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .immersiveEnvironmentBehavior(.coexist)

        // VR photos (180°, 360°, fisheye) around the wearer
        // (Views/Pictures/VRPhotoSpace.swift).
        ImmersiveSpace(id: VRPhotoPresenter.spaceID) {
            VRPhotoSpaceView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .immersiveEnvironmentBehavior(.coexist)
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    /// Real multiple windows, like visionOS, with the same window content:
    /// the gallery (`ContentView`, its tabs in a sidebar), a window per
    /// picture, video and slideshow, the shared-media viewer and the tool
    /// windows. No immersive spaces and no window manager: the Window menu
    /// and Mission Control do that job on a Mac.
    ///
    /// Only the gallery takes URLs (`hypnos://`, files opened with the app),
    /// opening one if none is open: left to itself SwiftUI would open a new
    /// window of whichever group it picked for each URL.
    @SceneBuilder
    private var macOSScenes: some Scene {
        WindowGroup("Convolution", id: HypnosSceneID.main) {
            ContentView()
                .environment(appModel)
                .frame(minWidth: 640, minHeight: 480)
                .handleIncomingMediaURLs(appModel: appModel)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .debugApprovalPrompts()
                .raveSupportWelcome(RAVESupportConfig(appName: "Convolution", appID: "com.illixion.hypnos"))
        }
        .defaultSize(width: 1280, height: 820)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            HypnosCommands(appModel: appModel)
        }

        WindowGroup("Picture", id: HypnosSceneID.photoDetail, for: PhotoWindowValue.self) { $windowValue in
            if let windowValue {
                PhotoWindowView(windowValue: windowValue, appModel: appModel, onSizeSettled: { size in
                    $windowValue.wrappedValue?.restoredSize = RAVECodableSize(size)
                })
                .environment(appModel)
                .viewerWindowChrome()
            } else {
                UnrestorableWindow()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 760)
        .handlesExternalEvents(matching: [])

        WindowGroup("Video", id: HypnosSceneID.videoDetail, for: VideoWindowValue.self) { $windowValue in
            if let windowValue, windowValue.video.opensInFilmPlayer {
                LocalDiscHandoffView(video: windowValue.video)
                    .environment(appModel)
            } else if let windowValue {
                VideoWindowView(windowValue: windowValue, appModel: appModel)
                    .environment(appModel)
                    .viewerWindowChrome()
            } else {
                UnrestorableWindow()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 700)
        .handlesExternalEvents(matching: [])

        WindowGroup("Shared Picture", id: HypnosSceneID.sharedPhoto, for: SharedMediaItem.self) { $item in
            if let item {
                SharedPhotoWindowView(item: item, appModel: appModel)
                    .environment(appModel)
                    .viewerWindowChrome()
            } else {
                UnrestorableWindow()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 760)
        .handlesExternalEvents(matching: [])

        // Slideshows of the app's own pictures or videos.
        WindowGroup("Slideshow", id: HypnosSceneID.remoteViewer, for: RemoteViewerWindowValue.self) { $windowValue in
            if let windowValue {
                RemoteViewerWindowView(windowValue: windowValue, onSizeSettled: { size in
                    $windowValue.wrappedValue?.restoredSize = RAVECodableSize(size)
                })
                .environment(appModel)
                .frame(minWidth: RemoteViewerWindowView.minimumWindowSize.width,
                       minHeight: RemoteViewerWindowView.minimumWindowSize.height)
                .viewerWindowChrome()
            } else {
                UnrestorableWindow()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .handlesExternalEvents(matching: [])

        // Film player: picture plus object audio (Settings → Developer →
        // Film Player), without head tracking on a Mac.
        Window("Film Player", id: FilmPlayerView.windowID) {
            FilmPlayerView()
                .environment(appModel)
        }
        .defaultSize(width: 900, height: 800)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        Window("Adjustments", id: HypnosSceneID.videoAdjustments) {
            VideoAdjustmentsWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 380, height: 640)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        // The music mini player (iTunes's): cover, song and transport, small enough to park beside other work.
        Window("Mini Player", id: MusicMiniPlayerWindowView.windowID) {
            MusicMiniPlayerWindowView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        // The music visualizer: the queue's album art as Cover Flow. A window of its own, so it can go full screen.
        Window("Visualizer", id: MusicVisualizerView.windowID) {
            MusicVisualizerView(presentation: .window)
        }
        .defaultSize(width: 1100, height: 720)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        Window("Console", id: HypnosSceneID.console) {
            ConsoleWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 900, height: 600)
        .handlesExternalEvents(matching: [])

        Window("GPU Memory", id: HypnosSceneID.gpuMemory) {
            GPUMemoryMonitorView()
                .environment(appModel)
        }
        .defaultSize(width: 500, height: 350)
        .handlesExternalEvents(matching: [])

        // The debug server's "Allow debug access?" prompt, which the gallery
        // opens (`debugApprovalPrompts`).
        DebugApprovalWindow()
    }
    #endif
}

