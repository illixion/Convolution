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

// A real `UIViewRepresentable` (nothing visionOS-only here), so it already
// compiles and runs on iOS/tvOS unchanged. macOS needs `NSViewRepresentable`
// instead — a different protocol with different required method names, even
// though every line of AVPlayer/Metal setup below is already fully
// cross-platform. Nothing in the macOS UI (Views/Mac/) mounts this view —
// `Views/Mac/MacVideoPlayerView.swift` uses AVKit's `AVPlayerView` directly,
// which is the more idiomatic Mac choice anyway — so this pass stubs it
// rather than writing the second (small, `Coordinator`-sharing) wrapper. See
// Hypnos/CLAUDE.md "macOS" for the seam list and gaps.
#if !os(macOS)

private struct VideoRCASUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var sharpen: Float
}

private struct VideoAAUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var applyResolve: Float
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
final class NativeVideoHostView: UIView {
    let metalView: MTKView
    let systemView = SystemVideoLayerView()

    init(metalView: MTKView) {
        self.metalView = metalView
        super.init(frame: .zero)
        isOpaque = false
        for view in [metalView, systemView] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        systemView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(tvOS) || os(visionOS)
    /// Stated to the window's display manager while the view is in it. On
    /// visionOS it is how a player declares HDR video (without it the picture
    /// dims once playback starts); tvOS switches the TV's mode with it.
    var displayCriteria: AVDisplayCriteria? {
        didSet { applyDisplayCriteria() }
    }
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

final class SystemVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct NativeMetalVideoPlayerView: UIViewRepresentable {
    let videoURL: URL
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
    var onPlaybackError: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NativeVideoHostView {
        guard let renderer = MetalImageRenderer.shared else {
            return NativeVideoHostView(metalView: MTKView())
        }

        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = context.coordinator
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = false
        view.layer.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let host = NativeVideoHostView(metalView: view)
        context.coordinator.renderer = renderer
        context.coordinator.attach(to: host)
        return host
    }

    func updateUIView(_ view: NativeVideoHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.visualAdjustments = visualAdjustments
        coordinator.onVideoSizeKnown = onVideoSizeKnown
        coordinator.onPlaybackError = onPlaybackError
        coordinator.startMuted = startMuted
        coordinator.startVolume = Float(playbackModel?.volume ?? 1)
        coordinator.speed = Float(playbackModel?.playbackSpeed ?? 1)
        coordinator.loops = loops
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
            playbackModel.setMutedCommand = { [weak coordinator] muted in
                coordinator?.setMuted(muted)
            }
            playbackModel.setVolumeCommand = { [weak coordinator] volume in
                coordinator?.setVolume(Float(volume))
            }
            playbackModel.setSpeedCommand = { [weak coordinator] speed in
                coordinator?.setSpeed(Float(speed))
            }
            coordinator.onPlayerChanged = { [weak playbackModel] player in
                playbackModel?.noteNativePlayer(player)
            }
            coordinator.onFrameRateKnown = { [weak playbackModel] rate in
                playbackModel?.notePictureFrameRate(rate)
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

        if coordinator.loadedURL != videoURL {
            coordinator.load(url: videoURL)
        }

        coordinator.setRoomActive(isRoomActive)
    }

    static func dismantleUIView(_ view: NativeVideoHostView, coordinator: Coordinator) {
        coordinator.cleanup()
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
        var renderer: MetalImageRenderer?
        var loadedURL: URL?
        var visualAdjustments = VisualAdjustments() {
            didSet { updatePresentation() }
        }
        /// Read off the first decoded frame of each load.
        private var dynamicRange = NativeVideoDynamicRange.unknown
        /// Dolby Vision profile 5: its frames are IPT-PQ-c2, which only the
        /// system's renderer maps (with the RPU), so it never shows through
        /// Metal. The app does no Dolby processing of its own.
        private var needsSystemRenderer = false
        private var usesSystemLayer = false
        /// The first HDR frame, for display criteria when the stream has no
        /// asset track to describe it (HLS).
        private var firstHDRFrameFormat: CMVideoFormatDescription?
        private var presentationSizeObservation: NSKeyValueObservation?
        private var criteriaTask: Task<Void, Never>?
        private var frameRateTask: Task<Void, Never>?
        var onVideoSizeKnown: ((CGSize) -> Void)?
        /// The picture's frame rate, for the control strip's readout.
        var onFrameRateKnown: ((Double) -> Void)?
        var onPlaybackUpdate: ((PlaybackState) -> Void)?
        /// The AVPlayer, as each load makes one and teardown drops it.
        var onPlayerChanged: ((AVPlayer?) -> Void)?
        var onPlaybackError: (() -> Void)?
        var startMuted = true
        var startVolume: Float = 1
        /// Playback speed, the default rate every `play()` starts at.
        var speed: Float = 1
        var loops = true

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
            if let device = renderer?.device {
                CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            }
        }

        func load(url: URL) {
            cleanupPlayer()
            loadedURL = url
            guard let renderer else { return }
            dynamicRange = .unknown
            needsSystemRenderer = false
            firstHDRFrameFormat = nil
            configureMetalView(for: .sdr)

            let asset = MediaAuthorization.shared.asset(for: url)
            let item = AVPlayerItem(asset: asset)
            item.applySpatialAudioPolicy()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            item.add(output)

            let player = AVPlayer(playerItem: item)
            player.applySpatialAudioPolicy(for: asset)
            player.isMuted = startMuted
            player.volume = startVolume
            player.defaultRate = speed

            self.player = player
            self.playerItem = item
            self.videoOutput = output
            onPlayerChanged?(player)
            usesSystemLayer = false
            showSystemLayer(false)

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
                    guard let self else { return }
                    self.reportPlaybackState()
                    if status == .playing {
                        self.involuntaryResumeCount = 0
                    } else if status == .paused, self.intendsToPlay, self.isRoomActive {
                        self.resumeAfterInvoluntaryPause()
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

            if renderer.device.currentAllocatedSize >= 0, isRoomActive {
                play()
            }
        }

        func play() {
            isRoomActive = true
            intendsToPlay = true
            player?.play()
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
            guard let player, let item = player.currentItem else { return }
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
        func setSpeed(_ speed: Float) {
            self.speed = speed
            guard let player else { return }
            player.defaultRate = speed
            if player.rate != 0 { player.rate = speed }
        }

        func setLoopBounds(a: Double?, b: Double?) {
            loopA = a
            loopB = b
        }

        func setRoomActive(_ active: Bool) {
            guard isRoomActive != active else { return }
            isRoomActive = active
            if active {
                // Restore the state from when the room deactivated — a video
                // the user manually paused must stay paused (focus flaps from
                // other media / Mac Virtual Display would otherwise unpause
                // it), while wall-snapped windows that were playing keep the
                // auto-resume-on-room-entry behavior.
                if wasPlayingBeforeRoomExit { play() }
            } else {
                // `!= .paused` (not `== .playing`): a just-opened player is
                // still .waitingToPlayAtSpecifiedRate while buffering, and the
                // transient inactive flap at window open would otherwise
                // capture it as "paused" and kill autoplay for good.
                wasPlayingBeforeRoomExit = player?.timeControlStatus != .paused
                pause()
            }
        }

        func cleanup() {
            cleanupPlayer()
            host = nil
            intermediate = nil
            textureCache = nil
            renderer = nil
            mtkView = nil
            onVideoSizeKnown = nil
            onFrameRateKnown = nil
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
                        self.onFrameRateKnown?(rate)
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        private func cleanupPlayer() {
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
            statusObservation?.invalidate()
            statusObservation = nil
            presentationSizeObservation?.invalidate()
            presentationSizeObservation = nil
            criteriaTask?.cancel()
            criteriaTask = nil
            host?.systemView.playerLayer.player = nil
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
                    paused: player.timeControlStatus != .playing,
                    muted: player.isMuted,
                    buffered: buffered,
                    waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                )
            )
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            intermediate = nil
        }

        func draw(in view: MTKView) {
            guard let renderer,
                  let output = videoOutput,
                  let textureCache,
                  let drawable = view.currentDrawable,
                  let finalPassDesc = view.currentRenderPassDescriptor,
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                return
            }

            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: itemTime),
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
                  let sourceTexture = makeTexture(from: pixelBuffer, cache: textureCache) else {
                return
            }
            reportSizeIfNeeded(pixelBuffer)
            if dynamicRange == .unknown {
                noteDynamicRange(of: pixelBuffer)
                if usesSystemLayer { return }
            }

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
            let hasRPU = CVBufferCopyAttachment(pixelBuffer, "DolbyVisionRPUData" as CFString, nil) != nil
            let hasPrimaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) != nil
            needsSystemRenderer = hasRPU && !hasPrimaries
            if dynamicRange.isHDR {
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
                firstHDRFrameFormat = format
                AppLogger.videoWindow.info(
                    "Native player: \(self.dynamicRange == .pq ? "PQ" : "HLG", privacy: .public) picture\(self.needsSystemRenderer ? " (Dolby Vision profile 5)" : "", privacy: .public)"
                )
            }
            updatePresentation()
            if dynamicRange.isHDR { applyDisplayCriteria() }
        }

        /// HDR plays through the system's video layer, which shows it (and
        /// Dolby Vision, RPU and all) as the OS does everywhere else. Metal
        /// takes over only while adjustments or sharpening are on, then in
        /// HDR itself (half-float frames into an EDR layer tagged PQ or HLG).
        /// Profile 5 never leaves the system layer.
        private func updatePresentation() {
            guard host != nil, player != nil, dynamicRange != .unknown else { return }
            let system = dynamicRange.isHDR && (needsSystemRenderer || adjustmentsAreNeutral)
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
        }

        private func showSystemLayer(_ show: Bool) {
            guard let host else { return }
            host.systemView.playerLayer.player = show ? player : nil
            host.systemView.isHidden = !show
            host.metalView.isHidden = show
            host.metalView.isPaused = show
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
            #endif
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
        }

        private func applyDisplayCriteria() {
            #if os(tvOS) || os(visionOS)
            criteriaTask?.cancel()
            let item = playerItem
            let fallback = firstHDRFrameFormat
            criteriaTask = Task { @MainActor [weak self] in
                // The asset's own track says Dolby Vision (dvh1) where a
                // decoded frame can't; an HLS stream has none, so the frame.
                var format = fallback
                var rate: Float = 0
                if let playerTrack = item?.tracks.first(where: { $0.assetTrack?.mediaType == .video }) {
                    rate = playerTrack.currentVideoFrameRate
                    if let track = playerTrack.assetTrack {
                        if let described = try? await track.load(.formatDescriptions).first { format = described }
                        if rate <= 0, let nominal = try? await track.load(.nominalFrameRate) { rate = nominal }
                    }
                }
                guard !Task.isCancelled, let self, self.playerItem === item, let format else { return }
                let measured = Double(rate > 0 ? rate : 24)
                let standard: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]
                let snapped = standard.min { abs($0 - measured) < abs($1 - measured) } ?? measured
                self.host?.displayCriteria = AVDisplayCriteria(refreshRate: Float(snapped), formatDescription: format)
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

#else

/// macOS stub — see the gate comment above.
struct NativeMetalVideoPlayerView: View {
    let videoURL: URL
    var isRoomActive: Bool = true
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var visualAdjustments: VisualAdjustments = VisualAdjustments()
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    var startMuted: Bool = true
    var loops: Bool = true
    var onPlaybackError: (() -> Void)? = nil

    var body: some View {
        Color.clear.onAppear { onPlaybackError?() }
    }
}

#endif
