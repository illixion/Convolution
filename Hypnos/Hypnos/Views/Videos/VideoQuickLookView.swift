/*
 Hypnos - Video Quick Look Preview

 Tap-and-hold "quick look" preview for the video grid, mirroring the image
 grid's `QuickLook3DView`. Plays Stash's short auto-generated scene preview
 clip (`/scene/{id}/preview`, typically 640×360 h264) inline over the grid,
 with side-menu actions to convert to real-time fake-3D, unmute, open the full
 player, or close.

 Animation, geometry, and the present/dismiss handshake are copied from
 `QuickLook3DView` so both grids feel identical. The preview drives its pop
 entirely from internal `@State`: on appear a `presented` flag animates
 false → true, interpolating scale + offset between the source cell and the
 fitted natural size; dismiss reverses it and only nils the parent state after
 the spring settles.

 Playback path (mirrors VideoWindowView):
   - Default: `NativeMetalVideoPlayerView` (AVFoundation → Metal). Loops; the
     initial mute state follows Settings ("Mute Videos on Open"). Falls back
     to WebKit on decode failure.
   - `WebVideoPlayerView` fallback for codecs AVFoundation can't decode.
   - `Pseudo3DVideoPlayerView` (realtime depth) when the user converts to 3D;
     gated on the native renderer + an installed real-time depth model.

 The muted/unmute + resume plumbing reuses the players' existing
 `playbackModel: VideoWindowModel` integration point — a lightweight throwaway
 model is created purely to carry the mute command and playback clock. It is
 never `start()`ed, so no window-scene side effects (renderer resolution,
 auto-hide, aspect lock) fire.
 */

import DebugTrace
import RAVEMedia
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

/// Z-offset so the preview and side menu sit clearly in front of any
/// diorama-thumbnail foreground layers in the grid below.
private let quickLookZOffset: CGFloat = 80
private let sideMenuWidth: CGFloat = 220
private let previewMenuSpacing: CGFloat = 24

struct VideoQuickLookView: View {
    @Environment(AppModel.self) private var appModel

    let video: GalleryVideo
    /// Source cell frame in the gallery coordinate space; drives the
    /// scale-from-cell animation. `nil` falls back to a center pop.
    let sourceFrame: CGRect?
    /// Container size resolved by the host's outer `GeometryReader`.
    let containerSize: CGSize
    let useScalePop: Bool
    /// Poster bitmap from the source cell, painted behind the player so the
    /// entry animation never starts on an empty frame while the clip buffers.
    let initialImage: UIImage?
    /// Open the full video player window for this video.
    let onOpenFull: (GalleryVideo) -> Void
    /// Invoked AFTER the dismiss animation settles so the host can nil the
    /// optional driving this view's presence.
    let onDismiss: () -> Void

    @State private var presented = false
    /// Gesture grace period — the pinch that completes the long-press tends to
    /// register as a tap on the fresh backdrop and dismiss instantly.
    @State private var dismissEnabled = false
    @State private var aspectRatio: CGFloat = 16.0 / 9.0
    /// Realtime fake-3D engaged for this preview.
    @State private var pseudo3DEnabled = false
    /// Native decode failed → fall back to the WebKit player.
    @State private var useWebKit = false
    /// Throwaway per-preview model used only to carry the players' mute command
    /// and playback clock (see file header). Created in `onAppear`.
    @State private var playbackModel: VideoWindowModel?
    /// Poster shown behind the player. Starts as the cell's (16:9-cropped,
    /// low-res) thumbnail seed, then upgrades to the uncropped full screenshot
    /// so non-16:9 videos aren't shown as a zoomed crop while the clip buffers.
    @State private var posterImage: UIImage?
    /// True once a decoded frame reported the real video size — from then on
    /// the poster's aspect must not override it.
    @State private var videoAspectKnown = false

    init(
        video: GalleryVideo,
        sourceFrame: CGRect?,
        containerSize: CGSize,
        useScalePop: Bool,
        initialImage: UIImage?,
        onOpenFull: @escaping (GalleryVideo) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.video = video
        self.sourceFrame = sourceFrame
        self.containerSize = containerSize
        self.useScalePop = useScalePop
        self.initialImage = initialImage
        self.onOpenFull = onOpenFull
        self.onDismiss = onDismiss
        // Seed the aspect ratio from the source dimensions (falls back to 16:9)
        // so `fitted` is correct on frame 0; the player refines it once the
        // first decoded frame reports its true size.
        if let w = video.sourceWidth, let h = video.sourceHeight, h > 0 {
            _aspectRatio = State(initialValue: CGFloat(w) / CGFloat(h))
        }
    }

    // MARK: - Derived

    /// Preview clip URL with the apikey appended, falling back to the full
    /// stream when the source has no server-side preview (e.g. local files).
    private var previewURL: URL {
        authenticatedURL(video.previewURL ?? video.streamURL)
    }

    private var isMuted: Bool {
        playbackModel?.isMuted ?? appModel.videoAutoplayMuted
    }

    /// Real-time fake-3D needs the native decoder and an installed model.
    private var canConvertTo3D: Bool {
        !useWebKit && CoreMLDepthProvider.hasAvailableModel(role: .realtime)
    }

    var body: some View {
        let menuReserve = sideMenuWidth + previewMenuSpacing
        let maxW = max(containerSize.width * 0.92 - menuReserve, 200)
        let maxH = containerSize.height * 0.92
        let fitted = fittedSize(in: CGSize(width: maxW, height: maxH))
        let cellSide = sourceFrame?.width ?? 200
        let previewSize = (useScalePop && !presented)
            ? CGSize(width: cellSide, height: cellSide)
            : fitted
        let cornerR: CGFloat = (useScalePop && !presented) ? 12 : 20
        let offsetVec = popOffset(containerSize: containerSize)

        ZStack {
            Color.black
                .opacity(presented ? 0.55 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { animateDismiss() }

            HStack(alignment: .center, spacing: previewMenuSpacing) {
                previewContent(size: previewSize, cornerRadius: cornerR)
                    .offset(x: presented ? 0 : offsetVec.dx, y: presented ? 0 : offsetVec.dy)
                    .offset(z: presented ? quickLookZOffset : 0)
                    .opacity(useScalePop ? 1 : (presented ? 1 : 0))

                sideMenu
                    .frame(width: sideMenuWidth)
                    .opacity(presented ? 1 : 0)
                    .scaleEffect(useScalePop ? (presented ? 1 : 0.85) : 1, anchor: .leading)
                    .offset(x: useScalePop ? (presented ? 0 : -30) : 0)
                    .offset(z: quickLookZOffset)
            }
            .frame(width: containerSize.width, height: containerSize.height, alignment: .center)
        }
        .onAppear {
            // Create the throwaway playback model (needs the environment
            // AppModel, unavailable in init).
            if playbackModel == nil {
                playbackModel = VideoWindowModel(
                    windowValue: VideoWindowValue(video: video),
                    appModel: appModel
                )
            }
            // Defer one runloop so SwiftUI commits the `presented == false`
            // frame before the spring begins.
            DispatchQueue.main.async {
                withAnimation(presentAnim) { presented = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismissEnabled = true
            }
            AppLogger.videoWindow.info("Video quick look opened; preview URL: \(previewURL.loggableDescription)")
        }
        .task {
            await loadFullPoster()
        }
    }

    /// Upgrade the poster from the cell's cropped thumbnail to the uncropped
    /// scene screenshot. The screenshot matches the video's true aspect, so
    /// this also corrects the pop frame for non-16:9 videos while the clip
    /// loads (unless a decoded frame already reported the real size).
    private func loadFullPoster() async {
        let url = video.thumbnailURL
        guard !url.isFileURL else { return }
        guard let image = try? await ImageLoader.shared.loadImage(from: url) else { return }
        posterImage = image
        if !videoAspectKnown, video.sourceWidth == nil, image.size.height > 0 {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { aspectRatio = image.size.width / image.size.height }
        }
    }

    // MARK: - Preview content

    @ViewBuilder
    private func previewContent(size: CGSize, cornerRadius: CGFloat) -> some View {
        ZStack {
            // Poster seed behind the player — instant first paint while the
            // clip buffers (the Metal/Web players are transparent until frames
            // arrive).
            if let poster = posterImage ?? initialImage {
                Image(platformImage: poster)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.secondary.opacity(0.2)
                    .frame(width: size.width, height: size.height)
            }

            player
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(cornerRadius)
        .contentShape(Rectangle())
        .onTapGesture { animateDismiss() }
        #if !os(tvOS)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if abs(value.translation.height) > 60 || abs(value.translation.width) > 60 {
                        animateDismiss()
                    }
                }
        )
        #endif
    }

    @ViewBuilder
    private var player: some View {
        if pseudo3DEnabled {
            Pseudo3DVideoPlayerView(
                videoURL: previewURL,
                onVideoSizeKnown: updateAspect,
                settings: appModel.globalPseudo3DSettings,
                depthMode: .realtime,
                startAtSeconds: playbackModel?.currentTime,
                playbackModel: playbackModel,
                // Keep the user's current mute choice across the 3D switch.
                startMuted: isMuted,
                onPlaybackError: {
                    // No usable depth (model missing / load failed) — drop back
                    // to flat playback.
                    pseudo3DEnabled = false
                }
            )
        } else {
            // Each `#if`/`#else` branch below must be a complete, balanced
            // statement — Swift can't pick up an `if` opened outside the
            // block — so the WebKit-vs-tvOS split lives entirely inside this
            // `else`, not spliced across the `if pseudo3DEnabled` above.
            #if canImport(WebKit)
            if useWebKit {
                WebVideoPlayerView(
                    videoURL: previewURL,
                    showControls: false,
                    onVideoSizeKnown: updateAspect,
                    loop: true,
                    playbackModel: playbackModel,
                    startMuted: isMuted
                )
            } else {
                nativeMetalPlayer
            }
            #else
            nativeMetalPlayer
            #endif
        }
    }

    private var nativeMetalPlayer: some View {
        Group {
            NativeMetalVideoPlayerView(
                videoURL: previewURL,
                onVideoSizeKnown: updateAspect,
                playbackModel: playbackModel,
                startMuted: isMuted,
                onPlaybackError: { useWebKit = true }
            )
        }
    }

    private func updateAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        videoAspectKnown = true
        let ratio = size.width / size.height
        guard abs(ratio - aspectRatio) > 0.001 else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { aspectRatio = ratio }
    }

    // MARK: - Side menu

    private var sideMenu: some View {
        VStack(spacing: 0) {
            menuButton(
                title: pseudo3DEnabled ? "Viewing in 3D" : "Convert to 3D",
                systemImage: "cube",
                tinted: pseudo3DEnabled,
                disabled: !pseudo3DEnabled && !canConvertTo3D
            ) {
                pseudo3DEnabled.toggle()
            }

            Divider().opacity(0.3)

            menuButton(
                title: isMuted ? "Unmute" : "Mute",
                systemImage: isMuted ? "speaker.slash" : "speaker.wave.2",
                tinted: !isMuted,
                disabled: playbackModel == nil
            ) {
                playbackModel?.toggleMute()
            }

            Divider().opacity(0.3)

            menuButton(
                title: "Open Player",
                systemImage: "rectangle.on.rectangle",
                tinted: false,
                disabled: false
            ) {
                onOpenFull(video)
            }

            Divider().opacity(0.3)

            menuButton(
                title: "Close",
                systemImage: "xmark",
                tinted: false,
                disabled: false
            ) {
                animateDismiss()
            }
        }
        .padding(.vertical, 6)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func menuButton(title: String, systemImage: String, tinted: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(tinted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        .hoverEffect()
        #endif
        .disabled(disabled)
    }

    // MARK: - Animation

    private var presentAnim: Animation {
        useScalePop
            ? .spring(response: 0.5, dampingFraction: 0.78)
            : .easeOut(duration: 0.25)
    }

    private var dismissAnim: Animation {
        useScalePop
            ? .spring(response: 0.4, dampingFraction: 0.86)
            : .easeIn(duration: 0.2)
    }

    private var dismissCompletionDelay: TimeInterval {
        useScalePop ? 0.55 : 0.25
    }

    private func animateDismiss() {
        guard dismissEnabled else { return }
        withAnimation(dismissAnim) { presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissCompletionDelay) {
            onDismiss()
        }
    }

    // MARK: - Geometry

    private struct PopOffset {
        let dx: CGFloat
        let dy: CGFloat
    }

    /// Offset translating the HStack-centered preview onto the source cell.
    /// Independent of the animated frame size (the HStack centers preview +
    /// spacing + menu as a unit), matching `QuickLook3DView`.
    private func popOffset(containerSize: CGSize) -> PopOffset {
        guard useScalePop, let frame = sourceFrame else {
            return PopOffset(dx: 0, dy: 0)
        }
        let previewCenter = CGPoint(
            x: containerSize.width / 2 - (sideMenuWidth + previewMenuSpacing) / 2,
            y: containerSize.height / 2
        )
        let cellCenter = CGPoint(x: frame.midX, y: frame.midY)
        return PopOffset(
            dx: cellCenter.x - previewCenter.x,
            dy: cellCenter.y - previewCenter.y
        )
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let ratio = max(aspectRatio, 0.0001)
        let containerRatio = container.width / container.height
        if ratio >= containerRatio {
            return CGSize(width: container.width, height: container.width / ratio)
        } else {
            return CGSize(width: container.height * ratio, height: container.height)
        }
    }

    // MARK: - Auth

    private func authenticatedURL(_ url: URL) -> URL {
        MediaAuthorization.shared.authorizedURL(url)
    }
}
