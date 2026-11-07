/*
 Hypnos - Native Metal Video Player View

 AVFoundation-backed video player that renders decoded frames through Metal.
 Used for formats AVFoundation can decode natively, while WKWebView remains the
 fallback for WebM and other Safari-only formats.
 */

import AVFoundation
import AVKit
import CoreVideo
import DebugTrace
import MetalKit
import RAVEMedia
import SwiftUI

// A `UIViewRepresentable` on iOS, tvOS and visionOS and an
// `NSViewRepresentable` on macOS, over the same host view and `Coordinator`:
// the AVPlayer/Metal code is the same everywhere.
#if os(macOS)
typealias NativePlayerPlatformView = NSView
#else
typealias NativePlayerPlatformView = UIView
#endif

/// Both match their Shaders.metal twins, `peak` included. A missing `peak`
/// reads as 0 and the shaders clamp every pixel to it: a black picture.
private struct VideoRCASUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var sharpen: Float
    var peak: Float = 1
}

private struct VideoAAUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var applyResolve: Float
    var peak: Float = 1
}

/// What the decoded frames are, read off the first one's attachments. The
/// stream's metadata can't say for an HLS remux, and the frames always can.
enum NativeVideoDynamicRange {
    case unknown, sdr, pq, hlg

    var isHDR: Bool { self == .pq || self == .hlg }
}

/// The player's view: the Metal picture (SDR, or HDR while adjustments are
/// on) and the system's own video layer (HDR and Dolby Vision as they are)
/// over one AVPlayer, one of them showing.
final class NativeVideoHostView: NativePlayerPlatformView {
    let metalView: MTKView
    let systemView = SystemVideoLayerView()
    #if os(iOS) || os(macOS)
    /// The player's picture for Picture in Picture alone, never shown inline.
    let pipView = SystemVideoLayerView()
    #endif

    init(metalView: MTKView) {
        self.metalView = metalView
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #else
        isOpaque = false
        #endif
        var views: [NativePlayerPlatformView] = [metalView, systemView]
        #if os(iOS) || os(macOS)
        // Under the Metal view, which covers it: Picture in Picture takes its
        // picture from here (`VideoPictureInPicture`).
        views.insert(pipView, at: 0)
        #endif
        for view in views {
            view.frame = bounds
            #if os(macOS)
            view.autoresizingMask = [.width, .height]
            #else
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            #endif
            addSubview(view)
        }
        systemView.isHidden = true
    }

    #if os(macOS)
    override var isOpaque: Bool { false }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(tvOS) || os(visionOS)
    /// Stated to the window's display manager while the view is in it. On
    /// visionOS it is how a player declares HDR video (without it the picture
    /// dims once playback starts); tvOS switches the TV's mode with it.
    var displayCriteria: AVDisplayCriteria? {
        didSet {
            if let displayCriteria { Self.lastStatedCriteria = displayCriteria }
            applyDisplayCriteria()
        }
    }
    /// The criteria a video window last stated, for the debug comparison's
    /// plain-layer renderer (`videoCompare`).
    static var lastStatedCriteria: AVDisplayCriteria?
    private weak var criteriaWindow: UIWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDisplayCriteria()
    }

    private func applyDisplayCriteria() {
        if let criteriaWindow, criteriaWindow !== window {
            criteriaWindow.avDisplayManager.preferredDisplayCriteria = nil
        }
        criteriaWindow = window
        window?.avDisplayManager.preferredDisplayCriteria = displayCriteria
    }
    #endif
}

extension MTKView {
    /// One presented, all-zero frame: draws nothing, but makes the view
    /// count where visionOS hit-tests what reaches the render server, which a
    /// video layer over it doesn't (see the coordinator's `showSystemLayer`).
    @MainActor
    func presentClearedFrame(commandQueue: MTLCommandQueue) {
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

final class SystemVideoLayerView: NativePlayerPlatformView {
    #if os(macOS)
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        // Otherwise HDR is tone-mapped to SDR (macOS 26 defaults to .standard).
        playerLayer.preferredDynamicRange = .high
        layer = playerLayer
        wantsLayer = true
    }

    /// Clicks go to the picture's tap target, not here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #else
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if os(macOS)
extension NativeMetalVideoPlayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeVideoHostView { makeHost(coordinator: context.coordinator) }

    func updateNSView(_ view: NativeVideoHostView, context: Context) { update(coordinator: context.coordinator) }

    static func dismantleNSView(_ view: NativeVideoHostView, coordinator: Coordinator) { coordinator.cleanup() }
}
#else
extension NativeMetalVideoPlayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> NativeVideoHostView { makeHost(coordinator: context.coordinator) }

    func updateUIView(_ view: NativeVideoHostView, context: Context) { update(coordinator: context.coordinator) }

    static func dismantleUIView(_ view: NativeVideoHostView, coordinator: Coordinator) { coordinator.cleanup() }
}
#endif

@MainActor
struct NativeMetalVideoPlayerView {
    let videoURL: URL
    var spatialAudioSceneIdentifier: String? = nil
    var isRoomActive: Bool = true
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var visualAdjustments: VisualAdjustments = VisualAdjustments()
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    /// Initial mute state applied when a video loads (autoplay always starts
    /// playback; this only controls whether it opens with audio).
    var startMuted: Bool = true
    /// Restart at the end. A clip loops; a Library title plays once and
    /// parks on its last frame, reported as paused at the end so the window
    /// can go on to the next episode.
    var loops: Bool = true
    /// Smooth Motion: an in-between frame for each pair of a 24-30 or 50-60
    /// fps SDR picture (visionOS; see the coordinator's `rebuildFramePresenter`).
    var interpolatesFrames: Bool = false
    /// Which interpolator Smooth Motion uses (Settings › Videos).
    var interpolationEngine: SmoothMotionEngine = .automatic
    /// A 2D Library title's fields from an analysis coordinator: pairs they
    /// cover are made from them, the rest by `interpolationEngine`.
    var sharedFields: SharedFieldProvider? = nil
    var onPlaybackError: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeHost(coordinator: Coordinator) -> NativeVideoHostView {
        guard let renderer = MetalImageRenderer.shared else {
            return NativeVideoHostView(metalView: MTKView())
        }

        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = coordinator
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        #if os(macOS)
        view.layer?.isOpaque = false
        #else
        view.isOpaque = false
        view.layer.isOpaque = false
        #endif
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let host = NativeVideoHostView(metalView: view)
        coordinator.renderer = renderer
        coordinator.attach(to: host)
        return host
    }

    func update(coordinator: Coordinator) {
#if HYPNOS_YOUTUBE
        coordinator.flashbackModel = playbackModel
#endif
        coordinator.spatialAudioSceneIdentifier = spatialAudioSceneIdentifier
        coordinator.visualAdjustments = visualAdjustments
        coordinator.onVideoSizeKnown = onVideoSizeKnown
        coordinator.onPlaybackError = onPlaybackError
        coordinator.startMuted = startMuted
        coordinator.startVolume = Float(playbackModel?.volume ?? 1)
        coordinator.speed = Float(playbackModel?.playbackSpeed ?? 1)
        coordinator.loops = loops
        coordinator.interpolationEngine = interpolationEngine
        coordinator.sharedFields = sharedFields
        coordinator.interpolatesFrames = interpolatesFrames
        coordinator.resumesAfterInterruptions = playbackModel == nil
        coordinator.maximumResolution = playbackModel?.maximumPictureResolution ?? .zero

        if let loopController {
            loopController.queryCurrentTime = { [weak coordinator] in
                coordinator?.currentTime
            }
            loopController.setLoopBounds = { [weak coordinator] a, b in
                coordinator?.setLoopBounds(a: a, b: b)
            }
        }

        if let playbackModel {
            playbackModel.playCommand = { [weak coordinator] in
                coordinator?.play()
            }
            playbackModel.pauseCommand = { [weak coordinator] in
                coordinator?.pause()
            }
            playbackModel.seekCommand = { [weak coordinator] time in
                coordinator?.seek(to: time)
            }
            #if HYPNOS_YOUTUBE
            playbackModel.flashbackScanCommand = { [weak coordinator] sensitivity in
                coordinator?.flashbackCandidates(sensitivity: sensitivity) ?? []
            }
            #endif
            playbackModel.setMutedCommand = { [weak coordinator] muted in
                coordinator?.setMuted(muted)
            }
            playbackModel.setVolumeCommand = { [weak coordinator] volume in
                coordinator?.setVolume(Float(volume))
            }
            playbackModel.setSpeedCommand = { [weak coordinator] speed in
                coordinator?.setSpeed(Float(speed))
            }
            #if os(iOS) || os(macOS)
            playbackModel.togglePictureInPictureCommand = { [weak coordinator] in
                coordinator?.pictureInPicture.toggle()
            }
            coordinator.pictureInPicture.onChange = { [weak playbackModel] possible, active in
                playbackModel?.notePictureInPicture(possible: possible, active: active)
            }
            #endif
            coordinator.onPlayerChanged = { [weak playbackModel, weak coordinator] player in
                playbackModel?.subtitles.bindAnalysisPlayer(player, buffering: { [weak coordinator] held in
                    coordinator?.setAnalysisBuffering(held)
                })
                playbackModel?.noteNativePlayer(player)
            }
            coordinator.onFrameRateKnown = { [weak playbackModel] rate in
                playbackModel?.notePictureFrameRate(rate)
            }
            coordinator.onFrameRangeKnown = { [weak playbackModel] range in
                playbackModel?.notePictureFrameRange(range, stereo: false)
            }
            coordinator.onSmoothMotionChanged = { [weak playbackModel] doubling in
                playbackModel?.noteSmoothMotionDoubling(doubling)
            }
            coordinator.onPlaybackUpdate = { [weak playbackModel] state in
                playbackModel?.applyPlaybackState(
                    currentTime: state.currentTime,
                    duration: state.duration,
                    paused: state.paused,
                    muted: state.muted,
                    buffered: state.buffered,
                    waiting: state.waiting
                )
            }
        }

        let identity = playbackModel?.video.identity ?? videoURL.absoluteString
        if coordinator.loadedURL != videoURL || coordinator.loadedIdentity != identity {
            let sameVideo = coordinator.loadedIdentity == identity
            coordinator.load(
                url: videoURL,
                identity: identity,
                startPaused: sameVideo && coordinator.loadedURL != nil && (playbackModel?.isPaused ?? false)
            )
        }

        coordinator.setRoomActive(isRoomActive)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        struct PlaybackState {
            let currentTime: Double
            let duration: Double
            let paused: Bool
            let muted: Bool
            let buffered: Double
            /// Waiting for data while it means to play.
            let waiting: Bool
        }

        weak var mtkView: MTKView?
        weak var host: NativeVideoHostView?
#if HYPNOS_YOUTUBE
        weak var flashbackModel: VideoWindowModel?
#endif
        var renderer: MetalImageRenderer?
        var loadedURL: URL?
        var loadedIdentity: String?
        var visualAdjustments = VisualAdjustments() {
            didSet { updatePresentation() }
        }
        /// Read off the first decoded frame of each load.
        private var dynamicRange = NativeVideoDynamicRange.unknown
        /// Dolby Vision profile 5: its frames are IPT-PQ-c2, which only the
        /// system's renderer maps (with the RPU), so it never shows through
        /// Metal. The app does no Dolby processing of its own.
        private var needsSystemRenderer = false
        /// The first frame carried a Dolby Vision RPU.
        private var hasRPU = false
        /// The first frame's HDR10 static metadata (SEI byte layout), for
        /// the EDR layer's tone mapping.
        private var masteringDisplay: Data?
        private var contentLightLevel: Data?
        /// The Dolby Vision 8.x scene whose range the EDR layer's metadata
        /// carries (sideload edition, `DolbyVisionScenes`); nil: the static
        /// HDR10 metadata.
        private var dolbyVisionScene: DolbyVisionScenes.Scene?
        /// What `onFrameRangeKnown` was last told, so a change of presenter
        /// (the RPU applied or not) is told again.
        private var reportedRange: VideoFrameRange?
        private var usesSystemLayer = false
        /// The first frame's format, for display criteria when the stream has
        /// no asset track to describe it (HLS).
        private var firstFrameFormat: CMVideoFormatDescription?
        /// What the frame output decodes to: BGRA for SDR, half float for HDR
        /// drawn by Metal.
        private var outputPixelFormat: OSType = kCVPixelFormatType_32BGRA
        /// Smooth Motion. Takes effect at once: the presenter is rebuilt over
        /// the same frame output, no reload.
        var interpolatesFrames = false {
            // An HDR picture leaves the system layer to be interpolated.
            didSet { if oldValue != interpolatesFrames { updatePresentation(); rebuildFramePresenter() } }
        }
        var interpolationEngine: SmoothMotionEngine = .automatic {
            didSet { if oldValue != interpolationEngine, interpolatesFrames { rebuildFramePresenter() } }
        }
        /// Fields made ahead for this 2D picture; a track arriving after the
        /// picture started rebuilds the presenter with it.
        var sharedFields: SharedFieldProvider? {
            didSet {
                if oldValue.map(ObjectIdentifier.init) != sharedFields.map(ObjectIdentifier.init), interpolatesFrames {
                    rebuildFramePresenter()
                }
            }
        }
        /// Doubles a 24-30 fps picture while Smooth Motion is on (nil: frames
        /// straight from the output).
        private var framePresenter: InterpolatedFramePresenter?
        /// The draw rate while Smooth Motion doubles: 96 (48 fps fits it
        /// evenly) until the display criteria find the picture's doubled rate
        /// is higher (100 or 120).
        private var doubledDrawRate = 96.0
        private var presentationSizeObservation: NSKeyValueObservation?
        private var criteriaTask: Task<Void, Never>?
        private var frameRateTask: Task<Void, Never>?
        /// The rate the player measured (`measureFrameRate`), for display
        /// criteria when the asset has no track to say (HLS).
        private var measuredFrameRate: Double?
        /// The display criteria were stated before any rate was known (24).
        private var criteriaGuessedRate = false
        var onVideoSizeKnown: ((CGSize) -> Void)?
        /// The picture's frame rate, for the control strip's readout.
        var onFrameRateKnown: ((Double) -> Void)?
        /// What the first frame of each load is (PQ, HLG, SDR; a Dolby
        /// Vision RPU), for the playback info panel.
        var onFrameRangeKnown: ((VideoFrameRange) -> Void)?
        /// Smooth Motion started or stopped doubling the picture.
        var onSmoothMotionChanged: ((Bool) -> Void)?
        var onPlaybackUpdate: ((PlaybackState) -> Void)?
        /// The AVPlayer, as each load makes one and teardown drops it.
        var onPlayerChanged: ((AVPlayer?) -> Void)?
        #if os(iOS) || os(macOS)
        let pictureInPicture = VideoPictureInPicture()
        #endif
        var onPlaybackError: (() -> Void)?
        var startMuted = true
        var startVolume: Float = 1
        /// Playback speed, the default rate every `play()` starts at.
        var speed: Float = 1
        var loops = true
        var spatialAudioSceneIdentifier: String? {
            didSet {
                guard oldValue != spatialAudioSceneIdentifier,
                      let player, let item = player.currentItem,
                      let asset = item.asset as? AVURLAsset else { return }
                item.applySpatialAudioPolicy(sceneIdentifier: spatialAudioSceneIdentifier)
                player.applySpatialAudioPolicy(for: asset, sceneIdentifier: spatialAudioSceneIdentifier)
            }
        }

        private var player: AVPlayer?
        private var playerItem: AVPlayerItem? {
            didSet { playerItem?.preferredMaximumResolution = maximumResolution }
        }
        /// The largest picture an adaptive stream may pick (zero: no cap).
        var maximumResolution: CGSize = .zero {
            didSet {
                guard maximumResolution != oldValue, let playerItem else { return }
                playerItem.preferredMaximumResolution = maximumResolution
                // What is already buffered (a minute or more) stays at the
                // old size until a seek to the playhead drops it.
                let lower = maximumResolution != .zero && (oldValue == .zero
                    || maximumResolution.width < oldValue.width || maximumResolution.height < oldValue.height)
                if lower { seek(to: currentTime) }
            }
        }
        private var videoOutput: AVPlayerItemVideoOutput?
#if HYPNOS_YOUTUBE
        private var flashbackFrames: [YouTubeFlashbackFrame] = []
        private var lastFlashbackCaptureTime = -Double.infinity

        func flashbackCandidates(sensitivity: Double) -> [YouTubeFlashbackCandidate] {
            YouTubeFlashback.candidates(in: flashbackFrames, sensitivity: sensitivity)
        }
#endif
        private var textureCache: CVMetalTextureCache?
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?
        private var failureObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?
        private var timeControlObservation: NSKeyValueObservation?
        private var lastReportedSize: CGSize?
        private var loopA: Double?
        private var loopB: Double?
        private var intermediate: MTLTexture?
        private var isRoomActive = true
        /// Playback state captured at room exit; room re-entry restores it so
        /// a manual pause survives focus/room flaps.
        private var wasPlayingBeforeRoomExit = true
        /// True whenever we intend playback to be running (set by play(),
        /// cleared by pause()). visionOS pauses the AVPlayer out from under us
        /// when a `pushWindow` transition settles (~1s in) — no scenePhase or
        /// room change fires, so nothing resumes it and the video freezes. When
        /// the player drops to .paused while we still intend to play and the
        /// room is active, that pause is involuntary and we resume it.
        var resumesAfterInterruptions = true
        private var intendsToPlay = false
        /// Guards the involuntary-resume path against a tight play/pause loop if
        /// the system insists on pausing. Reset to 0 each time playback actually
        /// resumes (status → .playing).
        private var involuntaryResumeCount = 0
        private static let maxInvoluntaryResumes = 5

        var currentTime: Double {
            player?.currentTime().seconds ?? 0
        }

        func attach(to host: NativeVideoHostView) {
            self.host = host
            mtkView = host.metalView
            #if os(iOS) || os(macOS)
            pictureInPicture.attach(to: host.pipView.playerLayer)
            #endif
            if let device = renderer?.device {
                CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            }
        }

        func load(url: URL, identity: String, startPaused: Bool = false) {
            cleanupPlayer()
            loadedURL = url
            loadedIdentity = identity
            guard let renderer else { return }
            dynamicRange = .unknown
            needsSystemRenderer = false
            hasRPU = false
            dolbyVisionScene = nil
            DolbyVisionSceneLog.reset()
            reportedRange = nil
            masteringDisplay = nil
            contentLightLevel = nil
            firstFrameFormat = nil
            configureMetalView(for: .sdr)

            let asset = MediaAuthorization.shared.asset(for: url)
            let item = AVPlayerItem(asset: asset)
            item.applySpatialAudioPolicy(sceneIdentifier: spatialAudioSceneIdentifier)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            item.add(output)

            let player = AVPlayer(playerItem: item)
            player.applySpatialAudioPolicy(for: asset, sceneIdentifier: spatialAudioSceneIdentifier)
            player.isMuted = startMuted
            player.volume = startVolume
            player.defaultRate = speed
            updateDrawRate()

            self.player = player
            self.playerItem = item
            self.videoOutput = output
#if HYPNOS_YOUTUBE
            flashbackFrames.removeAll(keepingCapacity: true)
            lastFlashbackCaptureTime = -Double.infinity
#endif
            #if os(iOS) || os(macOS)
            host?.pipView.playerLayer.player = player
            #endif
            outputPixelFormat = kCVPixelFormatType_32BGRA
            onPlayerChanged?(player)
            usesSystemLayer = false
            showSystemLayer(false)
            rebuildFramePresenter()

            // The Metal path learns the size from the frames it pulls; while
            // the system layer shows, nothing is pulled.
            measureFrameRate(of: item, player: player)

            presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] observed, _ in
                let size = observed.presentationSize
                Task { @MainActor [weak self] in
                    guard let self, self.usesSystemLayer, size.width > 0, size.height > 0,
                          self.lastReportedSize != size else { return }
                    self.lastReportedSize = size
                    self.onVideoSizeKnown?(size)
                }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.loops else {
                        // AVPlayer pauses at the end by itself.
                        self.reportPlaybackState()
                        return
                    }
                    self.seek(to: 0)
                    if self.isRoomActive {
                        self.play()
                    }
                }
            }

            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onPlaybackError?()
                }
            }

            // FailedToPlayToEndTime only fires for failures DURING playback.
            // A load failure (bad URL, auth, TLS, unsupported container) sets
            // item.status = .failed and would otherwise be swallowed silently:
            // the view just stays transparent forever. Observe it so the
            // fallback path (WebKit) actually engages and the reason is logged.
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
                guard observedItem.status == .failed else { return }
                let message = observedItem.error?.localizedDescription ?? "unknown error"
                // Domain and code (and the underlying one, which says why) are
                // public: the private message alone left a failure unreadable.
                let code = observedItem.error.map { error in
                    let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
                    return error.logCode + (underlying.map { " (\($0.logCode))" } ?? "")
                } ?? "-"
                Task { @MainActor [weak self] in
                    guard let self, self.playerItem === observedItem else { return }
                    AppLogger.videoWindow.error("Native player item failed for \(self.loadedURL?.loggableDescription ?? "?"): \(message) [\(code, privacy: .public)]")
                    self.onPlaybackError?()
                }
            }

            // The periodic time observer only fires while the timeline is
            // advancing, so it can't report a pause/stall (time stops). Observe
            // timeControlStatus directly so windowModel.isPaused stays truthful
            // through every transition — without this the play/pause button
            // desyncs (shows "pause" over a frozen frame) and needs two taps.
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
                let status = observed.timeControlStatus
                Task { @MainActor [weak self] in
                    guard let self, self.player === observed else { return }
                    self.needsPictureRedraw = true
                    self.reportPlaybackState()
                    if status == .playing {
                        self.involuntaryResumeCount = 0
                    } else if status == .paused, self.intendsToPlay, self.isRoomActive, self.resumesAfterInterruptions {
                        self.resumeAfterInvoluntaryPause()
                    } else if status == .paused, !self.resumesAfterInterruptions, !self.analysisBuffering {
                        self.intendsToPlay = false
                    }
                }
            }

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.handleTimeUpdate(time.seconds)
                }
            }

            if renderer.device.currentAllocatedSize >= 0, isRoomActive, !startPaused {
                play()
            }
        }

        private var analysisBuffering = false
        func setAnalysisBuffering(_ held: Bool) {
            analysisBuffering = held
            if held { player?.pause() }
            else if intendsToPlay, isRoomActive { player?.play() }
            reportPlaybackState()
        }

        func play() {
            isRoomActive = true
            intendsToPlay = true
            if !analysisBuffering { player?.play() }
            reportPlaybackState()
        }

        func pause() {
            intendsToPlay = false
            player?.pause()
            reportPlaybackState()
        }

        /// The system paused a player we intend to keep running (a `pushWindow`
        /// transition does this without any scenePhase/room change). Resume,
        /// unless we're at the natural end of the item (the end observer loops
        /// that) or we've already retried too many times (avoid a tight loop if
        /// the system genuinely won't let it play).
        private func resumeAfterInvoluntaryPause() {
            guard !analysisBuffering, let player, let item = player.currentItem else { return }
            let duration = item.duration.seconds
            let current = player.currentTime().seconds
            if duration.isFinite, duration > 0, current >= duration - 0.25 { return }
            guard involuntaryResumeCount < Self.maxInvoluntaryResumes else {
                AppLogger.videoWindow.error("Native player kept pausing after \(Self.maxInvoluntaryResumes, privacy: .public) resumes — giving up")
                return
            }
            involuntaryResumeCount += 1
            AppLogger.videoWindow.info("Native involuntary pause — resuming (attempt \(self.involuntaryResumeCount, privacy: .public))")
            player.play()
        }

        func seek(to seconds: Double) {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            framePresenter?.reset()
            player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        func setMuted(_ muted: Bool) {
            player?.isMuted = muted
            reportPlaybackState()
        }

        func setVolume(_ volume: Float) {
            startVolume = volume
            player?.volume = volume
        }

        /// Now if playing, and from every later `play()` (the default rate);
        /// the item's time-pitch keeps the voice at its pitch.
        /// Speed changes the frame rate: a 60 fps video at 2× shows all 120
        /// frames a second, so the view draws faster and the display is asked
        /// for the rate (`PlaybackFrameRate`).
        func setSpeed(_ speed: Float) {
            let changed = self.speed != speed
            self.speed = speed
            if changed {
                updateDrawRate()
                if dynamicRange != .unknown { updateDisplayCriteria() }
            }
            guard let player else { return }
            player.defaultRate = speed
            if player.rate != 0 { player.rate = speed }
        }

        /// The view draws 60 times a second (with Smooth Motion's doubled
        /// frames 96, or 120 for a doubled 50-60 fps picture once the display
        /// criteria know its rate), and that many times more at a faster
        /// speed, up to 120.
        private func updateDrawRate() {
            let base = framePresenter != nil ? doubledDrawRate : PlaybackFrameRate.normalDrawRate
            mtkView?.preferredFramesPerSecond = Int(PlaybackFrameRate.drawRate(base: base, speed: Double(speed)).rounded())
        }

        /// The speed the display criteria follow: on tvOS the TV would switch
        /// mode (and blank) at every speed change, so there it stays the film's.
        private var criteriaSpeed: Double {
            #if os(visionOS)
            Double(speed)
            #else
            1
            #endif
        }

        func setLoopBounds(a: Double?, b: Double?) {
            loopA = a
            loopB = b
        }

        func setRoomActive(_ active: Bool) {
            guard isRoomActive != active else { return }
            isRoomActive = active
            needsPictureRedraw = true
            if active {
                // Restore the state from when the room deactivated — a video
                // the user manually paused must stay paused (focus flaps from
                // other media / Mac Virtual Display would otherwise unpause
                // it), while wall-snapped windows that were playing keep the
                // auto-resume-on-room-entry behavior.
                if resumesAfterInterruptions, wasPlayingBeforeRoomExit { play() }
            } else {
                // `!= .paused` (not `== .playing`): a just-opened player is
                // still .waitingToPlayAtSpecifiedRate while buffering, and the
                // transient inactive flap at window open would otherwise
                // capture it as "paused" and kill autoplay for good.
                wasPlayingBeforeRoomExit = analysisBuffering ? intendsToPlay : player?.timeControlStatus != .paused
                pause()
            }
        }

        func cleanup() {
            #if os(iOS) || os(macOS)
            pictureInPicture.stop()
            pictureInPicture.onChange(false, false)
            pictureInPicture.onChange = { _, _ in }
            #endif
            cleanupPlayer()
            host = nil
            intermediate = nil
            textureCache = nil
            renderer = nil
            mtkView = nil
            onVideoSizeKnown = nil
            onFrameRateKnown = nil
            onFrameRangeKnown = nil
            onPlaybackUpdate = nil
            onPlaybackError = nil
        }

        /// The picture's frame rate: the video track's own where the asset has
        /// one (a file), else what the player measures of the variant playing
        /// (HLS has no asset track), read at normal speed only, where that is
        /// the content's rate. Polled, since an adaptive stream can change
        /// variant, and reported on a change.
        private func measureFrameRate(of item: AVPlayerItem, player: AVPlayer) {
            frameRateTask?.cancel()
            frameRateTask = Task { @MainActor [weak self, weak item, weak player] in
                var reported: Double?
                while !Task.isCancelled {
                    guard let self, let item, let player, self.playerItem === item else { return }
                    var rate: Double = 0
                    if let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }) {
                        if let assetTrack = track.assetTrack,
                           let nominal = try? await assetTrack.load(.nominalFrameRate), nominal > 0 {
                            rate = Double(nominal)
                        } else if player.rate == 1, player.timeControlStatus == .playing {
                            rate = Double(track.currentVideoFrameRate)
                        }
                    }
                    if rate > 0, rate != reported {
                        reported = rate
                        self.measuredFrameRate = rate
                        self.onFrameRateKnown?(rate)
                        // An HLS stream's first frame comes before the player
                        // has measured anything: the criteria said 24 Hz for
                        // a 23.976 fps episode.
                        if self.criteriaGuessedRate { self.updateDisplayCriteria() }
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        private func cleanupPlayer() {
            lastPixelBuffer = nil
            needsPictureRedraw = true
            intendsToPlay = false
            if player != nil { onPlayerChanged?(nil) }
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
            }
            frameRateTask?.cancel()
            frameRateTask = nil
            measuredFrameRate = nil
            criteriaGuessedRate = false
            statusObservation?.invalidate()
            statusObservation = nil
            presentationSizeObservation?.invalidate()
            presentationSizeObservation = nil
            framePresenter = nil
            criteriaTask?.cancel()
            criteriaTask = nil
            host?.systemView.playerLayer.player = nil
            #if os(iOS) || os(macOS)
            host?.pipView.playerLayer.player = nil
            #endif
            #if os(tvOS) || os(visionOS)
            host?.displayCriteria = nil
            #endif
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            player?.pause()
            if let videoOutput {
                playerItem?.remove(videoOutput)
            }
            timeObserver = nil
            endObserver = nil
            failureObserver = nil
            player = nil
            playerItem = nil
            videoOutput = nil
            loadedURL = nil
            lastReportedSize = nil
            loopA = nil
            loopB = nil
        }

        private func handleTimeUpdate(_ seconds: Double) {
            if let loopA, let loopB, seconds >= loopB - (1.0 / 60.0) {
                seek(to: loopA)
            }
            reportPlaybackState(currentTime: seconds)
        }

        private func reportPlaybackState(currentTime: Double? = nil) {
            guard let player else { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            let ranges = player.currentItem?.loadedTimeRanges ?? []
            let buffered = ranges
                .map(\.timeRangeValue)
                .map { $0.start.seconds + $0.duration.seconds }
                .filter { $0.isFinite }
                .max() ?? 0
            onPlaybackUpdate?(
                PlaybackState(
                    currentTime: currentTime ?? player.currentTime().seconds,
                    duration: duration.isFinite ? duration : 0,
                    paused: analysisBuffering ? !intendsToPlay : player.timeControlStatus == .paused,
                    muted: player.isMuted,
                    buffered: buffered,
                    waiting: !analysisBuffering && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                )
            )
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            needsPictureRedraw = true
            intermediate = nil
            // A cleared frame at the new size keeps the hit region whole
            // (see showSystemLayer); the drawable has the size next turn.
            if usesSystemLayer {
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.usesSystemLayer, let renderer = self.renderer else { return }
                    view.presentClearedFrame(commandQueue: renderer.commandQueue)
                }
            }
        }

        // Keep the last decoded picture available when the compositor needs
        // a new drawable after suspension, before decoding resumes.
        private var lastPixelBuffer: CVPixelBuffer?
        private var needsPictureRedraw = true

        func draw(in view: MTKView) {
            // A new frame first: the view ticks at up to 120 Hz, and a tick
            // with nothing new (between frames, paused) must cost nothing.
            // Taking the drawable first made every idle window ask the
            // compositor for one each tick.
            guard let renderer, let output = videoOutput, let textureCache else { return }

            var newFrame = false
            if let framePresenter {
                if let frame = framePresenter.frame(forHostTime: CACurrentMediaTime()) {
                    lastPixelBuffer = frame.pixelBuffer
                    needsPictureRedraw = true
                    newFrame = true
                }
            } else {
                let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: itemTime),
                   let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                    lastPixelBuffer = buffer
                    needsPictureRedraw = true
                    newFrame = true
                }
            }
#if HYPNOS_YOUTUBE
            if newFrame, flashbackModel?.youTubeID != nil, let pixelBuffer = lastPixelBuffer {
                let frameTime = player?.currentTime().seconds ?? 0
                if frameTime.isFinite, frameTime < lastFlashbackCaptureTime - 0.01 {
                    flashbackFrames.removeAll(keepingCapacity: true)
                    lastFlashbackCaptureTime = -Double.infinity
                }
                if frameTime.isFinite, frameTime - lastFlashbackCaptureTime >= 1.0 / 65.0,
                   let fingerprint = YouTubeFlashback.fingerprint(pixelBuffer, time: frameTime) {
                    flashbackFrames.append(fingerprint)
                    let cutoff = frameTime - YouTubeFlashback.window
                    if let first = flashbackFrames.firstIndex(where: { $0.time >= cutoff }), first > 0 {
                        flashbackFrames.removeFirst(first)
                    } else if flashbackFrames.last?.time ?? frameTime < cutoff {
                        flashbackFrames.removeAll(keepingCapacity: true)
                    }
                    lastFlashbackCaptureTime = frameTime
                }
            }
#endif
            guard needsPictureRedraw,
                  let drawable = view.currentDrawable,
                  let finalPassDesc = view.currentRenderPassDescriptor,
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
            guard let pixelBuffer = lastPixelBuffer,
                  let sourceTexture = makeTexture(from: pixelBuffer, cache: textureCache) else {
                return
            }
            reportSizeIfNeeded(pixelBuffer)
            if dynamicRange == .unknown {
                noteDynamicRange(of: pixelBuffer)
                if usesSystemLayer { return }
            }
            if newFrame, appliesDolbyVisionScenes { noteDolbyVisionScene(of: pixelBuffer) }

            let sharpen = Float(visualAdjustments.clampedSharpenAmount)
            let useRCAS = sharpen > 0.001
            let drawableW = drawable.texture.width
            let drawableH = drawable.texture.height
            var pass2InputTexture: MTLTexture = sourceTexture

            if useRCAS {
                let interW = min(max(sourceTexture.width, drawableW), drawableW * 2)
                let interH = min(max(sourceTexture.height, drawableH), drawableH * 2)
                if let intermediateTex = ensureIntermediate(
                    device: renderer.device,
                    width: interW,
                    height: interH,
                    pixelFormat: view.colorPixelFormat
                ) {
                    let pass1Desc = MTLRenderPassDescriptor()
                    pass1Desc.colorAttachments[0].texture = intermediateTex
                    pass1Desc.colorAttachments[0].loadAction = .clear
                    pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    pass1Desc.colorAttachments[0].storeAction = .store

                    if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) {
                        encoder.setRenderPipelineState(view.colorPixelFormat == .rgba16Float ? renderer.rcasPipelineState16 : renderer.rcasPipelineState)
                        encoder.setFragmentTexture(sourceTexture, index: 0)
                        var uniforms = VideoRCASUniforms(brightness: 0, contrast: 1, saturation: 1, sharpen: sharpen)
                        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoRCASUniforms>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                        encoder.endEncoding()
                        pass2InputTexture = intermediateTex
                    }
                }
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPassDesc) else {
                return
            }

            let didSupersample = pass2InputTexture.width > drawableW || pass2InputTexture.height > drawableH
            encoder.setRenderPipelineState(view.colorPixelFormat == .rgba16Float ? renderer.pipelineState16 : renderer.pipelineState)
            encoder.setFragmentTexture(pass2InputTexture, index: 0)
            var uniforms = VideoAAUniforms(
                brightness: Float(visualAdjustments.brightness),
                contrast: Float(visualAdjustments.contrast),
                saturation: Float(visualAdjustments.saturation),
                applyResolve: didSupersample ? 1.0 : 0.0
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoAAUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()

            needsPictureRedraw = false
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexture: CVMetalTexture?
            let isHalf = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil,
                cache,
                pixelBuffer,
                nil,
                isHalf ? .rgba16Float : .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
            guard status == kCVReturnSuccess,
                  let cvTexture,
                  let texture = CVMetalTextureGetTexture(cvTexture) else {
                return nil
            }
            return texture
        }

        // MARK: HDR

        private var adjustmentsAreNeutral: Bool {
            visualAdjustments.brightness == 0 && visualAdjustments.contrast == 1
                && visualAdjustments.saturation == 1 && visualAdjustments.clampedSharpenAmount <= 0.001
        }

        /// The picture goes to the system's video layer only for Dolby Vision
        /// profile 5, whose RPU only the system applies (purple and green
        /// without it). Everything else HDR draws through Metal's EDR layer,
        /// tone-mapped with the picture's own static metadata: HDR10 and HLG,
        /// and Dolby Vision 8.x as its HDR10 (8.1) or HLG (8.4) base layer.
        /// On the headset `AVPlayerLayer` showed HDR10 darker and flatter,
        /// reading as SDR beside the same episode in AI 3D and through Metal
        /// (user, 2026-11-04; the film player's A/B found the same of every
        /// Core Animation video layer), and applying an 8.1 RPU it blew a
        /// bright scene out (a Netflix 8.1 episode, most of the frame at
        /// 150-260 nits), where the base layer through Metal and AI 3D looked
        /// right (user, 2026-11-05). In the sideload edition each 8.x scene's
        /// RPU range then becomes the layer's metadata (`DolbyVisionScenes`).
        private var wantsSystemLayer: Bool {
            dynamicRange.isHDR && needsSystemRenderer
        }

        /// Smooth Motion is asked for and can run here (visionOS only).
        private var wantsSmoothMotion: Bool {
            #if os(visionOS)
            interpolatesFrames
            #else
            false
            #endif
        }

        /// The first frame says what the picture is. AVFoundation hands PQ
        /// and HLG frames over still encoded (PQ code values in BGRA), which
        /// an SDR drawable showed washed out and dim.
        private func noteDynamicRange(of pixelBuffer: CVPixelBuffer) {
            let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
            if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                dynamicRange = .pq
            } else if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                dynamicRange = .hlg
            } else {
                dynamicRange = .sdr
            }
            // Profile 5 carries an RPU and no colour primaries (its IPT-PQ-c2
            // picture has none to state); 8.1 states BT.2020.
            hasRPU = CVBufferCopyAttachment(pixelBuffer, "DolbyVisionRPUData" as CFString, nil) != nil
            masteringDisplay = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
            contentLightLevel = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
            let hasPrimaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) != nil
            needsSystemRenderer = hasRPU && !hasPrimaries
            // The system layer applies an RPU (HDR and Dolby Vision show
            // there); the Metal path (adjustments, Smooth Motion) does not.
            let range = VideoFrameRange(transferFunction: transfer, hasDolbyVisionRPU: rpuApplied(system: wantsSystemLayer))
            reportedRange = range
            onFrameRangeKnown?(range)
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
            firstFrameFormat = format
            if dynamicRange.isHDR {
                AppLogger.videoWindow.info(
                    "Native player: \(self.dynamicRange == .pq ? "PQ" : "HLG", privacy: .public) picture\(self.needsSystemRenderer ? " (Dolby Vision profile 5)" : "", privacy: .public)"
                )
            }
            updatePresentation()
            rebuildFramePresenter()
            updateDisplayCriteria()
        }

        /// HDR draws through Metal (half-float frames into an EDR layer tagged
        /// PQ or HLG, `wantsSystemLayer`), Dolby Vision 8.x as its base layer.
        /// Only profile 5 plays through the system's video layer, which
        /// applies its RPU, and never leaves it.
        private func updatePresentation() {
            guard host != nil, player != nil, dynamicRange != .unknown else { return }
            let system = wantsSystemLayer
            onFrameRangeKnown.map { report in
                if let range = reportedRange, range.hasDolbyVisionRPU != rpuApplied(system: system) {
                    var updated = range
                    updated.hasDolbyVisionRPU = rpuApplied(system: system)
                    reportedRange = updated
                    report(updated)
                }
            }
            if !system { configureMetalView(for: dynamicRange) }
            guard system != usesSystemLayer else { return }
            usesSystemLayer = system
            showSystemLayer(system)
            if system {
                // Nothing pulls frames while the system layer shows; an
                // attached output would still convert every one.
                if let videoOutput { playerItem?.remove(videoOutput) }
                videoOutput = nil
            } else {
                useOutput(pixelFormat: dynamicRange.isHDR ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA)
            }
            rebuildFramePresenter()
        }

        /// The Metal view stays in the window under the system layer, with
        /// one cleared frame. visionOS hit-tests what reaches the render
        /// server, and a video layer doesn't count: with the Metal view
        /// hidden, a tap on an HDR picture went through the window to the
        /// one behind it (device, 2026-10-25). A presented, all-zero drawable
        /// counts and draws nothing (LambdaVision's mouse catcher found the
        /// same).
        private func showSystemLayer(_ show: Bool) {
            guard let host else { return }
            host.systemView.playerLayer.player = show ? player : nil
            host.systemView.isHidden = !show
            host.metalView.isPaused = show
            if show, let renderer { host.metalView.presentClearedFrame(commandQueue: renderer.commandQueue) }
        }

        /// The drawable and the layer's colour space for the picture Metal
        /// draws: plain BGRA for SDR, half float in an EDR layer for HDR.
        private func configureMetalView(for range: NativeVideoDynamicRange) {
            guard let view = mtkView, let layer = view.layer as? CAMetalLayer else { return }
            let format: MTLPixelFormat = range.isHDR ? .rgba16Float : .bgra8Unorm
            if view.colorPixelFormat != format {
                view.colorPixelFormat = format
                intermediate = nil
            }
            switch range {
            case .pq: layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            case .hlg: layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            case .sdr, .unknown: layer.colorspace = nil
            }
            // tvOS has no EDR switch; the TV's own mode (display criteria)
            // carries HDR there.
            #if !os(tvOS)
            layer.wantsExtendedDynamicRangeContent = range.isHDR
            // Without metadata an EDR layer isn't tone-mapped at all: what is
            // above the display's headroom clips (CAMetalLayer.h), so an HDR10
            // film's highlights were cut off here where the system's video
            // layer rolled them off. With the film's own mastering display and
            // light levels the system tone-maps the layer as it does a video.
            switch range {
            case .pq: layer.edrMetadata = pqMetadata()
            case .hlg: layer.edrMetadata = CAEDRMetadata.hlg
            case .sdr, .unknown: layer.edrMetadata = nil
            }
            #endif
            #if os(macOS)
            // macOS 26 tone-maps a layer to SDR unless it asks for more.
            layer.preferredDynamicRange = range.isHDR ? .high : .standard
            #endif
        }

        #if !os(tvOS)
        /// HDR10's static metadata, or the Dolby Vision scene's range when one
        /// applies: the system then maps this scene, not the whole master.
        private func pqMetadata() -> CAEDRMetadata {
            if let scene = dolbyVisionScene, let maxNits = scene.maxNits {
                // A scene darker than paper white is still mapped as one that
                // reaches it, so the curve never lifts it.
                return CAEDRMetadata.hdr10(minLuminance: Float(max(scene.minNits ?? 0, 0.0001)),
                                           maxLuminance: Float(min(max(maxNits, 100), 10000)),
                                           opticalOutputScale: 100)
            }
            return CAEDRMetadata.hdr10(displayInfo: masteringDisplay, contentInfo: contentLightLevel,
                                       opticalOutputScale: 100)
        }
        #endif

        // MARK: Dolby Vision scenes (sideload edition)

        /// Metal draws a Dolby Vision 8.x picture (PQ base layer) and the
        /// build can read its RPUs: each scene's L1 range goes to the layer.
        private var appliesDolbyVisionScenes: Bool {
            hasRPU && !needsSystemRenderer && dynamicRange == .pq && !usesSystemLayer && DolbyVisionScenes.isAvailable
        }

        /// The RPU is applied: by the system's layer, or as scene metadata.
        private func rpuApplied(system: Bool) -> Bool {
            hasRPU && (system || (!needsSystemRenderer && dynamicRange == .pq && DolbyVisionScenes.isAvailable))
        }

        /// Reads a new frame's RPU and, at a new scene, hands its range to the
        /// layer. Interpolated frames carry none and keep the scene.
        private func noteDolbyVisionScene(of pixelBuffer: CVPixelBuffer) {
            guard let scene = DolbyVisionScenes.read(pixelBuffer), scene.maxNits != nil,
                  !scene.sameRange(as: dolbyVisionScene) else { return }
            dolbyVisionScene = scene
            #if !os(tvOS)
            (mtkView?.layer as? CAMetalLayer)?.edrMetadata = pqMetadata()
            #endif
            let seconds = player?.currentTime().seconds ?? 0
            DolbyVisionSceneLog.note(scene, at: seconds, applied: true)
            AppLogger.videoWindow.info(
                "Dolby Vision scene at \(seconds, format: .fixed(precision: 2), privacy: .public) s: L1 \(scene.minNits ?? 0, format: .fixed(precision: 3), privacy: .public)/\(scene.averageNits ?? 0, format: .fixed(precision: 1), privacy: .public)/\(scene.maxNits ?? 0, format: .fixed(precision: 1), privacy: .public) nits, CM \(scene.contentMappingVersion, privacy: .public), \(scene.l2Trims + scene.l8Trims, privacy: .public) trims, reshaping \(scene.identityReshaping ? "identity" : "not identity", privacy: .public)"
            )
        }

        /// Swaps the frame output for one in another pixel format.
        private func useOutput(pixelFormat: OSType) {
            guard let playerItem else { return }
            if let videoOutput { playerItem.remove(videoOutput) }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            playerItem.add(output)
            videoOutput = output
            outputPixelFormat = pixelFormat
        }

        // MARK: Smooth Motion

        /// Puts Vergence's interpolator between the frame output and the draw
        /// loop: a 24-30 or 50-60 fps picture plays at twice its rate, each
        /// in-between frame shown when it is due (`InterpolatedFramePresenter`),
        /// with the display asked for a matching refresh (48 fps on 96 Hz, 120
        /// on an M5 headset's 120 Hz). It sits before the adjustments and
        /// sharpening, which then apply to every frame alike.
        ///
        /// Two interpolators, by the picture's rate (`interpolationEngine`):
        /// VideoToolbox's for 24-30 fps, and for 50-60 fps the GPU one
        /// (`FlowMidFrameInterpolator`, ~1.5 ms a 1080p frame on an M2 Max),
        /// since VideoToolbox's 5-18 ms doesn't fit an in-between frame every
        /// 16.7 ms. A display without 120 Hz (an M2 headset tops out at 100)
        /// shows a doubled 60 fps picture as best it can.
        ///
        /// HDR too (since 2026-11-04): the picture leaves the system layer for
        /// half-float frames in an EDR layer (`wantsSystemLayer`), and an HDR
        /// pair goes through VideoToolbox's 8-bit interpolator with only its
        /// motion kept (Vergence's `HDRMidFrameComposer`), so the in-between
        /// frames don't band. A Dolby Vision profile 5 picture stays on the
        /// system layer and plays its own frames; an 8.x one shows its HDR10
        /// base layer while Smooth Motion is on.
        /// visionOS only: the motion sickness this is for is a headset's, and
        /// other displays (60/120 Hz) can't show 48 fps evenly. Nothing else
        /// uses the Neural Engine here, so it keeps up where AI 3D's depth
        /// model sharing it couldn't; the governor (`.flat` thresholds) still
        /// backs off if frames come late.
        private func rebuildFramePresenter() {
            #if os(visionOS)
            let had = framePresenter != nil
            framePresenter = nil
            if interpolatesFrames, !usesSystemLayer,
               FramePixelFormat.isSupported(outputPixelFormat),
               let videoOutput, let playerItem {
                let source = InterpolatingFrameSource.wrappingIfSupported(
                    AVPlayerFrameSource(output: videoOutput, item: playerItem), thresholds: .flat,
                    engine: interpolationEngine.vergenceEngine, sharedFields: sharedFields
                )
                if source is InterpolatingFrameSource {
                    framePresenter = InterpolatedFramePresenter(source: source)
                }
            }
            let has = framePresenter != nil
            doubledDrawRate = 96
            updateDrawRate()
            onSmoothMotionChanged?(has)
            if had || has {
                AppLogger.videoWindow.info("Native player: Smooth Motion \(has ? "on" : "off", privacy: .public) (\(self.interpolationEngine.rawValue, privacy: .public))")
                if dynamicRange != .unknown { updateDisplayCriteria() }
            }
            #endif
        }

        /// HDR states its format so the picture doesn't dim; a doubled picture,
        /// or one played at another speed, states the rate it shows so the
        /// display can show it evenly. Plain SDR at normal speed leaves the
        /// display as it is.
        private func updateDisplayCriteria() {
            #if os(tvOS) || os(visionOS)
            if dynamicRange.isHDR || framePresenter != nil || criteriaSpeed != 1 {
                applyDisplayCriteria()
            } else {
                criteriaTask?.cancel()
                host?.displayCriteria = nil
            }
            #endif
        }

        private func applyDisplayCriteria() {
            #if os(tvOS) || os(visionOS)
            criteriaTask?.cancel()
            let item = playerItem
            let fallback = firstFrameFormat
            criteriaTask = Task { @MainActor [weak self] in
                // The asset's own track says Dolby Vision (dvh1) where a
                // decoded frame can't; an HLS stream has none, so the frame.
                // The track's nominal rate first: what the player measures
                // (all HLS has) is the rate shown, which a speed multiplies.
                var format = fallback
                var rate: Double = 0
                if let playerTrack = item?.tracks.first(where: { $0.assetTrack?.mediaType == .video }) {
                    if let track = playerTrack.assetTrack {
                        if let described = try? await track.load(.formatDescriptions).first { format = described }
                        if let nominal = try? await track.load(.nominalFrameRate), nominal > 0 { rate = Double(nominal) }
                    }
                    if rate <= 0, let player = self?.player, player.rate > 0 {
                        rate = Double(playerTrack.currentVideoFrameRate) / Double(player.rate)
                    }
                }
                guard !Task.isCancelled, let self, self.playerItem === item, let format else { return }
                if rate <= 0, let measured = self.measuredFrameRate { rate = measured }
                self.criteriaGuessedRate = rate <= 0
                let snapped = PlaybackFrameRate.snapped(rate > 0 ? rate : 24)
                let highest = (self.framePresenter?.source as? InterpolatingFrameSource)?.highestSourceFrameRate ?? 0
                let doubled = snapped < highest
                let shown = PlaybackFrameRate.shown(source: snapped, doubled: doubled, speed: self.criteriaSpeed)
                if self.framePresenter != nil {
                    let draw = doubled ? max(96, min(PlaybackFrameRate.maximum, snapped * 2)) : 96
                    if draw != self.doubledDrawRate {
                        self.doubledDrawRate = draw
                        self.updateDrawRate()
                    }
                }
                self.host?.displayCriteria = AVDisplayCriteria(refreshRate: Float(shown), formatDescription: format)
                AppLogger.videoWindow.info("Native player: display at \(shown, format: .fixed(precision: 3), privacy: .public) Hz")
            }
            #endif
        }

        private func reportSizeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
            let size = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            guard size.width > 0, size.height > 0, lastReportedSize != size else { return }
            lastReportedSize = size
            onVideoSizeKnown?(size)
        }

        private func ensureIntermediate(
            device: MTLDevice,
            width: Int,
            height: Int,
            pixelFormat: MTLPixelFormat
        ) -> MTLTexture? {
            if let existing = intermediate,
               existing.width == width,
               existing.height == height,
               existing.pixelFormat == pixelFormat {
                return existing
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            let texture = device.makeTexture(descriptor: desc)
            intermediate = texture
            return texture
        }
    }
}
