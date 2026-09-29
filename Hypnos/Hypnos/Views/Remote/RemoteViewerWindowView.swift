/*
 Hypnos - Remote Viewer Window View

 Main viewer window that displays a slideshow of images from the
 remote API with clock, sensor overlays, Ken Burns animation,
 and ornament controls.
 */

import Combine
import DebugTrace
import RAVEMedia
import RAVESlideshow
import RAVEUI
import SwiftUI

struct RemoteViewerWindowView: View {
    let windowValue: RemoteViewerWindowValue
    /// Writes the resolved window size back into the Codable window value so
    /// visionOS persists it for the next cold relaunch (scene restoration).
    var onSizeSettled: ((CGSize) -> Void)? = nil
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.scenePhase) private var scenePhase
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow

    @State private var viewerModel: RemoteViewerModel?
    @State private var showHistory = false
    @State private var windowSize: CGSize = .zero
    @State private var currentTime = Date()
    @State private var autoHideTimer: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var didArmInitialAutoHide = false
    @State private var isRestoredWindow = false
    @State private var showRestorationPlaceholder = false
    @State private var metalRendererGeneration = 0
    @State private var renderRecoveryAttempt = 0
    @State private var renderRecoveryTask: Task<Void, Never>?
    @State private var didRecreateDeadScene = false

    // Ken Burns animation state
    @State private var kenBurnsScale: CGFloat = 1.0
    @State private var kenBurnsOffset: CGSize = .zero

    /// Alternates the ±1pt direction of the slideshow's IPC calibration
    /// nudge so the visible motion stays symmetric over time. Mirrors the
    /// fix in PhotoDisplayView — IPC drops its off-axis blur calibration
    /// across image swaps and only a real geometry change reasserts it.
    @State private var nudgeAlternator: Bool = false

    /// Persists / re-asserts the user's custom window size across cold
    /// relaunches. Shared with the pinned web-page window.
    @State private var sizePersistence: WindowSizePersistence?

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            // When diorama is on, the foreground plane is popped forward by
            // dioramaDistance in Z. Overlays anchored at z=0 would be occluded,
            // so lift them in front of the foreground plane. Match the
            // ornament's +30pt clearance on top of the foreground offset.
            let overlayZ: CGFloat = (viewerModel?.enableDiorama ?? false)
                ? appModel.dioramaDistance + 30
                : 0
            ZStack {
                // Background
                if !(viewerModel?.config.transparentBackground ?? false) {
                    Color.black.ignoresSafeArea()
                }

                if showRestorationPlaceholder {
                    WindowRestorationPlaceholder(
                        title: "Restoring Slideshow",
                        windowID: windowValue.id,
                        status: remoteRestorationStatus
                    )
                    .offset(z: overlayZ)
                }

                // Image layers — brightness/contrast/saturation are
                // pushed into MetalImageView's fragment shader for the
                // base texture and applied as SwiftUI modifiers inside
                // imageLayer for the diorama / WKWebView / video paths
                // (which aren't Metal-backed). Opacity stays at the top
                // level so it composites the whole stack uniformly.
                if let model = viewerModel {
                    imageLayer(model: model)
                        .opacity(model.effectiveOpacity)
                }

                // Clock overlay
                if let model = viewerModel, model.showClock {
                    clockOverlay(model: model)
                        .offset(z: overlayZ)
                }

                // Sensor overlay
                if let model = viewerModel, model.showSensors, !model.sortedSensors.isEmpty {
                    sensorOverlay(model: model)
                        .offset(z: overlayZ)
                }

                // Loading indicator — only when truly nothing is on screen.
                // A video/GIF/WebP plays via its own WKWebView layer (and
                // leaves currentImage nil), so checking currentImage alone
                // would pop the spinner over a playing video while the next
                // image prefetches. Gate on the image media type too so the
                // spinner appears only when there is genuinely no media shown
                // (e.g. first paint, or space restoration of snapped windows).
                if let model = viewerModel,
                   model.isLoading, model.currentMediaType == .image, model.currentImage == nil {
                    ProgressView()
                        .scaleEffect(2)
                        .offset(z: overlayZ)
                }

                // Toast notification
                if let model = viewerModel, let toast = model.toastMessage {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(toast)
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(model.toastIsError ? Color.red.opacity(0.85) : Color.black.opacity(0.7))
                                )
                            Spacer()
                        }
                        .padding(.bottom, 80)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut, value: model.toastMessage)
                    .offset(z: overlayZ)
                }

                // History overlay
                if showHistory, let model = viewerModel,
                   let store = appModel.remoteHistoryStore(for: model.config.apiEndpoint, accessToken: model.config.accessToken) {
                    RemoteHistoryView(
                        store: store,
                        onEntrySelected: { entry in
                            model.jumpToHistoryEntry(entry)
                            showHistory = false
                        }
                    )
                    .transition(.opacity)
                }
            }
            .onAppear {
                windowSize = geo.size
                sizePersistence?.currentSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                windowSize = newSize
                viewerModel?.updateWindowAspectRatio(newSize)
                sizePersistence?.currentSize = newSize
                sizePersistence?.scheduleWriteback(newSize)
            }
        }
        .ornament(
            visibility: controlsVisible ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomFront),
            contentAlignment: .top,
            ornament: {
                if let model = viewerModel, let tlm = model.tagListManager {
                    RemoteViewerOrnamentView(
                        model: model,
                        tagListManager: tlm,
                        modTagManager: appModel.modTagManager,
                        showHistory: $showHistory
                    )
                    .offset(z: model.enableDiorama ? 30 : 0)
                }
            }
        )
        .onAppear {
            isRestoredWindow = RestoredWindowTracker.isRestored(windowValue.id)
            showRestorationPlaceholder = isRestoredWindow
            AppLogger.windowState.info(
                "[Remote \(windowValue.id.uuidString, privacy: .public)] view appeared restored=\(self.isRestoredWindow, privacy: .public) config=\(windowValue.configId.uuidString, privacy: .public) savedSize=\(String(describing: windowValue.restoredSize?.cgSize), privacy: .public)"
            )
            setupModel()
            // Wall-snapped slideshow windows restored by visionOS after a
            // reboot come back with the same windowValue UUID. Keep controls
            // visible until the first post arrives so a failed first frame
            // never leaves a transparent, non-interactive window.
            if !isRestoredWindow {
                RestoredWindowTracker.markSeen(windowValue.id)
            }
            // Restore the user's custom window size/aspect ratio from the scene
            // archive. visionOS restores wall-snapped windows at the scene
            // `.defaultSize` (1400×900), so reassert the persisted size here.
            setupSizePersistence()
        }
        .onDisappear {
            if let model = viewerModel {
                appModel.unregisterRemoteViewerModel(model)
            }
            // Unregister unconditionally. Gating this on the model meant a
            // window whose config never resolved could never be unregistered,
            // so the registry kept claiming it was open forever.
            appModel.unregisterRemoteViewerWindow(configId: windowValue.configId, windowValueId: windowValue.id)
            viewerModel?.stop()
            autoHideTimer?.cancel()
            renderRecoveryTask?.cancel()
            sizePersistence?.cancel()
        }
        .onChange(of: viewerModel?.isTransitioning) { _, isTransitioning in
            // Refresh IPC's off-axis blur calibration mid-crossfade so
            // the window's 1pt size flicker is masked by the fade
            // itself instead of popping in once the new image is fully
            // visible. Crossfade is 1s; halfway is the visual quietest
            // point (both slots at ~0.5 opacity). No-op unless
            // slideshow 3D is active.
            guard isTransitioning == true,
                  viewerModel?.isSlideshow3DActive == true else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard viewerModel?.isSlideshow3DActive == true else { return }
                nudgeWindowSizeForCalibration()
            }
        }
        .onChange(of: viewerModel?.currentPost?.id) { _, postId in
            guard postId != nil else { return }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            viewerModel?.handleScenePhaseChange(from: oldPhase, to: newPhase)
            if newPhase == .active && oldPhase != .active, viewerModel?.isSlideshow3DActive == true {
                nudgeWindowSizeForCalibration()
            }
            // Restart Ken Burns animation on return to foreground — the SwiftUI
            // animation is time-based and continues running while backgrounded,
            // so the remaining duration would be too short without a restart.
            if newPhase == .active && oldPhase != .active, let model = viewerModel {
                if model.currentMediaType == .image && !model.isCurrentPostAnimatedGIF {
                    startKenBurnsAnimation(model: model)
                }
            }
        }
        .onReceive(clockTimer) { time in
            currentTime = time
        }
        .onChange(of: appModel.globalVisualAdjustments) { _, newValue in
            viewerModel?.globalAdjustments = newValue
        }
        .onChange(of: appModel.effectiveReduceMotion, initial: true) { _, newValue in
            viewerModel?.reduceMotion = newValue
        }
        .onChange(of: viewerModel?.showAdjustmentsPopover) { _, isOpen in
            if isOpen == true {
                autoHideTimer?.cancel()
            } else {
                resetAutoHideTimer()
            }
        }
        .onChange(of: viewerModel?.isAnyOrnamentMenuOpen) { _, isOpen in
            if isOpen == true {
                autoHideTimer?.cancel()
            } else {
                resetAutoHideTimer()
            }
        }
        .onChange(of: showHistory) { _, isOpen in
            guard isOpen, let model = viewerModel,
                  let store = appModel.remoteHistoryStore(for: model.config.apiEndpoint, accessToken: model.config.accessToken)
            else { return }
            Task { await store.refresh() }
        }
        .contentShape(.rect)
        .onTapGesture {
            controlsVisible.toggle()
            if controlsVisible {
                resetAutoHideTimer()
            } else {
                autoHideTimer?.cancel()
            }
            // Manual IPC blur recovery, matching the regular 3D photo
            // viewer's tap behaviour. The per-crossfade nudge already
            // covers steady-state, but a stray tap is the user's
            // expected escape hatch when calibration has drifted.
            if viewerModel?.isSlideshow3DActive == true {
                nudgeWindowSizeForCalibration()
            }
        }
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .hidesStatusBar(!controlsVisible)
    }

    @ViewBuilder
    private func imageLayer(model: RemoteViewerModel) -> some View {
        ZStack {
            // Static first-frame fallback for animated media (.animatedWebP via
            // WKWebView, .animatedGIF via the HEVC player). Both take a few
            // hundred ms to spin up on first creation — for GIFs the player is
            // only swapped in *after* the crossfade once HEVC conversion
            // finishes, so without this the slideshow briefly goes blank.
            // Rendered behind the live player in the ZStack so it shows through
            // until the player paints, then is visually covered by the
            // animation.
            if model.isAnimatedMediaWithStaticFallback,
               let image = model.currentImage {
                currentImageRenderer(model: model, image: image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .opacity(model.isTransitioning ? 0 : 1)
                    .clipped()
            }

            // Video / animated GIF layer (WebVideoPlayerView)
            switch model.currentMediaType {
            case .video, .videoAsImage:
                // Rendered by the unified video layer below (see activeVideoURL)
                // so the player survives the image→video crossfade commit.
                EmptyView()

            case .animatedGIF(let hevcURL):
                // Backgrounded windows fall back to the static first-frame layer
                // rendered above (isAnimatedMediaWithStaticFallback). Dropping the
                // WKWebView here tears down its out-of-process WebContent/GPU
                // helpers — which don't count toward our process footprint but do
                // pin device memory — and it rebuilds on return to active.
                //
                // tvOS has no WebKit at all, so it always shows that static
                // first frame instead of animating — see Hypnos/CLAUDE.md "tvOS".
                #if canImport(WebKit)
                if model.isRoomActive {
                    WebVideoPlayerView(
                        videoURL: hevcURL,
                        showControls: false,
                        isRoomActive: model.isRoomActive
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Also show the static image underneath during transition
                    .opacity(model.isTransitioning ? 0 : 1)
                    .brightness(model.effectiveBrightness)
                    .contrast(model.effectiveContrast)
                    .saturation(model.effectiveSaturation)
                }
                #endif

            case .animatedWebP(let url):
                #if canImport(WebKit)
                if model.isRoomActive {
                    AnimatedImageWebView(
                        imageURL: url,
                        elementType: .image,
                        imageData: model.currentAnimatedData,
                        imageDataMimeType: "image/webp"
                    )
                    .aspectRatio(model.currentImage?.size ?? CGSize(width: 1, height: 1), contentMode: .fit)
                    // Fade out during crossfade so the next image's static
                    // texture (or its own WebKit layer) takes over cleanly.
                    .opacity(model.isTransitioning ? 0 : 1)
                    .brightness(model.effectiveBrightness)
                    .contrast(model.effectiveContrast)
                    .saturation(model.effectiveSaturation)
                }
                #endif

            case .animatedJXL:
                #if canImport(WebKit)
                if model.isRoomActive {
                    AnimatedJXLWebView(imageData: model.currentAnimatedData)
                        .aspectRatio(model.currentImage?.size ?? CGSize(width: 1, height: 1), contentMode: .fit)
                        .opacity(model.isTransitioning ? 0 : 1)
                        .brightness(model.effectiveBrightness)
                        .contrast(model.effectiveContrast)
                        .saturation(model.effectiveSaturation)
                }
                #endif

            case .image:
                EmptyView()
            }

            // Slideshow 3D path (RealityKit) — replaces the SwiftUI image
            // pipeline when the profile selects 3D / Immersive 3D. The
            // layer owns two slot entities and pre-generates the next
            // image while the current is on screen, then crossfades by
            // swapping which slot is visible.
            if model.currentMediaType == .image && model.isSlideshow3DActive {
                // Tap callback fires from a targeted-entity gesture
                // wired inside each slot's RealityView — visionOS hit-
                // tests RealityKit entities in 3D space ahead of SwiftUI
                // overlays, so SwiftUI .onTapGesture / Color.clear
                // overlays in this region never see the tap.
                // Adjustments are baked into the Spatial3DImage's source
                // bytes inside SlideshowSpatial3DSlotView — RealityKit
                // content on visionOS doesn't honor SwiftUI compositing
                // modifiers like `.brightness`, so applying them here is
                // a no-op. Cache-key-keyed regeneration in the slot view
                // handles applying new values to future images and the
                // hidden pre-generated slot.
                SlideshowSpatial3DLayer(
                    model: model,
                    onTap: {
                        controlsVisible.toggle()
                        if controlsVisible {
                            resetAutoHideTimer()
                        } else {
                            autoHideTimer?.cancel()
                        }
                        nudgeWindowSizeForCalibration()
                    },
                    onSpatial3DGenerated: { image in
                        model.notifySpatial3DGenerated(image: image)
                        markContentPresented(renderer: "RealityKit")
                    }
                )
            }

            // Current image (shown for .image type, or as static first frame while GIF converts)
            if model.currentMediaType == .image && !model.isSlideshow3DActive, let image = model.currentImage {
                let useKenBurns = model.enableKenBurns && !model.isCurrentPostAnimatedGIF
                currentImageRenderer(model: model, image: image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .scaleEffect(useKenBurns ? kenBurnsScale : 1.0)
                    .offset(useKenBurns ? kenBurnsOffset : .zero)
                    .opacity(model.isTransitioning ? 0 : 1)
                    .clipped()

                // Diorama layers — hidden whenever an ornament-anchored
                // panel is open (adjustments popover, tag-list / mod-tag
                // menus). The popped-forward foreground at z=40 would
                // otherwise occlude the menu drop-down which renders near
                // the window plane.
                let dioramaVisible = model.enableDiorama
                    && !model.showAdjustmentsPopover
                    && !model.isAnyOrnamentMenuOpen
                    && !showHistory

                // Wrapped so a single .animation modifier drives the
                // fade-in when the diorama layers materialize after
                // fire-and-forget generation, instead of snapping in.
                Group {
                    if dioramaVisible, let backdrop = model.currentBackdropTexture {
                        MetalImageView(
                            texture: backdrop,
                            brightness: Float(model.effectiveBrightness),
                            contrast: Float(model.effectiveContrast),
                            saturation: Float(model.effectiveSaturation),
                            sharpen: 0
                        )
                            .aspectRatio(CGFloat(backdrop.width) / CGFloat(backdrop.height), contentMode: .fit)
                            .scaleEffect(useKenBurns ? kenBurnsScale : 1.0)
                            .offset(useKenBurns ? kenBurnsOffset : .zero)
                            .opacity(model.isTransitioning ? 0 : 1)
                            .clipped()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    if dioramaVisible, let foreground = model.currentForegroundTexture {
                        MetalImageView(
                            texture: foreground,
                            brightness: Float(model.effectiveBrightness),
                            contrast: Float(model.effectiveContrast),
                            saturation: Float(model.effectiveSaturation),
                            sharpen: 0
                        )
                            .aspectRatio(CGFloat(foreground.width) / CGFloat(foreground.height), contentMode: .fit)
                            .scaleEffect(useKenBurns ? kenBurnsScale : 1.0)
                            .offset(useKenBurns ? kenBurnsOffset : .zero)
                            .opacity(model.isTransitioning ? 0 : 1)
                            .clipped()
                            .offset(z: appModel.dioramaDistance)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: dioramaVisible)
                .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: model.currentForegroundTexture != nil)
                .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: model.currentBackdropTexture != nil)
            }

// Next image (fading in during transition) — skipped when slideshow 3D
            // owns the rendering since that path stacks two RealityViews.
            if !model.isSlideshow3DActive, let image = model.nextImage, model.isTransitioning {
                nextImageRenderer(model: model, image: image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .opacity(1)
                    .clipped()

                if model.enableDiorama, let backdrop = model.nextBackdropTexture {
                    MetalImageView(
                        texture: backdrop,
                        brightness: Float(model.effectiveBrightness),
                        contrast: Float(model.effectiveContrast),
                        saturation: Float(model.effectiveSaturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(backdrop.width) / CGFloat(backdrop.height), contentMode: .fit)
                        .clipped()
                        .allowsHitTesting(false)
                }
                if model.enableDiorama, let foreground = model.nextForegroundTexture {
                    MetalImageView(
                        texture: foreground,
                        brightness: Float(model.effectiveBrightness),
                        contrast: Float(model.effectiveContrast),
                        saturation: Float(model.effectiveSaturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(foreground.width) / CGFloat(foreground.height), contentMode: .fit)
                        .clipped()
                        .offset(z: appModel.dioramaDistance)
                        .allowsHitTesting(false)
                }
            }

            // Unified video layer. A single WebVideoPlayerView hosts both the
            // incoming image→video crossfade slot and the committed video slot.
            // Because the view's position and `videoURL` are identical before
            // and after the crossfade commit (see `activeVideoURL`), SwiftUI
            // preserves its identity across the commit instead of destroying
            // the playing layer and creating a fresh one — which previously
            // forced a reload and a brief blank flash right after the crossfade.
            if let videoURL = model.activeVideoURL {
                let isOutgoing = model.isTransitioning && model.nextVideoURL == nil
                Group {
                    if let url3D = model.activePseudo3DVideoURL {
                        // Slideshow 3D + an installed real-time depth model:
                        // convert the mono clip to windowed stereoscopic 3D on
                        // the fly. Always `.realtime` — the pre-processed mode
                        // would write a depth video per clip to disk, and a
                        // slideshow cycles through far too much content for
                        // that. Depth here lives only as long as the frame it
                        // warps.
                        Pseudo3DVideoPlayerView(
                            videoURL: url3D,
                            isRoomActive: model.isRoomActive,
                            // RealityKit ignores SwiftUI's .brightness/.contrast/
                            // .saturation, so the slideshow's adjustments (incl.
                            // dynamic brightness) ride the warp shader instead.
                            visualAdjustments: pseudo3DAdjustments(model: model),
                            settings: appModel.globalPseudo3DSettings,
                            depthMode: .realtime,
                            loops: model.currentVideoLoops,
                            // Same reason as the adjustments: the .opacity below
                            // can't fade RealityKit content, so the crossfade is
                            // driven through the scene's OpacityComponent.
                            contentOpacity: isOutgoing ? 0 : 1,
                            onDurationKnown: { [weak model] seconds in
                                guard let model, let post = model.nextPost ?? model.currentPost else { return }
                                model.onVideoDurationKnown(seconds, for: post)
                            },
                            onPlaybackError: { [weak model] in
                                // No usable depth or the stereo pipeline can't
                                // decode this source — drop to the flat tiers.
                                model?.reportPseudo3DVideoFailure()
                            }
                        )
                    } else {
                        // Swift's conditional compilation requires each
                        // `#if`/`#else` branch to be a complete, independently
                        // balanced statement — it can't pick up an `if` opened
                        // outside the block, so the WebKit-vs-tvOS split lives
                        // entirely inside this `else`, not spliced across the
                        // `if let url3D` above.
                        #if canImport(WebKit)
                        if model.activeVideoIsAnimatedImage {
                            // Native tier: WebKit plays H.264 in an <img>, managing
                            // playback lifecycle itself (pause / resume on room
                            // transitions) — no AVPlayer, no isRoomActive/duration
                            // wiring. If the source isn't a codec <img> can decode,
                            // onError escalates to the <video> tiers (raw → HLS).
                            AnimatedImageWebView(imageURL: videoURL, onError: { [weak model] in
                                model?.videoNativeImgFailed = true
                            })
                        } else {
                            // Fallback tiers: <video> plays the raw source natively
                            // (WebM/AV1 the device supports); on decode error it
                            // switches to the HLS stream (server-transcoded H.264).
                            WebVideoPlayerView(
                                videoURL: videoURL,
                                fallbackVideoURL: model.currentVideoHLSURL,
                                showControls: false,
                                isRoomActive: model.isRoomActive,
                                onDurationKnown: { [weak model] seconds in
                                    // During the image→video crossfade the incoming clip is
                                    // `nextPost` — loadedmetadata usually fires before the
                                    // engine commits it to `currentPost`. Attribute the
                                    // duration to the post that owns the video, not whatever
                                    // is still fading out.
                                    guard let model, let post = model.nextPost ?? model.currentPost else { return }
                                    model.onVideoDurationKnown(seconds, for: post)
                                },
                                loop: model.currentVideoLoops
                            )
                        }
                        #else
                        // tvOS: no WebKit, so no native-<img> or raw/HLS <video>
                        // tiers either. A slideshow post needing either simply
                        // doesn't play its video layer here.
                        EmptyView()
                        #endif
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fade out only when this is the *outgoing* video (video→video
                // through black, or video→image). When a video is crossfading
                // *in* over a fading image (nextVideoURL set), it stays at full
                // opacity and the image fades beneath it.
                .opacity(isOutgoing ? 0 : 1)
                .brightness(model.effectiveBrightness)
                .contrast(model.effectiveContrast)
                .saturation(model.effectiveSaturation)
                .onAppear {
                    markContentPresented(
                        renderer: model.activePseudo3DVideoURL != nil
                            ? "RealityKit stereo video" : "WebKit video"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.currentPost?.id) { _, _ in
            // Only animate Ken Burns for static images (not GIFs or videos)
            if model.currentMediaType == .image && !model.isCurrentPostAnimatedGIF {
                startKenBurnsAnimation(model: model)
            } else {
                resetKenBurns()
            }
        }
        .onChange(of: model.currentMediaType) { _, newType in
            // When media type changes (e.g. GIF HEVC conversion completes), reset Ken Burns
            if newType != .image {
                resetKenBurns()
            }
        }
    }

    /// Packs the slideshow's effective adjustments for the fake-3D warp shader.
    /// RealityKit content on visionOS doesn't honor SwiftUI's compositing
    /// modifiers, so brightness/contrast/saturation have to be baked into the
    /// per-eye warp the way `SlideshowSpatial3DSlotView` bakes them into the
    /// image bytes. `VisualAdjustments` declares its own init, so there's no
    /// memberwise one to call inline.
    private func pseudo3DAdjustments(model: RemoteViewerModel) -> VisualAdjustments {
        var adjustments = VisualAdjustments()
        adjustments.brightness = model.effectiveBrightness
        adjustments.contrast = model.effectiveContrast
        adjustments.saturation = model.effectiveSaturation
        return adjustments
    }

    /// Renders the current image via Metal when a GPU texture is available,
    /// otherwise falls back to a SwiftUI `Image` so the slideshow never
    /// goes blank if texture creation lags or fails. Adjustments ride the
    /// fragment-shader uniforms on the Metal path; the UIImage fallback
    /// uses SwiftUI modifiers so its output matches.
    @ViewBuilder
    private func currentImageRenderer(model: RemoteViewerModel, image: UIImage) -> some View {
        if let texture = model.currentTexture {
            MetalImageView(
                texture: texture,
                brightness: Float(model.effectiveBrightness),
                contrast: Float(model.effectiveContrast),
                saturation: Float(model.effectiveSaturation),
                sharpen: 0,
                diagnosticLabel: "remote-\(windowValue.id.uuidString.prefix(8))",
                onFramePresented: {
                    markContentPresented(renderer: "Metal")
                },
                onRenderStalled: recoverStalledRenderer
            )
            .id(metalRendererGeneration)
        } else {
            Image(platformImage: image)
                .resizable()
                .brightness(model.effectiveBrightness)
                .contrast(model.effectiveContrast)
                .saturation(model.effectiveSaturation)
                .onAppear {
                    markContentPresented(renderer: "SwiftUI image")
                }
        }
    }

    @ViewBuilder
    private func nextImageRenderer(model: RemoteViewerModel, image: UIImage) -> some View {
        if let texture = model.nextTexture {
            MetalImageView(
                texture: texture,
                brightness: Float(model.effectiveBrightness),
                contrast: Float(model.effectiveContrast),
                saturation: Float(model.effectiveSaturation),
                sharpen: 0
            )
        } else {
            Image(platformImage: image)
                .resizable()
                .brightness(model.effectiveBrightness)
                .contrast(model.effectiveContrast)
                .saturation(model.effectiveSaturation)
        }
    }

    @ViewBuilder
    private func clockOverlay(model: RemoteViewerModel) -> some View {
        let scale = model.config.textSize

        VStack {
            Spacer()
            HStack {
                // Clock (bottom-left)
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeString)
                        .font(.system(size: 48 * scale, weight: .light, design: .monospaced))
                    Text(dateString)
                        .font(.system(size: 20 * scale, weight: .regular))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.7))
                )
                .padding(16)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func sensorOverlay(model: RemoteViewerModel) -> some View {
        let scale = model.config.textSize

        VStack {
            HStack {
                Spacer()
                // Sensors (top-right)
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(model.sortedSensors) { sensor in
                        HStack(spacing: 4) {
                            if sensor.isUnavailable {
                                Text("\u{2757}")
                            }
                            Text(sensor.friendlyName + ":")
                            Text(sensor.isUnavailable ? (sensor.lastKnownState ?? "N/A") : sensor.state)
                            if !sensor.unitOfMeasurement.isEmpty {
                                Text(sensor.unitOfMeasurement)
                            }
                            Text(sensor.displayEmoji)
                        }
                        .font(.system(size: 16 * scale))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.7))
                )
                .padding(16)
            }
            Spacer()
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: currentTime)
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: currentTime)
    }

    private var remoteRestorationStatus: String {
        guard let model = viewerModel else {
            return "Resolving viewer configuration"
        }
        if model.currentPost == nil {
            return model.isLoading ? "Loading first post" : "Waiting for server playback"
        }
        if let texture = model.currentTexture {
            return "Waiting for Metal frame (\(texture.width)x\(texture.height))"
        }
        if model.currentImage != nil {
            return "Waiting for image renderer"
        }
        return "Waiting for \(String(describing: model.currentMediaType))"
    }

    private func markContentPresented(renderer: String) {
        renderRecoveryTask?.cancel()
        renderRecoveryTask = nil
        renderRecoveryAttempt = 0
        if showRestorationPlaceholder {
            showRestorationPlaceholder = false
            AppLogger.windowState.info(
                "[Remote \(windowValue.id.uuidString, privacy: .public)] content frame reported renderer=\(renderer, privacy: .public)"
            )
        }
        if !didArmInitialAutoHide {
            didArmInitialAutoHide = true
            controlsVisible = true
            resetAutoHideTimer()
        }
    }

    private func recoverStalledRenderer() {
        guard renderRecoveryAttempt < 3 else {
            AppLogger.windowState.error(
                "[Remote \(windowValue.id.uuidString, privacy: .public)] renderer recovery exhausted"
            )
            recreateDeadSceneIfNeeded()
            return
        }
        renderRecoveryAttempt += 1
        showRestorationPlaceholder = true
        controlsVisible = true
        autoHideTimer?.cancel()
        metalRendererGeneration += 1
        viewerModel?.refreshCurrentTextureForRenderRecovery()
        AppLogger.windowState.warning(
            "[Remote \(windowValue.id.uuidString, privacy: .public)] rebuilding Metal renderer attempt=\(self.renderRecoveryAttempt, privacy: .public)"
        )

        renderRecoveryTask?.cancel()
        renderRecoveryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, showRestorationPlaceholder else { return }
            await nudgeSceneForRenderRecovery()
        }
    }

    /// Last rung after renderer rebuilds and scene nudges have all failed: the
    /// scene claims to be active but has never produced a frame. On visionOS 27
    /// the room-persistence machinery can activate a summoned/restored scene
    /// without ever re-attaching it to a compositor placement — nothing inside
    /// the scene (new views, geometry updates) can revive it, so the only
    /// recovery is recreating the scene session: Apple's own documented beta
    /// workaround ("close the blank window and relaunch"), done
    /// programmatically. One attempt per window, and only while the scene
    /// claims foreground-active so a healthily parked window is never touched.
    private func recreateDeadSceneIfNeeded() {
        guard scenePhase == .active, !didRecreateDeadScene else { return }
        didRecreateDeadScene = true
        AppLogger.windowState.error(
            "[Remote \(windowValue.id.uuidString, privacy: .public)] scene never produced a frame — recreating window"
        )
        var value = RemoteViewerWindowValue(configId: windowValue.configId)
        if let scene = resolvedWindowScene {
            let size = scene.effectiveGeometrySize
            if Self.isPlausibleWindowSize(size) {
                value.restoredSize = RAVECodableSize(size)
            }
        }
        openWindow(id: "remote-viewer", value: value)
        dismissWindow(id: "remote-viewer", value: windowValue)
    }

    private func nudgeSceneForRenderRecovery() async {
        guard let scene = resolvedWindowScene else { return }
        AppLogger.windowState.warning(
            "[Remote \(windowValue.id.uuidString, privacy: .public)] nudging scene for render recovery"
        )
        await WindowSizeNudge.perform(on: scene, delta: 1)
    }

    private func setupModel() {
        guard viewerModel == nil else { return }

        // Look up config from saved configs or the gallery/video slideshow configs
        guard let config = appModel.remoteViewerConfig(id: windowValue.configId) else {
            AppLogger.remoteViewer.error("No config found for id \(windowValue.configId.uuidString, privacy: .public)")
            return
        }

        let model = RemoteViewerModel(config: config, windowId: windowValue.id)
        model.globalAdjustments = appModel.globalVisualAdjustments
        // Per-profile slideshow resolution caps fall back to the slideshow
        // defaults, which themselves default to 4096px.
        let resolved2D = config.maxImageResolution2D ?? appModel.slideshowMaxImageResolution2D
        let resolved3D = config.maxImageResolution3D ?? appModel.slideshowMaxImageResolution3D
        model.maxImageResolution = resolved2D
        model.maxImageResolution3D = resolved3D
        model.slideshow3DMode = config.slideshow3DMode
        model.updateWindowAspectRatio(windowSize)

        // Tag list state is per-window (created in RemoteViewerModel.init); the
        // current list is server-tracked. Seed the catalog from the last one
        // the app saw so the ornament has list names before the server
        // re-pushes `tagLists`, and mirror future pushes back for the next
        // window that opens.
        model.tagListManager?.tagLists = appModel.tagListCatalog
        model.tagListManager?.clampActiveIndex()
        model.onCatalogReceived = { [weak appModel] lists in
            appModel?.tagListCatalog = lists
        }
        model.modTagManager = appModel.modTagManager

        // Which content this window shows follows from the profile's mode. It
        // used to hinge on `apiEndpoint.isEmpty`, which made "no server
        // configured" indistinguishable from "show me the app's own gallery".
        switch config.mode {
        case .appGallery:
            // Launched by the play button, which parks the live source in a
            // transient override right before opening the window.
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
        case .slideshow:
            model.contentProvider = RemoteContentProvider(
                apiClient: model.apiClient,
                baseURL: config.apiEndpoint,
                accessToken: config.accessToken,
                deviceId: model.slideshowDeviceId
            )
        case .webPage:
            // A `.webPage` profile is built by WebPageWindowView, not here;
            // RemoteViewerSceneRoot routes on the same mode.
            AppLogger.remoteViewer.error(
                "Website profile “\(config.name)” reached the slideshow window"
            )
            return
        }

        // Wire up window callbacks
        model.onOpenAlertWindow = { [openWindow] text, bgColor, imageUrl in
            openWindow(id: "remote-alert", value: RemoteAlertWindowValue(text: text, bgColorHex: bgColor, imageUrl: imageUrl))
        }
        model.onDismissAlertWindow = { [dismissWindow] in
            dismissWindow(id: "remote-alert")
        }

        model.onConfigChanged = { [appModel] updatedConfig in
            // `updatedConfig` is this window's snapshot from when it opened
            // plus whatever the ornament just changed. Saving it as-is would
            // revert every unrelated edit the Remote tab made since the window
            // opened, so merge the viewer-owned display fields onto whatever
            // the profile looks like now.
            guard var current = appModel.remoteViewerConfig(id: updatedConfig.id) else {
                appModel.persistRemoteViewerConfig(updatedConfig)
                return
            }
            current.applyViewerDisplaySettings(from: updatedConfig)
            appModel.persistRemoteViewerConfig(current)
        }

        model.windowValue = windowValue
        self.viewerModel = model
        appModel.registerRemoteViewerWindow(configId: config.id, windowValue: windowValue)
        appModel.registerRemoteViewerModel(model)
        if config.mode == .appGallery {
            let mode3D: RAVESlideshow3DMode = switch config.slideshow3DMode {
            case .off: .off
            case .spatial3D: .spatial3D
            case .immersive3D: .immersive3D
            }
            model.useRAVESlideshowForLocalContent(
                mode3D: mode3D,
                maxImageResolution2D: resolved2D,
                maxImageResolution3D: resolved3D
            )
        }
        model.start()
    }

    private func startKenBurnsAnimation(model: RemoteViewerModel) {
        guard model.enableKenBurns else { return }

        resetKenBurns()

        // Then animate the zoom-in to the focus point
        let focus = model.focusPoint
        let targetScale: CGFloat = 1.3
        let offsetX = (focus.x - 0.5) * windowSize.width * 0.15
        let offsetY = (focus.y - 0.5) * windowSize.height * 0.15

        withAnimation(.easeInOut(duration: model.delay)) {
            kenBurnsScale = targetScale
            kenBurnsOffset = CGSize(width: -offsetX, height: -offsetY)
        }
    }

    private func resetKenBurns() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            kenBurnsScale = 1.0
            kenBurnsOffset = .zero
        }
    }

    /// Smallest geometry this window is allowed to occupy, and the floor below
    /// which a persisted size is treated as corrupt rather than restored.
    static let minimumWindowSize = WindowSizePersistence.defaultMinimumSize

    /// Whether a size is one the user could plausibly have resized to, as
    /// opposed to transient layout noise from a window the compositor hasn't
    /// placed yet. Guards both ends of the persist/restore round-trip.
    static func isPlausibleWindowSize(_ size: CGSize) -> Bool {
        WindowSizePersistence.isPlausible(size, minimum: minimumWindowSize)
    }

    /// Resolve the window scene hosting this viewer for geometry updates
    /// (restored-size apply, IPC calibration nudge). This is strictly THIS
    /// window's scene from the environment: the old foreground-active fallback
    /// could resolve to a *different* window and send it our resize, which is
    /// exactly the failure mode `VideoWindowView`'s aspect lock documents.
    private var resolvedWindowScene: PlatformWindowScene? {
        sceneDelegate?.windowScene
    }

    /// Create the size-persistence helper for this window and re-assert the
    /// user's custom size. The mechanics live in `WindowSizePersistence` so the
    /// pinned web-page window gets the same behaviour from one implementation.
    private func setupSizePersistence() {
        let persistence = WindowSizePersistence(
            windowId: windowValue.id,
            minimumSize: Self.minimumWindowSize,
            log: AppLogger.remoteViewer
        )
        persistence.currentSize = windowSize
        persistence.onSizeSettled = onSizeSettled
        persistence.windowScene = { [weak sceneDelegate] in sceneDelegate?.windowScene }
        sizePersistence = persistence
        persistence.applyRestoredSizeIfNeeded(archived: windowValue.restoredSize?.cgSize)
    }

    private func nudgeWindowSizeForCalibration() {
        guard let windowScene = resolvedWindowScene else { return }
        let delta: CGFloat = nudgeAlternator ? 1 : -1
        nudgeAlternator.toggle()
        Task { @MainActor in
            await WindowSizeNudge.perform(on: windowScene, delta: delta)
        }
    }

    private func resetAutoHideTimer() {
        autoHideTimer?.cancel()
        guard appModel.autoHideDelay > 0 else { return }
        autoHideTimer = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }
}
