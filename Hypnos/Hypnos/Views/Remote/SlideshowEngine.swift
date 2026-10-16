/*
 Hypnos - Slideshow Engine

 What a slideshow window renders, driven by RAVESDK's `RAVESlideshowEngine`.
 The shared engine owns the timing, the queue, prefetch and history; this
 class turns its media into the window's view state: decoded images and
 their Metal textures, the media type, the crossfade's incoming slot, the
 Ken Burns focus and dynamic-brightness analysis, diorama layers, and
 real-time fake-3D for videos.

 The shared engine is observed rather than polled: its `incoming` item stages
 the crossfade, its `onTransition` commits it, and its prefetched look-ahead
 is decoded early for the 3D layer. A decoded image is cached by item id, so
 the `UIImage` the 3D layer pre-generated a depth map against is the very
 instance that later becomes current, and is never decoded twice.

 RemoteViewerModel subclasses it with the window's profile and display
 toggles.
 */

import CoreGraphics
import DebugTrace
import Metal
import Observation
import RAVESlideshow
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

@MainActor
@Observable
class SlideshowEngine {
    // MARK: - State

    enum SlideshowState: Equatable, CustomStringConvertible {
        case idle
        case loading
        case displaying
        case transitioning
        case paused
        case backgrounded
        case stopped

        var description: String {
            switch self {
            case .idle: "idle"
            case .loading: "loading"
            case .displaying: "displaying"
            case .transitioning: "transitioning"
            case .paused: "paused"
            case .backgrounded: "backgrounded"
            case .stopped: "stopped"
            }
        }
    }

    /// Mirrors the shared engine's state.
    private(set) var state: SlideshowState = .idle

    // MARK: - Media Type

    enum SlideshowMediaType: Equatable {
        case image
        case video(URL)
        case animatedGIF(URL)
        /// Animated WebP rendered via WKWebView (browser-native animation).
        /// The URL is the original image URL — WebKit decodes/animates the
        /// WebP directly, no HEVC conversion needed.
        case animatedWebP(URL)
        /// Animated JPEG XL rendered via WKWebView. WebKit can't decode JXL,
        /// so a bundled WASM libjxl build decodes the frames and muxes them
        /// into an APNG the `<img>` animates. The bytes travel in
        /// `currentAnimatedData`; the URL is the original image URL.
        case animatedJXL(URL)
    }

    // MARK: - Display State

    var currentImage: UIImage?
    var nextImage: UIImage?
    /// GPU-private texture mirrors of `currentImage` / `nextImage`, so the
    /// window view renders via Metal (matching the photo viewer's pipeline)
    /// while the UIImages stay available for diorama and focus analysis.
    var currentTexture: MTLTexture?
    var nextTexture: MTLTexture?
    /// Raw bytes for the current post when its mediaType is animated, passed
    /// to the WebKit views so they decode from memory instead of re-fetching.
    var currentAnimatedData: Data?
    /// Streaming URL for the current video (a Stash transcode): the fallback
    /// the `<video>` player switches to when the raw source won't play.
    var currentVideoHLSURL: URL?
    var currentPost: RemotePost?
    var nextPost: RemotePost?
    var currentMediaType: SlideshowMediaType = .image
    /// URL for the incoming video layer during a crossfade into a video.
    var nextVideoURL: URL?

    /// The video URL that should currently be rendered, unifying the
    /// incoming-crossfade slot and the committed slot. During a crossfade
    /// into a video `nextVideoURL` is set while `currentMediaType` is still
    /// the outgoing media; after the commit `currentMediaType` becomes
    /// `.video(url)` with the *same* URL. Returning that single URL lets the
    /// window view host one stable player across the commit, so the player
    /// isn't destroyed and reloaded right after the crossfade.
    var activeVideoURL: URL? {
        if let url = nextVideoURL { return url }
        if case .video(let url) = currentMediaType { return url }
        return nil
    }

    /// True when the current media is animated (WebP, JXL or HEVC-GIF) and
    /// its player needs a static first-frame fallback behind it to avoid a
    /// blank flash while the player spins up.
    var isAnimatedMediaWithStaticFallback: Bool {
        switch currentMediaType {
        case .animatedWebP, .animatedGIF, .animatedJXL: return true
        case .image, .video: return false
        }
    }

    var isCurrentPostAnimatedGIF: Bool = false
    var isRoomActive: Bool = true
    var isTransitioning: Bool = false
    var isLoading: Bool = false

    /// Posts shown so far, oldest first, as the shared engine's history.
    /// Enables the ornament's Previous button.
    var postHistory: [RemotePost] = []

    // Toast notifications
    var toastMessage: String?
    var toastIsError: Bool = false
    private var toastDismissTask: Task<Void, Never>?

    // Ken Burns
    var focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Dynamic brightness
    var autoBrightnessAdjustment: Double = 0
    var autoContrastAdjustment: Double = 1.0

    // User visual adjustments
    var currentAdjustments: VisualAdjustments = VisualAdjustments()
    var showAdjustmentsPopover: Bool = false
    var globalAdjustments: VisualAdjustments = VisualAdjustments()

    /// Counter for ornament-anchored Menu drop-downs (3D mode, resolution).
    /// SwiftUI's `Menu` doesn't expose an open binding; ornaments increment
    /// when the menu's content panel appears and decrement when it dismisses.
    /// Used by the window view to suppress the diorama foreground while a
    /// menu panel is shown so the menu isn't visually occluded by the
    /// popped-forward foreground at z=40.
    var openOrnamentMenuCount: Int = 0

    var isAnyOrnamentMenuOpen: Bool {
        openOrnamentMenuCount > 0
    }

    var effectiveBrightness: Double {
        autoBrightnessAdjustment + currentAdjustments.brightness + globalAdjustments.brightness
    }

    var effectiveContrast: Double {
        autoContrastAdjustment * currentAdjustments.contrast * globalAdjustments.contrast
    }

    var effectiveSaturation: Double {
        currentAdjustments.saturation * globalAdjustments.saturation
    }

    var effectiveOpacity: Double {
        currentAdjustments.opacity * globalAdjustments.opacity
    }

    // MARK: - Configuration
    //
    // Each change is passed on to the shared engine, which owns the timing.

    var delay: TimeInterval { didSet { if delay != oldValue { pushDisplaySettings() } } }
    var enableKenBurns: Bool { didSet { if enableKenBurns != oldValue { pushDisplaySettings() } } }
    var useAspectRatio: Bool {
        didSet {
            guard useAspectRatio != oldValue else { return }
            pushDisplaySettings()
            pushPreferredAspectRatio()
        }
    }
    var enableDynamicBrightness: Bool {
        didSet {
            guard enableDynamicBrightness != oldValue else { return }
            if !enableDynamicBrightness {
                autoBrightnessAdjustment = 0
                autoContrastAdjustment = 1.0
            }
            pushDisplaySettings()
        }
    }
    /// Cap used for 2D images; `maxImageResolution3D` applies while slideshow
    /// 3D is on, when the same bytes feed RealityKit's `Spatial3DImage`.
    var maxImageResolution: Int = 0 { didSet { if maxImageResolution != oldValue { pushDisplaySettings() } } }
    var maxImageResolution3D: Int = 0 { didSet { if maxImageResolution3D != oldValue { pushDisplaySettings() } } }

    /// When non-`.off`, the window view renders via RealityKit
    /// `ImagePresentationComponent` instead of a SwiftUI `Image`.
    var slideshow3DMode: Slideshow3DMode = .off {
        didSet {
            guard slideshow3DMode != oldValue else { return }
            if slideshow3DMode != .off {
                // Ken Burns + diorama don't apply to the RealityKit pipeline.
                if enableKenBurns { enableKenBurns = false }
                if enableDiorama { enableDiorama = false }
            }
            pushDisplaySettings()
            // A video already on screen converts (or drops back to flat)
            // immediately, matching how the image layer swaps renderers.
            refreshPseudo3DForActiveVideo()
        }
    }

    /// True when the engine is rendering through RealityKit. View layer
    /// reads this to suppress Ken Burns + diorama overlays.
    var isSlideshow3DActive: Bool { slideshow3DMode != .off }

    /// Diorama mode — when enabled, each image gets an uncropped foreground
    /// (background removed) the view layer pops forward in z. Expensive
    /// per-image processing, so off by default.
    var enableDiorama: Bool = false {
        didSet {
            guard enableDiorama != oldValue else { return }
            if !enableDiorama { clearDioramaForegrounds() }
            pushDisplaySettings()
        }
    }

    /// When true, the crossfade between images is replaced with an instant
    /// switch (driven by AppModel's effectiveReduceMotion).
    var reduceMotion: Bool = false { didSet { if reduceMotion != oldValue { pushDisplaySettings() } } }

    var windowAspectRatio: Double = 16.0 / 9.0

    // MARK: - Slideshow 3D Video (real-time fake 3D)

    /// A video post cleared for real-time mono→stereo conversion, together with
    /// the URL that has to be played to get it (the raw source when AVFoundation
    /// can decode it, otherwise the transcode).
    struct Pseudo3DVideoTarget: Equatable {
        let postId: Int
        let url: URL
    }

    /// Resolved target for the video post currently being displayed. Never read
    /// directly by the view — see `activePseudo3DVideoURL`, which re-checks that
    /// the target still belongs to the video on screen.
    private(set) var pseudo3DVideoTarget: Pseudo3DVideoTarget?
    private var pseudo3DResolveTask: Task<Void, Never>?

    /// Memoized decodability answers, keyed by URL. RAM-only and bounded — a
    /// looping slideshow revisits the same clips, and each probe costs an
    /// `AVURLAsset` metadata round-trip.
    private var nativeDecodeProbeCache: [URL: Bool] = [:]
    private static let nativeDecodeProbeCacheLimit = 64
    /// Per-candidate probe budget; a source that hasn't answered by then
    /// plays flat.
    private static let nativeDecodeProbeTimeout: TimeInterval = 2.0

    /// URL to hand `Pseudo3DVideoPlayerView`, or nil when the active video
    /// should play flat. Gated on the resolved target still matching the video
    /// on screen, so it self-invalidates on every post change without any
    /// clearing at the call sites — during a crossfade into a video the video
    /// is `nextPost`, after the commit it's `currentPost`.
    var activePseudo3DVideoURL: URL? {
        guard isSlideshow3DActive, activeVideoURL != nil,
              let target = pseudo3DVideoTarget else { return nil }
        let activeId = (nextVideoURL != nil ? nextPost?._id : nil) ?? currentPost?._id
        guard target.postId == activeId else { return nil }
        return target.url
    }

    /// The stereo pipeline couldn't play this source (no usable depth, decode
    /// failure). Drop back to the flat tiers for this post; the next post
    /// resolves fresh.
    func reportPseudo3DVideoFailure() {
        // Ignore a late report from a player torn down for a post we've moved
        // past — that would wrongly disable 3D for the clip now on screen.
        guard let target = pseudo3DVideoTarget, activePseudo3DVideoURL == target.url else { return }
        AppLogger.remoteViewer.warning("Slideshow fake-3D failed for post \(target.postId, privacy: .private(mask: .hash)); falling back to flat playback")
        pseudo3DVideoTarget = nil
    }

    /// Decide whether `post`'s video can be converted in real time, and on which
    /// URL. Requires slideshow 3D on, an installed real-time depth model, and an
    /// AVFoundation-decodable source — the stereo pump pulls frames from an
    /// `AVPlayerItemVideoOutput`, so WebKit-only sources (WebM/VP9) are reachable
    /// only via the transcode.
    ///
    /// Real-time inference only: depth lives in GPU/RAM for the frame it warps
    /// and is never written to disk, so a slideshow can't quietly fill storage
    /// with depth videos for everything it cycles past.
    private func resolvePseudo3DTarget(url: URL, hlsURL: URL?, post: RemotePost) async -> Pseudo3DVideoTarget? {
        guard isSlideshow3DActive else { return nil }
        guard CoreMLDepthProvider.hasAvailableModel(role: .realtime) else {
            AppLogger.remoteViewer.debug("Slideshow 3D on but no real-time depth model installed — video plays flat")
            return nil
        }
        var candidates = [url]
        if let hlsURL, hlsURL != url { candidates.append(hlsURL) }
        for candidate in candidates {
            if await canDecodeNatively(candidate) {
                return Pseudo3DVideoTarget(postId: post._id, url: candidate)
            }
        }
        AppLogger.remoteViewer.info("Slideshow post \(post._id, privacy: .private(mask: .hash)) isn't AVFoundation-decodable — video plays flat in 2D")
        return nil
    }

    private func canDecodeNatively(_ url: URL) async -> Bool {
        if let cached = nativeDecodeProbeCache[url] { return cached }
        let result = await NativeVideoDecodeProbe.canPlayNatively(
            url: url, timeout: Self.nativeDecodeProbeTimeout
        )
        if nativeDecodeProbeCache.count >= Self.nativeDecodeProbeCacheLimit {
            nativeDecodeProbeCache.removeAll(keepingCapacity: true)
        }
        nativeDecodeProbeCache[url] = result
        return result
    }

    /// Resolve (or tear down) fake-3D for the video on screen: when a video
    /// becomes current, and when the 3D mode is toggled mid-video.
    private func refreshPseudo3DForActiveVideo() {
        pseudo3DResolveTask?.cancel()
        pseudo3DResolveTask = nil
        guard isSlideshow3DActive else {
            pseudo3DVideoTarget = nil
            return
        }
        guard let url = activeVideoURL,
              let post = (nextVideoURL != nil ? nextPost : nil) ?? currentPost,
              pseudo3DVideoTarget?.postId != post._id else { return }
        let hls = currentVideoHLSURL
        pseudo3DResolveTask = Task { [weak self] in
            guard let self else { return }
            let target = await self.resolvePseudo3DTarget(url: url, hlsURL: hls, post: post)
            guard !Task.isCancelled else { return }
            self.pseudo3DVideoTarget = target
        }
    }

    // MARK: - Look-ahead

    /// The next image, decoded, so the 3D layer can mount a hidden RealityKit
    /// entity and finish depth-map generation before the crossfade. The same
    /// instance becomes `nextImage` and then `currentImage` (see
    /// `decodedImages`), so that work survives the commit.
    private(set) var peekedNextImage: UIImage?

    /// Decoded stills by item id: the peek, the incoming image and the current
    /// one. Small and bounded; anything else is evicted on each commit.
    private var decodedImages: [String: (image: UIImage, texture: MTLTexture?)] = [:]
    private var decodingIds: Set<String> = []

    // MARK: - Diorama

    /// Uncropped foreground for the currently displayed post, when diorama
    /// is enabled. GPU-private MTLTexture so the pixels live in GPU
    /// memory and don't count toward jetsam-tracked dirty CPU pages.
    /// Nil while still being generated or when diorama is off.
    var currentForegroundTexture: MTLTexture?

    /// Subject-blurred backdrop for the currently displayed post — replaces
    /// the original as the base layer when diorama is on so the floating
    /// foreground doesn't expose a doubled silhouette.
    var currentBackdropTexture: MTLTexture?

    /// Diorama pair for the incoming post, during its crossfade.
    var nextForegroundTexture: MTLTexture?
    var nextBackdropTexture: MTLTexture?

    /// In-flight generation keyed by post id, so navigating away or turning
    /// diorama off can cancel it.
    private var dioramaTasks: [Int: Task<Void, Never>] = [:]

    /// Completed pairs keyed by post id. Generation can finish before the
    /// post reaches a slot, so results land here and the commit picks them up.
    private var dioramaCache: [Int: (foreground: MTLTexture?, backdrop: MTLTexture?)] = [:]

    // MARK: - Shared engine

    var contentProvider: (any RAVESlideshowContentProvider)?
    private var sharedEngine: RAVESlideshowEngine?

    // MARK: - Init

    init(delay: TimeInterval = 15, enableKenBurns: Bool = true, useAspectRatio: Bool = true, enableDynamicBrightness: Bool = true, enableDiorama: Bool = false) {
        self.delay = delay
        self.enableKenBurns = enableKenBurns
        self.useAspectRatio = useAspectRatio
        self.enableDynamicBrightness = enableDynamicBrightness
        self.enableDiorama = enableDiorama
    }

    // MARK: - Lifecycle

    /// Build the shared engine over `contentProvider`. Call once, before `start()`.
    func useRAVESlideshowForLocalContent(
        mode3D: RAVESlideshow3DMode = .off,
        maxImageResolution2D: Int = 0,
        maxImageResolution3D: Int = 0
    ) {
        guard let provider = contentProvider else { return }
        let configuration = RAVESlideshowConfiguration(
            prefetchLimit: 3,
            retryLimit: 2,
            automaticAdvancement: true,
            platformCapabilities: .current
        )
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: displaySettings(mode3D: mode3D, maxImageResolution2D: maxImageResolution2D, maxImageResolution3D: maxImageResolution3D),
            configuration: configuration
        )
        engine.onTransition = { [weak self] displayed in
            self?.commit(displayed)
            RAVESlideshowLocalSyncCoordinator.shared.broadcast(from: engine)
        }
        sharedEngine = engine
        RAVESlideshowLocalSyncCoordinator.shared.register(engine)
        pushPreferredAspectRatio()
        observe(engine)
    }

    func start() {
        guard state == .idle, let sharedEngine else { return }
        state = .loading
        isLoading = true
        sharedEngine.start()
    }

    func stop() {
        state = .stopped
        if let sharedEngine {
            RAVESlideshowLocalSyncCoordinator.shared.unregister(sharedEngine)
            sharedEngine.stop()
            self.sharedEngine = nil
        }
        pseudo3DResolveTask?.cancel()
        pseudo3DResolveTask = nil
        clearDioramaForegrounds()
    }

    private func displaySettings(mode3D: RAVESlideshow3DMode, maxImageResolution2D: Int, maxImageResolution3D: Int) -> RAVESlideshowDisplaySettings {
        RAVESlideshowDisplaySettings(
            delay: delay,
            transitionDuration: reduceMotion ? 0 : 1,
            showClock: true,
            showSensors: false,
            useAspectRatio: useAspectRatio,
            enableKenBurns: enableKenBurns,
            enableDynamicBrightness: enableDynamicBrightness,
            enableDiorama: enableDiorama,
            transparentBackground: false,
            textScale: 1,
            reduceMotion: reduceMotion,
            mode3D: mode3D,
            maxImageResolution2D: maxImageResolution2D,
            maxImageResolution3D: maxImageResolution3D
        )
    }

    private func pushDisplaySettings() {
        guard let sharedEngine else { return }
        let mode3D: RAVESlideshow3DMode = switch slideshow3DMode {
        case .off: .off
        case .spatial3D: .spatial3D
        case .immersive3D: .immersive3D
        }
        sharedEngine.displaySettings = displaySettings(
            mode3D: mode3D,
            maxImageResolution2D: maxImageResolution,
            maxImageResolution3D: maxImageResolution3D
        )
    }

    private func pushPreferredAspectRatio() {
        sharedEngine?.preferredAspectRatio = useAspectRatio ? windowAspectRatio : nil
    }

    /// Follow the shared engine: its state, the item it's fading in, and the
    /// head of its prefetch queue. Re-armed after every change, as
    /// observation tracking fires once.
    private func observe(_ engine: RAVESlideshowEngine) {
        withObservationTracking {
            _ = engine.state
            _ = engine.incoming
            _ = engine.peekedNext
            _ = engine.history
        } onChange: { [weak self, weak engine] in
            Task { @MainActor [weak self, weak engine] in
                guard let self, let engine, self.sharedEngine === engine else { return }
                self.engineChanged(engine)
                self.observe(engine)
            }
        }
    }

    private func engineChanged(_ engine: RAVESlideshowEngine) {
        state = switch engine.state {
        case .idle: .idle
        case .loading: .loading
        case .displaying: .displaying
        case .transitioning: .transitioning
        case .paused: .paused
        case .backgrounded: .backgrounded
        case .stopped: .stopped
        }
        isLoading = engine.isLoading && currentPost == nil
        postHistory = engine.history.map(Self.post(for:))
        if let incoming = engine.incoming, incoming.item.id != currentPost.map({ String($0._id) }) {
            stage(incoming)
        }
        if let peek = engine.peekedNext, case .still(let data, _) = peek.media {
            decode(peek.item.id, data) { [weak self] image, _ in
                guard let self, self.sharedEngine?.peekedNext?.item.id == peek.item.id else { return }
                self.peekedNextImage = image
            }
        }
    }

    // MARK: - Transitions

    /// The shared engine started fading `displayed` in: put it in the
    /// incoming slot so the window crossfades to it.
    private func stage(_ displayed: RAVESlideshowDisplayedMedia) {
        let post = Self.post(for: displayed.item)
        switch displayed.media {
        case .still(let data, _):
            decode(displayed.item.id, data) { [weak self] image, texture in
                guard let self, self.sharedEngine?.incoming?.item.id == displayed.item.id else { return }
                if self.enableDiorama, let cached = self.dioramaCache[post._id] {
                    self.nextForegroundTexture = cached.foreground
                    self.nextBackdropTexture = cached.backdrop
                }
                self.crossfade {
                    self.nextImage = image
                    self.nextTexture = texture
                    self.nextPost = post
                    self.isTransitioning = true
                }
            }
        case .video(let url, _):
            crossfade {
                self.nextVideoURL = url
                self.nextPost = post
                self.isTransitioning = true
            }
            refreshPseudo3DForActiveVideo()
        case .animatedImage:
            // Animated media cuts in at the commit; its WebKit player has no
            // incoming slot to fade from.
            break
        }
    }

    private func crossfade(_ changes: () -> Void) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, changes)
        } else {
            withAnimation(.easeInOut(duration: 1.0), changes)
        }
    }

    /// The shared engine finished its transition: `displayed` is current.
    private func commit(_ displayed: RAVESlideshowDisplayedMedia) {
        let post = Self.post(for: displayed.item)
        let previousPostId = currentPost?._id
        currentPost = post
        currentVideoHLSURL = nil
        currentAnimatedData = nil
        isCurrentPostAnimatedGIF = false
        switch displayed.media {
        case let .still(data, _):
            currentMediaType = .image
            if let decoded = decodedImages[displayed.item.id] {
                currentImage = decoded.image
                currentTexture = decoded.texture
            } else {
                // Not staged (reduce motion, or the decode lost the race):
                // decode now, and show it as soon as it's ready.
                currentImage = nil
                currentTexture = nil
                decode(displayed.item.id, data) { [weak self] image, texture in
                    guard let self, self.currentPost?._id == post._id else { return }
                    self.currentImage = image
                    self.currentTexture = texture
                    self.analyze(image, post: post)
                    self.promoteDiorama(for: post)
                }
            }
        case let .animatedImage(data, url):
            currentImage = data.flatMap(UIImage.init(data:))
            currentTexture = currentImage.flatMap {
                MetalImageRenderer.shared?.createTexture(from: $0, autoCropTransparentEdges: false)
            }
            currentAnimatedData = data
            isCurrentPostAnimatedGIF = true
            let ext = url.pathExtension.lowercased()
            currentMediaType = ext == "gif" ? .animatedGIF(url) : ext == "jxl" ? .animatedJXL(url) : .animatedWebP(url)
        case let .video(url, hlsURL):
            currentImage = nil
            currentTexture = nil
            currentMediaType = .video(url)
            currentVideoHLSURL = hlsURL
        }
        nextImage = nil
        nextTexture = nil
        nextVideoURL = nil
        nextPost = nil
        isTransitioning = false
        isLoading = false

        if let image = currentImage, currentMediaType == .image {
            analyze(image, post: post)
        } else {
            autoBrightnessAdjustment = 0
            autoContrastAdjustment = 1.0
        }
        promoteDiorama(for: post)
        if case .video = currentMediaType { refreshPseudo3DForActiveVideo() }
        if previousPostId != post._id { evictDecodedImages() }
    }

    /// Ken Burns focus and dynamic brightness for the image now on screen.
    private func analyze(_ image: UIImage, post: RemotePost) {
        guard let cgImage = image.cgImage else { return }
        let kenBurns = enableKenBurns, dynamicBrightness = enableDynamicBrightness
        Task { [weak self] in
            let focus: CGPoint? = kenBurns ? await Task.detached { SobelFocusAnalyzer.focusPoint(from: cgImage) }.value : nil
            let luminance: Double? = dynamicBrightness ? await Task.detached { Double(SobelFocusAnalyzer.averageLuminance(from: cgImage)) }.value : nil
            guard let self, self.currentPost?._id == post._id else { return }
            if let focus { self.focusPoint = focus }
            if let luminance, luminance < 0.3 {
                let boost = (0.3 - luminance) * 0.5
                self.autoBrightnessAdjustment = boost
                self.autoContrastAdjustment = 1.0 + boost * 0.5
            } else {
                self.autoBrightnessAdjustment = 0
                self.autoContrastAdjustment = 1.0
            }
        }
    }

    // MARK: - Decoding

    /// Decode `data` for item `id` off the main actor, with its texture, and
    /// hand both to `completion`. A cached decode is handed over at once.
    private func decode(_ id: String, _ data: Data, completion: @escaping (UIImage, MTLTexture?) -> Void) {
        if let cached = decodedImages[id] {
            completion(cached.image, cached.texture)
            return
        }
        guard !decodingIds.contains(id) else { return }
        decodingIds.insert(id)
        let maxDimension = CGFloat(isSlideshow3DActive ? maxImageResolution3D : maxImageResolution)
        Task { [weak self] in
            let image = await Task.detached { MetalImageRenderer.downsampledImage(from: data, maxDimension: maxDimension) }.value
            var texture: MTLTexture?
            if let image { texture = await Self.makeTexture(from: image) }
            guard let self else { return }
            self.decodingIds.remove(id)
            guard let image else { return }
            self.decodedImages[id] = (image, texture)
            completion(image, texture)
        }
    }

    /// Keep only what can still be shown: the current image, the incoming one
    /// and the peek.
    private func evictDecodedImages() {
        let keep = Set([
            currentPost.map { String($0._id) },
            sharedEngine?.incoming?.item.id,
            sharedEngine?.peekedNext?.item.id,
        ].compactMap { $0 })
        decodedImages = decodedImages.filter { keep.contains($0.key) }
        if let peek = peekedNextImage, !decodedImages.values.contains(where: { $0.image === peek }) {
            peekedNextImage = nil
        }
    }

    nonisolated static func makeTexture(from image: UIImage) async -> MTLTexture? {
        guard let cg = image.cgImage else { return nil }
        let sendable: SendableTexture? = await Task.detached {
            guard let tex = MetalImageRenderer.shared?.createTexture(from: cg) else { return nil }
            return SendableTexture(texture: tex)
        }.value
        return sendable?.texture
    }

    /// Re-upload the currently displayed static image into a fresh private
    /// texture. Restored scenes can receive a GPU resource before their window
    /// surface is ready; replacing it after the post is mounted separates a
    /// stale-resource failure from an MTKView/compositor failure.
    func refreshCurrentTextureForRenderRecovery() {
        guard currentMediaType == .image, let image = currentImage else { return }
        AppLogger.windowState.info("[Remote] refreshing current texture for render recovery")
        Task { [weak self, weak image] in
            guard let self, let image else { return }
            let texture = await Self.makeTexture(from: image)
            guard self.currentImage === image else { return }
            self.currentTexture = texture
        }
    }

    /// The shared engine's item as the post the window's views read.
    private static func post(for item: RAVESlideshowItem) -> RemotePost {
        RemotePost(
            _id: Int(item.id) ?? abs(item.id.hashValue),
            file_ext: item.fileExtension,
            tags: Array(item.tags),
            rating: nil,
            image_width: nil,
            image_height: nil,
            fav_count: nil,
            md5: nil,
            parent_id: nil,
            score: nil,
            ratio: nil,
            path: item.metadata["url"],
            duration: item.duration
        )
    }

    // MARK: - Diorama

    /// Generate the diorama foreground+backdrop for `post`, filling the
    /// current slot if it's still the displayed post.
    func generateDioramaForeground(post: RemotePost, image: UIImage, isCurrent: Bool) {
        guard enableDiorama else { return }
        if dioramaTasks[post.id] != nil { return }

        let postId = post.id
        let task = Task { @MainActor [weak self] in
            defer { Task { @MainActor [weak self] in self?.dioramaTasks.removeValue(forKey: postId) } }
            do {
                let pair = try await BackgroundRemover.shared.generateDioramaPair(from: image)
                guard !Task.isCancelled, let self else { return }
                let foregroundTexture: MTLTexture? = await Self.uploadDioramaTexture(pair.foreground)
                let backdropTexture: MTLTexture? = await Self.uploadDioramaTexture(pair.backdrop)
                guard !Task.isCancelled else { return }
                self.dioramaCache[postId] = (foreground: foregroundTexture, backdrop: backdropTexture)
                if isCurrent, self.currentPost?.id == postId {
                    self.currentForegroundTexture = foregroundTexture
                    self.currentBackdropTexture = backdropTexture
                }
            } catch {
                // Generation can fail on unsupported formats; silently skip.
            }
        }
        dioramaTasks[postId] = task
    }

    /// The post just became current: show its diorama pair, generating it if
    /// it isn't ready.
    private func promoteDiorama(for post: RemotePost) {
        nextForegroundTexture = nil
        nextBackdropTexture = nil
        guard enableDiorama, currentMediaType == .image, let image = currentImage else {
            currentForegroundTexture = nil
            currentBackdropTexture = nil
            return
        }
        if let cached = dioramaCache[post._id] {
            currentForegroundTexture = cached.foreground
            currentBackdropTexture = cached.backdrop
        } else {
            currentForegroundTexture = nil
            currentBackdropTexture = nil
            generateDioramaForeground(post: post, image: image, isCurrent: true)
        }
        dioramaCache = dioramaCache.filter { $0.key == post._id }
    }

    /// Drop all in-flight diorama work and clear cached foregrounds + backdrops.
    func clearDioramaForegrounds() {
        for (_, task) in dioramaTasks { task.cancel() }
        dioramaTasks.removeAll()
        dioramaCache.removeAll()
        currentForegroundTexture = nil
        currentBackdropTexture = nil
        nextForegroundTexture = nil
        nextBackdropTexture = nil
    }

    /// Upload a diorama UIImage to a GPU-private MTLTexture off the main
    /// actor. Uses lossy compression — diorama is a decorative overlay,
    /// the small color delta from lossy texture compression is invisible
    /// next to the base layer's rendering. Transparent-edge auto-crop is
    /// disabled so the foreground stays at the full source frame size —
    /// see PhotoWindowModel+Diorama.uploadDioramaTexture for the
    /// rationale.
    nonisolated static func uploadDioramaTexture(_ image: UIImage?) async -> MTLTexture? {
        guard let image, let cg = image.cgImage else { return nil }
        let sendable: SendableTexture? = await Task.detached {
            guard let tex = MetalImageRenderer.shared?.createTexture(from: cg, useLossyCompression: true, autoCropTransparentEdges: false) else { return nil }
            return SendableTexture(texture: tex)
        }.value
        return sendable?.texture
    }

    // MARK: - Memory

    /// Drop the look-ahead and diorama working sets after a system memory
    /// warning, keeping what's on screen.
    func trimForMemoryPressure() {
        sharedEngine?.trimForMemoryPressure()
        nextForegroundTexture = nil
        nextBackdropTexture = nil
        dioramaCache.removeAll(keepingCapacity: false)
        evictDecodedImages()
    }

    // MARK: - Scene phase

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        // On visionOS scenePhase flips to .inactive constantly — gaze shifts,
        // Control Center, notifications, or simply not being the user's current
        // focus. A wall-snapped ambient slideshow is *meant* to sit unfocused,
        // so it lives in .inactive almost permanently and keeps cycling there.
        // Only .background means the window is truly gone — app suspended,
        // headset off, or window closed.
        let wasVisible = oldPhase != .background
        let isVisible = newPhase != .background
        guard wasVisible != isVisible else { return }
        isRoomActive = isVisible
        sharedEngine?.setVisible(isVisible)
        if !isVisible {
            // A backgrounded window no longer cycles, so its look-ahead would
            // only sit resident until a memory warning.
            nextForegroundTexture = nil
            nextBackdropTexture = nil
            dioramaCache.removeAll(keepingCapacity: false)
            evictDecodedImages()
        }
    }

    func updateWindowAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        windowAspectRatio = size.width / size.height
        pushPreferredAspectRatio()
    }

    // MARK: - Navigation

    func goToNextImage() {
        sharedEngine?.advanceToNext()
    }

    func previousImage() {
        sharedEngine?.previous()
    }

    func togglePause() {
        sharedEngine?.togglePause()
    }

    func showToast(_ message: String, isError: Bool = false) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastIsError = isError
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }
}
