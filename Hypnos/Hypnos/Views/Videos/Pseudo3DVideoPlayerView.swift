/*
 Hypnos - Pseudo 3D Video Player View

 The SwiftUI surface for real-time "fake 3D" video in a normal (Shared Space)
 window. Everything below the view — `Pseudo3DStereoEngine`, `StereoPump`, the
 depth sources and the warp shaders — now lives in `RAVEMedia`, because none of
 it is Hypnos-shaped: the browser (Raven) mounts the same engine on
 frames lifted out of a WKWebView instead of an AVPlayer.

 What stays here is what is genuinely this app's: the window-chrome geometry
 constants, the gesture wiring, and the binding of the engine's transport to
 `VideoWindowModel` / `VideoLoopController`.
 */

import RealityKit
import RAVEMedia
import SwiftUI

#if os(visionOS)

struct Pseudo3DVideoPlayerView: View {
    let videoURL: URL
    var isRoomActive: Bool = true
    /// When true (a menu/popover/sheet is open), recede the video plane within
    /// the RealityKit scene so it renders behind the presented chrome.
    var chromeOpen: Bool = false
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var visualAdjustments: VisualAdjustments = VisualAdjustments()
    var settings: Pseudo3DSettings = .default
    /// Realtime inference vs. pre-processed cached depth.
    var depthMode: Pseudo3DDepthMode = .realtime
    /// Resume position (seconds) captured from the 2D player at engage time.
    var startAtSeconds: Double? = nil
    /// Engage without auto-playing: seek to `startAtSeconds` and warp that one
    /// frame (visibly playable in 3D) but don't start sustained playback. Used
    /// for a progressive engage mid-conversion so a second decode session
    /// doesn't fight the converter's reader; manual Play starts it.
    var startPaused: Bool = false
    /// A stereo video that already holds both eyes: played live as real 3D,
    /// each eye cropped out, with no depth model. Nil warps a mono video.
    var packedStereo: RAVEPackedStereoLayout? = nil
    var isFlipped: Bool = false
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    /// Initial mute state applied when a video loads (autoplay always starts
    /// playback; this only controls whether it opens with audio).
    var startMuted: Bool = true
    /// Restart from the top at end of playback. The video window always loops;
    /// the slideshow only loops clips shorter than its dwell interval (a longer
    /// clip plays through once and the server times the advance off its end).
    var loops: Bool = true
    /// Scene-space opacity for the video plane, applied via `OpacityComponent`.
    /// RealityKit content on visionOS ignores SwiftUI's `.opacity`, so a caller
    /// that crossfades (the slideshow) has to drive the fade through here.
    var contentOpacity: Double = 1
    /// Fired once per loaded item when its duration becomes known — the
    /// AVPlayer equivalent of the web player's `loadedmetadata`.
    var onDurationKnown: ((Double) -> Void)? = nil
    var onPlaybackError: (() -> Void)? = nil
    /// Tap on the video surface (toggles chrome) — handled as a RealityKit tap
    /// target because a 2D overlay can't catch gaze over a RealityView.
    var onToggleUI: (() -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @State private var engine = Pseudo3DStereoEngine()

    /// Distance (points) the video plane is pulled back toward the window
    /// glass. `.frame(depth: 0, alignment: .front)` pins the slab to the front
    /// of the window's depth region, which on-device reads ~9cm in front of
    /// the ornament / window-controls plane. Offsetting the whole assembly
    /// (slab + its clip volume, via .offset(z:) on the GeometryReader3D, so
    /// the internal fit math is unaffected) brings the video back to the
    /// chrome's plane. ~10 points/cm; tune on device — 0 restores the old
    /// front-of-region placement.
    private static let videoPlaneZRecess: CGFloat = 90

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                engine.configure(
                    adjustments: visualAdjustments.stereoWarpAdjustments,
                    settings: settings,
                    isFlipped: isFlipped
                )
                engine.onVideoSizeKnown = onVideoSizeKnown
                engine.onPlaybackError = onPlaybackError
                engine.onDurationKnown = onDurationKnown
                engine.startMuted = startMuted
                engine.loops = loops
                engine.setContentOpacity(contentOpacity)
                engine.setSquareCorners(!appModel.roundedCorners)
                content.add(engine.makeVideoEntity())
                engine.observeVideoSize(content: content)
                engine.load(url: videoURL, roomActive: isRoomActive, depthMode: depthMode, startAt: startAtSeconds, startPaused: startPaused,
                            httpHeaderFields: MediaAuthorization.shared.headerFields(for: videoURL),
                            packedStereo: packedStereo)
            } update: { content in
                // Fit the video plane to the window (VideoPlayerComponent's screen
                // defaults to ~2× the window otherwise).
                let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                engine.updateViewBounds(bounds)
            }
            // Zero-depth slab keeps the video stable (nothing gets re-clipped
            // or culled). frame(depth:) defaults to .center alignment, which
            // parks the slab at the middle of the window's depth region — that
            // half-depth gap was the "Flip3D" recession. Align the slab to
            // .front; the videoPlaneZRecess offset below then pulls it back to
            // the ornament/window-controls plane (front of the depth region
            // measured ~9cm proud of the chrome on-device).
            .frame(depth: 0, alignment: .front)
            // Tapping the video toggles chrome. Targeted to the video entity's
            // tap-target collision (set up once the video size is known).
            .gesture(
                SpatialTapGesture()
                    .targetedToAnyEntity()
                    .onEnded { _ in onToggleUI?() }
            )
        }
        // Align the video plane with the chrome — see videoPlaneZRecess.
        .offset(z: -Self.videoPlaneZRecess)
        .onChange(of: videoURL) { _, newURL in
            engine.load(url: newURL, roomActive: isRoomActive, depthMode: depthMode,
                        httpHeaderFields: MediaAuthorization.shared.headerFields(for: newURL),
                        packedStereo: packedStereo)
        }
        // Follows Settings → Rounded Corners, like the photo viewer.
        .onChange(of: appModel.roundedCorners) { _, rounded in
            engine.setSquareCorners(!rounded)
        }
        .onChange(of: depthMode) { _, newMode in
            engine.setDepthMode(newMode)
        }
        // Real-time depth model switched (ViewMode menu or Settings): rebuild
        // the pump so the new model applies to THIS video immediately, keeping
        // position. (Cached playback is unaffected — its depth is baked.)
        .onChange(of: appModel.realtimeDepthModelName) { _, _ in
            if case .realtime = depthMode, packedStereo == nil {
                engine.reloadDepthPipeline()
            }
        }
        .onAppear {
            engine.startMuted = startMuted
            engine.loops = loops
            engine.onDurationKnown = onDurationKnown
            engine.bindCommands(loopController: loopController, playbackModel: playbackModel)
            engine.configure(adjustments: visualAdjustments.stereoWarpAdjustments, settings: settings, isFlipped: isFlipped)
            engine.setRoomActive(isRoomActive)
            engine.setChromeOpen(chromeOpen)
            engine.setContentOpacity(contentOpacity)
        }
        .onChange(of: loops) { _, new in
            engine.loops = new
        }
        .modifier(AnimatableSceneOpacity(opacity: contentOpacity) { [engine] value in
            engine.setContentOpacity(value)
        })
        .onChange(of: chromeOpen) { _, open in
            engine.setChromeOpen(open)
        }
        .onChange(of: visualAdjustments) { _, new in
            engine.configure(adjustments: new.stereoWarpAdjustments, settings: settings, isFlipped: isFlipped)
        }
        .onChange(of: settings) { _, new in
            engine.configure(adjustments: visualAdjustments.stereoWarpAdjustments, settings: new, isFlipped: isFlipped)
        }
        .onChange(of: isFlipped) { _, new in
            engine.configure(adjustments: visualAdjustments.stereoWarpAdjustments, settings: settings, isFlipped: new)
        }
        .onChange(of: isRoomActive) { _, active in
            engine.setRoomActive(active)
        }
        .onDisappear {
            engine.cleanup()
        }
    }
}

extension VisualAdjustments {
    /// The three fields the warp shader consumes. The rest of this struct
    /// (opacity, sharpen, auto-enhance, the two RealityKit scales) is applied
    /// elsewhere and has no meaning inside the stereo pump.
    var stereoWarpAdjustments: RAVEColorAdjustments {
        RAVEColorAdjustments(brightness: brightness, contrast: contrast, saturation: saturation)
    }
}

extension Pseudo3DStereoEngine {
    /// Wire the engine's transport to this app's per-window models. Deliberately
    /// app-side: the engine publishes `play`/`pause`/`seek`/`setMuted` and a
    /// `RAVEPlaybackState`, and knows nothing about what consumes them.
    @MainActor
    func bindCommands(loopController: VideoLoopController?, playbackModel: VideoWindowModel?) {
        if let loopController {
            loopController.queryCurrentTime = { [weak self] in self?.currentTime }
            loopController.setLoopBounds = { [weak self] a, b in self?.setLoopBounds(a: a, b: b) }
        }
        if let playbackModel {
            playbackModel.playCommand = { [weak self] in self?.play() }
            playbackModel.pauseCommand = { [weak self] in self?.pause() }
            playbackModel.seekCommand = { [weak self] t in self?.seek(to: t) }
            playbackModel.setMutedCommand = { [weak self] m in self?.setMuted(m) }
            onPlaybackUpdate = { [weak playbackModel] state in
                playbackModel?.applyPlaybackState(
                    currentTime: state.currentTime,
                    duration: state.duration,
                    paused: state.paused,
                    muted: state.muted,
                    buffered: state.buffered
                )
            }
        }
    }
}

/// Bridges a SwiftUI-animated opacity out to RealityKit. SwiftUI interpolates
/// `animatableData` frame-by-frame for the duration of the enclosing
/// `withAnimation`, so the callback sees the whole ramp; a plain
/// `.onChange(of:)` only ever observes the endpoints, which would turn a
/// crossfade into a cut to black. Needed because RealityKit content on visionOS
/// ignores SwiftUI's `.opacity` — the fade has to reach `OpacityComponent`.
private struct AnimatableSceneOpacity: ViewModifier, Animatable {
    var opacity: Double
    let apply: @MainActor (Double) -> Void

    /// `nonisolated` to satisfy `Animatable`, which SwiftUI drives from outside
    /// the main-actor-isolated `ViewModifier` surface. Animation ticks do run on
    /// the main thread, hence `assumeIsolated` rather than a hop (a hop would
    /// land after the tick it belongs to).
    nonisolated var animatableData: Double {
        get { opacity }
        set {
            opacity = newValue
            MainActor.assumeIsolated { apply(newValue) }
        }
    }

    func body(content: Content) -> some View { content }
}

#endif

#if !os(visionOS)

/// iOS stand-in: the real-time fake-3D stereo pipeline
/// (`Pseudo3DStereoEngine`/`StereoPump`) is visionOS-only within RAVEMedia
/// (gated `#if os(visionOS)` there too), and there is no per-eye rendering
/// surface on a flat display anyway. This renders nothing and immediately
/// reports playback failure so every caller (`VideoWindowView`,
/// `RemoteViewerWindowView`, `VideoQuickLookView`) falls back to its flat
/// player automatically — the same recovery path already used when depth
/// pipeline setup fails on visionOS. Same init shape as the real view so
/// call sites compile unchanged.
struct Pseudo3DVideoPlayerView: View {
    let videoURL: URL
    var isRoomActive: Bool = true
    var chromeOpen: Bool = false
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var visualAdjustments: VisualAdjustments = VisualAdjustments()
    var settings: Pseudo3DSettings = .default
    var depthMode: Pseudo3DDepthMode = .realtime
    var startAtSeconds: Double? = nil
    var startPaused: Bool = false
    var packedStereo: RAVEPackedStereoLayout? = nil
    var isFlipped: Bool = false
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    var startMuted: Bool = true
    var loops: Bool = true
    var contentOpacity: Double = 1
    var onDurationKnown: ((Double) -> Void)? = nil
    var onPlaybackError: (() -> Void)? = nil
    var onToggleUI: (() -> Void)? = nil

    var body: some View {
        Color.black
            .onAppear {
                onPlaybackError?()
            }
    }
}

#endif
