/*
 Hypnos - Photo Display View

 Shared image display component used by all picture viewer windows.
 Handles animated GIF, RealityKit 3D, and lightweight 2D display modes
 with optional swipe navigation and automatic window sizing.
 */

import DebugTrace
import RealityKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

struct PhotoDisplayView: View {
    @Bindable var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.scenePhase) private var scenePhase
    #if os(visionOS)
    @Environment(\.surfaceSnappingInfo) private var snappingInfo: SurfaceSnappingInfo
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    /// Whether the window is snapped to a surface. Only visionOS windows can be.
    private var isWindowSnapped: Bool {
        #if os(visionOS)
        return snappingInfo.isSnapped
        #else
        return false
        #endif
    }

    /// Whether swipe navigation between gallery images is enabled
    let enableSwipeNavigation: Bool

    /// User's persisted custom window size from the scene-restoration archive.
    /// Non-nil only for standalone pop-outs that were resized in a prior session;
    /// when set, it takes priority over aspect-ratio sizing on appear so a
    /// wall-snapped window restores to the exact size the user left it.
    var restoredSize: CGSize? = nil

    /// Writes the resolved window size back into the Codable window value so
    /// visionOS persists it for the next cold relaunch. Debounced via the
    /// geometry-change handler. Nil for windows that don't persist size.
    var onSizeSettled: ((CGSize) -> Void)? = nil

    /// Reports when the selected renderer has submitted or mounted its first
    /// visible frame. Used by restored windows to remove their diagnostic
    /// placeholder only after media has reached the presentation layer.
    var onFirstFramePresented: (() -> Void)? = nil
    var metalRendererGeneration: Int = 0
    var onMetalRenderStalled: (() -> Void)? = nil

    /// Closes the viewer. Bound to the iOS pull-down gesture; on visionOS the
    /// gesture is not compiled and a window is closed by its own controls.
    @DismissWindowProxy private var dismissWindow

    private func dismissViewer() {
        dismissWindow()
    }

    /// Effective swipe navigation state: disabled when window is snapped to a surface,
    /// and only active while the viewer's UI chrome is visible so swipes don't fire
    /// during the hidden-chrome immersive state.
    private var isSwipeEnabled: Bool {
        enableSwipeNavigation
            && !isWindowSnapped
            && !windowModel.isUIHidden
    }

    /// Tracks the viewer window's current size (updated live via GeometryReader)
    @State private var viewerWindowSize: CGSize?

    /// Parity flag for the IPC calibration nudge — each call toggles this and
    /// uses it to pick a +1pt or -1pt nudge direction, so the visible motion
    /// alternates and doesn't drift in one direction over many invocations.
    @State private var nudgeAlternator: Bool = false

    // MARK: - Swipe Gesture State

    /// Horizontal drag offset during swipe gesture
    @State private var dragOffset: CGFloat = 0

    /// Whether a swipe transition animation is in progress
    @State private var isSwipeTransitioning: Bool = false

    /// The width of the view for swipe threshold calculations
    @State private var containerWidth: CGFloat = 0

    /// Suppresses window resize during swipe transitions
    @State private var suppressWindowResize: Bool = false

    /// Every geometry request this window makes goes through here. Six
    /// independent triggers compute the same target size for one image open,
    /// and on visionOS each granted resize also re-anchors the window in
    /// space — which, for a pushed viewer sharing the gallery's scene, is what
    /// walks the grid window across the room. The coalescer sends the first
    /// request and drops the restatements; it re-reads the live grant, so a
    /// request the system clamped or ignored is never mistaken for one that
    /// landed. See `WindowResizeCoalescer`.
    @State private var resizeCoalescer = WindowResizeCoalescer()

    /// One-shot follow-up after an immersive resize request, verifying that the
    /// request actually took effect. visionOS can drop a geometry request made
    /// while the scene is still being placed, and nothing else re-requests — so
    /// the window silently keeps its pre-immersive size (seen once on an
    /// immersive pop-out, which asks to grow moments after its scene appears,
    /// and stable on every attempt after). Mirrors `VideoWindowView`'s
    /// `aspectRelockTask`, which exists for the same reason on the video side.
    @State private var immersiveResizeVerifyTask: Task<Void, Never>?

    /// Task for delayed window size verification (catches restoration timing issues)
    @State private var sizeVerificationTask: Task<Void, Never>?

    /// Debounce task for persisting the resolved window size back into the
    /// Codable window value (scene-restoration write-back).
    @State private var sizeWritebackTask: Task<Void, Never>?

    /// True once the restored size has been applied on appear, so the
    /// aspect-ratio / verifier resize paths defer to it during launch.
    @State private var didApplyRestoredSize: Bool = false

    /// Minimum drag fraction of container width to trigger swipe
    private let swipeThresholdFraction: CGFloat = 0.2

    /// Very large window size for immersive mode (fills field of vision)
    private let immersiveWindowSize: CGSize = CGSize(width: 3000, height: 3000)

    /// How many times an unsettled immersive resize is re-requested before
    /// giving up. Bounded so a window the system genuinely refuses to size as
    /// asked can't spin; with the front-loaded cadence below this spans ~1.9s,
    /// which covered every competing request observed on device.
    private static let immersiveResizeVerifyAttempts = 6


    /// The bounds used to fit images into — starts as saved window size or main window size, then tracks viewer size
    private var currentBounds: CGSize {
        // While restoring a persisted size on launch, fit images into the
        // restored bounds rather than the OS-supplied scene default — visionOS
        // sets `viewerWindowSize` to `.defaultSize` before our geometry request
        // resolves, so the image-load resize would otherwise fit to the default.
        if didApplyRestoredSize, let restoredSize {
            return restoredSize
        }
        return viewerWindowSize ?? windowModel.savedWindowSize ?? appModel.mainWindowSize
    }

    var body: some View {
        ZStack {
            #if !os(visionOS)
            // visionOS sizes the window to the photo, so the window *is* the
            // photo and a tap anywhere in it lands on the image. A phone's
            // screen has a fixed shape, so an aspect-fit photo leaves black
            // margins — without this layer a tap there does nothing, and the
            // chrome can only be summoned by hitting the picture itself.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { windowModel.toggleUIVisibility() }
            #endif

            imageContent
                .scaleEffect(x: windowModel.isImageFlipped ? -1 : 1, y: 1)
                .offset(x: dragOffset)

            // Diorama layers — backdrop at the window plane, foreground popped
            // forward in z. The ornament has its own z-offset to float above.
            // Wrapped in a Group so a single .animation modifier drives the
            // fade-in transition when the diorama layers appear (e.g. after
            // fire-and-forget generation completes during a gallery swipe).
            Group {
            if windowModel.isDioramaMode,
               !windowModel.is3DMode,
               !windowModel.isViewingSpatial3DImmersive,
               !windowModel.isAnimatedGIF {
                if let backdrop = windowModel.dioramaBackdropTexture {
                    MetalImageView(
                        texture: backdrop,
                        brightness: Float(windowModel.effectiveAdjustments.brightness),
                        contrast: Float(windowModel.effectiveAdjustments.contrast),
                        saturation: Float(windowModel.effectiveAdjustments.saturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(backdrop.width) / CGFloat(backdrop.height), contentMode: .fit)
                        .opacity(windowModel.effectiveAdjustments.opacity)
                        .scaleEffect(x: windowModel.isImageFlipped ? -1 : 1, y: 1)
                        .offset(x: dragOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if let foreground = windowModel.dioramaForegroundTexture {
                    MetalImageView(
                        texture: foreground,
                        brightness: Float(windowModel.effectiveAdjustments.brightness),
                        contrast: Float(windowModel.effectiveAdjustments.contrast),
                        saturation: Float(windowModel.effectiveAdjustments.saturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(foreground.width) / CGFloat(foreground.height), contentMode: .fit)
                        .opacity(windowModel.effectiveAdjustments.opacity)
                        .scaleEffect(x: windowModel.isImageFlipped ? -1 : 1, y: 1)
                        .offset(x: dragOffset)
                        .offset(z: appModel.dioramaDistance)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            }
            .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: windowModel.isDioramaMode)
            .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: windowModel.dioramaForegroundTexture != nil)

            // 3D restore prompt pill at the bottom
            if windowModel.showAutoRestorePrompt {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text("Switch to \(windowModel.autoRestoreImmersive ? "immersive 3D" : "3D")?")
                            .font(.callout)
                            .lineLimit(1)

                        Button {
                            let url = windowModel.imageURL
                            windowModel.dismissAutoRestorePrompt()
                            Task {
                                await ImageEnhancementTracker.shared.setLastViewingMode(url: url, mode: .mono)
                            }
                        } label: {
                            Text("Never")
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            let forAnimated = windowModel.autoRestoreForAnimated
                            let immersive = windowModel.autoRestoreImmersive
                            windowModel.dismissAutoRestorePrompt()
                            Task {
                                if forAnimated {
                                    // Animated content: explicitly render the first
                                    // frame in 3D (auto paths never would).
                                    windowModel.activate3DMode(generateImmediately: true, explicit: true)
                                } else {
                                    let mode: ImagePresentationComponent.ViewingMode = immersive ? .spatial3DImmersive : .spatial3D
                                    await windowModel.switchToViewingMode(mode)
                                }
                            }
                        } label: {
                            Text("Yes")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            windowModel.dismissAutoRestorePrompt()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassBackgroundEffect(in: Capsule())
                    .padding(.bottom, 80) // clear the ornament
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: windowModel.showAutoRestorePrompt)
                // Match the ornament's z-offset so the pill stays above the
                // diorama foreground (which sits at appModel.dioramaDistance).
                .offset(z: windowModel.isDioramaMode ? 30 : 0)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewerWindowSize = geo.size
                        containerWidth = geo.size.width
                        // If image is already loaded but window may be mis-sized (restoration case)
                        if windowModel.displayTexture != nil || windowModel.displayImage != nil || windowModel.isAnimatedImage || windowModel.is3DMode {
                            scheduleWindowSizeVerification()
                        }
                    }
                    .onChange(of: geo.size) { _, newSize in
                        viewerWindowSize = newSize
                        containerWidth = newSize.width
                        windowModel.handleWindowResize(newSize)
                        scheduleSizeWriteback(newSize)
                    }
            }
        )
        .onAppear {
            // Restore the user's custom window size from the scene-restoration
            // archive. This wins over aspect-ratio sizing: visionOS restores
            // wall-snapped windows at the scene `.defaultSize`, so we reassert
            // the persisted size and suppress the aspect-driven resize paths for
            // ~1s so they don't stomp it before the OS resolves the request.
            applyRestoredSizeIfNeeded()
            // Schedule post-restoration size verification (initial 2D load is
            // handled sequentially by PhotoWindowModel.start())
            scheduleWindowSizeVerification()
            windowModel.isWindowSnapped = isWindowSnapped
        }
        #if os(visionOS)
        .onChange(of: snappingInfo.isSnapped) { _, isSnapped in
            windowModel.isWindowSnapped = isSnapped
            if isSnapped {
                windowModel.dismissAutoRestorePrompt()
            }
        }
        #endif
        .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
            if wasLoading && !isLoading && !isSwipeTransitioning {
                windowModel.isUIHidden = false
                windowModel.startAutoHideTimer()
            }
        }
        .onChange(of: appModel.useLightweightDisplay) { wasLightweight, isLightweight in
            if !wasLightweight && isLightweight {
                Task {
                    await windowModel.switchToLightweightDisplay()
                }
            }
        }
        #if os(visionOS)
        .onChange(of: windowModel.hostFullyImmersiveSpace) { _, isOpen in
            // The photo window stays open and doubles as the controls
            // anchor — its RealityView content is hidden by an opacity
            // gate so the user only sees the ornament + immersive scene.
            Task {
                if isOpen {
                    // Loan the windowed IPC entity to the immersive scene
                    // so RealityKit reuses the already-generated
                    // Spatial3DImage instead of regenerating + double-
                    // allocating GPU resources.
                    appModel.immersiveLoanEntity = windowModel.contentEntity
                    appModel.immersiveLoanOwner = windowModel
                    let value = Spatial3DImmersiveValue(imageURL: windowModel.imageURL)
                    _ = await openImmersiveSpace(value: value)
                    windowModel.cancelAutoHideTimer()
                    windowModel.isUIHidden = false
                } else {
                    await dismissImmersiveSpace()
                    // Flip the IPC back to windowed spatial3D so the
                    // photo window's RealityView re-adopts the entity at
                    // the correct viewing mode (the update closure's
                    // `parent == nil` guard handles the re-attach).
                    if var ipc = windowModel.contentEntity.components[ImagePresentationComponent.self] {
                        ipc.desiredViewingMode = .spatial3D
                        windowModel.desiredViewingMode = .spatial3D
                        windowModel.contentEntity.components.set(ipc)
                    }
                    // Reset the transform — it was carrying the
                    // immersive world pose (eye-height Y, ~2m -Z) which,
                    // applied as window-local on re-adoption, slid the
                    // entity up and out of the window's visible bounds.
                    // The windowed update closure recomputes scale +
                    // position correctly on its next pass.
                    windowModel.contentEntity.transform = Transform()
                    appModel.immersiveLoanEntity = nil
                    if appModel.immersiveLoanOwner === windowModel {
                        appModel.immersiveLoanOwner = nil
                    }
                    windowModel.startAutoHideTimer()
                }
            }
        }
        #endif
        .onDisappear {
            immersiveResizeVerifyTask?.cancel()
            immersiveResizeVerifyTask = nil
            #if os(visionOS)
            if windowModel.hostFullyImmersiveSpace {
                windowModel.hostFullyImmersiveSpace = false
                appModel.immersiveLoanEntity = nil
                if appModel.immersiveLoanOwner === windowModel {
                    appModel.immersiveLoanOwner = nil
                }
                Task { await dismissImmersiveSpace() }
            }
            #endif
        }
        // MARK: - Scene Phase Idle Downscale
        .onChange(of: scenePhase) { oldPhase, newPhase in
            windowModel.handleScenePhaseChange(from: oldPhase, to: newPhase)
            // When the window comes back to the foreground, IPC's off-axis
            // calibration is likely stale — kick a nudge to clear any blur.
            // No-op unless the photo is currently in windowed spatial3D.
            if newPhase == .active && oldPhase != .active {
                windowModel.refreshSpatial3DCalibration()
            }
        }
    }

    // MARK: - Image Content

    @ViewBuilder
    private var imageContent: some View {
        // The four animated-image branches below (cached HEVC playback, raw
        // JXL/WebP/GIF-via-<img>) all render through WebKit, which doesn't
        // exist on tvOS. There is no tvOS fallback for animated formats yet —
        // an animated GIF/WebP/JXL on Apple TV falls through to the Metal/
        // UIImage branches further down and shows its first decoded frame as
        // a static image rather than animating. See Hypnos/CLAUDE.md "tvOS".
        #if canImport(WebKit)
        if !windowModel.is3DMode, (windowModel.isAnimatedGIF || windowModel.isAnimatedJXL), let hevcURL = windowModel.animatedHEVCURL {
            // Play the cached HEVC conversion. Preferred path is the native
            // video-in-<img> tier: WebKit owns the animation loop and
            // pauses/resumes it with the window, matching the raw GIF and
            // animated-WebP paths (no AVPlayer, no isRoomActive/controls
            // wiring). If WebKit can't decode HEVC in an <img> it errors, and
            // we fall back to the <video> player, which decodes it reliably.
            Group {
                if windowModel.animatedImgPlaybackFailed {
                    WebVideoPlayerView(
                        videoURL: hevcURL,
                        showControls: !windowModel.isUIHidden,
                        isRoomActive: windowModel.isInActiveRoom
                    )
                } else {
                    AnimatedImageWebView(
                        imageURL: hevcURL,
                        elementType: .image,
                        onError: { [weak windowModel] in
                            AppLogger.gifConverter.info("HEVC failed to decode in <img> tier — falling back to <video> player")
                            windowModel?.animatedImgPlaybackFailed = true
                        }
                    )
                }
            }
            .brightness(windowModel.effectiveAdjustments.brightness)
            .contrast(windowModel.effectiveAdjustments.contrast)
            .saturation(windowModel.effectiveAdjustments.saturation)
            .opacity(windowModel.effectiveAdjustments.opacity)
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: appModel.photoCornerRadius, style: .continuous))
            .overlay {
                // Transparent tap target to re-show photo ornaments when UI is hidden.
                // When visible, taps pass through to the HTML video controls instead.
                if windowModel.isUIHidden {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture {
                            windowModel.toggleUIVisibility()
                        }
                }
            }
            .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded, onDismissDrag: dismissViewer))
            .onAppear {
                onFirstFramePresented?()
                let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                resizeGIFWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
            }
            .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                guard !suppressWindowResize else { return }
                resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
            }
            .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                if wasLoading && !isLoading {
                    resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                    scheduleWindowSizeVerification()
                }
            }
        } else if windowModel.isAnimatedJXL, !windowModel.is3DMode {
            // No HEVC yet — decode on-device via WASM this session; the decode
            // is converted to HEVC in the background so the next open plays
            // through the native path above.
            AnimatedJXLWebView(imageData: windowModel.currentImageData, sourceURL: windowModel.imageURL)
                .brightness(windowModel.effectiveAdjustments.brightness)
                .contrast(windowModel.effectiveAdjustments.contrast)
                .saturation(windowModel.effectiveAdjustments.saturation)
                .opacity(windowModel.effectiveAdjustments.opacity)
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: appModel.photoCornerRadius, style: .continuous))
                .overlay {
                    if windowModel.isUIHidden {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture {
                                windowModel.toggleUIVisibility()
                            }
                    }
                }
                .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded, onDismissDrag: dismissViewer))
                .onAppear {
                    onFirstFramePresented?()
                    let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                    resizeGIFWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
                }
        } else if (windowModel.isAnimatedWebP || windowModel.isAnimatedWebVisual), !windowModel.is3DMode {
            AnimatedImageWebView(
                imageURL: windowModel.animatedImageSourceURL ?? windowModel.imageURL,
                elementType: windowModel.isAnimatedWebVisual ? .video : .image
            )
                .brightness(windowModel.effectiveAdjustments.brightness)
                .contrast(windowModel.effectiveAdjustments.contrast)
                .saturation(windowModel.effectiveAdjustments.saturation)
                .opacity(windowModel.effectiveAdjustments.opacity)
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: appModel.photoCornerRadius, style: .continuous))
                .overlay {
                    if windowModel.isUIHidden {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture {
                                windowModel.toggleUIVisibility()
                            }
                    }
                }
                .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded, onDismissDrag: dismissViewer))
                .onAppear {
                    onFirstFramePresented?()
                    let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                    resizeGIFWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        scheduleWindowSizeVerification()
                    }
                }
        } else if windowModel.isAnimatedGIF, !windowModel.is3DMode {
            // No cached H.264 yet — play the raw GIF immediately (WebKit animates
            // it in an <img>). The H.264 conversion runs in the background and,
            // once ready, `animatedHEVCURL` flips this to the branch above.
            AnimatedImageWebView(
                imageURL: windowModel.animatedImageSourceURL ?? windowModel.imageURL,
                imageData: windowModel.currentImageData,
                imageDataMimeType: "image/gif"
            )
                .brightness(windowModel.effectiveAdjustments.brightness)
                .contrast(windowModel.effectiveAdjustments.contrast)
                .saturation(windowModel.effectiveAdjustments.saturation)
                .opacity(windowModel.effectiveAdjustments.opacity)
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: appModel.photoCornerRadius, style: .continuous))
                .overlay {
                    if windowModel.isUIHidden {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture {
                                windowModel.toggleUIVisibility()
                            }
                    }
                }
                .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded, onDismissDrag: dismissViewer))
                .onAppear {
                    onFirstFramePresented?()
                    let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                    resizeGIFWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
                }
        } else {
            nonAnimatedImageContent
        }
        #else
        nonAnimatedImageContent
        #endif
    }

    /// The `is3DMode` / Metal-texture / `UIImage` / loading-placeholder tail,
    /// shared between the WebKit-available chain above and the tvOS build
    /// (which skips straight here — see the header comment on `imageContent`).
    /// Split out as its own statement rather than spliced mid-`if` across
    /// `#if canImport(WebKit)`/`#else`, because Swift's conditional
    /// compilation requires each branch to be a complete, independently
    /// balanced statement; it cannot pick up an `if` opened in one branch and
    /// continue it in another.
    @ViewBuilder
    private var nonAnimatedImageContent: some View {
        if windowModel.is3DMode {
            #if os(visionOS)
            // Display with RealityKit for 3D spatial conversion (full resolution)
            GeometryReader3D { geometry in
                RealityView { content in
                    await windowModel.createImagePresentationComponent()
                    let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                    scaleImagePresentationToFit(in: availableBounds)
                    if windowModel.contentEntity.parent == nil {
                        content.add(windowModel.contentEntity)
                    }
                    windowModel.ensureInputPlaneReady()
                    updateInputPlane(in: availableBounds)
                    if windowModel.inputPlaneEntity.parent == nil {
                        content.add(windowModel.inputPlaneEntity)
                    }
                    resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)

                    // Only handle 3D generation when in explicit 3D mode.
                    if windowModel.is3DMode {
                        if windowModel.pendingGenerate3D {
                            windowModel.pendingGenerate3D = false
                            await windowModel.generateSpatial3DImage()
                        } else {
                            await windowModel.autoGenerateSpatial3DIfNeeded()
                        }
                    }
                } update: { content in
                    // While Fully Immersive 3D owns the entity, the
                    // immersive scene is the one mutating its transform —
                    // any setPosition/scale here would clobber the
                    // placement every frame and snap the IPC back to the
                    // (hidden) photo window's pose.
                    guard !windowModel.hostFullyImmersiveSpace else { return }
                    guard let presentationScreenSize = windowModel
                        .contentEntity
                        .observable
                        .components[ImagePresentationComponent.self]?
                        .presentationScreenSize, presentationScreenSize != .zero else {
                            return
                    }
                    let originalPosition = windowModel.contentEntity.position(relativeTo: nil)
                    // Experimental: recess the spatial3D scene slightly behind the
                    // window glass to mask the off-axis comfort-cone falloff. Pairs
                    // with the soft BillboardComponent set by updateExperimentalSpatial3DTuning().
                    let experimentalZ: Float = windowModel.shouldApplyExperimentalSpatial3DTuning
                        ? PhotoWindowModel.experimentalSpatial3DZInset
                        : 0.0
                    windowModel.contentEntity.setPosition(SIMD3<Float>(originalPosition.x, originalPosition.y, experimentalZ), relativeTo: nil)
                    let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                    scaleImagePresentationToFit(in: availableBounds)
                    if windowModel.contentEntity.parent == nil {
                        content.add(windowModel.contentEntity)
                    }
                    windowModel.ensureInputPlaneReady()
                    updateInputPlane(in: availableBounds)
                    if windowModel.inputPlaneEntity.parent == nil {
                        content.add(windowModel.inputPlaneEntity)
                    }
                }
                .modifier(EntitySwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded))
                .gesture(
                    TapGesture()
                        .targetedToAnyEntity()
                        .onEnded { _ in
                            windowModel.toggleUIVisibility()
                            // Refresh IPC's off-axis calibration on every tap
                            // — cheap and matches the manual-resize fix the
                            // user would otherwise need to do themselves.
                            windowModel.refreshSpatial3DCalibration()
                        }
                )
                .onAppear {
                    onFirstFramePresented?()
                    guard let windowScene = resolvedWindowScene else {
                        AppLogger.views.warning("Unable to get the window scene. Unable to set the resizing restrictions.")
                        return
                    }
                    resizeCoalescer.request(windowScene, restriction: .uniform, animated: true)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.immersiveResizeTrigger) { _, _ in
                    // Triggered when entering or exiting immersive mode
                    guard !suppressWindowResize else { return }
                    
                    // Check the component's desiredViewingMode to see if we're going immersive
                    if let component = windowModel.contentEntity.components[ImagePresentationComponent.self] {
                        let isImmersive = component.desiredViewingMode == .spatial3DImmersive
                        
                        if isImmersive {
                            // Store current size before entering immersive
                            let preImmersiveSize = viewerWindowSize ?? currentBounds
                            windowModel.preImmersiveWindowSize = preImmersiveSize
                            requestVerifiedImmersiveResize(from: preImmersiveSize)
                        } else {
                            // Exiting immersive - restore original size.
                            // The coalescer's memory is of a request made
                            // against the immersive bounds, which says nothing
                            // about the windowed geometry being restored here.
                            immersiveResizeVerifyTask?.cancel()
                            immersiveResizeVerifyTask = nil
                            resizeCoalescer.invalidate()
                            let restoreSize = windowModel.preImmersiveWindowSize ?? appModel.mainWindowSize
                            resizeWindowToFit(windowModel.imageAspectRatio, within: restoreSize, forceImmersive: false)
                            windowModel.preImmersiveWindowSize = nil
                        }
                    }
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        scheduleWindowSizeVerification()
                    }
                }
                .onChange(of: windowModel.calibrationNudgeTrigger) { _, _ in
                    nudgeWindowSizeForCalibration()
                }
            }
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            // Hide the windowed RealityKit presentation while the Fully
            // Immersive space is hosting the IPC — the photo window stays
            // as a controls anchor (ornament + chrome) but doesn't double
            // up the spatial scene.
            .opacity(windowModel.hostFullyImmersiveSpace ? 0 : windowModel.effectiveAdjustments.opacity)
            .clipShape(RoundedRectangle(
                cornerRadius: windowModel.isViewingSpatial3DImmersive ? 0 : appModel.photoCornerRadius,
                style: .continuous
            ))
            #else
            // Spatial 3D is visionOS-only; `is3DMode` is never set on iOS
            // (PlatformCapabilities.supportsSpatial3D), so this is a guard
            // against persisted state, not a path a user can reach.
            loadStatusPlaceholder
            #endif
        } else if let texture = windowModel.displayTexture {
            // GPU-backed 2D display using Metal (texture lives in GPU private memory,
            // not counted as dirty CPU pages — reduces jetsam pressure significantly)
            MetalImageView(
                texture: texture,
                brightness: Float(windowModel.effectiveAdjustments.brightness),
                contrast: Float(windowModel.effectiveAdjustments.contrast),
                saturation: Float(windowModel.effectiveAdjustments.saturation),
                sharpen: Float(windowModel.effectiveAdjustments.sharpen),
                diagnosticLabel: "photo-\(windowModel.popOutWindowValue?.id.uuidString.prefix(8) ?? "shared")",
                onFramePresented: onFirstFramePresented,
                onRenderStalled: onMetalRenderStalled
            )
            .id(metalRendererGeneration)
            .opacity(windowModel.effectiveAdjustments.opacity)
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: appModel.photoCornerRadius, style: .continuous))
            .contentShape(.rect)
            .onTapGesture {
                windowModel.toggleUIVisibility()
            }
            .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded, onDismissDrag: dismissViewer))
            .onAppear {
                // The 3D-adjustment 2D preview re-mounts this branch
                // every time is3DMode flips false. Re-running the
                // initial-size resize would shrink the window back to
                // its saved 2D bounds (often much smaller than the
                // current 3D window) and the geometry change would
                // also instantly dismiss the open adjustments popover.
                // Leave the window alone during the preview.
                guard !windowModel.isShowingAdjustmentPreview else { return }
                setUniformResizing()
                let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                resizeWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
            }
            .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                guard !suppressWindowResize, !windowModel.isShowingAdjustmentPreview else { return }
                resizeWindowToFit(newAspectRatio, within: currentBounds)
            }
            .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                if wasLoading && !isLoading, !windowModel.isShowingAdjustmentPreview {
                    resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                    scheduleWindowSizeVerification()
                }
            }
        } else if let uiImage = windowModel.displayImage {
            // Fallback: lightweight 2D display with UIImage (used for idle-downscale thumbnails
            // and 3D adjustment previews where Metal overhead isn't justified)
            Image(platformImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .brightness(windowModel.effectiveAdjustments.brightness)
                .contrast(windowModel.effectiveAdjustments.contrast)
                .saturation(windowModel.effectiveAdjustments.saturation)
            .opacity(windowModel.effectiveAdjustments.opacity)
                .clipShape(RoundedRectangle(cornerRadius: appModel.photoCornerRadius, style: .continuous))
                .contentShape(.rect)
                .onTapGesture {
                    windowModel.toggleUIVisibility()
                }
                .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded, onDismissDrag: dismissViewer))
                .onAppear {
                    onFirstFramePresented?()
                    // Same rationale as the MetalImageView branch above —
                    // the adjustments preview re-mounts this branch, and
                    // resizing here would both shrink the window and
                    // instantly dismiss the open popover.
                    guard !windowModel.isShowingAdjustmentPreview else { return }
                    setUniformResizing()
                    let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                    resizeWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize, !windowModel.isShowingAdjustmentPreview else { return }
                    resizeWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading, !windowModel.isShowingAdjustmentPreview {
                        resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        scheduleWindowSizeVerification()
                    }
                }
        } else {
            // Nothing renderable yet: still fetching, or the fetch failed.
            // This branch used to be absent, so a photo the backend never
            // returned left an empty window whose ornament was locked by the
            // loading flag — no retry, no way to tell what had happened.
            loadStatusPlaceholder
        }
    }

    // MARK: - Loading / Failure Placeholder

    @ViewBuilder
    private var loadStatusPlaceholder: some View {
        VStack(spacing: 16) {
            if let failure = windowModel.loadFailure {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Couldn't load this image")
                    .font(.title3.weight(.semibold))
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                ProgressView()
                    .controlSize(.large)
                if windowModel.isLoadStalled {
                    Text("Still waiting for the server")
                        .font(.title3.weight(.semibold))
                    Text("The image hasn't arrived yet. You can keep waiting, retry, or move on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }

            if windowModel.loadFailure != nil || windowModel.isLoadStalled {
                Button {
                    Task { await windowModel.retryImageLoad() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture {
            windowModel.toggleUIVisibility()
        }
        .onChange(of: windowModel.loadFailure) { _, failure in
            // A restored window sits behind the "Restoring Photo" diagnostic
            // until media reaches the presentation layer. A failed load never
            // gets there, so release it here — otherwise the failure card is
            // covered by a placeholder that spins forever.
            if failure != nil {
                windowModel.isUIHidden = false
                onFirstFramePresented?()
            }
        }
        .onAppear {
            if windowModel.loadFailure != nil {
                onFirstFramePresented?()
            }
        }
    }

    // MARK: - Swipe Gesture Handling

    private func handleDragEnded(translation: CGFloat, predictedEnd: CGFloat) {
        guard !isSwipeTransitioning && !windowModel.isLoadingDetailImage else {
            return
        }

        let threshold = max(containerWidth * swipeThresholdFraction, 54)
        let actualDistance = abs(translation)

        // Only allow predicted velocity to assist if the finger has already moved at least 40% of the threshold
        let velocityAssistMinimum = threshold * 0.4
        let shouldNavigateNext: Bool
        let shouldNavigatePrevious: Bool

        if actualDistance >= velocityAssistMinimum {
            shouldNavigateNext = (translation < -threshold || predictedEnd < -threshold * 2) && windowModel.hasNextGalleryImage
            shouldNavigatePrevious = (translation > threshold || predictedEnd > threshold * 2) && windowModel.hasPreviousGalleryImage
        } else {
            // Too little movement — only commit if past the full threshold (no velocity assist)
            shouldNavigateNext = translation < -threshold && windowModel.hasNextGalleryImage
            shouldNavigatePrevious = translation > threshold && windowModel.hasPreviousGalleryImage
        }

        if shouldNavigateNext {
            performSwipeTransition(direction: .next)
        } else if shouldNavigatePrevious {
            performSwipeTransition(direction: .previous)
        }
    }

    private enum SwipeDirection {
        case next
        case previous
    }

    private func performSwipeTransition(direction: SwipeDirection) {
        isSwipeTransitioning = true
        suppressWindowResize = true
        let offScreenOffset: CGFloat = direction == .next ? -containerWidth : containerWidth
        let reduceMotion = appModel.effectiveReduceMotion

        // Phase 1: Animate current image off-screen (skipped under reduce motion)
        if reduceMotion {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dragOffset = 0 }
        } else {
            withAnimation(.easeIn(duration: 0.2)) {
                dragOffset = offScreenOffset
            }
        }

        Task { @MainActor in
            // Wait for off-screen animation to complete
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(220))
            }

            // Phase 2: Switch to new image (await ensures image data is ready)
            if direction == .next {
                await windowModel.nextGalleryImage()
            } else {
                await windowModel.previousGalleryImage()
            }

            // Position new image on opposite side without animation
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragOffset = reduceMotion ? 0 : -offScreenOffset
            }

            // Brief pause to let SwiftUI process the view update
            try? await Task.sleep(for: .milliseconds(50))

            // Phase 3: Animate new image sliding to center
            if reduceMotion {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { dragOffset = 0 }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    dragOffset = 0
                }
            }

            // Wait for slide-in animation to complete
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(270))
            }

            // Phase 4: Clear transition state and resize window
            isSwipeTransitioning = false
            suppressWindowResize = false
            if windowModel.isAnimatedImage {
                resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            } else {
                resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            }
        }
    }

    // MARK: - Window Sizing

    /// Calculate window size for image aspect ratio using the larger dimension of
    /// the bounds. This prevents shrinking when switching between tall and wide images
    /// (e.g. a tall 600×900 window switching to a wide image would otherwise cap at 600 wide).
    private func windowSize(for aspectRatio: CGFloat, within bounds: CGSize) -> CGSize {
        let maxDim = max(bounds.width, bounds.height)
        let imageWidth: CGFloat
        let imageHeight: CGFloat
        if aspectRatio >= 1.0 {
            // Wide or square image: width is the dominant axis
            imageWidth = maxDim
            imageHeight = maxDim / aspectRatio
        } else {
            // Tall image: height is the dominant axis
            imageWidth = maxDim * aspectRatio
            imageHeight = maxDim
        }
        return CGSize(width: imageWidth, height: imageHeight)
    }

    /// Resize window to fit image aspect ratio within given bounds
    private func resizeWindowToFit(
        _ aspectRatio: CGFloat,
        within bounds: CGSize,
        forceImmersive: Bool? = nil,
        force: Bool = false
    ) {
        guard let windowScene = resolvedWindowScene else { return }

        // Use explicit immersive flag if provided, otherwise detect automatically.
        //
        // Detection has to include the *desired* mode, not just the settled
        // one. `viewingMode` lags a mode change by hundreds of milliseconds,
        // and every other resize path (load completion, aspect change) fires
        // inside that gap — computing a non-immersive size and overwriting the
        // immersive geometry that was already requested. That is what left an
        // immersive pop-out at its small windowed size: not a dropped request,
        // a later request that disagreed about which mode the window was in.
        let shouldUseImmersive: Bool
        if let forceImmersive {
            shouldUseImmersive = forceImmersive
        } else {
            let desired = windowModel.contentEntity
                .components[ImagePresentationComponent.self]?.desiredViewingMode
            shouldUseImmersive = windowModel.isViewingSpatial3DImmersive
                || desired == .spatial3DImmersive
        }
        
        let effectiveBounds = shouldUseImmersive ? immersiveWindowSize : bounds
        let size = windowSize(for: aspectRatio, within: effectiveBounds)

        resizeCoalescer.request(windowScene, size: size, force: force)
    }

    /// Grow the window for immersive 3D, then verify the grant is actually an
    /// answer to that request.
    ///
    /// A window opened straight into immersive (a pop-out of a window already
    /// in immersive 3D) would otherwise be left at the `photo-detail` group's
    /// `.defaultSize` of 1200x900: the immersive request goes out within ~25ms
    /// of the window appearing, and the system then applies that scene default
    /// on top of it. Nothing else re-requested, so the window simply stayed
    /// small — intermittently, since it depends on which request lands last.
    ///
    /// Deliberately *not* tested here: whether the grant matches `intended`.
    /// The request is `immersiveWindowSize`-fitted and far larger than the
    /// platform ceiling (~1360pt tall), so every grant is clamped; treating a
    /// clamp as failure would fight the steady state on every immersive entry.
    /// See the two tests inline for what failure actually looks like.
    private func requestVerifiedImmersiveResize(from preImmersiveSize: CGSize) {
        let intended = windowSize(for: windowModel.imageAspectRatio, within: immersiveWindowSize)

        AppLogger.views.debug(
            "Immersive resize: pre=\(Int(preImmersiveSize.width), privacy: .public)x\(Int(preImmersiveSize.height), privacy: .public) intended=\(Int(intended.width), privacy: .public)x\(Int(intended.height), privacy: .public) aspect=\(self.windowModel.imageAspectRatio, privacy: .public) fullyImmersiveMode=\(self.appModel.fullyImmersive3DMode, privacy: .public)"
        )

        // Requested immediately, not after waiting for the scene to settle:
        // deferring it delays the common case (a window already on screen
        // entering immersive, which lands correct on the first request) into a
        // visible lag, which measured worse than the snap it was meant to
        // avoid. A freshly opened window's dropped request is recovered by the
        // verifier below instead.
        //
        // Forced past the coalescer, here and on every re-request below: this
        // is the one path that deliberately asks for a size it knows will be
        // clamped, so its request never matches its own grant and
        // "already asked for that" reasoning does not apply to it.
        //
        // The window's geometry *in scene units*, sampled before the request.
        // `preImmersiveSize` is a SwiftUI content size and the readback below
        // is a scene size; the two differ by the window's chrome insets, so
        // only this one can answer "has the window moved at all yet".
        let preImmersiveGranted = resolvedWindowScene?.effectiveGeometrySize

        resizeWindowToFit(
            windowModel.imageAspectRatio,
            within: immersiveWindowSize,
            forceImmersive: true,
            force: true
        )

        immersiveResizeVerifyTask?.cancel()
        immersiveResizeVerifyTask = Task { @MainActor in
            // Largest grant seen so far. Seeded at zero, not just below the
            // pre-immersive size: the old seed made the first aspect-correct
            // grant read as "still growing" and drew a second, identical
            // request on *every* immersive entry — one extra re-anchor in the
            // healthy case, which on a pushed window is one extra shove of the
            // gallery window across the room. Growth is now only watched; a
            // re-request needs evidence that the grant is actually wrong.
            var lastGranted: CGSize = .zero
            // Consecutive samples showing the window still sitting at exactly
            // its pre-immersive size. One is not evidence (the grant may not
            // have been applied yet); two means the request never landed.
            var unchangedSamples = 0
            for attempt in 1...Self.immersiveResizeVerifyAttempts {
                // Front-loaded cadence: a correction the user can see as a
                // "snap" is far less noticeable at 150ms than at 500ms, while
                // the later, longer waits still catch a grant that settles slowly.
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 150 : 350))
                guard !Task.isCancelled, let scene = resolvedWindowScene else { return }

                // The *desired* mode, not the settled one: `viewingMode` lags
                // the request by well over a sample, so gating on it made this
                // verifier bail during exactly the interval it exists to watch.
                let ipc = windowModel.contentEntity.components[ImagePresentationComponent.self]
                let stillHeadingImmersive = ipc?.desiredViewingMode == .spatial3DImmersive
                let granted = scene.effectiveGeometrySize

                AppLogger.views.debug(
                    "Immersive resize readback #\(attempt, privacy: .public): granted=\(Int(granted.width), privacy: .public)x\(Int(granted.height), privacy: .public) mode=\(String(describing: ipc?.viewingMode), privacy: .public) desired=\(String(describing: ipc?.desiredViewingMode), privacy: .public) suppressed=\(self.suppressWindowResize, privacy: .public)"
                )

                guard stillHeadingImmersive, !suppressWindowResize else { return }
                guard granted.width > 2, granted.height > 2 else { continue }

                // Two independent things can be wrong with the grant, and
                // each needs its own test.
                //
                // Wrong *shape*: a competing geometry request lands on top of
                // ours with a size that isn't derived from the image at all
                // (measured: 1200x900 granted for a 1.78 image, while a clean
                // entry at that same aspect reached 2579x1360). Every sizing
                // path here preserves aspect, so an aspect-mismatched grant is
                // never an answer to this request and must be re-requested —
                // "it stopped changing" is not consent.
                //
                // Wrong *size*: the grant is aspect-correct but still growing
                // toward the platform ceiling (~1360pt tall), which a 3000pt
                // request always hits. There is no point comparing against
                // `intended` — it is deliberately larger than any grant — so
                // convergence is the test: stop once a correctly-shaped grant
                // stops growing.
                defer { lastGranted = granted }
                let aspect = windowModel.imageAspectRatio
                let grantedAspect = granted.width / granted.height
                let aspectMatches = abs(grantedAspect - aspect) <= aspect * 0.02
                let stalled = granted.width <= lastGranted.width + 2
                    && granted.height <= lastGranted.height + 2
                let atPreImmersiveSize = preImmersiveGranted.map {
                    abs(granted.width - $0.width) <= 2 && abs(granted.height - $0.height) <= 2
                } ?? false

                if aspectMatches {
                    if !atPreImmersiveSize {
                        // Correctly-shaped immersive geometry. Either it has
                        // settled, or it is still growing toward the platform
                        // ceiling — and a window that is growing on its own
                        // needs watching, not pushing.
                        if stalled { return }
                        continue
                    }
                    unchangedSamples += 1
                    // Sample 1: too early to call. Sample 2: re-request once.
                    // Sample 3+: the platform will not grow this window (it may
                    // already have been at the ceiling), so stop asking.
                    if unchangedSamples != 2 {
                        if unchangedSamples > 2 { return }
                        continue
                    }
                }

                AppLogger.views.info(
                    "Immersive resize not settled (granted \(Int(granted.width), privacy: .public)x\(Int(granted.height), privacy: .public) aspect=\(grantedAspect, privacy: .public) want=\(aspect, privacy: .public) shapeOK=\(aspectMatches, privacy: .public) atPreImmersive=\(atPreImmersiveSize, privacy: .public)); re-requesting, attempt \(attempt, privacy: .public)"
                )
                resizeWindowToFit(
                    windowModel.imageAspectRatio,
                    within: immersiveWindowSize,
                    forceImmersive: true,
                    force: true
                )
            }
        }
    }

    /// Resize GIF window to fit image aspect ratio within given bounds (with uniform restrictions)
    private func resizeGIFWindowToFit(_ aspectRatio: CGFloat, within bounds: CGSize, force: Bool = false) {
        guard let windowScene = resolvedWindowScene else { return }

        // Use the same windowSize helper for consistent sizing
        let size = windowSize(for: aspectRatio, within: bounds)
        resizeCoalescer.request(windowScene, size: size, restriction: .uniform, force: force)
    }

    /// Alternating 1pt nudge: each call moves the window by -1pt OR +1pt
    /// (alternating between calls), then reverts to the base size. Halves
    /// the visible motion of the previous shrink-then-grow round-trip since
    /// only one transition is visible per call. Direction alternates so the
    /// nudge looks symmetric over time and doesn't drift in one direction.
    private func nudgeWindowSizeForCalibration() {
        guard let windowScene = resolvedWindowScene else { return }
        let delta: CGFloat = nudgeAlternator ? 1 : -1
        nudgeAlternator.toggle()
        Task { @MainActor in
            await WindowSizeNudge.perform(on: windowScene, delta: delta)
        }
    }

    /// Apply the persisted custom window size (if any) on appear. Requests the
    /// geometry immediately and holds `suppressWindowResize` for ~1s so the
    /// aspect-ratio and verifier resize paths defer to the restored size until
    /// the OS has resolved the request. No-op when there is no persisted size.
    private func applyRestoredSizeIfNeeded() {
        guard let restoredSize, restoredSize.width > 2, restoredSize.height > 2 else { return }
        guard let windowScene = resolvedWindowScene else { return }
        didApplyRestoredSize = true
        suppressWindowResize = true
        if windowModel.isAnimatedImage {
            resizeCoalescer.request(windowScene, size: restoredSize, restriction: .uniform)
        } else {
            resizeCoalescer.request(windowScene, size: restoredSize)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            suppressWindowResize = false
            didApplyRestoredSize = false
        }
    }

    /// Debounce a write-back of the resolved window size into the Codable window
    /// value so visionOS persists it for the next cold relaunch. Skipped while
    /// `suppressWindowResize` is set (during restored-size apply / swipe
    /// transitions) so a transient default size isn't persisted over the user's.
    private func scheduleSizeWriteback(_ size: CGSize) {
        guard let onSizeSettled else { return }
        guard !suppressWindowResize, size.width > 2, size.height > 2 else { return }
        sizeWritebackTask?.cancel()
        sizeWritebackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onSizeSettled(size)
        }
    }

    /// Schedule a delayed check that the window size matches the loaded image content.
    /// Catches cases where requestGeometryUpdate was ignored during window restoration.
    private func scheduleWindowSizeVerification() {
        sizeVerificationTask?.cancel()
        sizeVerificationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            verifyWindowSizeMatchesContent()
        }
    }

    /// Verify the window size matches the loaded image's aspect ratio and saved size.
    /// If they differ by more than 5%, re-trigger resize using the saved window size
    /// (if available) to restore the user's previous window dimensions after reboot.
    private func verifyWindowSizeMatchesContent() {
        guard let currentSize = viewerWindowSize,
              windowModel.imageAspectRatio > 0,
              !windowModel.isLoadingDetailImage,
              !suppressWindowResize else { return }

        // Prefer the per-window restored size (from the scene archive) over the
        // per-image saved size — this ensures post-reboot restoration uses the
        // exact size the user left this window at rather than the scene default
        // or a different window's size for the same image.
        let targetBounds = restoredSize ?? windowModel.savedWindowSize ?? currentBounds

        // Compare the current window against the expected size for the image AR within target bounds
        let expectedSize = windowSize(for: windowModel.imageAspectRatio, within: targetBounds)
        let widthRatio = currentSize.width / expectedSize.width
        let heightRatio = currentSize.height / expectedSize.height

        guard widthRatio < 0.95 || widthRatio > 1.05 || heightRatio < 0.95 || heightRatio > 1.05 else { return }

        AppLogger.views.info("Window size mismatch detected (current: \(currentSize.width, privacy: .public)x\(currentSize.height, privacy: .public), expected: \(expectedSize.width, privacy: .public)x\(expectedSize.height, privacy: .public)). Resizing.")
        // Forced: this is the app's safety net and it only gets here having
        // measured a >5% mismatch, which is exactly the read-back evidence the
        // coalescer's dedupe is not allowed to second-guess.
        if windowModel.isAnimatedImage {
            resizeGIFWindowToFit(windowModel.imageAspectRatio, within: targetBounds, force: true)
        } else {
            resizeWindowToFit(windowModel.imageAspectRatio, within: targetBounds, force: true)
        }
    }

    private func setUniformResizing() {
        resizeCoalescer.request(resolvedWindowScene, restriction: .uniform, animated: true)
    }

    func resetWindowRestrictions() {
        resizeCoalescer.request(resolvedWindowScene, restriction: .freeform, animated: true)
    }

    /// Fit the image presentation inside a bounding box by scaling the content entity.
    private func scaleImagePresentationToFit(in boundsInMeters: BoundingBox) {
        guard let imagePresentationComponent = windowModel.contentEntity.components[ImagePresentationComponent.self] else {
            return
        }

        let presentationScreenSize = imagePresentationComponent.presentationScreenSize
        let fit = min(
            boundsInMeters.extents.x / presentationScreenSize.x,
            boundsInMeters.extents.y / presentationScreenSize.y
        )
        // "Distance" (Adjustments) scales the presentation, remembered separately
        // for regular 3D (.spatial3D) vs portal Immersive 3D (.spatial3DImmersive).
        // The RealityView update closure re-runs this so the slider updates live.
        let userScale = windowModel.desiredViewingMode == .spatial3DImmersive
            ? windowModel.currentAdjustments.immersiveScale
            : windowModel.currentAdjustments.scale
        let scale = fit * Float(userScale)

        windowModel.contentEntity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    /// Match the input plane to the current window bounds for hit-testing.
    private func updateInputPlane(in boundsInMeters: BoundingBox) {
        let scale = SIMD3<Float>(boundsInMeters.extents.x, boundsInMeters.extents.y, 1.0)
        windowModel.inputPlaneEntity.scale = scale
        let center = boundsInMeters.center
        windowModel.inputPlaneEntity.setPosition(
            SIMD3<Float>(center.x, center.y, 0.01),
            relativeTo: nil
        )
    }

    private var resolvedWindowScene: PlatformWindowScene? {
        if let sceneDelegate {
            return sceneDelegate.windowScene
        }

        #if os(macOS)
        return nil
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        #endif
    }
}

// MARK: - Swipe Gesture Modifiers

/// Adds a drag gesture for swipe navigation on standard SwiftUI views (GIF, 2D image).
/// Uses discrete detection (onEnded only) to avoid per-frame offset flicker on visionOS.
private struct SwipeGestureModifier: ViewModifier {
    let enabled: Bool
    let onEnded: (CGFloat, CGFloat) -> Void
    /// iOS: pull-down-to-close, the way Photos closes a full-screen photo.
    /// Nil (and unused) on visionOS, where a window is closed by its own
    /// controls and there is nothing to drag it out of.
    var onDismissDrag: (() -> Void)? = nil

    /// How far the photo has been pulled down, tracked here so **every**
    /// render tier gets the same follow-the-finger feedback without each one
    /// wiring up its own state.
    @State private var dismissDrag: CGFloat = 0

    // Keep view identity stable across `enabled` flips: an if/else here
    // produces a _ConditionalContent whose branch swap reroots the wrapped
    // view. On the RealityKit 3D path that tears down the
    // ImagePresentationComponent and the immersive window vanishes when the
    // ornament auto-hides.
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.gesture(gesture)
        #elseif os(tvOS)
        // No touch surface to drag on tvOS — the TV root UI's own fullscreen
        // photo viewer drives prev/next off the remote (`.onMoveCommand`)
        // instead of a swipe. `DragGesture` itself is unavailable here.
        content
        #else
        content
            .offset(y: dismissDrag)
            // Shrink a little as it goes, so the photo reads as leaving
            // rather than sliding off the bottom.
            .scaleEffect(1 - min(dismissDrag / 1600, 0.12))
            .gesture(gesture)
        #endif
    }

    #if !os(tvOS)
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                #if !os(visionOS)
                guard onDismissDrag != nil else { return }
                // Claim the drag only once it is clearly vertical, so a
                // horizontal swipe between gallery images is untouched.
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dismissDrag = max(0, value.translation.height)
                #endif
            }
            .onEnded { value in
                #if !os(visionOS)
                if let onDismissDrag,
                   abs(value.translation.height) > abs(value.translation.width) {
                    // Either a decisive distance or a flick counts, matching
                    // the horizontal swipe's own velocity assist.
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                        onDismissDrag()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dismissDrag = 0
                    }
                    return
                }
                dismissDrag = 0
                #endif
                guard enabled else { return }
                onEnded(value.translation.width, value.predictedEndTranslation.width)
            }
    }
    #endif
}

// Only used from the RealityKit `is3DMode` branch above, which is itself
// `#if os(visionOS)` — `targetedToAnyEntity()` and `DragGesture` are both
// visionOS/iOS-only (unavailable on tvOS).
#if os(visionOS)
/// Adds a targeted entity drag gesture for swipe navigation on RealityKit views.
/// Uses discrete detection (onEnded only) to avoid per-frame offset flicker on visionOS.
private struct EntitySwipeGestureModifier: ViewModifier {
    let enabled: Bool
    let onEnded: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 20)
                .targetedToAnyEntity()
                .onEnded { value in
                    guard enabled else { return }
                    onEnded(value.translation.width, value.predictedEndTranslation.width)
                }
        )
    }
}
#endif
