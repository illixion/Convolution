/*
 Hypnos - Video Window Model

 Per-window @Observable model for individual video player windows. Mirrors
 PhotoWindowModel: each window owns its own current video, navigation snapshot,
 3D intent, visual adjustments, playback state, A-B loop, share state, and
 auto-hide timers. This is what makes multiple video windows independent — the
 viewer no longer leans on shared AppModel.selectedVideo (which made every
 pushed window display whichever video was selected last).

 Important pattern (matching PhotoWindowModel): `init` must be side-effect-free
 because SwiftUI may re-create the view struct multiple times while `@State`
 discards duplicate models. All side effects are deferred to `start()`, called
 from onAppear.
 */

import DebugTrace
import Foundation
import AVFoundation
import RAVEMedia
import SwiftUI

@MainActor
@Observable
final class VideoWindowModel {
    enum PlaybackRenderer {
        case resolving
        case nativeMetal
        case webKit
    }

    // MARK: - Identity / Context

    /// The video currently displayed in this window (was AppModel.selectedVideo).
    var video: GalleryVideo

    /// Whether this window was opened via pushWindow (back button dismisses)
    /// vs openWindow (standalone pop-out with gallery button).
    let wasPushed: Bool

    /// The originating window value's UUID (used for RestoredWindowTracker).
    let windowValueId: UUID

    /// This window's originating value, for standalone (non-pushed) windows only.
    /// Registered with AppModel so saved window groups can capture open video
    /// windows; nil for pushed windows, which aren't independently restorable.
    let popOutWindowValue: VideoWindowValue?

    /// Shared app state (browse list, global settings, API client).
    let appModel: AppModel

    // MARK: - Navigation Snapshot

    /// Snapshot of the gallery video list when this window opened. Navigation
    /// operates over this private copy + lazily-loaded pages, never mutating
    /// AppModel state, so each window navigates independently.
    var galleryVideos: [GalleryVideo]

    /// Current index into `galleryVideos`.
    var currentIndex: Int

    /// True when `galleryVideos` is a complete list carried by the window value
    /// (Local tab) rather than the paginated app-gallery snapshot. Preserved
    /// across pop-out so navigation survives.
    let usesStaticGalleryList: Bool

    /// Video source used for lazy pagination.
    let videoSource: any VideoSource

    /// Filter snapshot from when this window opened.
    let snapshotFilter: SceneFilterCriteria

    var currentPage: Int
    var hasMorePages: Bool
    let pageSize: Int
    var isLoadingMoreVideos: Bool = false
    let prefetchThreshold: Int = 5

    // MARK: - 3D / Viewing Mode (per-window intent)

    /// nil = auto-detect, true = force 3D, false = force 2D.
    var stereoscopicOverride: Bool?
    /// Chosen stereoscopic settings for this window's video.
    var video3DSettings: Video3DSettings?
    /// Drives the per-window Video3DSettingsSheet.
    var showVideo3DSettingsSheet: Bool = false

    /// Real-time fake-3D conversion of a mono video (windowed, no precompute).
    /// Distinct from `stereoscopicOverride`, which presents a genuinely
    /// stereoscopic source (SBS / MV-HEVC). Only applies to AVFoundation-
    /// decodable videos (the `.nativeMetal` renderer).
    var pseudo3DEnabled: Bool = false
    /// Depth/convergence tuning for the fake-3D warp.
    var pseudo3DSettings: Pseudo3DSettings = .default

    // MARK: - Per-Window Visuals

    var isFlipped: Bool = false
    /// Per-window visual adjustments tier (falls back to global when unmodified).
    var currentAdjustments: VisualAdjustments = VisualAdjustments()
    var playbackRenderer: PlaybackRenderer = .resolving
    /// True once this window has swapped the original file for the server's
    /// transcode (`GalleryVideo.transcodeStreamURL`) — either because the
    /// original proved undecodable or because a feature needed AVFoundation.
    /// Reset on every video switch so each video starts on its original.
    var usingTranscodedStream: Bool = false
    /// Native video pixel aspect (width/height), reported once the first frame's
    /// size is known. Used to aspect-fit the native Metal player so it never
    /// stretches when the window can't match the video's aspect (tall videos).
    var videoAspectRatio: CGFloat?

    // MARK: - Playback State (driven by the WebVideoPlayerView JS bridge)

    var currentTime: Double = 0
    var duration: Double = 0
    var isPaused: Bool = true
    /// Seeded from AppModel.videoAutoplayMuted in init (autoplay defaults to
    /// muted unless the setting says otherwise); toggled via the control bar.
    var isMuted: Bool = true
    /// End of the last buffered range (seconds).
    var bufferedEnd: Double = 0
    /// True while the user is dragging the scrubber — suppresses incoming
    /// timeupdate writes so the thumb doesn't fight the drag.
    var isScrubbing: Bool = false

    // MARK: - Load Status

    /// True once the player has reported the video's size, i.e. there is a
    /// picture in the window. Until then the chrome stays up: a player that
    /// never produces a frame is an empty, transparent window, and with the
    /// ornament auto-hidden there was nothing left to see or tap.
    private(set) var hasPresentedVideo = false
    /// Nothing has appeared `loadStallTimeout` after the player started.
    private(set) var isLoadStalled = false
    /// Every renderer has given up on this video. Shown in place of the video.
    private(set) var playbackFailure: String?
    /// Bumped by Retry; part of the players' view identity, so a retry
    /// rebuilds the player rather than reusing the one that failed.
    private(set) var playbackAttempt = 0
    @ObservationIgnored private var loadStallTask: Task<Void, Never>?
    static let loadStallTimeout: Duration = .seconds(20)

    /// Command hooks bound by WebVideoPlayerView.updateUIView (only when this
    /// model is passed as the player's `playbackModel`). They evaluate JS on
    /// the underlying <video> element.
    @ObservationIgnored var playCommand: (@MainActor () -> Void)?
    @ObservationIgnored var pauseCommand: (@MainActor () -> Void)?
    @ObservationIgnored var seekCommand: (@MainActor (Double) -> Void)?
    @ObservationIgnored var setMutedCommand: (@MainActor (Bool) -> Void)?

    // MARK: - A-B Loop

    /// Owns the A-B loop state machine (was a VideoWindowView @State). The
    /// player view binds its queryCurrentTime/setLoopBounds closures.
    let loopController = VideoLoopController()

    // MARK: - Share

    var isPreparingShare: Bool = false
    var shareFileURL: URL?

    // MARK: - UI Visibility

    var isUIHidden: Bool = false
    var isWindowControlsHidden: Bool = false
    /// Whether this window is in the user's current room (drives auto-resume).
    var isInActiveRoom: Bool = true
    /// True when visionOS restored this pop-out (vs. a fresh user open); starts
    /// with chrome hidden instead of arming the reveal timer.
    var isRestoredPopOut: Bool = false

    @ObservationIgnored var autoHideTask: Task<Void, Never>?
    @ObservationIgnored var windowControlsHideTask: Task<Void, Never>?

    /// Open ornament menus / popovers. `>0` pauses auto-hide so chrome doesn't
    /// vanish mid-selection.
    var openOrnamentMenuCount: Int = 0
    var showMediaInfo: Bool = false
    var showAdjustments: Bool = false
    var showShareSheet: Bool = false

    /// An *overlapping* menu/dropdown/sheet is open — used to fade the fake-3D
    /// video so it doesn't occlude that chrome. Excludes `showAdjustments`: the
    /// adjustments panel is a side ornament that doesn't overlap the video, so
    /// the video should stay fully visible while editing.
    var isChromeModalOpen: Bool {
        showMediaInfo || showShareSheet || showVideo3DSettingsSheet || openOrnamentMenuCount > 0
    }

    /// Whether any chrome is open that should pin the ornament/control bar.
    var hasOpenPopover: Bool {
        showMediaInfo || showAdjustments || showShareSheet || isScrubbing || openOrnamentMenuCount > 0
    }

    @ObservationIgnored private var didStart = false
    /// Playable file URL for a Photos-backed video, resolved once per video.
    ///
    /// Not persisted and never used as identity: it points into the Photos
    /// library (or a one-off export) and is valid for this launch only. The
    /// `photos-asset:///` URL in `video.streamURL` remains the stable key.
    @ObservationIgnored private var resolvedPhotosStreamURL: URL?
    @ObservationIgnored private var photosResolveTask: Task<Void, Never>?
    @ObservationIgnored private var playbackRendererTask: Task<Void, Never>?

    // MARK: - Initialization (side-effect-free)

    init(windowValue: VideoWindowValue, appModel: AppModel) {
        self.video = windowValue.video
        self.wasPushed = windowValue.wasPushed
        self.windowValueId = windowValue.id
        self.popOutWindowValue = windowValue.wasPushed ? nil : windowValue
        self.appModel = appModel
        self.stereoscopicOverride = windowValue.stereoscopicOverride
        self.video3DSettings = windowValue.video3DSettings
        self.pseudo3DEnabled = windowValue.pseudo3DEnabled
        self.pseudo3DSettings = windowValue.pseudo3DSettings ?? .default
        self.isMuted = Self.startsMuted(windowValue.video, appModel: appModel)

        // Snapshot the browse list + pagination so prev/next navigate over this
        // window's own copy (parallels PhotoWindowModel.init). A window value may
        // carry its own complete list (Local tab, which isn't backed by
        // appModel.galleryVideos) — then navigate that fixed list, no pagination.
        self.videoSource = appModel.videoSource
        self.snapshotFilter = appModel.currentVideoFilter
        self.pageSize = appModel.pageSize
        if let list = windowValue.galleryVideos, !list.isEmpty {
            self.usesStaticGalleryList = true
            self.galleryVideos = list
            self.currentIndex = list.firstIndex(of: windowValue.video) ?? 0
            self.currentPage = 0
            self.hasMorePages = false
        } else {
            self.usesStaticGalleryList = false
            self.galleryVideos = appModel.galleryVideos
            self.currentIndex = appModel.galleryVideos.firstIndex(of: windowValue.video) ?? 0
            self.currentPage = appModel.currentVideoPage
            self.hasMorePages = appModel.hasMoreVideoPages
        }

        // NOTE: side effects deferred to start().
    }

    /// Call once from onAppear.
    func start() {
        guard !didStart else { return }
        didStart = true
        appModel.lastViewedVideoId = video.id
        if let popOutWindowValue {
            appModel.registerVideoWindow(video: video, windowValue: popOutWindowValue)
        }
        // A restored window re-engages fake-3D with the default realtime mode;
        // prefer the pre-processed cache when one exists for this video.
        if pseudo3DEnabled, pseudo3DDepthMode == .realtime,
           DepthCacheStore.entry(videoIdentity: video.identity) != nil {
            pseudo3DDepthMode = .cached(videoIdentity: video.identity)
        }
        resolvePlaybackRenderer()
        armLoadStallWatch()
    }

    /// Browsing autoplay follows Settings (muted by default). A Library title
    /// is different: someone pressed Play on a film, and a muted start read
    /// as the stream having no audio at all.
    private static func startsMuted(_ video: GalleryVideo, appModel: AppModel) -> Bool {
        if LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) != nil {
            return false
        }
        return appModel.videoAutoplayMuted
    }

    // MARK: - Load Status

    /// Called when the player reports the video's size (its first frame).
    func markVideoPresented() {
        guard !hasPresentedVideo else { return }
        hasPresentedVideo = true
        isLoadStalled = false
        loadStallTask?.cancel()
        // The auto-hide timer held off while the window was empty; start it now.
        if !isUIHidden { startAutoHideTimer() }
    }

    /// The last fallback failed; there is nothing further to try.
    func reportPlaybackFailure(_ message: String) {
        AppLogger.videoWindow.error("[\(self.videoDisplayName, privacy: .private(mask: .hash))] playback failed: \(message, privacy: .public)")
        playbackFailure = message
        isLoadStalled = false
        loadStallTask?.cancel()
        revealChrome()
    }

    /// Starts this video again from a fresh player.
    func retryPlayback() {
        playbackFailure = nil
        isLoadStalled = false
        hasPresentedVideo = false
        playbackAttempt += 1
        usingTranscodedStream = false
        pseudo3DEnabled = false
        resolvePlaybackRenderer()
        armLoadStallWatch()
    }

    private func armLoadStallWatch() {
        loadStallTask?.cancel()
        loadStallTask = Task { [weak self] in
            try? await Task.sleep(for: Self.loadStallTimeout)
            guard !Task.isCancelled, let self,
                  !self.hasPresentedVideo, self.playbackFailure == nil,
                  // Genuine stereoscopic plays in the immersive space and
                  // never reports a size to this window.
                  !self.shouldUse3DMode else { return }
            AppLogger.videoWindow.error("[\(self.videoDisplayName, privacy: .private(mask: .hash))] no picture after \(Self.loadStallTimeout, privacy: .public)")
            self.isLoadStalled = true
            self.revealChrome()
        }
    }

    private func revealChrome() {
        cancelAutoHideTimer()
        isUIHidden = false
    }

    /// Call from onDisappear.
    func cleanup() {
        if popOutWindowValue != nil {
            appModel.unregisterVideoWindow(video: video, windowValueId: windowValueId)
        }
        cancelAutoHideTimer()
        dismissDepthReadyPrompt()
        progressiveEngageTask?.cancel()
        progressiveEngageTask = nil
        playbackRendererTask?.cancel()
        playbackRendererTask = nil
        loadStallTask?.cancel()
        loadStallTask = nil
        photosResolveTask?.cancel()
        photosResolveTask = nil
        loopController.reset()
        playCommand = nil
        pauseCommand = nil
        seekCommand = nil
        setMutedCommand = nil
        // Release the standalone Adjustments window's ref to us (also makes that
        // window dismiss itself), so this closed window's model isn't retained.
        if appModel.videoAdjustmentsTarget === self {
            appModel.videoAdjustmentsTarget = nil
        }
    }

    // MARK: - Navigation

    var hasNextVideo: Bool { currentIndex + 1 < galleryVideos.count }
    var hasPreviousVideo: Bool { currentIndex > 0 }
    var currentVideoPosition: Int { galleryVideos.isEmpty ? 0 : currentIndex + 1 }
    var videoCount: Int { galleryVideos.count }

    func nextVideo() {
        guard hasNextVideo else { return }
        currentIndex += 1
        checkAndLoadMoreIfNeeded()
        switchToVideo(galleryVideos[currentIndex])
    }

    func previousVideo() {
        guard hasPreviousVideo else { return }
        currentIndex -= 1
        switchToVideo(galleryVideos[currentIndex])
    }

    /// Switch to a different video, resetting per-window viewing state. The
    /// WebVideoPlayerView reloads automatically because its `videoURL` changes.
    func switchToVideo(_ newVideo: GalleryVideo) {
        appModel.lastViewedVideoId = newVideo.id
        // Keep the open-window registry pointed at what this window actually
        // shows, so a window group saved after prev/next captures the right video.
        if popOutWindowValue != nil {
            appModel.updateVideoWindowVideo(
                windowValueId: windowValueId,
                oldVideo: video,
                newVideo: newVideo
            )
        }
        video = newVideo

        // Reset per-window viewing state
        stereoscopicOverride = nil
        video3DSettings = nil
        pseudo3DEnabled = false
        pseudo3DDepthMode = .realtime
        pseudo3DEngageResumeTime = nil
        pseudo3DEngagePaused = false
        progressiveEngageTask?.cancel()
        progressiveEngageTask = nil
        dismissDepthReadyPrompt()
        pseudo3DSettings = .default
        pendingPseudo3DEngage = nil
        // Every video starts on its own original file, whatever the previous
        // one ended up playing.
        usingTranscodedStream = false
        resolvedPhotosStreamURL = nil
        isFlipped = false
        currentAdjustments = VisualAdjustments()
        loopController.reset()
        resolvePlaybackRenderer()

        // Reset playback state (the player reloads as a fresh autoplay at the
        // default mute state)
        currentTime = 0
        duration = 0
        isPaused = true
        isMuted = Self.startsMuted(newVideo, appModel: appModel)
        bufferedEnd = 0
        isScrubbing = false
        hasPresentedVideo = false
        isLoadStalled = false
        playbackFailure = nil
        armLoadStallWatch()
    }

    func loadMoreVideos() async {
        guard !isLoadingMoreVideos && hasMorePages else { return }
        isLoadingMoreVideos = true
        defer { isLoadingMoreVideos = false }
        do {
            let result = try await videoSource.fetchVideos(page: currentPage, pageSize: pageSize, filter: snapshotFilter)
            galleryVideos.append(contentsOf: result.videos)
            hasMorePages = result.hasMore
            currentPage += 1
        } catch {
            AppLogger.videoWindow.error("Failed to load more videos for window: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    func checkAndLoadMoreIfNeeded() {
        let remaining = galleryVideos.count - currentIndex - 1
        if remaining <= prefetchThreshold && hasMorePages && !isLoadingMoreVideos {
            Task { await loadMoreVideos() }
        }
    }

    // MARK: - 3D / Viewing Mode

    /// Whether this window should render with the stereoscopic player.
    var shouldUse3DMode: Bool {
        // Immersive MV-HEVC playback needs an ImmersiveSpace; on iOS a
        // stereoscopic file plays flat (one eye), whatever it is tagged as.
        guard PlatformCapabilities.supportsImmersiveSpaces else { return false }
        if stereoscopicOverride == false { return false }
        if stereoscopicOverride == true || video3DSettings != nil { return true }
        return video.isStereoscopic
    }

    /// Whether this window should render with the real-time fake-3D player.
    /// Mutually exclusive with the genuine stereoscopic path, and limited to the
    /// AVFoundation (native Metal) renderer since it pulls decoded frames via
    /// AVPlayerItemVideoOutput.
    var shouldUsePseudo3D: Bool {
        pseudo3DEnabled && !shouldUse3DMode && playbackRenderer == .nativeMetal
    }

    func set2DMode() {
        stereoscopicOverride = false
        pseudo3DEnabled = false
    }

    /// Set when the user requests fake-3D with no depth model installed — drives
    /// the first-run `DepthModelSetupSheet`. Fake-3D requires a real depth model
    /// (there is no heuristic fallback), so the sheet gates first use.
    var showDepthModelSetup = false

    /// Where fake-3D gets its depth: realtime inference (30fps, instant) or a
    /// pre-processed cache entry (60fps, exact-frame sync). Resolved when the
    /// user engages Convert to 3D.
    var pseudo3DDepthMode: Pseudo3DDepthMode = .realtime

    /// Drives the "Real-time or Pre-process?" alert when engaging Convert to 3D
    /// with no cache yet (same alert pattern as the window Summon/Copy prompts).
    var showPseudo3DModePrompt = false

    /// "3D ready" pill shown when this video's background conversion completes,
    /// or on open when a completed conversion already exists (restore).
    var showDepthReadyPrompt = false
    /// Pill label — "ready" (conversion just finished) vs "available" (restore).
    var depthReadyPromptMessage = "3D version ready"
    /// Non-nil while the conversion-failed alert is up.
    var depthConversionFailureMessage: String?
    /// Playhead captured when fake-3D is engaged so the stereo player resumes
    /// where the 2D player was instead of restarting.
    var pseudo3DEngageResumeTime: Double?
    /// Engage fake-3D paused rather than playing. Set for a progressive engage
    /// mid-conversion: the stereo player decodes a single frame (so it's
    /// visibly playable in 3D) but doesn't start sustained playback — a second
    /// decode session concurrent with the converter's reader can trip a
    /// transient VideoToolbox decode failure. The user's manual Play then
    /// opts into that second session deliberately.
    var pseudo3DEngagePaused = false
    /// Polls for the safe point to auto-engage 3D playback mid-conversion.
    @ObservationIgnored private var progressiveEngageTask: Task<Void, Never>?
    /// The frontier must lead the playhead by at least this much before
    /// engaging — covers fragment/meta write latency (~4s) plus rebuild gaps.
    private static let progressiveMinLeadSeconds: Double = 10
    /// Fraction of the measured conversion rate we rely on — headroom for
    /// thermal throttling. Underruns degrade to flat depth, not stutter.
    private static let progressiveSafetyFactor: Double = 0.8
    @ObservationIgnored private var depthReadyPromptDismissTask: Task<Void, Never>?
    private static let depthReadyPromptTimeout: TimeInterval = 10

    /// ViewMode "Convert to 3D" entry point.
    /// - A completed cache from the selected pre-process model → engage
    ///   pre-processed playback directly, no prompt.
    /// - No model installed (and no cache) → first-run model setup sheet.
    /// - Otherwise → ask Real-time vs Pre-process (unless a conversion for this
    ///   video is already running).
    func requestPseudo3D() {
        // Engage requires the *selected* pre-process model's cache (a different
        // model's cache would silently override a deliberate model switch);
        // engageEntry falls back to any cache only when no model is installed.
        if DepthCacheStore.engageEntry(videoIdentity: video.identity) != nil {
            engageCachedPseudo3D()
            return
        }
        if DepthModelStore.installedModelNames().isEmpty {
            showDepthModelSetup = true
            return
        }
        guard !DepthConversionManager.shared.isProcessing(videoIdentity: video.identity) else {
            // Already converting (e.g. started from a previous window of this
            // video): monitor it so this window auto-engages at the safe point
            // — immediately, once a two-pass conversion's first sweep has made
            // the entry playable end to end.
            startProgressiveEngageMonitor()
            return
        }
        showPseudo3DModePrompt = true
    }

    /// Engage the realtime (synchronous inference) fake-3D path. Never starts a
    /// background conversion — it would fight the live inference for the ANE.
    func engageRealtimePseudo3D() {
        pseudo3DEngageResumeTime = currentTime
        pseudo3DEngagePaused = false
        pseudo3DDepthMode = .realtime
        enablePseudo3D()
    }

    /// Engage fake-3D from this video's depth cache (complete, or still growing
    /// when the conversion is running — progressive playback). `startPaused`
    /// engages showing a single 3D frame without starting playback (used for a
    /// progressive engage mid-conversion — see `pseudo3DEngagePaused`).
    func engageCachedPseudo3D(startPaused: Bool = false) {
        dismissDepthReadyPrompt()
        pseudo3DEngageResumeTime = currentTime
        pseudo3DEngagePaused = startPaused
        if startPaused { isPaused = true }
        pseudo3DDepthMode = .cached(videoIdentity: video.identity)
        enablePseudo3D()
    }

    /// Kick off the background depth conversion. The window keeps playing 2D,
    /// then auto-engages 3D at the safe point mid-conversion (see
    /// startProgressiveEngageMonitor) or on completion.
    func startDepthPreprocessing() {
        DepthConversionManager.shared.enqueue(DepthConversionManager.Request(
            videoIdentity: video.identity,
            title: video.title ?? video.fileName,
            sourceURL: depthConversionSourceURL,
            httpHeaderFields: MediaAuthorization.shared.headerFields(for: depthConversionSourceURL)
        ))
        startProgressiveEngageMonitor()
    }

    /// Whether this window is plain-2D and eligible to be auto-switched into
    /// cached fake-3D (never override an explicit 3D/realtime choice).
    private var canAutoEngageProgressive3D: Bool {
        !shouldUse3DMode && !pseudo3DEnabled && playbackRenderer == .nativeMetal
    }

    /// While this video converts, poll for the point where 3D playback can
    /// start without ever catching the conversion frontier: the remaining
    /// conversion must finish within the remaining playback at the measured
    /// rate (with headroom for throttling), and the frontier must lead the
    /// playhead by a buffer. Auto-engages cached fake-3D there (or on
    /// completion if the safe point never arrives). Stops when the user picks
    /// another viewing mode or navigates away; drops back to 2D if the
    /// conversion is cancelled or fails mid-progressive-playback.
    private func startProgressiveEngageMonitor() {
        progressiveEngageTask?.cancel()
        let identity = video.identity
        progressiveEngageTask = Task { [weak self] in
            var engagedProgressively = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.video.identity == identity else { return }
                let manager = DepthConversionManager.shared

                // willRestart covers the gap while a conversion interrupted by
                // app backgrounding waits to restart on foreground.
                guard manager.isProcessing(videoIdentity: identity) || manager.willRestart(videoIdentity: identity) else {
                    // Strict lookup: only the entry THIS conversion produced
                    // counts. The lenient entry() would find an older model's
                    // cache after a failed conversion and auto-engage it over
                    // the failure alert.
                    if DepthCacheStore.engageEntry(videoIdentity: identity) != nil {
                        // Completed. Engage if still watching plain 2D (the
                        // ready pill covers windows that moved on).
                        if !engagedProgressively, self.canAutoEngageProgressive3D {
                            self.engageCachedPseudo3D()
                        }
                    } else if engagedProgressively, self.pseudo3DEnabled,
                              case .cached = self.pseudo3DDepthMode {
                        // Cancelled/failed mid-progressive-playback: the depth
                        // file stops growing (or vanishes) — back to 2D.
                        self.disablePseudo3D()
                    }
                    self.progressiveEngageTask = nil
                    return
                }

                guard !engagedProgressively else { continue }
                guard self.canAutoEngageProgressive3D,
                      let status = manager.progressiveStatus(videoIdentity: identity),
                      self.duration > 0 else { continue }

                let playhead = self.currentTime
                let lead = status.frontier - playhead
                let remainingPlayback = max(self.duration - playhead, 0)
                let remainingConversion = max(self.duration - status.frontier, 0)
                if lead >= Self.progressiveMinLeadSeconds,
                   remainingConversion <= status.rate * remainingPlayback * Self.progressiveSafetyFactor {
                    AppLogger.videoWindow.info("Progressive 3D engage (paused): frontier \(status.frontier, privacy: .public)s, rate \(status.rate, privacy: .public)x, playhead \(playhead, privacy: .public)s")
                    // Engage paused: show one 3D frame without a second decode
                    // session fighting the converter. Manual Play starts it.
                    self.engageCachedPseudo3D(startPaused: true)
                    engagedProgressively = true
                }
            }
        }
    }

    /// A downloadable, AVAssetReader-readable source for depth conversion. See
    /// `GalleryVideo.transcodedDownloadURL` for the HLS→MP4 rewrite rationale;
    /// here we just layer on whatever query-param credential the host has.
    /// A header credential can't ride a URL, so the conversion request carries
    /// it separately — see `startDepthPreprocessing`.
    private var depthConversionSourceURL: URL {
        authenticatedURL(video.transcodedDownloadURL)
    }

    /// Called when the conversion manager reports a completion for this video,
    /// or with the "available" message when opening an already-converted video.
    func presentDepthReadyPrompt(message: String = "3D version ready") {
        // Already watching from the cache — nothing to offer.
        if shouldUsePseudo3D, case .cached = pseudo3DDepthMode { return }
        depthReadyPromptMessage = message
        showDepthReadyPrompt = true
        depthReadyPromptDismissTask?.cancel()
        depthReadyPromptDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.depthReadyPromptTimeout))
            guard !Task.isCancelled else { return }
            self?.showDepthReadyPrompt = false
            self?.depthReadyPromptDismissTask = nil
        }
    }

    func dismissDepthReadyPrompt() {
        depthReadyPromptDismissTask?.cancel()
        depthReadyPromptDismissTask = nil
        showDepthReadyPrompt = false
    }

    /// Engage fake-3D, ensuring the genuine-stereoscopic path is off.
    /// Single choke point for engaging fake-3D, so every entry path (the
    /// ViewMode menu, the realtime/pre-process prompt, the "3D ready" pill, the
    /// progressive monitor, the auto-engage setting) picks up the transcode swap.
    ///
    /// Fake-3D pulls frames through `AVPlayerItemVideoOutput`, so a source
    /// WebKit is decoding (WebM) has to move to the server's HLS transcode
    /// first. The intent is parked in `pendingPseudo3DEngage` and replayed by
    /// `resolvePlaybackRenderer` once the new renderer is known.
    func enablePseudo3D() {
        // Only swap once the renderer is actually known to be WebKit — swapping
        // while still `.resolving` could abandon an original that AVFoundation
        // was about to accept.
        if playbackRenderer == .webKit, canUseTranscodedStream {
            pendingPseudo3DEngage = PendingPseudo3DEngage(
                depthMode: pseudo3DDepthMode,
                startPaused: pseudo3DEngagePaused,
                resumeAt: pseudo3DEngageResumeTime ?? (currentTime > 0 ? currentTime : nil)
            )
            switchToTranscodedStream(reason: "fake-3D requires the AVFoundation renderer")
            return
        }
        stereoscopicOverride = false
        pseudo3DEnabled = true
    }

    /// A fake-3D engage deferred until the transcode's renderer resolves.
    private struct PendingPseudo3DEngage {
        let depthMode: Pseudo3DDepthMode
        let startPaused: Bool
        let resumeAt: Double?
    }

    @ObservationIgnored private var pendingPseudo3DEngage: PendingPseudo3DEngage?

    /// Replay (or abandon) a fake-3D engage that was waiting on the transcode.
    private func resumePendingPseudo3DEngage() {
        guard let pending = pendingPseudo3DEngage else { return }
        pendingPseudo3DEngage = nil
        guard playbackRenderer == .nativeMetal else {
            // The transcode isn't AVFoundation-playable either (a server that
            // only offers the non-seekable /stream.mp4 lands here). Say so
            // rather than leaving a menu item that silently does nothing.
            depthConversionFailureMessage = "This video can't be converted to 3D: its server transcode isn't playable by AVFoundation. HLS transcoding must be available on the Stash server."
            return
        }
        pseudo3DDepthMode = pending.depthMode
        pseudo3DEngagePaused = pending.startPaused
        pseudo3DEngageResumeTime = pending.resumeAt
        if pending.startPaused { isPaused = true }
        stereoscopicOverride = false
        pseudo3DEnabled = true
    }

    func disablePseudo3D() {
        pseudo3DEnabled = false
    }

    /// Resolve the best 3D settings for the current video and engage 3D, or
    /// open the settings sheet when none can be inferred.
    func enable3DMode() async {
        pseudo3DEnabled = false
        if let saved = await Video3DSettingsTracker.shared.loadSettings(videoId: video.identity) {
            video3DSettings = saved
            stereoscopicOverride = true
            return
        }
        if let tagSettings = Video3DSettings.from(video: video) {
            video3DSettings = tagSettings
            stereoscopicOverride = true
            return
        }
        showVideo3DSettingsSheet = true
    }

    // MARK: - Visual Adjustments

    /// Per-window adjustments if modified, otherwise the global tier.
    var effectiveVideoAdjustments: VisualAdjustments {
        currentAdjustments.isModified ? currentAdjustments : appModel.globalVisualAdjustments
    }

    /// Per-window fake-3D tuning if modified, otherwise the global default.
    var effectivePseudo3DSettings: Pseudo3DSettings {
        pseudo3DSettings.isModified ? pseudo3DSettings : appModel.globalPseudo3DSettings
    }

    /// The URL this window is currently playing: the original file, or the
    /// server transcode once `usingTranscodedStream` is set.
    var activeStreamURL: URL {
        // A photos-asset URL is an identity, not something AVPlayer can open;
        // until it resolves this returns it unchanged so callers stay honest
        // about not being ready. `resolvePlaybackRenderer` waits for the
        // resolution rather than probing the unopenable form.
        if PhotosAssetURL.isPhotosAsset(video.streamURL) {
            return resolvedPhotosStreamURL ?? video.streamURL
        }
        guard usingTranscodedStream, let transcode = video.transcodeStreamURL else {
            return video.streamURL
        }
        return transcode
    }

    var authenticatedStreamURL: URL {
        authenticatedURL(activeStreamURL)
    }

    /// Whether swapping to the server transcode is still an available move.
    var canUseTranscodedStream: Bool {
        !usingTranscodedStream && video.hasNativePlayableTranscode
    }

    /// Whether the fake-3D ("Convert to 3D") path is reachable for this video —
    /// either it already decodes through AVFoundation, or a server transcode can
    /// get it there. WebM lands in the second case: WebKit plays the original,
    /// and picking 3D re-routes playback through the HLS transcode.
    var pseudo3DAvailable: Bool {
        // The stereo pump renders a per-eye pair; there is nothing to show it
        // on without a stereoscopic display.
        guard PlatformCapabilities.supportsStereoVideo else { return false }
        return playbackRenderer == .nativeMetal || canUseTranscodedStream
    }

    func forceWebKitPlayback() {
        playbackRendererTask?.cancel()
        playbackRenderer = .webKit
    }

    /// Swap the original file for the server's live transcode and re-resolve the
    /// renderer. Returns false when there's nothing to swap to.
    ///
    /// Called from two places: the WebKit player reporting the original as
    /// undecodable, and any fake-3D engage on a WebKit-rendered source (fake-3D
    /// needs AVPlayerItemVideoOutput). The playhead is carried over so the swap
    /// resumes rather than restarts.
    @discardableResult
    func switchToTranscodedStream(reason: String) -> Bool {
        guard canUseTranscodedStream else { return false }
        AppLogger.videoWindow.info(
            "[\(self.videoDisplayName, privacy: .private(mask: .hash))] switching to server transcode: \(reason, privacy: .public)"
        )
        usingTranscodedStream = true
        resolvePlaybackRenderer()
        return true
    }

    /// Called by the WebKit player when the original file can't be decoded (or
    /// its network retries are exhausted). Falls forward to the transcode; with
    /// no transcode available the player keeps its own retry behaviour.
    func handleSourceUnplayable() {
        guard !switchToTranscodedStream(reason: "original file is not decodable by WebKit") else { return }
        reportPlaybackFailure("The server didn't send a video this device can play. Check that the server is reachable and that you're still signed in.")
    }

    private func resolvePlaybackRenderer() {
        playbackRendererTask?.cancel()
        photosResolveTask?.cancel()
        playbackRenderer = .resolving

        // Photos assets must become a real file URL first — probing the
        // synthetic one would find it unplayable and fall through to WebKit,
        // which cannot open it either.
        if PhotosAssetURL.isPhotosAsset(video.streamURL), resolvedPhotosStreamURL == nil {
            let assetURL = video.streamURL
            photosResolveTask = Task { [weak self] in
                let playable = await PhotosAssetStore.shared.playableURL(for: assetURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.video.streamURL == assetURL else { return }
                    guard let playable else {
                        // The asset is gone, or access to it was revoked.
                        AppLogger.videoWindow.error(
                            "[\(self.videoDisplayName, privacy: .private(mask: .hash))] Photos video could not be resolved"
                        )
                        self.playbackRenderer = .nativeMetal
                        return
                    }
                    self.resolvedPhotosStreamURL = playable
                    self.resolvePlaybackRenderer()
                }
            }
            return
        }

        let url = authenticatedStreamURL
        playbackRendererTask = Task { [weak self] in
            let isPlayable = await Self.canPlayNatively(url: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.authenticatedStreamURL == url else { return }
                self.playbackRenderer = isPlayable ? .nativeMetal : .webKit
                // A fake-3D engage waiting on the transcode swap resolves here.
                if self.pendingPseudo3DEngage != nil {
                    self.resumePendingPseudo3DEngage()
                    return
                }
                // A restored window that was in fake-3D over a WebKit-decoded
                // source needs the same transcode swap to get back there.
                if self.pseudo3DEnabled, !self.shouldUse3DMode, !isPlayable, self.canUseTranscodedStream {
                    self.enablePseudo3D()
                    return
                }
                self.autoEngagePseudo3DIfPreferred()
                self.offerCached3DIfAvailable()
            }
        }
    }

    /// Settings → "Real-Time 3D for All Videos": engage fake-3D as soon as
    /// the native renderer is confirmed (runs on open and on every video
    /// switch), unless this window already has a mode — restored fake-3D or
    /// genuine stereoscopic. Prefers this video's pre-processed cache (strict
    /// engageEntry, so a deliberate pre-process model switch isn't silently
    /// overridden by an old cache), else real-time inference; with no depth
    /// model installed it stays 2D silently — never forces the setup sheet.
    private func autoEngagePseudo3DIfPreferred() {
        guard appModel.defaultRealtimePseudo3D,
              !pseudo3DEnabled, !shouldUse3DMode,
              // WebKit-decoded sources qualify too — enablePseudo3D swaps them
              // onto the server transcode first (WebM with transcoding on).
              pseudo3DAvailable else { return }
        if DepthCacheStore.engageEntry(videoIdentity: video.identity) != nil {
            pseudo3DDepthMode = .cached(videoIdentity: video.identity)
        } else if CoreMLDepthProvider.hasAvailableModel(role: .realtime) {
            pseudo3DDepthMode = .realtime
        } else {
            return
        }
        enablePseudo3D()
    }

    /// Mirror of the photo viewer's auto-3D restore pill: a video that already
    /// has a completed pre-processed conversion offers "Watch in 3D" on open /
    /// gallery switch instead of hiding it behind the ViewMode menu. Runs after
    /// autoEngagePseudo3DIfPreferred, whose engagement (or a restored fake-3D
    /// window, or genuine stereoscopic) suppresses it. An in-progress
    /// conversion can't trigger it — engageEntry only returns completed
    /// entries, and completion has its own prompt.
    private func offerCached3DIfAvailable() {
        guard !pseudo3DEnabled, !shouldUse3DMode, pseudo3DAvailable,
              DepthCacheStore.engageEntry(videoIdentity: video.identity) != nil else { return }
        presentDepthReadyPrompt(message: "3D version available")
    }

    private func authenticatedURL(_ url: URL) -> URL {
        MediaAuthorization.shared.authorizedURL(url)
    }

    private nonisolated static func canPlayNatively(url: URL) async -> Bool {
        await NativeVideoDecodeProbe.canPlayNatively(url: url)
    }

    func toggleFlip() {
        isFlipped.toggle()
    }

    // MARK: - Playback Commands

    func togglePlayPause() {
        if isPaused {
            playCommand?()
        } else {
            pauseCommand?()
        }
        // Optimistic flip; reconciled by the next videoPlayback message.
        isPaused.toggle()
    }

    func beginScrub() {
        isScrubbing = true
        cancelAutoHideTimer()
    }

    func scrub(to time: Double) {
        currentTime = time
    }

    func endScrub(at time: Double) {
        let clamped = max(0, duration > 0 ? min(time, duration) : time)
        currentTime = clamped
        seekCommand?(clamped)
        isScrubbing = false
        startAutoHideTimer()
    }

    func toggleMute() {
        isMuted.toggle()
        setMutedCommand?(isMuted)
    }

    /// Apply a state report from the JS bridge (ignored mid-scrub).
    func applyPlaybackState(currentTime: Double, duration: Double, paused: Bool, muted: Bool, buffered: Double) {
        guard !isScrubbing else { return }
        self.currentTime = currentTime
        if duration > 0 { self.duration = duration }
        self.isPaused = paused
        self.isMuted = muted
        self.bufferedEnd = buffered
    }

    // MARK: - Share

    func shareVideo() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        let url = video.streamURL
        let shareName = video.fileName ?? video.title

        if url.isFileURL {
            presentShareSheet(url: ShareSheetHelper.prepareShareFile(from: url, title: shareName, originalURL: url))
            return
        }

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let namedURL = ShareSheetHelper.prepareShareFile(from: tempURL, title: shareName, originalURL: url)
            try? FileManager.default.removeItem(at: tempURL)
            presentShareSheet(url: namedURL)
        } catch {
            AppLogger.videoWindow.error("Failed to download video for sharing: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    private func presentShareSheet(url: URL) {
        cancelAutoHideTimer()
        shareFileURL = url
    }

    // MARK: - Auto-Hide

    func startAutoHideTimer() {
        cancelAutoHideTimer()
        guard appModel.autoHideDelay > 0 else { return }
        guard !hasOpenPopover else { return }

        // Hide only over a picture; `markVideoPresented` re-arms this.
        guard hasPresentedVideo else { return }

        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            if !Task.isCancelled, !self.hasOpenPopover, self.hasPresentedVideo {
                isUIHidden = true
                scheduleWindowControlsHiding()
            }
        }
    }

    func scheduleWindowControlsHiding() {
        windowControlsHideTask?.cancel()
        windowControlsHideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                isWindowControlsHidden = true
            }
        }
    }

    func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
        isWindowControlsHidden = false
    }

    func toggleUIVisibility() {
        isUIHidden.toggle()
        isWindowControlsHidden = false
        if !isUIHidden {
            startAutoHideTimer()
        }
    }

    // MARK: - Scene Phase / Room Activity

    var videoDisplayName: String {
        video.title ?? video.streamURL.lastPathComponent
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active {
            isInActiveRoom = true
        } else if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
            isInActiveRoom = false
        }
    }
}
