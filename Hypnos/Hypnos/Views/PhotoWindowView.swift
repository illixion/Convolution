/*
 Hypnos - Photo Window View

 Window view for displaying individual photos.
 Handles two modes:
 - Pushed (wasPushed=true): opened via pushWindow from gallery, dismiss returns to gallery
 - Standalone (wasPushed=false): opened via openWindow as independent pop-out window
 Uses PhotoDisplayView for rendering and PhotoOrnamentView for controls.
 */

import DebugTrace
import RAVEUI
import SwiftUI

struct PhotoWindowView: View {
    let wasPushed: Bool
    private let popOutWindowID: UUID?
    /// User's persisted custom window size from the restoration archive (nil on fresh opens)
    private let restoredSize: CGSize?
    /// Writes the resolved window size back into the Codable window value for scene restoration
    private let onSizeSettled: (CGSize) -> Void
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow

    @State private var pendingPopOutImage: GalleryImage? = nil
    @State private var showDuplicateWindowAlert: Bool = false
    @State private var showRestorationPlaceholder: Bool = false
    @State private var metalRendererGeneration = 0
    @State private var renderRecoveryAttempt = 0
    @State private var renderRecoveryTask: Task<Void, Never>?

    init(windowValue: PhotoWindowValue, appModel: AppModel, onSizeSettled: @escaping (CGSize) -> Void = { _ in }) {
        self.wasPushed = windowValue.wasPushed
        self.popOutWindowID = windowValue.wasPushed ? nil : windowValue.id
        self.restoredSize = windowValue.restoredSize?.cgSize
        // Mirror the settled size into RestoredWindowTracker as well as the
        // scene archive. It's the store every window type writes to, so it's
        // where "save the current window arrangement" reads live geometry from
        // — and it doubles as a fallback if the archive round-trip drops the
        // mutated window value.
        let trackedWindowID: UUID? = windowValue.wasPushed ? nil : windowValue.id
        if let id = trackedWindowID {
            self.onSizeSettled = { size in
                if WindowSizePersistence.isPlausible(size) {
                    RestoredWindowTracker.setWindowSize(size, for: id)
                }
                onSizeSettled(size)
            }
        } else {
            self.onSizeSettled = onSizeSettled
        }
        // Re-resolve local file URLs in case this is a visionOS scene restoration
        // where the sandbox container UUID has changed since the window was saved.
        let resolvedImage = windowValue.image.resolvingLocalFileURL()
        _windowModel = State(initialValue: PhotoWindowModel(
            image: resolvedImage,
            appModel: appModel,
            // Only register as pop-out for standalone windows (not pushed)
            // so pushed windows don't trigger duplicate detection against themselves
            popOutWindowValue: windowValue.wasPushed ? nil : windowValue
        ))
    }

    var body: some View {
        ZStack {
            if showRestorationPlaceholder, let popOutWindowID {
                WindowRestorationPlaceholder(
                    title: "Restoring Photo",
                    windowID: popOutWindowID,
                    status: photoRestorationStatus
                )
            }

            PhotoDisplayView(
                windowModel: windowModel,
                enableSwipeNavigation: true,
                restoredSize: wasPushed ? nil : restoredSize,
                onSizeSettled: wasPushed ? nil : onSizeSettled,
                onFirstFramePresented: markContentPresented,
                metalRendererGeneration: metalRendererGeneration,
                onMetalRenderStalled: recoverStalledRenderer
            )
        }
        .opacity(appModel.allWindowsHidden ? 0 : 1)
        .persistentSystemOverlays(windowModel.isWindowControlsHidden ? .hidden : .visible)
        .hidesStatusBar(windowModel.isUIHidden)
        .ornament(
            visibility: windowModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            contentAlignment: .top,
            ornament: {
                PhotoOrnamentView(
                    windowModel: windowModel,
                    context: wasPushed ? .pushedFromGallery : .standalone,
                    onGalleryButtonTap: {
                        appModel.showMainWindow(openWindow: openWindow)
                    },
                    extraMenuItems: {
                        if wasPushed {
                            Button {
                                let image = windowModel.image
                                let state = appModel.existingWindowState(for: image.fullSizeURL)
                                switch state {
                                case .backgroundedInOtherRoom(let existingValue):
                                    openWindow(id: "photo-detail", value: existingValue)
                                    dismissWindow()
                                case .activeInCurrentRoom:
                                    pendingPopOutImage = image
                                    showDuplicateWindowAlert = true
                                case .none:
                                    // Hand the generated Spatial3DImage to the
                                    // window that is about to open, so it opens
                                    // in 3D immediately instead of decoding and
                                    // regenerating the same depth scene. The
                                    // deposit must land before the dismiss —
                                    // cleanup() releases this window's reference.
                                    Task {
                                        await windowModel.depositSpatial3DForHandoff()
                                        appModel.enqueuePhotoWindowOpen(image)
                                        dismissWindow()
                                    }
                                }
                            } label: {
                                Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.forward")
                            }
                            .disabled(windowModel.controlsLocked)
                        }
                    }
                )
                .offset(z: windowModel.isDioramaMode ? 30 : 0)
            }
        )
        .onAppear {
            appModel.lastViewedImageId = windowModel.image.id
            // Wall-snapped pop-outs restored by visionOS after a reboot come
            // back with the same Codable windowValue UUID. Treat repeat
            // appearances as system-restored and suppress global viewing-mode
            // defaults so a "default to 3D" setting doesn't blow the memory
            // budget across many windows. Keep the ornament visible until the
            // normal image-load completion path arms auto-hide.
            let isRestored = popOutWindowID.map(RestoredWindowTracker.isRestored) ?? false
            if isRestored {
                windowModel.isRestoredPopOut = true
                showRestorationPlaceholder = true
                if let popOutWindowID {
                    AppLogger.windowState.info(
                        "[Photo \(popOutWindowID.uuidString, privacy: .public)] restored view appeared image=\(windowModel.imageURL.loggableDescription) savedSize=\(String(describing: restoredSize), privacy: .public)"
                    )
                }
            } else if let id = popOutWindowID {
                RestoredWindowTracker.markSeen(id)
            }
            windowModel.start()
            if !isRestored {
                windowModel.startAutoHideTimer()
            }
        }
        .onDisappear {
            renderRecoveryTask?.cancel()
            windowModel.cleanup()
        }
        .alert(
            "Window Already Open",
            isPresented: $showDuplicateWindowAlert
        ) {
            Button("Summon") {
                if let image = pendingPopOutImage {
                    let existingValues = appModel.popOutWindowValues(for: image.fullSizeURL)
                    if let existingValue = existingValues.first {
                        openWindow(id: "photo-detail", value: existingValue)
                    }
                    pendingPopOutImage = nil
                    dismissWindow()
                }
            }
            Button("Open Copy") {
                if let image = pendingPopOutImage {
                    pendingPopOutImage = nil
                    Task {
                        await windowModel.depositSpatial3DForHandoff()
                        appModel.enqueuePhotoWindowOpen(image, bypassDuplicatePrompt: true)
                        dismissWindow()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPopOutImage = nil
            }
        } message: {
            Text("A window for this image is already open. You can summon it or open a copy.")
        }
    }

    private var photoRestorationStatus: String {
        if let failure = windowModel.loadFailure {
            return failure
        }
        if windowModel.isLoadingDetailImage {
            return windowModel.isLoadStalled ? "Waiting on the server" : "Loading image data"
        }
        if let texture = windowModel.displayTexture {
            return "Waiting for Metal frame (\(texture.width)x\(texture.height))"
        }
        if windowModel.displayImage != nil {
            return "Waiting for SwiftUI image"
        }
        if windowModel.is3DMode {
            return "Waiting for RealityKit content"
        }
        return "Preparing media renderer"
    }

    private func markContentPresented() {
        renderRecoveryTask?.cancel()
        renderRecoveryTask = nil
        renderRecoveryAttempt = 0
        guard showRestorationPlaceholder else { return }
        showRestorationPlaceholder = false
        if let popOutWindowID {
            AppLogger.windowState.info(
                "[Photo \(popOutWindowID.uuidString, privacy: .public)] first content frame reported"
            )
        }
        windowModel.startAutoHideTimer()
    }

    private func recoverStalledRenderer() {
        guard renderRecoveryAttempt < 3 else {
            AppLogger.windowState.error(
                "[Photo \(self.popOutWindowID?.uuidString ?? "pushed", privacy: .public)] renderer recovery exhausted"
            )
            return
        }
        renderRecoveryAttempt += 1
        showRestorationPlaceholder = true
        windowModel.cancelAutoHideTimer()
        windowModel.isUIHidden = false
        metalRendererGeneration += 1
        AppLogger.windowState.warning(
            "[Photo \(self.popOutWindowID?.uuidString ?? "pushed", privacy: .public)] rebuilding Metal renderer attempt=\(self.renderRecoveryAttempt, privacy: .public)"
        )

        renderRecoveryTask?.cancel()
        renderRecoveryTask = Task { @MainActor in
            // Let SwiftUI tear down the exhausted MTKView and mount the new
            // generation before publishing a replacement texture.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await windowModel.applyResolutionOverride(windowModel.resolutionOverride)
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, showRestorationPlaceholder else { return }
            await nudgeSceneForRenderRecovery()
        }
    }

    private func nudgeSceneForRenderRecovery() async {
        guard let scene = sceneDelegate?.windowScene else { return }
        AppLogger.windowState.warning(
            "[Photo \(self.popOutWindowID?.uuidString ?? "pushed", privacy: .public)] nudging scene for render recovery"
        )
        await WindowSizeNudge.perform(on: scene, delta: 1)
    }

}
