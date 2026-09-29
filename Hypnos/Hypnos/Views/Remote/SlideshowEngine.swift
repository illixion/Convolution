/*
 Hypnos - Slideshow Engine

 Core slideshow engine using a state machine for lifecycle management.
 Handles timer-driven image transitions, prefetching, Ken Burns focus
 analysis, dynamic brightness, navigation, and background lifecycle.

 States: idle → loading → displaying ⇄ paused / backgrounded → stopped

 This is the reusable base class. RemoteViewerModel subclasses it to
 add WebSocket, save/block, sensor display, and display sync features.
 Gallery-mode slideshows can use this class directly.
 */

import CoreGraphics
import DebugTrace
import Metal
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
    // MARK: - State Machine

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

    /// Current slideshow state. All lifecycle transitions go through `transition(to:)`.
    private(set) var state: SlideshowState = .idle

    /// Signal used to wake the run loop when state changes (e.g. unpause, next).
    /// The run loop sleeps on this; any transition increments it to break the sleep.
    private var stateVersion: Int = 0

    // MARK: - Media Type

    enum SlideshowMediaType: Equatable {
        case image
        case video(URL)
        /// H.264 rendered via WKWebView `<img src=mp4>` — WebKit plays it as a
        /// muted looping animated image and manages playback lifecycle (pause /
        /// resume on room transitions) itself. Used by the RoboFrame slideshow
        /// for both animated posts and videos, in place of an AVPlayer.
        case videoAsImage(URL)
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

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"
    ]

    // MARK: - Display State

    var currentImage: UIImage?
    var nextImage: UIImage?
    /// GPU-private texture mirrors of `currentImage` / `nextImage`. Set
    /// alongside the UIImages so the window view can render via Metal
    /// (matching the photo viewer's pipeline) while UIImages remain
    /// available for diorama / focus analysis / display sync.
    var currentTexture: MTLTexture?
    var nextTexture: MTLTexture?
    /// Raw bytes for the current post when its mediaType is animated
    /// (.animatedWebP, etc.). Passed to `AnimatedImageWebView` so WebKit
    /// decodes from memory via a `data:` URL instead of re-fetching the
    /// URL — startup time for an animated WebP drops from several
    /// seconds to near-instant. Cleared on every non-animated commit.
    var currentAnimatedData: Data?
    /// HLS streaming URL for the current video post — the fallback the
    /// `<video>` player switches to when native playback of the raw source
    /// fails. nil for non-video posts or providers without a streaming
    /// fallback (e.g. local files).
    var currentVideoHLSURL: URL?
    /// Set when the native video-in-`<img>` tier reports an error for the
    /// current video post; flips rendering to the `<video>` tiers (raw → HLS).
    var videoNativeImgFailed: Bool = false
    var currentPost: RemotePost?
    var nextPost: RemotePost?
    var currentMediaType: SlideshowMediaType = .image
    /// Media type of the incoming (crossfading-in) slot. Normally `.image`;
    /// set to `.video` during an image→video true crossfade so the window
    /// view can render a second `WebVideoPlayerView` for `nextVideoURL` at
    /// full opacity while the outgoing image fades out.
    var nextMediaType: SlideshowMediaType = .image
    /// URL for the incoming video layer during an image→video crossfade.
    var nextVideoURL: URL?

    /// The video URL that should currently be rendered, unifying the
    /// incoming-crossfade slot and the committed slot. During an image→video
    /// crossfade `nextVideoURL` is set while `currentMediaType` is still
    /// `.image`; after commit `currentMediaType` becomes `.video(url)` with the
    /// *same* URL. Returning that single URL lets the window view host one
    /// stable `WebVideoPlayerView` across the commit, so the player isn't
    /// destroyed and reloaded (which caused a brief blank flash right after the
    /// crossfade completed). Returns nil for animated GIF/WebP, which have
    /// their own players.
    var activeVideoURL: URL? {
        // Incoming crossfade slot takes precedence (image→video), then the
        // committed slot (steady-state video, or after the crossfade commits).
        if let url = nextVideoURL { return url }
        if case .video(let url) = currentMediaType { return url }
        if case .videoAsImage(let url) = currentMediaType { return url }
        return nil
    }

    /// Whether the active video layer should render via the video-in-`<img>`
    /// path (RoboFrame content) rather than an AVPlayer. Mirrors `activeVideoURL`
    /// precedence: the incoming crossfade slot first, then the committed slot.
    var activeVideoIsAnimatedImage: Bool {
        // Native <img> playback failed for this post → use the <video> tiers.
        if videoNativeImgFailed { return false }
        if nextVideoURL != nil {
            if case .videoAsImage = nextMediaType { return true }
            return false
        }
        if case .videoAsImage = currentMediaType { return true }
        return false
    }

    /// True when the current media is animated (WebP or HEVC-GIF) and its
    /// player needs a static first-frame fallback behind it to avoid a blank
    /// flash while the player spins up. For GIFs the player only swaps in after
    /// the crossfade (once HEVC conversion finishes), so the fallback bridges
    /// that gap.
    var isAnimatedMediaWithStaticFallback: Bool {
        switch currentMediaType {
        case .animatedWebP, .animatedGIF, .animatedJXL: return true
        case .image, .video, .videoAsImage: return false
        }
    }

    var isCurrentPostAnimatedGIF: Bool = false
    var isRoomActive: Bool = true
    var isTransitioning: Bool = false
    var isLoading: Bool = false

    /// Remote mode is purely server-paced: the orchestrator's `playback`
    /// frames are the sole advance trigger and the engine never advances on
    /// its own dwell clock. This guarantees the displayed post always matches
    /// the server's `current`, so `imageReady` can't report an image the
    /// server hasn't committed (which the readiness barrier would drop,
    /// stalling the channel). Gallery mode leaves this false and runs the
    /// local dwell timer. Set by the remote viewer before the run loop starts.
    var serverDriven: Bool = false
    /// The orchestrator's latest `current` post (remote mode only). The engine
    /// advances toward this whenever it's in a state where jumping is safe.
    private(set) var serverCurrentPost: RemotePost?

    /// The orchestrator's latest `next` post (remote mode only). In server-
    /// driven mode display always flows through the `pendingPost` path, so
    /// `prefetchedImages` is never consumed in id order and its `.first` is a
    /// stale duplicate of an early image — not the true look-ahead. The 3D
    /// pre-generation layer needs the real next, so `peekedNextImage` resolves
    /// the prefetched image whose id matches this instead.
    private(set) var serverNextPost: RemotePost?

    /// Record the orchestrator's announced `next`. Set from the remote
    /// viewer's `playback` handler alongside `setServerCurrent`.
    func setServerNext(_ post: RemotePost?) {
        serverNextPost = post
    }

    /// Drop prefetched images the orchestrator has moved past (remote mode
    /// only). In server-driven mode the buffer is drained solely by exact id
    /// match in `fetchAndDisplayPost`, so entries whose post never becomes a
    /// future `current` are stranded forever: the copy prefetch finished
    /// downloading *after* the display path already fetched the same post
    /// directly (a race every short-interval channel hits), and any announced
    /// next/upcoming the server skipped past (block from another device,
    /// requestNext, dark advance, merge-driver change). The provider's
    /// `seenIds` dedup guarantees a stranded id never re-enqueues. Once
    /// strays fill the buffer to `prefetchTarget`, prefetch stops downloading
    /// entirely and `peekedNextImage` can never resolve again — the 3D
    /// layer's hidden slot then fades in stale content on every crossfade.
    /// Called on each `playback` frame with the server's full announced
    /// look-ahead (current + next + upcoming), so a stray lives at most one
    /// interval.
    func pruneStalePrefetchedImages(keepingPostIds ids: Set<Int>) {
        guard serverDriven else { return }
        let before = prefetchedImages.count
        prefetchedImages.removeAll { !ids.contains($0.post._id) }
        let dropped = before - prefetchedImages.count
        if dropped > 0 {
            AppLogger.remoteViewer.debug("Pruned \(dropped, privacy: .public) stale prefetched image(s) the server moved past")
        }
    }

    /// True once the slideshow has shown a real image at least once. Used to
    /// distinguish the cold-start case (allow a bounded wait for the first
    /// image, show spinner) from steady state (show placeholder immediately on
    /// missing prefetch).
    private var hasDisplayedFirstMedia: Bool = false

    /// In steady state, when the auto-advance can't produce a prefetched
    /// image, we keep the current image displayed and re-check after this
    /// short interval rather than flashing the warning placeholder. Short
    /// enough that the slideshow resumes quickly once prefetch fills.
    private static let steadyStateRetryInterval: TimeInterval = 3

    /// Convenience for views — true when state is .paused
    var isPaused: Bool { state == .paused }

    // Toast notifications
    var toastMessage: String?
    var toastIsError: Bool = false
    private var toastDismissTask: Task<Void, Never>?

    // Save grace period
    var previousPost: RemotePost?
    private var previousPostGraceTask: Task<Void, Never>?

    var saveablePost: RemotePost? {
        currentPost ?? previousPost
    }

    // Ken Burns
    var focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Dynamic brightness
    var autoBrightnessAdjustment: Double = 0
    var autoContrastAdjustment: Double = 1.0

    // User visual adjustments
    var currentAdjustments: VisualAdjustments = VisualAdjustments()
    var showAdjustmentsPopover: Bool = false
    var globalAdjustments: VisualAdjustments = VisualAdjustments()

    /// Counter for ornament-anchored Menu drop-downs (tag list, mod tag, etc.).
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

    // MARK: - Content State

    var cachedPosts: [RemotePost] = []
    var postHistory: [RemotePost] = []
    var historyImageURLs: [Int: URL] = [:]
    var isFetching: Bool = false
    var fetchReturnedEmpty: Bool = false

    // MARK: - Blocking

    var blockedPosts: Set<Int> = []
    var blockedTags: Set<String> = []

    // MARK: - Configuration

    var delay: TimeInterval
    var enableKenBurns: Bool
    var useAspectRatio: Bool
    var enableDynamicBrightness: Bool
    /// Cap used by the 2D download/prefetch pipeline. The window view uses
    /// `maxImageResolution3D` when slideshow 3D is enabled to derive the
    /// RealityKit `Spatial3DImage` source from the original disk file.
    var maxImageResolution: Int = 0
    var maxImageResolution3D: Int = 0

    /// When non-`.off`, the window view should render via RealityKit
    /// `ImagePresentationComponent` instead of a SwiftUI `Image`. Engine
    /// keeps generating UIImage previews so the gallery overlays + Ken
    /// Burns code paths stay unchanged for `.off` consumers; the 3D
    /// path is opt-in per-window.
    var slideshow3DMode: Slideshow3DMode = .off {
        didSet {
            guard slideshow3DMode != oldValue else { return }
            if slideshow3DMode != .off {
                // Ken Burns + diorama don't apply to the RealityKit pipeline.
                if enableKenBurns { enableKenBurns = false }
                if enableDiorama { enableDiorama = false }
            }
            // A video already on screen converts (or drops back to flat)
            // immediately, matching how the image layer swaps renderers.
            refreshPseudo3DForActiveVideo()
        }
    }

    /// True when the engine is rendering through RealityKit. View layer
    /// reads this to suppress Ken Burns + diorama overlays.
    var isSlideshow3DActive: Bool { slideshow3DMode != .off }

    /// Resolution passed to `downloadImage` — uses the 3D cap while
    /// slideshow 3D is active, otherwise the regular 2D cap. The same image
    /// data feeds both the SwiftUI preview and RealityKit's Spatial3DImage,
    /// so a single download per post is enough.
    var effectiveDownloadResolution: Int {
        isSlideshow3DActive ? maxImageResolution3D : maxImageResolution
    }

    // MARK: - Slideshow 3D Video (real-time fake 3D)

    /// A video post cleared for real-time mono→stereo conversion, together with
    /// the URL that has to be played to get it (the raw source when AVFoundation
    /// can decode it, otherwise the server's HLS transcode).
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
    /// Per-candidate probe budget. Bounded because it sits in front of a video
    /// transition; a source that hasn't answered by then plays flat.
    private static let nativeDecodeProbeTimeout: TimeInterval = 2.0

    /// URL to hand `Pseudo3DVideoPlayerView`, or nil when the active video
    /// should play flat. Gated on the resolved target still matching the video
    /// on screen, so it self-invalidates on every post change without any
    /// clearing at the call sites — during an image→video crossfade the video is
    /// `nextPost`, after the commit it's `currentPost`.
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
    /// only via the server transcode.
    ///
    /// Real-time inference only: depth lives in GPU/RAM for the frame it warps
    /// and is never written to disk (no `DepthConverter` / `DepthCacheStore`
    /// involvement), so a slideshow can't quietly fill storage with depth
    /// videos for everything it cycles past.
    private func resolvePseudo3DTarget(url: URL, hlsURL: URL?, post: RemotePost) async -> Pseudo3DVideoTarget? {
        guard isSlideshow3DActive else { return nil }
        guard CoreMLDepthProvider.hasAvailableModel(role: .realtime) else {
            AppLogger.remoteViewer.debug("Slideshow 3D on but no real-time depth model installed — video plays flat")
            return nil
        }
        // Raw source first (no transcode cost); HLS transcode as the fallback
        // for containers AVFoundation won't touch.
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

    /// Re-resolve (or tear down) fake-3D for the video already on screen. Used
    /// when the 3D mode is toggled mid-video from the ornament.
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

    /// First image queued for the next crossfade. Exposed so the 3D
    /// renderer can mount a hidden RealityKit entity ahead of time and
    /// finish depth-map generation before `displayImage` flips the
    /// transition flag — without this peek the hidden view only sees the
    /// image at the start of the crossfade and generation visibly runs
    /// twice (once in each slot).
    var peekedNextImage: UIImage? {
        if serverDriven {
            // Server-paced: the prefetch buffer isn't drained in id order
            // (display goes through the `pendingPost` path, not the fast
            // path), so `.first` is a stale duplicate of an early image, not
            // the real look-ahead. Resolve the prefetched image whose post id
            // matches the orchestrator's announced `next` — this is the same
            // instance `fetchAndDisplayPost` will reuse when it commits, so
            // the hidden 3D slot's pre-generated depth map survives the
            // crossfade without a wasteful regen.
            guard let nextId = serverNextPost?._id else { return nil }
            return prefetchedImages.first(where: { $0.post._id == nextId })?.image
        }
        return prefetchedImages.first?.image
    }

    /// Diorama mode — when enabled, the engine generates an uncropped
    /// foreground (background-removed) for each loaded image so the view
    /// layer can pop the subject forward in z. Disabled by default; expensive
    /// per-image processing.
    var enableDiorama: Bool = false {
        didSet { if !enableDiorama { clearDioramaForegrounds() } }
    }

    /// When true, the crossfade between images is replaced with an instant
    /// switch (driven by AppModel's effectiveReduceMotion).
    var reduceMotion: Bool = false

    /// Deadline for a one-shot instant (cut, not crossfade) transition, armed
    /// when the viewer becomes present again. While we were away the server
    /// dark-advanced to a fresh post and parked it; committing that post is not
    /// a slideshow advance the user watched happen, and protocol.md describes
    /// the return as "no stale hold and no old→new crossfade" — dissolving the
    /// stale image into the fresh one advertises exactly the staleness the dark
    /// advance exists to hide. Bounded rather than a bare one-shot: if the
    /// server had nothing newer for us, the arm must expire instead of stealing
    /// the crossfade from a later, legitimate advance.
    private var instantTransitionDeadline: Date?

    /// How long after becoming present a commit still counts as "the post we
    /// returned to". Covers download + decode (+ 3D generation) of the parked
    /// post; past it we're in steady state and crossfade normally.
    private static let postReturnCutWindow: TimeInterval = 10

    /// Arm the post-return cut. Called when this session flips back to present.
    func armInstantTransition() {
        instantTransitionDeadline = Date().addingTimeInterval(Self.postReturnCutWindow)
    }

    /// Take the arm if it's still valid. Consumed either way so a stale arm
    /// can't leak into a later transition.
    private func consumeInstantTransition() -> Bool {
        guard let deadline = instantTransitionDeadline else { return false }
        instantTransitionDeadline = nil
        return Date() < deadline
    }

    /// Uncropped foreground for the currently displayed post, when diorama
    /// is enabled. GPU-private MTLTexture so the pixels live in GPU
    /// memory and don't count toward jetsam-tracked dirty CPU pages;
    /// rgba16Float when the source is deep color so the diorama matches
    /// the base image's color fidelity. Nil while still being generated
    /// or when diorama is off.
    var currentForegroundTexture: MTLTexture?

    /// Subject-blurred backdrop for the currently displayed post — replaces
    /// the original as the base layer when diorama is on so the floating
    /// foreground doesn't expose a doubled silhouette.
    var currentBackdropTexture: MTLTexture?

    /// Uncropped foreground for the prefetched next post.
    var nextForegroundTexture: MTLTexture?

    /// Subject-blurred backdrop for the prefetched next post.
    var nextBackdropTexture: MTLTexture?

    /// Tracks foreground generation tasks keyed by post id so we can cancel
    /// in-flight work when navigating away or disabling diorama.
    private var dioramaTasks: [Int: Task<Void, Never>] = [:]

    /// Cache of completed diorama pairs keyed by post id. Generation may
    /// finish before the post is promoted into the current/next slot
    /// (especially during prefetch), so results land here first and the
    /// transition pulls from this cache when wiring up the slots. Cleared
    /// alongside the slots in `clearDioramaForegrounds`.
    private var dioramaCache: [Int: (foreground: MTLTexture?, backdrop: MTLTexture?)] = [:]

    // MARK: - Content Provider & Tag List Manager

    var contentProvider: SlideshowContentProvider?
    private var sharedLocalEngine: RAVESlideshowEngine?
    private var usesSharedLocalEngine = false
    var tagListManager: TagListManager?
    let engineId = UUID()

    // MARK: - Private

    var gifConversionTask: Task<Void, Never>?
    private var runLoopTask: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    /// The state the engine was in before being backgrounded, for proper restoration.
    private var stateBeforeBackground: SlideshowState?
    private var lastAdvanceTime: Date?

    /// Wall-clock deadline at which the current image should advance.
    /// Persists across background/foreground cycles so the timer keeps ticking
    /// while backgrounded. Reset only when a new image is displayed.
    private var displayDeadline: Date?

    /// When the engine entered an effectively-paused state (either `.paused`
    /// directly, or `.backgrounded` with a paused prior state). Used to extend
    /// `displayDeadline` by the pause duration on resume so pausing truly
    /// freezes the timer.
    private var pauseStartedAt: Date?

    // MARK: - Watchdog
    /// Periodic health check that forces progress when the engine appears
    /// stuck while the user is actively viewing the window.
    private var watchdogTask: Task<Void, Never>?
    private var watchdogLastVersion: Int = 0
    private var watchdogLastChangeAt: Date = Date()
    private static let watchdogInterval: TimeInterval = 5
    /// How long past `displayDeadline` the engine can sit in `.displaying`
    /// before the watchdog kicks it to `.loading`.
    private static let watchdogAdvanceGrace: TimeInterval = 5
    /// How long the engine can sit in `.loading` or `.transitioning` with no
    /// state change before the watchdog restarts the run loop.
    private static let watchdogStuckThreshold: TimeInterval = 60
    var windowAspectRatio: Double = 16.0 / 9.0

    var prefetchedImages: [(post: RemotePost, image: UIImage, url: URL, data: Data)] = []
    private static let prefetchTarget = 3
    /// Tracks whether the prefetch task is actively running. A completed
    /// `Task` reports `isCancelled == false`, so we can't tell from the
    /// task handle alone whether prefetch finished normally or is still
    /// in flight. Set true at task start, false on exit.
    private var prefetchInProgress: Bool = false

    /// When set, the next run loop iteration will display this specific post
    /// instead of advancing normally. Used by previousImage/jumpToHistoryPost.
    private var pendingPost: RemotePost?

    /// True while a prev/jump navigation is in flight — subclasses can use
    /// this to avoid interrupting an intentional navigation.
    var hasPendingNavigation: Bool { pendingPost != nil }

    // MARK: - Init

    init(delay: TimeInterval = 15, enableKenBurns: Bool = true, useAspectRatio: Bool = true, enableDynamicBrightness: Bool = true, enableDiorama: Bool = false) {
        self.delay = delay
        self.enableKenBurns = enableKenBurns
        self.useAspectRatio = useAspectRatio
        self.enableDynamicBrightness = enableDynamicBrightness
        self.enableDiorama = enableDiorama
    }

    // MARK: - Diorama Foreground Processing

    /// Kick off diorama foreground+backdrop generation for `post`. Stores the
    /// pair in current/next slots once ready, depending on `isCurrent` and
    /// whether the post is still the displayed/prefetched one.
    func generateDioramaForeground(post: RemotePost, image: UIImage, isCurrent: Bool) {
        guard enableDiorama else { return }
        if dioramaTasks[post.id] != nil { return }

        let postId = post.id
        let task = Task { @MainActor [weak self] in
            defer { Task { @MainActor [weak self] in self?.dioramaTasks.removeValue(forKey: postId) } }
            do {
                let pair = try await BackgroundRemover.shared.generateDioramaPair(from: image)
                guard !Task.isCancelled, let self else { return }
                // Upload to GPU-private textures so the diorama layers
                // ride the same memory path as the base image (escape
                // jetsam-tracked dirty pages, get OS purging). Deep-color
                // sources stay rgba16Float end-to-end.
                let foregroundTexture: MTLTexture? = await Self.uploadDioramaTexture(pair.foreground)
                let backdropTexture: MTLTexture? = await Self.uploadDioramaTexture(pair.backdrop)
                guard !Task.isCancelled else { return }
                // Cache by id first — the post may not be in any slot yet
                // (typical during prefetch), and discarding the result here
                // is what caused the foreground to pop in after the
                // crossfade completed.
                self.dioramaCache[postId] = (foreground: foregroundTexture, backdrop: backdropTexture)
                if isCurrent, self.currentPost?.id == postId {
                    self.currentForegroundTexture = foregroundTexture
                    self.currentBackdropTexture = backdropTexture
                } else if self.nextPost?.id == postId {
                    self.nextForegroundTexture = foregroundTexture
                    self.nextBackdropTexture = backdropTexture
                }
            } catch {
                // Generation can fail on unsupported formats; silently skip.
            }
        }
        dioramaTasks[postId] = task
    }

    /// Ensure the diorama pair for `post` is generated and stored in the
    /// `next` slot, then await its completion. Called right before the
    /// crossfade so foreground/backdrop layers materialize in lock-step with
    /// the base image instead of popping in afterwards. Strict timing is
    /// sacrificed here: the crossfade may start late if generation is slow.
    func awaitNextDioramaReady(post: RemotePost, image: UIImage) async {
        guard enableDiorama else { return }
        if let cached = dioramaCache[post.id] {
            nextForegroundTexture = cached.foreground
            nextBackdropTexture = cached.backdrop
            return
        }
        // Reuse in-flight prefetch task if present; otherwise kick one off.
        if dioramaTasks[post.id] == nil {
            generateDioramaForeground(post: post, image: image, isCurrent: false)
        }
        if let task = dioramaTasks[post.id] {
            _ = await task.value
        }
        if let cached = dioramaCache[post.id] {
            nextForegroundTexture = cached.foreground
            nextBackdropTexture = cached.backdrop
        }
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

    // MARK: - State Transitions

    /// Central state transition — all lifecycle changes go through here.
    /// Logs transitions and wakes the run loop.
    func transition(to newState: SlideshowState) {
        let oldState = state
        guard oldState != newState else { return }

        // Validate transitions
        switch (oldState, newState) {
        case (.stopped, _) where newState != .stopped:
            AppLogger.remoteViewer.warning("Ignoring transition from stopped to \(newState.description, privacy: .public)")
            return
        default:
            break
        }

        // Track "effective pause" duration so the display deadline can be
        // extended on resume. `.paused` is always paused; `.backgrounded`
        // inherits paused state from `stateBeforeBackground`.
        let wasEffectivelyPaused: Bool
        switch oldState {
        case .paused: wasEffectivelyPaused = true
        case .backgrounded: wasEffectivelyPaused = (stateBeforeBackground == .paused)
        default: wasEffectivelyPaused = false
        }
        let willBeEffectivelyPaused: Bool
        switch newState {
        case .paused: willBeEffectivelyPaused = true
        case .backgrounded: willBeEffectivelyPaused = (oldState == .paused)
        default: willBeEffectivelyPaused = false
        }
        if !wasEffectivelyPaused && willBeEffectivelyPaused {
            pauseStartedAt = Date()
        } else if wasEffectivelyPaused && !willBeEffectivelyPaused {
            if let start = pauseStartedAt, let deadline = displayDeadline {
                displayDeadline = deadline.addingTimeInterval(Date().timeIntervalSince(start))
            }
            pauseStartedAt = nil
        }

        state = newState
        stateVersion += 1

        AppLogger.remoteViewer.debug("State: \(oldState.description, privacy: .public) → \(newState.description, privacy: .public)")
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else {
            AppLogger.remoteViewer.warning("start() called in state \(self.state.description, privacy: .public), ignoring")
            return
        }

        if usesSharedLocalEngine, let sharedLocalEngine {
            transition(to: .loading)
            sharedLocalEngine.start()
            return
        }

        if let tagListManager {
            tagListManager.addChangeHandler(id: engineId) { [weak self] in
                self?.handleTagListChanged()
            }
        }

        transition(to: .loading)
        startRunLoop()
    }

    func stop() {
        transition(to: .stopped)
        if let sharedLocalEngine {
            RAVESlideshowLocalSyncCoordinator.shared.unregister(sharedLocalEngine)
            sharedLocalEngine.stop()
            self.sharedLocalEngine = nil
        }
        runLoopTask?.cancel()
        runLoopTask = nil
        cancelPrefetch()
        gifConversionTask?.cancel()
        gifConversionTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        pseudo3DResolveTask?.cancel()
        pseudo3DResolveTask = nil
        tagListManager?.removeChangeHandler(id: engineId)
    }

    func useRAVESlideshowForLocalContent(
        mode3D: RAVESlideshow3DMode = .off,
        maxImageResolution2D: Int = 0,
        maxImageResolution3D: Int = 0
    ) {
        guard !serverDriven, let provider = contentProvider as? any RAVESlideshowContentProvider else {
            return
        }
        let settings = RAVESlideshowDisplaySettings(
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
        let configuration = RAVESlideshowConfiguration(
            prefetchLimit: 3,
            retryLimit: 2,
            automaticAdvancement: true,
            platformCapabilities: .current
        )
        let engine = RAVESlideshowEngine(
            provider: provider,
            displaySettings: settings,
            configuration: configuration
        )
        engine.onTransition = { [weak self] displayed in
            self?.adoptSharedLocalMedia(displayed)
            RAVESlideshowLocalSyncCoordinator.shared.broadcast(from: engine)
        }
        engine.onSettingsChanged = { [weak self] display, _ in
            guard let self else { return }
            self.delay = display.delay
            self.enableKenBurns = display.enableKenBurns
            self.useAspectRatio = display.useAspectRatio
            self.enableDynamicBrightness = display.enableDynamicBrightness
            self.enableDiorama = display.enableDiorama
        }
        sharedLocalEngine = engine
        usesSharedLocalEngine = true
        RAVESlideshowLocalSyncCoordinator.shared.register(engine)
    }

    private func adoptSharedLocalMedia(_ displayed: RAVESlideshowDisplayedMedia) {
        let id = Int(displayed.item.id) ?? abs(displayed.item.id.hashValue)
        let post = RemotePost(
            _id: id,
            file_ext: displayed.item.fileExtension,
            tags: Array(displayed.item.tags),
            rating: nil,
            image_width: nil,
            image_height: nil,
            fav_count: nil,
            md5: nil,
            parent_id: nil,
            score: nil,
            ratio: nil,
            path: displayed.media.displayURL?.absoluteString,
            duration: displayed.item.duration
        )
        nextImage = nil
        nextPost = nil
        currentPost = post
        currentVideoHLSURL = nil
        currentAnimatedData = nil
        videoNativeImgFailed = false
        switch displayed.media {
        case let .still(data, _):
            currentImage = UIImage(data: data)
            currentTexture = currentImage.flatMap {
                MetalImageRenderer.shared?.createTexture(from: $0, autoCropTransparentEdges: false)
            }
            currentMediaType = .image
        case let .animatedImage(data, url):
            currentImage = data.flatMap(UIImage.init(data:))
            currentTexture = currentImage.flatMap {
                MetalImageRenderer.shared?.createTexture(from: $0, autoCropTransparentEdges: false)
            }
            currentAnimatedData = data
            currentMediaType = url.pathExtension.lowercased() == "gif"
                ? .animatedGIF(url)
                : .animatedWebP(url)
        case let .video(url, hlsURL):
            currentImage = nil
            currentTexture = nil
            currentMediaType = .video(url)
            currentVideoHLSURL = hlsURL
        }
        isCurrentPostAnimatedGIF = currentMediaType == .animatedGIF(displayed.media.displayURL ?? URL(fileURLWithPath: "/"))
        isLoading = false
        isTransitioning = false
        transition(to: .displaying)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogLastVersion = stateVersion
        watchdogLastChangeAt = Date()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                guard !Task.isCancelled else { return }
                self?.checkWatchdog()
            }
        }
    }

    /// Health check fired every few seconds. Two distinct failure modes:
    ///
    /// 1. **Stuck in `.displaying` past deadline** — normal path should have
    ///    exited the displaying loop and transitioned to `.loading`. Force it.
    /// 2. **Stuck in `.loading`/`.transitioning` with no state progress** —
    ///    the run loop is likely blocked in an await on a network call that
    ///    never returned. Cancel and restart the run loop so the slideshow
    ///    resumes instead of freezing indefinitely on the last image.
    ///
    /// Only acts while `isRoomActive` so legitimate paused/backgrounded
    /// sleeps don't trigger intervention.
    private func checkWatchdog() {
        if stateVersion != watchdogLastVersion {
            watchdogLastVersion = stateVersion
            watchdogLastChangeAt = Date()
        }

        guard isRoomActive else { return }

        // Case 1: overdue in .displaying — force the advance the run loop
        // missed. Skipped when server-driven: there is no local deadline to be
        // "overdue" against; advances come only from the orchestrator.
        if !serverDriven, state == .displaying, let deadline = displayDeadline {
            let overdue = Date().timeIntervalSince(deadline)
            if overdue > Self.watchdogAdvanceGrace {
                AppLogger.remoteViewer.warning("Watchdog: stuck in .displaying \(Int(overdue), privacy: .public)s past deadline — forcing advance")
                transition(to: .loading)
                return
            }
        }

        // Case 2: no state change for too long while in a "should be active" state
        let stuckFor = Date().timeIntervalSince(watchdogLastChangeAt)
        if (state == .loading || state == .transitioning), stuckFor > Self.watchdogStuckThreshold {
            AppLogger.remoteViewer.warning("Watchdog: stuck in \(self.state.description, privacy: .public) for \(Int(stuckFor), privacy: .public)s — restarting run loop")
            isFetching = false
            // Clear any pending manual nav target — if we're stuck on it,
            // trying the same post again would likely hang again. The fresh
            // run loop falls through to the auto-advance path (prefetch or
            // placeholder).
            pendingPost = nil
            cancelPrefetch()
            runLoopTask?.cancel()
            runLoopTask = nil
            // Route through .loading so the fresh run loop re-enters cleanly.
            if state != .loading {
                transition(to: .loading)
            }
            watchdogLastChangeAt = Date()
            watchdogLastVersion = stateVersion
            startRunLoop()
        }
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        // On visionOS scenePhase flips to .inactive constantly — gaze shifts,
        // Control Center, notifications, or simply not being the user's current
        // focus. A wall-snapped ambient slideshow is *meant* to sit unfocused,
        // so it lives in .inactive almost permanently; treating that as hidden
        // would skip imageReady and report visibility=false, parking the channel
        // for a single-window deployment (the window's own report leaves the
        // server with zero visible sessions). Only .background means the window
        // is truly gone — app suspended, headset off, or window closed.
        // "Nobody in the room" is handled separately via HA displayState frames.
        let wasVisible = oldPhase != .background
        let isVisible = newPhase != .background
        guard wasVisible != isVisible else { return }

        if isVisible {
            sharedLocalEngine?.setVisible(true)
            // Returning to visible. isRoomActive flips before the hook runs
            // so overrides observe the new activity state — the model's
            // barrier-rejoin imageReady gates on it and would be silently
            // dropped under the old value.
            isRoomActive = true

            if state == .backgrounded {
                // Restore to the state we were in before backgrounding.
                // Content is always preserved — the slideshow manages its own
                // memory by cycling images as it advances, so there is no
                // background unload timer.
                let restoreState = stateBeforeBackground ?? .displaying
                stateBeforeBackground = nil

                if restoreState == .paused {
                    // Preserve paused state across background cycle
                    transition(to: .paused)
                } else if currentImage != nil || currentMediaType != .image {
                    // Resume the slideshow timer
                    transition(to: .displaying)
                } else {
                    sharedLocalEngine?.setVisible(false)
                    // Content was never loaded (backgrounded before first fetch) — fetch fresh
                    transition(to: .loading)
                }
            }

            // The hook runs *after* the restore, not before it. Overrides use it
            // to rejoin the server (reconcile onto the post the server
            // dark-advanced to, re-report readiness), and every one of those
            // paths is gated on being out of `.backgrounded` —
            // `reconcileWithServer` requires `.displaying`/`.idle`. Calling the
            // hook first made the whole rejoin a silent no-op, and in remote
            // mode there is no local clock to recover with (`runDisplayingPhase`
            // just awaits a state change and the watchdog refuses to advance a
            // server-driven engine), so the window sat on the stale post
            // forever.
            onBecameActive()
        } else {
            // Truly backgrounded. Same ordering as above: the hook observes
            // the new state.
            isRoomActive = false
            onEnteredBackground()

            // Remember current state so we can restore it properly
            if state != .stopped && state != .idle && state != .backgrounded {
                stateBeforeBackground = state
                transition(to: .backgrounded)
                // Release the look-ahead working set now rather than waiting for
                // a system memory warning — a backgrounded window no longer cycles.
                trimForBackground()
            }
        }
    }

    func onBecameActive() {}
    func onEnteredBackground() {}

    func updateWindowAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        windowAspectRatio = size.width / size.height
    }

    // MARK: - Navigation

    func goToNextImage() {
        pendingPost = nil
        transition(to: .loading)
    }

    // MARK: - Server-driven advance (remote mode)

    /// Record the orchestrator's current post and advance toward it. Called
    /// from every `playback` frame. The advance is deferred (not lost) when
    /// the engine is mid-load / transitioning / paused: `reconcileWithServer`
    /// re-runs from `onPostTransitioned` and `onBecameActive`, so the engine
    /// always converges on the server's current without racing ahead of it.
    func setServerCurrent(_ post: RemotePost?) {
        serverCurrentPost = post
        reconcileWithServer()
    }

    /// Advance to the server's current post if we're in a state where a jump
    /// is safe and we're not already on it. No-op when not server-driven.
    func reconcileWithServer() {
        guard serverDriven, let target = serverCurrentPost else { return }
        guard state == .displaying || state == .idle else { return }
        guard target._id != currentPost?._id else { return }
        pendingPost = target
        transition(to: .loading)
    }

    func previousImage() {
        guard postHistory.count >= 2 else { return }
        if let current = currentPost {
            cachedPosts.insert(current, at: 0)
        }
        postHistory.removeLast()
        let previous = postHistory.last!
        pendingPost = previous
        transition(to: .loading)
    }

    func jumpToHistoryPost(_ post: RemotePost) {
        pendingPost = post
        transition(to: .loading)
    }

    func togglePause() {
        switch state {
        case .displaying, .loading, .transitioning:
            transition(to: .paused)
        case .paused:
            if currentImage != nil || currentMediaType != .image {
                transition(to: .displaying)
            } else {
                transition(to: .loading)
            }
        default:
            break
        }
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

    // MARK: - Tag List Change

    func handleTagListChanged() {
        fetchReturnedEmpty = false
        cachedPosts.removeAll()
        prefetchedImages.removeAll()
        // Cache was just invalidated; allow the cold-start wait so the current
        // image stays on screen while the new list's first image loads,
        // instead of immediately flashing the placeholder.
        hasDisplayedFirstMedia = false
        cancelPrefetch()
        contentProvider?.resetPagination()
        if let tlm = tagListManager {
            let firstTag = tlm.tagLists[safe: tlm.activeIndex]?.first ?? ""
            showToast("List \(tlm.activeIndex + 1)/\(tlm.tagLists.count): \(firstTag)")
        }
        pendingPost = nil
        transition(to: .loading)
    }

    // MARK: - Run Loop

    /// The single run loop task that drives the slideshow. Reacts to state
    /// changes rather than being cancelled and recreated.
    func startRunLoop() {
        guard runLoopTask == nil else { return }
        startWatchdog()
        runLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && state != .stopped {
                switch state {
                case .loading:
                    await runLoadingPhase()

                case .displaying:
                    await runDisplayingPhase()

                case .paused, .backgrounded:
                    // Sleep until state changes
                    await waitForStateChange()

                case .transitioning:
                    // Shouldn't reach here — transitioning is handled inside display methods
                    // but just in case, wait briefly
                    try? await Task.sleep(for: .milliseconds(100))

                case .idle, .stopped:
                    break
                }
            }

            AppLogger.remoteViewer.debug("Run loop exited (state: \(self.state.description, privacy: .public))")
        }
    }

    /// Wait until stateVersion changes (i.e. a transition happened).
    private func waitForStateChange() async {
        let versionAtEntry = stateVersion
        while stateVersion == versionAtEntry && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Loading phase: hand off to the next image. Auto-advances MUST NOT block
    /// on network — if no prefetched image is ready, show a placeholder and let
    /// the timer keep cycling. Manual navigation (pendingPost) is allowed to
    /// await the download since it's user-initiated.
    private func runLoadingPhase() async {
        isLoading = true
        defer { isLoading = false }

        // Manual navigation: specific post requested (prev/jump).
        // Awaits download; on failure, keep the current image and toast —
        // the user explicitly initiated nav, so silently dropping is bad,
        // but clobbering their current view with a warning icon is worse.
        if let post = pendingPost {
            pendingPost = nil
            let displayed = await fetchAndDisplayPost(post)
            if !displayed {
                showToast("Image failed to load", isError: true)
                advanceDisplayDeadline()
            }
            if state == .loading {
                transition(to: .displaying)
            }
            triggerPrefetch()
            return
        }

        // Video fast path: the prefetch loop deliberately stops at video
        // posts (videos play live, they aren't decoded into prefetched
        // images), so a queue of videos never fills `prefetchedImages` and
        // would otherwise fall through to the steady-state-miss stall. Drive
        // video display directly from the post queue here so videos advance
        // on the same timer loop as images.
        if prefetchedImages.isEmpty {
            if cachedPosts.isEmpty && !isFetching {
                await fetchMorePosts()
            }
            if let candidate = nextNonBlockedPost() {
                if Self.videoExtensions.contains(candidate.file_ext.lowercased()) {
                    guard state == .loading else { return }
                    await fetchAndDisplayPost(candidate)
                    if state == .loading {
                        transition(to: .displaying)
                    }
                    triggerPrefetch()
                    return
                } else {
                    // Not a video — return it for the image prefetch path.
                    cachedPosts.insert(candidate, at: 0)
                }
            }
        }

        // Fast path: use a prefetched image (in-memory, no network await).
        if let prefetched = prefetchedImages.first {
            prefetchedImages.removeFirst()
            guard state == .loading else { return }
            await displayDownloadedPost(
                post: prefetched.post,
                image: prefetched.image,
                data: prefetched.data,
                url: prefetched.url,
                ext: prefetched.post.file_ext.lowercased()
            )
            if state == .loading {
                transition(to: .displaying)
            }
            triggerPrefetch()
            return
        }

        // Cold start: no prefetch yet because nothing has been fetched.
        // Kick prefetch and wait — no timeout. `isLoading` stays true so the
        // view shows the progress spinner. Queueing rather than failing-fast
        // avoids the previous A → B → A → "No images available" → C
        // sequence when a transient miss tripped the cold-start path.
        if !hasDisplayedFirstMedia {
            triggerPrefetch()
            while prefetchedImages.isEmpty && state == .loading {
                try? await Task.sleep(for: .milliseconds(250))
                // Re-arm in case the prior trigger no-op'd against an
                // already-finished/cancelled task — idempotent via the
                // prefetchInProgress guard, so this just self-heals a missed kick.
                triggerPrefetch()
            }
            if let prefetched = prefetchedImages.first {
                prefetchedImages.removeFirst()
                guard state == .loading else { return }
                await displayDownloadedPost(
                    post: prefetched.post,
                    image: prefetched.image,
                    data: prefetched.data,
                    url: prefetched.url,
                    ext: prefetched.post.file_ext.lowercased()
                )
                if state == .loading {
                    transition(to: .displaying)
                }
                triggerPrefetch()
            }
            return
        }

        // Steady-state miss: keep the current image on screen, re-arm a
        // short retry deadline, and let prefetch try to fill. The slideshow
        // visibly stalls for a few seconds rather than flashing the warning
        // icon — much less disruptive when the cause is a transient network
        // hiccup or a momentarily slow server.
        triggerPrefetch()
        displayDeadline = Date().addingTimeInterval(Self.steadyStateRetryInterval)
        if state == .loading {
            transition(to: .displaying)
        }
    }

    /// Displaying phase: wait for the stored deadline, then advance.
    /// The deadline is a wall-clock target that keeps ticking across
    /// background/foreground cycles, so returning to active does not reset
    /// the timer. If the deadline has already passed (e.g. returning after
    /// a long background) the loop exits immediately and advances once.
    private func runDisplayingPhase() async {
        let versionAtEntry = stateVersion

        // Server-paced: hold the current image until the orchestrator pushes a
        // new `current` (which drives the transition via reconcileWithServer).
        // No local dwell timer means the engine can't diverge from the server,
        // so it never reports `imageReady` for a frame the server hasn't
        // committed.
        if serverDriven {
            await waitForStateChange()
            return
        }

        // Defensive: if no deadline was set (shouldn't normally happen since
        // displayImage/displayVideo set it), establish one now.
        if displayDeadline == nil {
            displayDeadline = Date().addingTimeInterval(effectiveDelay)
        }

        while state == .displaying && stateVersion == versionAtEntry {
            guard let deadline = displayDeadline else { break }
            let remaining = deadline.timeIntervalSince(Date())
            if remaining <= 0 { break }
            let chunk = min(remaining, 0.5)
            try? await Task.sleep(for: .seconds(chunk))
        }

        // Only advance if we're still in displaying state and nothing interrupted us
        if state == .displaying && stateVersion == versionAtEntry {
            transition(to: .loading)
        }
    }

    /// Effective delay — uses video duration if available and longer than config delay
    var effectiveDelay: TimeInterval {
        if case .video = currentMediaType,
           let duration = currentPost?.duration, duration > delay {
            return duration
        }
        return delay
    }

    /// Set `displayDeadline` for the image/video that was just committed.
    ///
    /// If the previous image's deadline had already passed (natural advance
    /// or return from background), we extend the schedule by one interval
    /// so the new image's deadline is `previous + delay` — that's what gives
    /// the "5s later" behavior when the user returns mid-interval. If that
    /// continued deadline is also in the past (return after many intervals),
    /// we fall back to a fresh `now + delay` so we never cycle more than once.
    ///
    /// If the previous deadline is still in the future (manual prev/next, or
    /// the first image at startup), the new image gets a fresh `now + delay`.
    private func advanceDisplayDeadline() {
        let now = Date()
        let delay = effectiveDelay
        if let previous = displayDeadline, now >= previous {
            let continued = previous.addingTimeInterval(delay)
            displayDeadline = continued > now ? continued : now.addingTimeInterval(delay)
        } else {
            displayDeadline = now.addingTimeInterval(delay)
        }
        // Starting a fresh image invalidates any pending pause-start marker.
        pauseStartedAt = nil
    }

    // MARK: - Content Loading

    func nextNonBlockedPost() -> RemotePost? {
        while !cachedPosts.isEmpty {
            let candidate = cachedPosts.removeFirst()
            if !blockedPosts.contains(candidate._id) &&
               !candidate.tags.contains(where: { blockedTags.contains($0) }) {
                return candidate
            }
        }
        return nil
    }

    /// Download and display the given post. Returns true on success, false on
    /// failure (caller can show a placeholder). State-change bailouts return
    /// true since the work was implicitly superseded, not failed.
    @discardableResult
    func fetchAndDisplayPost(_ post: RemotePost) async -> Bool {
        guard let imageURL = contentProvider?.resolveImageURL(for: post) else { return false }

        let ext = post.file_ext.lowercased()
        let asImage = contentProvider?.rendersVideoAsAnimatedImage == true

        if Self.videoExtensions.contains(ext) {
            guard state == .loading else { return true }
            await displayVideo(url: imageURL, post: post, asImage: asImage,
                               hlsURL: contentProvider?.hlsURL(for: post))
            return true
        }

        // Reuse an already-prefetched copy when one exists. This is the
        // common case in server-driven mode, where every display arrives via
        // this path rather than the prefetch fast-path. Reusing the buffered
        // entry (a) hands the crossfade the *same* `UIImage` instance the 3D
        // layer pre-generated its depth map against — so the hidden slot just
        // promotes instead of regenerating — and (b) drains the buffer so
        // `prefetchedImages` doesn't grow stale (which is what corrupted
        // `peekedNextImage`). Prefetched entries are only ever images, so
        // videos never match and fall through to the download path.
        if let idx = prefetchedImages.firstIndex(where: { $0.post._id == post._id }) {
            let entry = prefetchedImages.remove(at: idx)
            guard state == .loading else { return true }
            await displayDownloadedPost(post: entry.post, image: entry.image, data: entry.data, url: entry.url, ext: entry.post.file_ext.lowercased())
            return true
        }

        guard let media = await contentProvider?.downloadImage(for: post, maxResolution: effectiveDownloadResolution) else { return false }
        guard state == .loading else { return true }

        switch media {
        case .still(let image, let data):
            await displayDownloadedPost(post: post, image: image, data: data, url: imageURL, ext: ext)
        case .video(let videoURL):
            // A post the server delivered as video (e.g. legacy H.264) — render
            // it via the same tiered path as a video post.
            await displayVideo(url: videoURL, post: post, asImage: true,
                               hlsURL: contentProvider?.hlsURL(for: post))
        }
        return true
    }

    /// Animation-aware display dispatch. Shared by `fetchAndDisplayPost`
    /// (manual nav) and the prefetched fast-path so byte-level animation
    /// detection (`isAnimatedGIF` / `isAnimatedWebP`) runs for every post,
    /// not just the manual-nav case. Without this, prefetched animated
    /// WebP / GIF would always be displayed as static via `.image`.
    func displayDownloadedPost(post: RemotePost, image: UIImage, data: Data, url: URL, ext: String) async {
        // Animated GIF
        if ext == "gif" && data.isAnimatedGIF {
            isCurrentPostAnimatedGIF = true
            currentAnimatedData = nil
            await displayImage(image, post: post, url: url, mediaType: .image)
            let bytes = data
            gifConversionTask?.cancel()
            gifConversionTask = Task { [weak self] in
                do {
                    let hevcURL = try await AnimatedHEVCConverter.shared.convert(animatedData: bytes, sourceURL: url)
                    guard !Task.isCancelled else { return }
                    if self?.currentPost?._id == post._id {
                        self?.currentMediaType = .animatedGIF(hevcURL)
                    }
                } catch {
                    AppLogger.remoteViewer.warning("GIF HEVC conversion failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                }
            }
            return
        }

        // Animated WebP — WKWebView animates these natively, no conversion
        // needed. Mark as animated so Ken Burns / 3D gates are bypassed.
        let isAnimatedWebP = data.isAnimatedWebP
        AppLogger.remoteViewer.debug("Post \(post._id, privacy: .private(mask: .hash)) ext=\(ext, privacy: .public) isAnimatedWebP=\(isAnimatedWebP, privacy: .public) bytes=\(data.count, privacy: .public)")
        if isAnimatedWebP {
            isCurrentPostAnimatedGIF = true
            // Stash the bytes so the view can hand them to WKWebView
            // inline; cleared in the non-animated branches below.
            currentAnimatedData = data
            await displayImage(image, post: post, url: url, mediaType: .animatedWebP(url))
            return
        }

        // Animated JPEG XL — WebKit can't decode JXL, so the bytes go to a
        // WASM libjxl decoder that muxes an APNG for the <img>. Detected from
        // the codestream header (ImageIO reports frame count 1 for animated
        // JXL, so it can't gate this). `image` is the ImageIO first-frame decode
        // and serves as the static fallback while the WASM decode runs.
        if ext == "jxl" && data.isAnimatedJXL {
            isCurrentPostAnimatedGIF = true
            currentAnimatedData = data
            await displayImage(image, post: post, url: url, mediaType: .animatedJXL(url))
            return
        }

        isCurrentPostAnimatedGIF = false
        currentAnimatedData = nil
        await displayImage(image, post: post, url: url)
    }

    // MARK: - Memory Pressure

    /// Drop the prefetch look-ahead and diorama working sets in response
    /// to a system memory warning. The currently-displayed image and the
    /// single next-up prefetched slot are kept intact so the natural
    /// cycle continues; everything beyond that is released and will be
    /// re-fetched on demand. The photo viewer's full LRU idle-downscale
    /// is intentionally skipped — GPU-private MTLTextures are OS-managed
    /// for purging, and aggressive eviction here would fight the prefetch
    /// loop and visibly stall the slideshow.
    @MainActor
    func trimForMemoryPressure() {
        let droppedPrefetch = max(0, prefetchedImages.count - 1)
        let droppedDiorama = dioramaCache.count
        if droppedPrefetch > 0 {
            prefetchedImages = Array(prefetchedImages.prefix(1))
        }
        // The visible diorama (currentForeground/Backdrop) stays; only
        // the next slot and the generation cache are released.
        nextForegroundTexture = nil
        nextBackdropTexture = nil
        dioramaCache.removeAll(keepingCapacity: false)
        if droppedPrefetch + droppedDiorama > 0 {
            AppLogger.remoteViewer.info("Slideshow trim for memory pressure: dropped \(droppedPrefetch, privacy: .public) prefetched, \(droppedDiorama, privacy: .public) diorama entries")
        }
    }

    /// Release the look-ahead working set when the window backgrounds. A
    /// backgrounded slideshow has stopped cycling (run loop paused), so the
    /// "continuous cycling bounds memory" assumption no longer holds — the
    /// prefetch buffer and diorama working set would otherwise sit resident
    /// indefinitely until a system memory warning. On visionOS gaze shifts
    /// background windows constantly, so with several slideshow windows this
    /// look-ahead is the dominant resident cost. Unlike `trimForMemoryPressure`
    /// (which keeps one prefetch slot) this drops the entire buffer; the on-
    /// screen `current` + crossfade-ready `next` image/texture are preserved so
    /// resume is seamless, and the run loop re-prefetches on return to active.
    @MainActor
    func trimForBackground() {
        let dropped = prefetchedImages.count
        let droppedDiorama = dioramaCache.count
        prefetchedImages.removeAll(keepingCapacity: false)
        nextForegroundTexture = nil
        nextBackdropTexture = nil
        dioramaCache.removeAll(keepingCapacity: false)
        if dropped + droppedDiorama > 0 {
            AppLogger.remoteViewer.info("Slideshow trim for background: dropped \(dropped, privacy: .public) prefetched, \(droppedDiorama, privacy: .public) diorama entries")
        }
    }

    // MARK: - Display

    func displayVideo(url: URL, post: RemotePost, asImage: Bool = false, hlsURL: URL? = nil) async {
        // Resolve real-time fake-3D before the transition so the clip mounts
        // straight into the stereo player; resolving afterwards would paint a
        // flat frame and then swap renderers under the viewer. Returns without
        // suspending when slideshow 3D is off, so the 2D path pays nothing.
        let entryState = state
        pseudo3DResolveTask?.cancel()
        pseudo3DResolveTask = nil
        let resolvedPseudo3D = await resolvePseudo3DTarget(url: url, hlsURL: hlsURL, post: post)
        // The probe suspends — if the slideshow moved on meanwhile this display
        // is superseded (callers already treat a state change as implicit
        // success rather than failure). Bail before touching the target so the
        // video still on screen keeps the one it's playing with.
        guard state == entryState else { return }
        pseudo3DVideoTarget = resolvedPseudo3D

        trackPreviousPost()
        trackHistory(post: post, url: url)
        Task { await contentProvider?.onPostDisplayed(post) }

        autoBrightnessAdjustment = 0
        autoContrastAdjustment = 1.0

        gifConversionTask?.cancel()
        gifConversionTask = nil

        isCurrentPostAnimatedGIF = false
        hasDisplayedFirstMedia = true
        // Reset the native→streaming escalation for this post: start on the
        // <img>/<video> raw tier, keep the HLS URL for the fallback.
        currentVideoHLSURL = hlsURL
        videoNativeImgFailed = false

        // The RoboFrame slideshow renders video (and animated posts) through
        // the video-in-<img> path; other modes keep the AVPlayer. Same
        // crossfade slots either way — only the media type (and thus the
        // renderer the window view picks) differs.
        let target: SlideshowMediaType = asImage ? .videoAsImage(url) : .video(url)

        let outgoingWasVideo: Bool
        switch currentMediaType {
        case .video, .videoAsImage: outgoingWasVideo = true
        default: outgoingWasVideo = false
        }
        let hadCurrentMedia = currentPost != nil

        if reduceMotion || consumeInstantTransition() || !hadCurrentMedia {
            // Instant switch — reduce-motion, the post we returned to (see
            // instantTransitionDeadline), or the cold-start first video
            // (nothing on screen to crossfade from).
            clearImageDisplayState()
            isTransitioning = false
            currentPost = post
            currentMediaType = target
        } else if outgoingWasVideo {
            // video → video: fade through black so only one video layer is
            // ever alive. Phase 1 fades the current video out (the black
            // background shows through); phase 2 swaps in the new video URL
            // while hidden, then fades it back in.
            transition(to: .transitioning)
            withAnimation(.easeInOut(duration: 0.5)) {
                isTransitioning = true
            }
            try? await Task.sleep(for: .seconds(0.5))
            guard state == .transitioning else { return }
            clearImageDisplayState()
            currentPost = post
            currentMediaType = target
            withAnimation(.easeInOut(duration: 0.5)) {
                isTransitioning = false
            }
        } else {
            // image / animated → video: true crossfade. The incoming video
            // layer renders at full opacity while the outgoing image fades
            // out via its `isTransitioning` opacity binding.
            transition(to: .transitioning)
            withAnimation(.easeInOut(duration: 1.0)) {
                nextMediaType = target
                nextVideoURL = url
                nextPost = post
                isTransitioning = true
            }
            try? await Task.sleep(for: .seconds(1.0))
            guard state == .transitioning else { return }
            clearImageDisplayState()
            currentPost = post
            currentMediaType = target
            nextMediaType = .image
            nextVideoURL = nil
            nextPost = nil
            isTransitioning = false
        }

        lastAdvanceTime = Date()
        advanceDisplayDeadline()
        if state == .transitioning {
            transition(to: .displaying)
        }

        AppLogger.remoteViewer.info("Displaying video post \(post._id, privacy: .private(mask: .hash))")
        onPostTransitioned(post: post, url: url)
    }

    /// Clear all image-pipeline display state (base images, GPU textures,
    /// animated bytes, diorama layers). Shared by the video display paths,
    /// which never use these slots.
    private func clearImageDisplayState() {
        currentImage = nil
        nextImage = nil
        currentTexture = nil
        nextTexture = nil
        currentAnimatedData = nil
        currentForegroundTexture = nil
        currentBackdropTexture = nil
        nextForegroundTexture = nil
        nextBackdropTexture = nil
    }

    func displayImage(_ image: UIImage, post: RemotePost, url: URL, mediaType: SlideshowMediaType = .image) async {
        trackPreviousPost()
        trackHistory(post: post, url: url)
        Task { await contentProvider?.onPostDisplayed(post) }

        // Analyze for Ken Burns and brightness
        if let cgImage = image.cgImage {
            if enableKenBurns {
                let focus = await Task.detached {
                    SobelFocusAnalyzer.focusPoint(from: cgImage)
                }.value
                focusPoint = focus
            }

            if enableDynamicBrightness {
                let luminance = await Task.detached {
                    SobelFocusAnalyzer.averageLuminance(from: cgImage)
                }.value

                if luminance < 0.3 {
                    let boost = Double(0.3 - luminance) * 0.5
                    autoBrightnessAdjustment = boost
                    autoContrastAdjustment = 1.0 + boost * 0.5
                } else {
                    autoBrightnessAdjustment = 0
                    autoContrastAdjustment = 1.0
                }
            } else {
                autoBrightnessAdjustment = 0
                autoContrastAdjustment = 1.0
            }
        }

        // Bail if state changed during analysis
        guard state == .loading || state == .displaying else { return }

        if mediaType == .image {
            gifConversionTask?.cancel()
            gifConversionTask = nil
        }

        // Wait for diorama pair before starting the crossfade so the
        // backdrop/foreground layers fade in alongside the base image
        // instead of popping in after the transition completes.
        if enableDiorama && mediaType == .image {
            await awaitNextDioramaReady(post: post, image: image)
            // State may have changed while awaiting (e.g. navigation away).
            guard state == .loading || state == .displaying else {
                AppLogger.remoteViewer.debug("displayImage post-diorama guard bailed for post \(post._id, privacy: .private(mask: .hash)) in state \(self.state.description, privacy: .public) — onPostTransitioned will not fire")
                return
            }
        }

        // Build the GPU-private texture for the new image in parallel with
        // any other async work above. Falls back to nil — the window view
        // will keep showing the UIImage path if texture creation fails.
        let newTexture = await Self.makeTexture(from: image)
        guard state == .loading || state == .displaying else {
            AppLogger.remoteViewer.debug("displayImage post-texture guard bailed for post \(post._id, privacy: .private(mask: .hash)) in state \(self.state.description, privacy: .public) — onPostTransitioned will not fire")
            return
        }

        // Crossfade transition (skipped under reduce motion, or when this is
        // the post we returned to — see instantTransitionDeadline)
        transition(to: .transitioning)
        if reduceMotion || consumeInstantTransition() {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                nextImage = image
                nextTexture = newTexture
                nextPost = post
                isTransitioning = true
            }
        } else {
            withAnimation(.easeInOut(duration: 1.0)) {
                nextImage = image
                nextTexture = newTexture
                nextPost = post
                isTransitioning = true
            }
            try? await Task.sleep(for: .seconds(1.0))
        }

        // Commit the transition using local parameters (not nextImage/nextPost)
        // to avoid races with interleaved calls
        currentImage = image
        currentTexture = newTexture
        currentPost = post
        currentMediaType = mediaType
        nextImage = nil
        nextTexture = nil
        nextMediaType = .image
        nextVideoURL = nil
        isTransitioning = false
        hasDisplayedFirstMedia = true
        lastAdvanceTime = Date()
        advanceDisplayDeadline()

        // Promote prefetched diorama pair (if any) to current; if not ready,
        // kick off generation. The next slot is cleared on promotion.
        if enableDiorama && mediaType == .image {
            currentForegroundTexture = nextForegroundTexture
            currentBackdropTexture = nextBackdropTexture
            nextForegroundTexture = nil
            nextBackdropTexture = nil
            if currentForegroundTexture == nil {
                generateDioramaForeground(post: post, image: image, isCurrent: true)
            }
        } else {
            currentForegroundTexture = nil
            currentBackdropTexture = nil
            nextForegroundTexture = nil
            nextBackdropTexture = nil
        }

        // If still transitioning (nobody interrupted), move to displaying.
        // If state was changed (e.g. goToNextImage during crossfade), respect that.
        if state == .transitioning {
            transition(to: .displaying)
        }

        onPostTransitioned(post: post, url: url)
    }

    func onPostTransitioned(post: RemotePost, url: URL) {}

    // MARK: - History Tracking

    private func trackPreviousPost() {
        if let outgoing = currentPost {
            previousPost = outgoing
            previousPostGraceTask?.cancel()
            previousPostGraceTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                previousPost = nil
            }
        }
    }

    private func trackHistory(post: RemotePost, url: URL) {
        postHistory.append(post)
        historyImageURLs[post._id] = url
        if postHistory.count > 100 { postHistory.removeFirst() }
    }

    // MARK: - Prefetching

    /// Kick prefetch only if a task isn't currently running. Cancelling an
    /// in-flight prefetch threw away mid-download work, which is the main
    /// reason the engine ever ran out of prefetched images during a
    /// transient network blip. Trigger sites call this freely; the running
    /// task drains itself once `prefetchedImages` reaches the target. We
    /// track liveness via `prefetchInProgress` because a `Task` that has
    /// completed still reports `isCancelled == false`, so the handle alone
    /// can't tell us whether prefetch is still running or already exited.
    func triggerPrefetch() {
        if prefetchInProgress { return }
        prefetchInProgress = true
        prefetchTask = Task { [weak self] in
            await self?.prefetchImages()
            await MainActor.run { self?.prefetchInProgress = false }
        }
    }

    /// Cancel any in-flight prefetch and clear the liveness flag.
    ///
    /// `prefetchInProgress` gates `triggerPrefetch()` so callers can fire it
    /// freely without spawning duplicate tasks. The running task normally
    /// clears the flag itself when it exits — but a task cancelled mid-download
    /// can hang on a dead socket (e.g. the `code=53` connection aborts seen
    /// when visionOS unloads/reloads a snapped-to-wall window) and never reach
    /// its reset. If we cancel without clearing the flag here, every future
    /// `triggerPrefetch()` no-ops forever, the cold-start loading loop never
    /// fills, and the engine wedges in `.loading` — which not even the watchdog
    /// restart can recover. So always pair cancellation with clearing the flag.
    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchInProgress = false
    }

    private func prefetchImages() async {
        while prefetchedImages.count < Self.prefetchTarget, !Task.isCancelled {
            if cachedPosts.isEmpty && !isFetching {
                await fetchMorePosts()
            }

            guard let post = nextNonBlockedPost() else { break }

            if Self.videoExtensions.contains(post.file_ext.lowercased()) {
                cachedPosts.insert(post, at: 0)
                break
            }

            guard let imageURL = contentProvider?.resolveImageURL(for: post) else { continue }

            // Retry transient download failures a couple of times before
            // dropping the post — a single network hiccup shouldn't cost
            // us a slot in the prefetch buffer.
            var media: DownloadedMedia?
            for attempt in 0..<3 {
                if Task.isCancelled { break }
                if let r = await contentProvider?.downloadImage(for: post, maxResolution: effectiveDownloadResolution) {
                    media = r
                    break
                }
                if attempt < 2 {
                    let delay: TimeInterval = attempt == 0 ? 0.5 : 1.5
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            guard let media, !Task.isCancelled else { continue }
            // Animated posts arrive as H.264 (`.video`); they're not decoded
            // into the still buffer — the display path streams them via the
            // <img> renderer, like a video post (which never reaches here).
            guard case .still(let image, let data) = media else { continue }
            prefetchedImages.append((post: post, image: image, url: imageURL, data: data))
            AppLogger.remoteViewer.debug("Prefetched post \(post._id, privacy: .private(mask: .hash)) (\(self.prefetchedImages.count, privacy: .public)/\(Self.prefetchTarget, privacy: .public))")

            // Pre-process diorama foreground for the upcoming post so the
            // overlay is ready the moment it transitions in.
            if enableDiorama {
                generateDioramaForeground(post: post, image: image, isCurrent: false)
            }
        }

        if cachedPosts.count < 5 && !isFetching {
            await fetchMorePosts()
        }
    }

    // MARK: - Texture helpers

    /// Build a GPU-private MTLTexture for `image` off the main actor. The
    /// CGImage extraction happens on the caller (main); the Metal upload
    /// itself runs in a detached task so display setup isn't blocked.
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

    // MARK: - Fetching

    func fetchMorePosts() async {
        guard let contentProvider, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let tagQuery = tagListManager?.activeTagQuery ?? "order:random"

        var ratioRange: String?
        if useAspectRatio {
            let ratio = windowAspectRatio
            let min = ratio * 0.85
            let max = ratio * 1.15
            ratioRange = String(format: "%.2f..%.2f", min, max)
        }

        let posts = await contentProvider.fetchMoreContent(
            tagQuery: tagQuery,
            ratioRange: ratioRange,
            blockedPosts: blockedPosts,
            blockedTags: blockedTags
        )

        cachedPosts.append(contentsOf: posts)
        if !posts.isEmpty { fetchReturnedEmpty = false }
    }
}

// MARK: - Collection safe subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
