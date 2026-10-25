/*
 Hypnos - tvOS slideshow

 The app's slideshow on Apple TV: the same `RemoteViewerModel` /
 `RAVESlideshowEngine` the visionOS and iOS `remote-viewer` window runs, with
 the same profiles (`AppModel.gallerySlideshowConfig` /
 `videoSlideshowConfig`) and entry points (`startGallerySlideshow` /
 `startVideoSlideshow`), shown full screen by `TVRootView` when a slideshow
 is asked for (see `hypnos-slideshows.md`). Only the rendering is tvOS's own,
 because `RemoteViewerWindowView` draws videos and animated pictures with
 WebKit and its controls are an ornament:

 - pictures crossfade and drift (Ken Burns toward the engine's focus point),
   with the engine's dynamic brightness, as in the window;
 - videos play muted in an `AVPlayerLayer` (the original when AVFoundation
   opens it, else the on-device Matroska remux, else the server's
   transcode), looping when shorter than the interval;
 - animated pictures play through ImageIO (`TVAnimatedImageView`);
 - the remote drives it: left/right for previous/next, Play/Pause, Select
   for the profile's display settings (clock, Ken Burns, interval), Menu to
   close them and then the slideshow.

 3D is off here, whatever the profile says: there is no 3D on a TV.
 */

#if os(tvOS)

import AVFoundation
import Combine
import DebugTrace
import RAVESlideshow
import SwiftUI
import UIKit

struct TVSlideshowView: View {
    let windowValue: RemoteViewerWindowValue
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: RemoteViewerModel?
    @State private var screenSize: CGSize = .zero
    @State private var kenBurnsScale: CGFloat = 1
    @State private var kenBurnsOffset: CGSize = .zero
    @State private var showsSettings = false
    @State private var now = Date()
    @FocusState private var hasFocus: Bool
    @State private var arrowPresses = TVArrowPressObserver()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let model {
                    pictureLayers(model)
                        .opacity(model.effectiveOpacity)
                    if model.showClock {
                        clockOverlay(model)
                    }
                    if model.isLoading, model.currentImage == nil, model.activeVideoURL == nil {
                        ProgressView()
                    }
                    statusOverlay(model)
                } else {
                    ContentUnavailableView("Can't Start the Slideshow", systemImage: "play.slash",
                                           description: Text("Its settings couldn't be found."))
                }
            }
            .onAppear { screenSize = geo.size }
            .onChange(of: geo.size) { _, size in
                screenSize = size
                model?.updateWindowAspectRatio(size)
            }
        }
        .ignoresSafeArea()
        .background(TVArrowPressObserver.Host(observer: arrowPresses))
        .focusable(!showsSettings)
        .focused($hasFocus)
        .onAppear {
            hasFocus = true
            setUpModel()
        }
        .onDisappear {
            if let model {
                appModel.unregisterRemoteViewerModel(model)
                model.stop()
            }
            appModel.unregisterRemoteViewerWindow(configId: windowValue.configId, windowValueId: windowValue.id)
        }
        .onMoveCommand { direction in
            guard !showsSettings, let model else { return }
            // A press points where to go; a swipe drags the picture, as in
            // the photo viewer.
            let forward = arrowPresses.justPressed()
            switch direction {
            case .right: forward ? model.goToNextImage() : model.previousImage()
            case .left: forward ? model.previousImage() : model.goToNextImage()
            default: break
            }
        }
        .onPlayPauseCommand { model?.togglePause() }
        .onTapGesture { showsSettings = true }
        .onExitCommand {
            if showsSettings {
                showsSettings = false
                hasFocus = true
            } else {
                dismiss()
            }
        }
        .overlay(alignment: .bottom) {
            if showsSettings, let model {
                TVSlideshowSettingsPanel(model: model)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsSettings)
        .onReceive(clock) { now = $0 }
        .onChange(of: scenePhase) { old, new in
            model?.handleScenePhaseChange(from: old, to: new)
        }
        .onChange(of: model?.currentPost?.id) { _, _ in
            guard let model else { return }
            if model.currentMediaType == .image, !model.isCurrentPostAnimatedGIF {
                startKenBurns(model)
            } else {
                resetKenBurns()
            }
        }
        .onChange(of: appModel.effectiveReduceMotion, initial: true) { _, reduce in
            model?.reduceMotion = reduce
        }
    }

    // MARK: Layers

    @ViewBuilder
    private func pictureLayers(_ model: RemoteViewerModel) -> some View {
        ZStack {
            if model.currentMediaType == .image, let image = model.currentImage {
                let drifts = model.enableKenBurns && !model.isCurrentPostAnimatedGIF
                adjusted(Image(platformImage: image).resizable(), model)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(drifts ? kenBurnsScale : 1)
                    .offset(drifts ? kenBurnsOffset : .zero)
                    .opacity(model.isTransitioning ? 0 : 1)
            }

            switch model.currentMediaType {
            case .animatedGIF, .animatedWebP, .animatedJXL:
                if let data = model.currentAnimatedData {
                    adjusted(TVAnimatedImageView(data: data, poster: model.currentImage), model)
                        .opacity(model.isTransitioning ? 0 : 1)
                } else if let image = model.currentImage {
                    adjusted(Image(platformImage: image).resizable(), model)
                        .aspectRatio(contentMode: .fit)
                }
            case .image, .video:
                EmptyView()
            }

            if let image = model.nextImage, model.isTransitioning {
                adjusted(Image(platformImage: image).resizable(), model)
                    .aspectRatio(contentMode: .fit)
            }

            // One player across the crossfade commit: the incoming slot and
            // the committed video share a URL (`activeVideoURL`).
            if let url = model.activeVideoURL {
                let isOutgoing = model.isTransitioning && model.nextVideoURL == nil
                adjusted(TVSlideshowVideoLayer(url: url, fallbackURL: transcode(of: url, model),
                                               loops: model.currentVideoLoops,
                                               onDurationKnown: { [weak model] seconds in
                                                   guard let model, let post = model.nextPost ?? model.currentPost
                                                   else { return }
                                                   model.onVideoDurationKnown(seconds, for: post)
                                               },
                                               onFailed: { [weak model] in
                                                   // Nothing here can play it: on to the next.
                                                   guard let model, model.activeVideoURL == url else { return }
                                                   AppLogger.remoteViewer.info("[tvOS] A slideshow video can't play here; skipping it")
                                                   model.goToNextImage()
                                               }), model)
                .id(url)
                .opacity(isOutgoing ? 0 : 1)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .clipped()
    }

    /// The server's transcode of the clip at `url`, once it is the committed
    /// one: during the crossfade in, `currentVideoHLSURL` still belongs to
    /// the clip going out.
    private func transcode(of url: URL, _ model: RemoteViewerModel) -> URL? {
        if case .video(let committed) = model.currentMediaType, committed == url { return model.currentVideoHLSURL }
        return nil
    }

    private func adjusted(_ view: some View, _ model: RemoteViewerModel) -> some View {
        view
            .brightness(model.effectiveBrightness)
            .contrast(model.effectiveContrast)
            .saturation(model.effectiveSaturation)
    }

    private func clockOverlay(_ model: RemoteViewerModel) -> some View {
        let scale = model.config.textSize
        return VStack(alignment: .leading, spacing: 4) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 72 * scale, weight: .light, design: .rounded))
                .monospacedDigit()
            Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 30 * scale))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 20))
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// Paused, and the engine's own messages (nothing to show, a failed load).
    @ViewBuilder
    private func statusOverlay(_ model: RemoteViewerModel) -> some View {
        VStack(spacing: 16) {
            if model.state == .paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            if let toast = model.toastMessage {
                Text(toast)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(model.toastIsError ? Color.red.opacity(0.85) : Color.black.opacity(0.7),
                                in: .rect(cornerRadius: 12))
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut, value: model.state == .paused)
        .animation(.easeInOut, value: model.toastMessage)
    }

    // MARK: Model

    /// The same profile and content the `remote-viewer` window would get
    /// for this request (`RemoteViewerWindowView.setupModel`).
    private func setUpModel() {
        guard model == nil,
              // A TV shows 4K at most, and plays every profile flat.
              let model = RemoteViewerModel.open(
                  for: windowValue, appModel: appModel,
                  windowSize: screenSize.width > 0 ? screenSize : CGSize(width: 1920, height: 1080),
                  resolutionCap: 3840, allows3D: false)
        else { return }
        self.model = model
        AppLogger.remoteViewer.info("[tvOS] Slideshow started: \(model.delay, privacy: .public) s per picture")
    }

    // MARK: Ken Burns

    private func startKenBurns(_ model: RemoteViewerModel) {
        resetKenBurns()
        guard model.enableKenBurns, !appModel.effectiveReduceMotion else { return }
        let focus = model.focusPoint
        withAnimation(.easeInOut(duration: model.delay)) {
            kenBurnsScale = 1.2
            kenBurnsOffset = CGSize(width: -(focus.x - 0.5) * screenSize.width * 0.15,
                                    height: -(focus.y - 0.5) * screenSize.height * 0.15)
        }
    }

    private func resetKenBurns() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            kenBurnsScale = 1
            kenBurnsOffset = .zero
        }
    }
}

// MARK: - Settings

/// The profile's display settings, over the slideshow: written back through
/// the model's `display*` setters, so they persist with the profile.
private struct TVSlideshowSettingsPanel: View {
    @Bindable var model: RemoteViewerModel
    /// The slideshow behind stops taking focus as the panel opens; nothing
    /// in the panel takes it on its own, so the first button is given it.
    @FocusState private var focusesFirst: Bool

    private static let intervals: [TimeInterval] = [5, 10, 15, 30, 60, 120]

    var body: some View {
        HStack(spacing: 24) {
            Button {
                model.togglePause()
            } label: {
                Label(model.state == .paused ? "Play" : "Pause",
                      systemImage: model.state == .paused ? "play.fill" : "pause.fill")
            }
            .focused($focusesFirst)
            Button {
                model.displayShowClock.toggle()
            } label: {
                Label(model.displayShowClock ? "Hide Clock" : "Show Clock", systemImage: "clock")
            }
            Button {
                model.displayEnableKenBurns.toggle()
            } label: {
                Label(model.displayEnableKenBurns ? "Ken Burns On" : "Ken Burns Off",
                      systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Menu {
                ForEach(Self.intervals, id: \.self) { seconds in
                    Button {
                        model.displayDelay = seconds
                    } label: {
                        if model.displayDelay == seconds {
                            Label(Self.label(seconds), systemImage: "checkmark")
                        } else {
                            Text(Self.label(seconds))
                        }
                    }
                }
            } label: {
                Label("Every \(Self.label(model.displayDelay))", systemImage: "timer")
            }
        }
        .padding(24)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .onAppear {
            DispatchQueue.main.async { focusesFirst = true }
        }
    }

    private static func label(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }
}

// MARK: - Video

/// A slideshow clip: muted, fitted to the screen, looping when the slideshow
/// says so. The original plays when AVFoundation opens it; otherwise an MKV
/// or WebM is remuxed on the device, and anything else plays the server's
/// transcode. A clip none of those can play is reported, and skipped.
private struct TVSlideshowVideoLayer: UIViewRepresentable {
    let url: URL
    /// The server's transcode; arrives once the clip is committed.
    let fallbackURL: URL?
    let loops: Bool
    let onDurationKnown: (Double) -> Void
    let onFailed: () -> Void

    func makeUIView(context: Context) -> TVPlayerLayerView {
        let view = TVPlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.fallbackURL = fallbackURL
        context.coordinator.start(url: url, in: view, onDurationKnown: onDurationKnown, onFailed: onFailed)
        return view
    }

    func updateUIView(_ view: TVPlayerLayerView, context: Context) {
        context.coordinator.loops = loops
        if let fallbackURL { context.coordinator.fallbackURL = fallbackURL }
    }

    static func dismantleUIView(_ view: TVPlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(loops: loops) }

    @MainActor
    final class Coordinator {
        var loops: Bool
        var fallbackURL: URL?
        private let player = AVPlayer()
        private var task: Task<Void, Never>?
        private var endObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?
        private var onFailed: () -> Void = {}

        init(loops: Bool) {
            self.loops = loops
            player.isMuted = true
            player.actionAtItemEnd = .pause
        }

        func start(url: URL, in view: TVPlayerLayerView, onDurationKnown: @escaping (Double) -> Void,
                   onFailed: @escaping () -> Void) {
            view.playerLayer.player = player
            self.onFailed = onFailed
            task = Task { [weak self] in
                guard let self else { return }
                let playable = await self.playableURL(url)
                guard !Task.isCancelled else { return }
                guard let playable else {
                    self.onFailed()
                    return
                }
                let asset = MediaAuthorization.shared.asset(for: playable)
                let item = AVPlayerItem(asset: asset)
                self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.onFailed() }
                    }
                }
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.loops else { return }
                        self.player.seek(to: .zero)
                        self.player.play()
                    }
                }
                self.player.replaceCurrentItem(with: item)
                self.player.play()
                if let duration = try? await asset.load(.duration), duration.seconds.isFinite, !Task.isCancelled {
                    onDurationKnown(duration.seconds)
                }
            }
        }

        func stop() {
            task?.cancel()
            statusObservation?.invalidate()
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        private func playableURL(_ url: URL) async -> URL? {
            if PhotosAssetURL.isPhotosAsset(url) {
                return await PhotosAssetStore.shared.playableURL(for: url)
            }
            let authorized = MediaAuthorization.shared.authorizedURL(url)
            if await NativeVideoDecodeProbe.canPlayNatively(url: authorized, timeout: 4) { return authorized }
            if let remuxed = await MatroskaRemuxService.shared.playlistURL(for: authorized,
                                                                          fileName: url.lastPathComponent) {
                return remuxed
            }
            // The transcode comes with the slideshow's commit, which can
            // still be a moment away while the clip fades in.
            for _ in 0 ..< 30 where fallbackURL == nil {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return nil }
            }
            return fallbackURL.map(MediaAuthorization.shared.authorizedURL)
        }
    }
}

/// A view whose layer is an `AVPlayerLayer`.
final class TVPlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

#endif
