/*
 Hypnos - Native Metal Video Player View

 AVFoundation-backed video player that renders decoded frames through Metal.
 Used for formats AVFoundation can decode natively, while WKWebView remains the
 fallback for WebM and other Safari-only formats.
 */

import AVFoundation
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
    var onPlaybackError: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        guard let renderer = MetalImageRenderer.shared else {
            return MTKView()
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

        context.coordinator.renderer = renderer
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.visualAdjustments = visualAdjustments
        coordinator.onVideoSizeKnown = onVideoSizeKnown
        coordinator.onPlaybackError = onPlaybackError
        coordinator.startMuted = startMuted

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
            coordinator.onPlaybackUpdate = { [weak playbackModel] state in
                playbackModel?.applyPlaybackState(
                    currentTime: state.currentTime,
                    duration: state.duration,
                    paused: state.paused,
                    muted: state.muted,
                    buffered: state.buffered
                )
            }
        }

        if coordinator.loadedURL != videoURL {
            coordinator.load(url: videoURL)
        }

        coordinator.setRoomActive(isRoomActive)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
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
        }

        weak var mtkView: MTKView?
        var renderer: MetalImageRenderer?
        var loadedURL: URL?
        var visualAdjustments = VisualAdjustments()
        var onVideoSizeKnown: ((CGSize) -> Void)?
        var onPlaybackUpdate: ((PlaybackState) -> Void)?
        var onPlaybackError: (() -> Void)?
        var startMuted = true

        private var player: AVPlayer?
        private var playerItem: AVPlayerItem?
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

        func attach(to view: MTKView) {
            mtkView = view
            if let device = renderer?.device {
                CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            }
        }

        func load(url: URL) {
            cleanupPlayer()
            loadedURL = url
            guard let renderer else { return }

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

            self.player = player
            self.playerItem = item
            self.videoOutput = output

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.seek(to: 0)
                    if self?.isRoomActive == true {
                        self?.play()
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
                Task { @MainActor [weak self] in
                    guard let self, self.playerItem === observedItem else { return }
                    AppLogger.videoWindow.error("Native player item failed for \(self.loadedURL?.loggableDescription ?? "?"): \(message)")
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
            intermediate = nil
            textureCache = nil
            renderer = nil
            mtkView = nil
            onVideoSizeKnown = nil
            onPlaybackUpdate = nil
            onPlaybackError = nil
        }

        private func cleanupPlayer() {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
            }
            statusObservation?.invalidate()
            statusObservation = nil
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
                    buffered: buffered
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
                        encoder.setRenderPipelineState(renderer.rcasPipelineState)
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
            encoder.setRenderPipelineState(renderer.pipelineState)
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
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
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
    var onPlaybackError: (() -> Void)? = nil

    var body: some View {
        Color.clear.onAppear { onPlaybackError?() }
    }
}

#endif
