/*
 Hypnos - Remote Viewer Model

 Subclass of SlideshowEngine that adds remote-specific features:
 WebSocket integration, save/block functionality, sensor display,
 display sync, and remote API configuration management.
 */

import DebugTrace
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
class RemoteViewerModel: SlideshowEngine {
    // MARK: - Configuration

    var config: RemoteViewerConfig
    /// Stable RoboFrame identity used by MQTT, history, and display control.
    let slideshowDeviceId: String
    /// Persistent window identity used as the server-side slideshow session.
    let slideshowSessionId: String
    var windowValue: RemoteViewerWindowValue?

    // MARK: - Gallery Mode

    /// Whether this window plays the app's own content rather than a RoboFrame
    /// channel — no WebSocket, no orchestrator, so the engine keeps its own
    /// dwell clock and handles block/advance locally.
    ///
    /// Keyed on the profile's mode, not on the content provider: a *video*
    /// slideshow also has no server, but its provider isn't a
    /// `GalleryContentProvider`, so the old provider test called it remote and
    /// left it `serverDriven` with nothing to drive it.
    var isGalleryMode: Bool { config.mode == .appGallery }

    // MARK: - Display State (remote-specific)

    /// User-facing toggle that claims/releases the displaySync merge driver
    /// role on the server. Writing this emits `displaySync { enabled }`. On
    /// `true` the orchestrator merges every channel into this session's
    /// channel — every connected display mirrors what we play. On `false`
    /// each channel resumes its own cadence.
    var enableDisplaySync: Bool = false {
        didSet {
            if oldValue != enableDisplaySync {
                wsSession?.sendDisplaySync(enabled: enableDisplaySync)
            }
        }
    }

    /// Last `playback.mergeDriver` value the server pushed (deviceId of the
    /// session currently holding the displaySync merge claim, or `nil` when
    /// no merge is active). Used by the UI to reflect merge state
    /// independently of the local toggle.
    private(set) var serverPrimaryDeviceId: String?

    /// Shared mod-tag preset catalog. Injected by RemoteViewerWindowView,
    /// same pattern as `tagListManager` on the engine superclass.
    var modTagManager: ModTagManager?

    var showClock: Bool = true
    var showSensors: Bool = true

    // MARK: - Sensor Display

    var sortedSensors: [HASensorReading] {
        wsSession?.sensorData.values.sorted { $0.friendlyName < $1.friendlyName } ?? []
    }

    // MARK: - Window Callbacks

    var onOpenAlertWindow: ((String, String, String?) -> Void)?
    var onDismissAlertWindow: (() -> Void)?

    // MARK: - Services

    let apiClient = RemoteAPIClient()
    /// Per-viewer logical session over a shared WebSocket connection.
    /// All viewers pointed at the same WS endpoint share one TCP/TLS path
    /// (one server-side ws) and multiplex under per-session sessionIds —
    /// see SlideshowSyncHub.subscribeWS and protocol.md.
    private(set) var wsSession: RemoteWSSession?

    /// When true, `onPostTransitioned` skips broadcasting local sync to avoid
    /// feedback loops while this model is applying an incoming sync.
    private var isApplyingIncomingSync: Bool = false

    /// While set to a future date, incoming `playback` frames are dropped
    /// on the floor. Stamped when the user picks a post from the history
    /// grid so the room's tick doesn't yank them away from the manually
    /// chosen image before they've finished looking at it. Suppression is
    /// per-window/local — other devices keep advancing.
    private var playbackSuppressedUntil: Date?

    /// Post that's transitioned visually but is still waiting on the
    /// RealityKit slot to finish generating its depth map before we tell
    /// the server we're ready. Without this gate, a short channel
    /// interval (6 s, etc.) advances the room ahead of the slowest 3D
    /// client and the user sees the IPC conversion animation play during
    /// the next crossfade. Cleared when we actually send `imageReady`.
    private var pendingImageReadyPost: RemotePost?
    /// Watchdog for the 3D deferral above. Kept under the server's default
    /// `readyTimeoutMs` (15 s) so a slow depth map degrades to a normal report
    /// rather than letting the channel promote without us and march toward its
    /// three-strike stall.
    @ObservationIgnored private var spatial3DReadyTimeoutTask: Task<Void, Never>?
    private static let spatial3DReadyGrace: TimeInterval = 12
    /// Object identities of images whose 3D depth-map generation has
    /// completed. Two-slot pipeline means at most two are live at once,
    /// so we cap the set rather than letting it grow unbounded.
    private var generatedImageIds: Set<ObjectIdentifier> = []

    /// Clip length (ms) of the current video, once the player reports it via
    /// `loadedmetadata`. nil for images, and reset to nil on every transition.
    /// Reported to the server in `imageReady` so a clip longer than the
    /// interval delays the advance until it has played through.
    @ObservationIgnored private var currentVideoDurationMs: Int?
    /// Which post `currentVideoDurationMs` belongs to. The player's
    /// loadedmetadata usually fires *during* the image→video crossfade —
    /// before the engine commits `currentPost` — so the duration arrives
    /// tagged with the incoming (`nextPost`) id. `onPostTransitioned` keeps
    /// the value when this id matches the post it just committed instead of
    /// blindly wiping it (the webview's identity is preserved across the
    /// commit, so loadedmetadata never re-fires for the same clip).
    @ObservationIgnored private var currentVideoDurationPostId: Int?
    /// Watchdog for a deferred video imageReady: if the player never reports
    /// duration (load failure, NaN duration on a stream, torn-down webview),
    /// fire imageReady without a duration after a grace period rather than
    /// stalling the channel forever.
    @ObservationIgnored private var videoDurationTimeoutTask: Task<Void, Never>?
    /// A video post that transitioned visually but whose clip length isn't
    /// known yet. imageReady is deferred until the player reports duration
    /// (mirrors the web kiosk, which reports on `loadeddata` with the
    /// duration) so the server can size the dwell to the full clip.
    @ObservationIgnored private var pendingVideoImageReadyPost: RemotePost?
    /// Whether the current video should loop: true unless its clip length
    /// exceeds the interval, in which case it plays once and freezes on its
    /// last frame so it doesn't restart its opening frame before the advance.
    private(set) var currentVideoLoops: Bool = true

    // MARK: - Init

    init(config: RemoteViewerConfig, windowId: UUID) {
        self.config = config
        let configuredDeviceId = config.wsDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.slideshowDeviceId = configuredDeviceId.isEmpty ? "hypnos" : configuredDeviceId
        self.slideshowSessionId = windowId.uuidString.lowercased()
        self.showClock = config.showClock
        self.showSensors = config.showSensors

        super.init(
            // In remote mode the channel's `interval` arrives in the first
            // `playback` frame after WS connect and overrides this. The
            // config value is only authoritative for gallery mode (no
            // apiEndpoint) and during the brief window before the first
            // playback frame in remote mode.
            delay: config.delay,
            enableKenBurns: config.enableKenBurns,
            useAspectRatio: config.useAspectRatio,
            enableDynamicBrightness: config.enableDynamicBrightness,
            enableDiorama: config.enableDiorama
        )

        // Per-window tag list state. The current list is server-tracked; this
        // per-window manager just holds the active index so two windows on
        // different channels don't clobber a shared value when each receives
        // its own channel's `playback.currentList`. The catalog (`tagLists`)
        // is filled when the server pushes a `tagLists` frame.
        self.tagListManager = TagListManager()

        // Block lists are server-only state — the orchestrator filters
        // blocked posts out of every channel's queue before broadcasting,
        // so a remote-mode kiosk never sees them. The engine's local
        // blockedPosts/blockedTags Sets stay empty here and are only
        // populated by the gallery-mode code path, where local filtering
        // is the only option (no WS).
    }

    /// Mirror of catalog updates into AppModel so a freshly opened viewer's
    /// ornament has the tag list names before the server re-pushes them (the
    /// `tagLists` frame is only sent on connect, so late joiners on a shared
    /// connection would otherwise start empty). Injected by setupModel.
    var onCatalogReceived: (([[String]]) -> Void)?

    /// Callback to persist config changes back to AppModel
    var onConfigChanged: ((RemoteViewerConfig) -> Void)?

    // MARK: - Lifecycle

    override func start() {
        guard state == .idle else { return }

        if !isGalleryMode {
            SlideshowSyncHub.shared.registerForLocalSync(self)
        }

        if !isGalleryMode {
            // Remote mode is purely server-paced — the orchestrator's playback
            // frames drive every advance and the engine never runs its own
            // dwell clock. See SlideshowEngine.serverDriven.
            serverDriven = true

            // Tag lists used to be HTTP-fetched here from `/tags.json`. The RoboFrame
            // rpcserver now pushes them on WebSocket connect (action: tagLists), so we
            // just open the socket and let the server announce.
            setupWebSocket()

            // The server tracks the channel's current list and announces it in
            // the first `playback` frame after connect. If WS is active, wait
            // 1s for that frame before starting so the slideshow opens on the
            // server's persisted list rather than briefly fetching list 0.
            if !config.effectiveWsEndpoint.isEmpty {
                // Register tag list handler before the delay
                tagListManager?.addChangeHandler(id: engineId) { [weak self] in
                    self?.handleTagListChanged()
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    guard self.state != .stopped else { return }
                    // Playback can arrive before this delay expires and
                    // transition the engine to .loading. In that case we still
                    // need to start the run loop; only force idle -> loading.
                    if self.state == .idle {
                        self.transition(to: .loading)
                    }
                    self.startRunLoop()
                }
                return
            }
        }
        super.start()
    }

    override func stop() {
        super.stop()
        if !isGalleryMode {
            SlideshowSyncHub.shared.unregisterForLocalSync(self)
        }
        wsSession?.close()
        modTagManager?.removeSendHandler(id: engineId)
        tagListManager?.removeSendHandler(id: engineId)
        wsSession = nil
        playbackSuppressedUntil = nil
        ratioResendTask?.cancel()
        ratioResendTask = nil
        sceneStateDebounce?.cancel()
        sceneStateDebounce = nil
        videoDurationTimeoutTask?.cancel()
        videoDurationTimeoutTask = nil
        pendingVideoImageReadyPost = nil
        spatial3DReadyTimeoutTask?.cancel()
        spatial3DReadyTimeoutTask = nil
        pendingImageReadyPost = nil
    }

    override func onBecameActive() {
        // visionOS flips scenePhase on gaze shifts and minor system
        // interruptions, not just true sleep/wake. Probing with a ping
        // lets a healthy socket prove itself; only a missing pong
        // forces a reconnect.
        wsSession?.probeOrReconnect()
        // Immediate, like the OFF edge: `flushAndSuspendIfAbsent`'s in-flight
        // continuation re-checks `allSessionsAbsent` before releasing the
        // socket, and a 250ms-debounced ON report leaves that check reading
        // "still absent" — so a window that comes back during the background
        // flush gets its freshly-reconnected socket suspended out from under it.
        // Recording the contribution synchronously here closes that race.
        // (Debouncing exists for scenePhase flutter, which never reaches this
        // hook: only .background edges do.)
        scheduleSceneStateReport(effectiveVisible, immediate: true)
        // While HA holds the panel off, the channel stays parked: reporting
        // present or rejoining the barrier here would resume a slideshow the
        // user explicitly switched off. The displayState(on) frame is what
        // lifts the hold.
        guard effectiveVisible else { return }
        rejoinReadinessBarrier()
        // Per protocol §"Presence drives freshness; the client never
        // wake-advances": reporting present=true makes the server commit a
        // fresh post (it dark-advanced while we were away) and broadcast it —
        // we adopt that via the normal playback path. No client-side
        // requestNext here; the server already refreshed on our behalf.
    }

    override func onEnteredBackground() {
        // Send the OFF edge immediately, not debounced: visionOS suspends the
        // app (and freezes the socket) fast enough that a 250ms-delayed Task
        // never fires, so the server would never learn we left — no
        // dark-advance/park, stale image on return.
        scheduleSceneStateReport(false, immediate: true)
        // Queuing the frame isn't the same as sending it. Hold a background
        // assertion so the flush (and, once every window on the shared socket is
        // absent, the clean close that parks the channel immediately instead of
        // waiting out the broker's 5-10s heartbeat reap) actually completes
        // before the app suspends.
        endBackgroundFlushAssertion()
        #if !os(macOS)
        // No background-task assertion API on macOS — the app isn't
        // suspended when it loses focus the way iOS/visionOS suspend a
        // backgrounded scene, so there's nothing to hold open here.
        backgroundFlushAssertion = UIApplication.shared.beginBackgroundTask(withName: "roboframe-presence-flush") {
            Task { @MainActor [weak self] in self?.endBackgroundFlushAssertion() }
        }
        #endif
        Task { [weak self] in
            await self?.wsSession?.flushAndSuspendIfAbsent()
            self?.endBackgroundFlushAssertion()
        }
    }

    /// Assertion held while the background presence flush completes. visionOS
    /// would otherwise suspend us mid-send.
    #if !os(macOS)
    @ObservationIgnored private var backgroundFlushAssertion: UIBackgroundTaskIdentifier = .invalid
    #endif

    private func endBackgroundFlushAssertion() {
        #if !os(macOS)
        guard backgroundFlushAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundFlushAssertion)
        backgroundFlushAssertion = .invalid
        #endif
    }

    /// HA-driven panel state addressed to this window's deviceId
    /// (`displayState` frames). While off, this session reports present=false
    /// so the channel dark-advances one post and parks server-side — but the
    /// window keeps the current image rendered and decoded, so the PIR/HA
    /// wake that follows shows the fresh post without a pop-in.
    private var remotePanelOff = false
    /// Whether this session should report itself present/visible: the room
    /// must be active AND the panel not held off by HA. Also gates
    /// imageReady — an absent session is outside the readiness barrier, and
    /// reporting would drive the channel forward for a panel nobody sees.
    private var effectiveVisible: Bool { isRoomActive && !remotePanelOff }

    /// Catch up after this session becomes present again. Reporting
    /// present=true (see the caller) makes the server commit the post it
    /// dark-advanced to while we were away and broadcast it; we adopt that
    /// fresh post through the normal playback path (which re-reports
    /// imageReady on render). We just nudge reconciliation in case a
    /// `playback` frame already landed. No client-side wake-advance.
    private func rejoinReadinessBarrier() {
        // The post we're about to adopt is the one the server dark-advanced to
        // while we were away, not an advance the user watched happen. Cut to it
        // instead of dissolving the stale image into it — a crossfade on
        // re-entry advertises the very staleness the dark advance hides.
        armInstantTransition()
        reconcileWithServer()

        // Sign of life. If reconcile didn't move us — the server is parked on
        // the post we already show, or nothing new arrived while we were away —
        // then nothing else is going to report for this channel. Re-reporting
        // what's on screen is idempotent: the server drops a late imageReady for
        // a channel that is no longer loading.
        if let post = currentPost,
           serverCurrentPost == nil || serverCurrentPost?._id == post._id {
            reportImageReady(for: post)
        }
    }

    /// A `displayState` frame addressed to this window's deviceId.
    func handlePanelState(on: Bool) {
        let off = !on
        guard off != remotePanelOff else { return }
        remotePanelOff = off
        AppLogger.remoteViewer.info("displayState \(on ? "on" : "off", privacy: .public) for deviceId=\(self.slideshowDeviceId, privacy: .private(mask: .hash))")
        scheduleSceneStateReport(effectiveVisible)
        if effectiveVisible { rejoinReadinessBarrier() }
    }

    /// Coalesces scene-state changes so visionOS scenePhase flutter
    /// (active→inactive→background→inactive→active cycles fire in rapid
    /// succession around a window dismiss or gaze shift) doesn't produce a
    /// dozen reports before settling.
    private var sceneStateDebounce: Task<Void, Never>?

    /// Report this window's scene state. `present` drives the slideshow — while
    /// every display on this deviceId is absent the server dark-advances one
    /// post and parks, so the next arrival sees a fresh image (no client-side
    /// wake-advance). `visibility` is home-location telemetry (the HA motion
    /// sensor). For a VP window both track the same condition — the window is
    /// showing the slideshow iff someone's here to see it — so they go together.
    ///
    /// This is a report of *this window's* state, not a wire frame. The socket
    /// owns deduplication and post-reconnect replay for every deviceId carried
    /// over the pooled connection.
    private func scheduleSceneStateReport(_ active: Bool, immediate: Bool = false) {
        sceneStateDebounce?.cancel()
        if immediate {
            sceneStateDebounce = nil
            sendSceneStateNow(active)
            return
        }
        sceneStateDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.sendSceneStateNow(active)
        }
    }

    private func sendSceneStateNow(_ active: Bool) {
        wsSession?.reportSceneState(deviceId: slideshowDeviceId, present: active, visible: active)
    }

    // MARK: - Remote Actions

    func saveCurrentPost() {
        guard let post = saveablePost else { return }
        Task {
            do {
                let result = try await apiClient.save(baseURL: config.apiEndpoint, postId: post._id, accessToken: config.accessToken)
                AppLogger.remoteViewer.info("Saved post \(post._id, privacy: .private(mask: .hash)): \(result)")
                showToast(result)
            } catch {
                AppLogger.remoteViewer.error("Failed to save post: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                showToast("Save failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func blockCurrentPost() {
        guard let post = currentPost else { return }
        // Gallery mode has no server to notify, so it needs the local filter.
        // Remote mode must NOT keep one (protocol.md "Blocklist is server-side
        // and invisible to clients"): the server already drops the post from
        // every channel's queue, and a local set would additionally filter a
        // post the server later re-serves on purpose.
        if isGalleryMode {
            blockedPosts.insert(post._id)
        }
        wsSession?.sendBlock(postId: post._id)
        showToast("Blocked post #\(post._id)")
        if isGalleryMode {
            // No server to advance us — pull the next from the local queue.
            goToNextImage()
        }
        // Remote mode is purely server-driven (see start()/serverDriven): the
        // server removes the blocked post and pushes a fresh, ratio-appropriate
        // `current` via the next playback frame. Advancing locally would race
        // that and surface a prefetched post ignoring the window's advertised
        // ratio (a wide image in a tall window), so we do nothing here.
    }

    /// Advance one post forward. In gallery mode there's no server, so pull the
    /// next from the local queue. In remote mode the engine is purely
    /// server-driven (see start()/serverDriven), so a local advance would race
    /// the orchestrator and surface a prefetched post that ignores the window's
    /// advertised ratio. Instead emit `requestNext`: the protocol lets any
    /// session advance its own channel, and the server replies with a fresh,
    /// ratio-appropriate `current` that drives the transition via the playback
    /// frame. (This is a manual user action, not a wake-advance — the protocol's
    /// "no client-side wake-advance" rule doesn't apply.)
    func advanceToNext() {
        if isGalleryMode {
            goToNextImage()
        } else {
            wsSession?.sendRequestNext()
        }
    }

    /// Ask the server to reshuffle the current channel's post order.
    func reshuffle() {
        wsSession?.sendReshuffle()
        showToast("Reshuffling…")
    }

    func toggleClock() {
        showClock.toggle()
    }

    func toggleSensors() {
        showSensors.toggle()
    }

    // MARK: - Bindable Display Toggles
    //
    // Bridging properties for the Viewer tab of VisualAdjustmentsPopover.
    // Several display flags live on both the engine (runtime source of truth)
    // and `config` (persistence). Writing through these setters keeps the
    // two in sync and triggers `onConfigChanged` so the change is saved.

    var displayShowClock: Bool {
        get { showClock }
        set {
            showClock = newValue
            if config.showClock != newValue {
                config.showClock = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayShowSensors: Bool {
        get { showSensors }
        set {
            showSensors = newValue
            if config.showSensors != newValue {
                config.showSensors = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableKenBurns: Bool {
        get { enableKenBurns }
        set {
            enableKenBurns = newValue
            if config.enableKenBurns != newValue {
                config.enableKenBurns = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableDynamicBrightness: Bool {
        get { enableDynamicBrightness }
        set {
            enableDynamicBrightness = newValue
            if config.enableDynamicBrightness != newValue {
                config.enableDynamicBrightness = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableDiorama: Bool {
        get { enableDiorama }
        set {
            enableDiorama = newValue
            if config.enableDiorama != newValue {
                config.enableDiorama = newValue
                onConfigChanged?(config)
            }
            // When toggled on while a post is already displayed, kick off
            // foreground generation so the overlay appears without waiting
            // for the next slide to advance.
            if newValue, let post = currentPost, let image = currentImage, currentForegroundTexture == nil {
                generateDioramaForeground(post: post, image: image, isCurrent: true)
            }
        }
    }

    var displayTransparentBackground: Bool {
        get { config.transparentBackground }
        set {
            if config.transparentBackground != newValue {
                config.transparentBackground = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayUseAspectRatio: Bool {
        get { useAspectRatio }
        set {
            useAspectRatio = newValue
            if config.useAspectRatio != newValue {
                config.useAspectRatio = newValue
                onConfigChanged?(config)
            }
            // Remote mode: re-advertise so the server adds/drops its
            // `ratio:lo..hi` clause immediately. Without this the toggle only
            // takes effect on the next reconnect. Gallery mode filters locally
            // in fetchMorePosts, so no server round-trip is needed.
            if !isGalleryMode {
                sendSlideshowConfigToServer()
            }
        }
    }

    var displayDelay: TimeInterval {
        get { delay }
        set {
            // Optimistic local update for slider responsiveness.
            delay = newValue
            if isGalleryMode {
                // No server to defer to, so persist locally.
                if config.delay != newValue {
                    config.delay = newValue
                    onConfigChanged?(config)
                }
            } else {
                // Remote mode — interval is server-managed. Push to the
                // orchestrator; its clamped echo (2000–3600000 ms) lands
                // on the next playback frame and overwrites `delay`.
                // config.delay is stale here and not re-persisted.
                sendSlideshowConfigToServer()
            }
        }
    }

    // MARK: - Display Sync (subclass hook)

    override func onPostTransitioned(post: RemotePost, url: URL) {
        // New media on screen — drop any prior video's clip-length state. A
        // video reports its length asynchronously (player loadedmetadata),
        // and often *before* this commit (the incoming player mounts during
        // the crossfade), so keep a duration already recorded for this post.
        videoDurationTimeoutTask?.cancel()
        videoDurationTimeoutTask = nil
        pendingVideoImageReadyPost = nil
        if currentVideoDurationPostId != post._id {
            currentVideoDurationMs = nil
            currentVideoDurationPostId = nil
            currentVideoLoops = true
        }

        // Tell the server we've finished transitioning to this post. The
        // orchestrator's readiness barrier starts the dwell on the *first*
        // present session to report (first-ready-wins), so this is what keeps
        // the channel on wall-clock cadence — without it the server rides its
        // 15 s readiness-timeout fallback every cycle and, after three such
        // cycles with no reports at all, stalls the channel outright. (Skip when
        // applying an incoming local sync: the
        // transition was driven by another window, not by our own engine
        // ticking, and that window already reported.)
        if !isApplyingIncomingSync {
            reportImageReady(for: post)
        } else {
            AppLogger.remoteViewer.debug("imageReady suppressed for post \(post._id, privacy: .private(mask: .hash)) — applying incoming local sync")
        }

        // If the server advanced again while this image was loading, the
        // deferred advance lands now that we're back in .displaying.
        reconcileWithServer()

        // Local broadcast — gallery mode only. In remote mode each window
        // owns its own WS, and the server's per-deviceId channel (or the
        // displaySync merge driver) already pushes the same `playback`
        // frames to every connected window. Running local sync there too
        // would race those broadcasts and pull peer windows out of sync
        // with other clients (browser kiosks, node-display).
        guard isGalleryMode, enableDisplaySync, !isApplyingIncomingSync else { return }

        let payload = LocalDisplaySyncPayload(
            currentPost: post,
            currentImage: currentImage,
            currentImageURL: url,
            currentMediaType: currentMediaType,
            isCurrentPostAnimatedGIF: isCurrentPostAnimatedGIF,
            prefetched: prefetchedImages,
            cachedPosts: cachedPosts,
            delay: delay
        )
        SlideshowSyncHub.shared.broadcastLocalSync(from: self, payload: payload)
    }

    /// Report (or defer) `imageReady` for the post currently on screen,
    /// honouring scene-phase visibility and the 3D generation gate. Called
    /// both when the engine transitions to a new post and when the window
    /// returns to active (so the server's readiness barrier — which re-includes
    /// this session the moment it reports visibility=true — gets the report it
    /// would otherwise wait on indefinitely).
    private func reportImageReady(for post: RemotePost) {
        guard effectiveVisible else {
            // Session is hidden (window backgrounded, or HA holds the panel
            // off). The server already knows via the visibility=false report
            // and won't hold the readiness barrier on this session, so
            // reporting imageReady here would needlessly drive the channel
            // forward for a window nobody is looking at. Drop any pending
            // deferral too — it gets re-evaluated on the next effective-
            // visibility flip.
            pendingImageReadyPost = nil
            pendingVideoImageReadyPost = nil
            videoDurationTimeoutTask?.cancel()
            videoDurationTimeoutTask = nil
            spatial3DReadyTimeoutTask?.cancel()
            spatial3DReadyTimeoutTask = nil
            AppLogger.remoteViewer.debug("imageReady skipped for post \(post._id, privacy: .private(mask: .hash)) — session hidden")
            return
        }
        if case .video = currentMediaType, knownDurationMs(for: post) == nil {
            // Real AVPlayer video on screen but its clip length isn't known
            // yet (the video-in-<img> path has no duration source and reports
            // immediately, treated as an animated image). Hold the
            // report until the duration arrives — from the playback frame's
            // `current.durationMs` (applyServerVideoDuration) or, failing that,
            // the player (onVideoDurationKnown) — so the server can delay the
            // slideshow for a clip longer than the interval.
            pendingVideoImageReadyPost = post
            AppLogger.remoteViewer.debug("imageReady deferred for post \(post._id, privacy: .private(mask: .hash)) — waiting on video duration")
            // Watchdog: the duration can legitimately never arrive (load
            // failure after retries, non-finite duration on a stream). Don't
            // park the server's readiness barrier forever — report without a
            // duration after a grace period and let the channel use its
            // normal interval.
            videoDurationTimeoutTask?.cancel()
            videoDurationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                guard let pending = self.pendingVideoImageReadyPost, pending._id == post._id else { return }
                self.pendingVideoImageReadyPost = nil
                self.videoDurationTimeoutTask = nil
                guard self.effectiveVisible else {
                    AppLogger.remoteViewer.debug("imageReady (duration timeout) dropped for post \(post._id, privacy: .private(mask: .hash)) — session hidden")
                    return
                }
                // Send directly — going back through reportImageReady would
                // just re-enter the duration deferral and re-arm this timer.
                if self.wsSession == nil {
                    AppLogger.remoteViewer.warning("Video duration never reported for post \(post._id, privacy: .private(mask: .hash)) and wsSession is nil — imageReady not sent")
                } else {
                    AppLogger.remoteViewer.warning("Video duration never reported for post \(post._id, privacy: .private(mask: .hash)) — sending imageReady without duration after 10 s")
                    self.wsSession?.sendImageReady(postId: pending._id, durationMs: nil)
                }
            }
            return
        }
        if isSlideshow3DActive, !isCurrentPostAnimatedGIF,
           let image = currentImage,
           !generatedImageIds.contains(ObjectIdentifier(image)) {
            // Defer until the slot reports generation complete, so the channel
            // doesn't advance ahead of the slowest 3D client and play the depth
            // conversion animation inside the next crossfade.
            //
            // Bounded, though: the barrier is first-ready-wins with a
            // readiness-timeout fallback (`readyTimeoutMs`, 15 s by default),
            // and three consecutive timeouts with no reports *stall* the
            // channel. Deferring past that budget gets us the worst of both —
            // the frame is promoted without us anyway, and we're on our way to
            // stalling the room — so give up just under it and report.
            //
            // Animated media (GIF/WebP) is excluded: the spatial-3D layer only
            // renders for a static `.image`, so it never generates a depth map
            // for animated content and `notifySpatial3DGenerated` never fires.
            // Without this guard an animated post in 3D mode would defer
            // imageReady forever and stall the channel (videos return above;
            // static photos generate and release — only animated got stuck).
            pendingImageReadyPost = post
            AppLogger.remoteViewer.debug("imageReady deferred for post \(post._id, privacy: .private(mask: .hash)) — waiting on 3D generation")
            spatial3DReadyTimeoutTask?.cancel()
            spatial3DReadyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.spatial3DReadyGrace))
                guard !Task.isCancelled, let self else { return }
                guard let pending = self.pendingImageReadyPost, pending._id == post._id else { return }
                self.pendingImageReadyPost = nil
                self.spatial3DReadyTimeoutTask = nil
                guard self.effectiveVisible else { return }
                AppLogger.remoteViewer.warning("3D generation still pending for post \(post._id, privacy: .private(mask: .hash)) — reporting imageReady after \(Self.spatial3DReadyGrace, privacy: .public) s to stay inside the server's readiness budget")
                self.wsSession?.sendImageReady(postId: pending._id)
            }
        } else {
            pendingImageReadyPost = nil
            spatial3DReadyTimeoutTask?.cancel()
            spatial3DReadyTimeoutTask = nil
            if wsSession == nil {
                AppLogger.remoteViewer.warning("imageReady not sent for post \(post._id, privacy: .private(mask: .hash)) — wsSession is nil")
            } else {
                AppLogger.remoteViewer.debug("imageReady sent for post \(post._id, privacy: .private(mask: .hash))")
                wsSession?.sendImageReady(postId: post._id, durationMs: knownDurationMs(for: post))
            }
        }
    }

    /// Called by the video player once the current clip's length is known
    /// (loadedmetadata). Records the duration so reportImageReady can pass it
    /// to the server, decides whether the clip should loop, and releases the
    /// imageReady that was deferred waiting on it.
    @MainActor
    func onVideoDurationKnown(_ seconds: Double, for post: RemotePost) {
        guard seconds.isFinite, seconds > 0 else {
            AppLogger.remoteViewer.warning("Video duration unusable for post \(post._id, privacy: .private(mask: .hash)): \(seconds, privacy: .public)")
            return
        }
        // A late callback from a torn-down player for a post we've moved past
        // is irrelevant — only the post on screen (or crossfading in as
        // `nextPost`, since loadedmetadata typically beats the commit) matters.
        guard currentPost?._id == post._id || nextPost?._id == post._id else {
            AppLogger.remoteViewer.debug("Stale video duration ignored for post \(post._id, privacy: .private(mask: .hash))")
            return
        }
        let ms = Int((seconds * 1000).rounded())
        currentVideoDurationMs = ms
        currentVideoDurationPostId = post._id
        AppLogger.remoteViewer.debug("Video duration known for post \(post._id, privacy: .private(mask: .hash)): \(ms, privacy: .public) ms")
        // Loop only if the clip fits inside the interval; a longer clip plays
        // through once and the server delays the advance until it ends.
        currentVideoLoops = Double(ms) <= delay * 1000
        if let pending = pendingVideoImageReadyPost, pending._id == post._id {
            videoDurationTimeoutTask?.cancel()
            videoDurationTimeoutTask = nil
            pendingVideoImageReadyPost = nil
            reportImageReady(for: pending)
        }
    }

    // MARK: - Slideshow 3D Generation Gate

    /// Called by `SlideshowSpatial3DLayer` whenever a slot finishes
    /// generating its IPC depth map. If the visible image is the one
    /// the engine just transitioned to and we were holding an
    /// `imageReady` event waiting on this generation, send it now.
    @MainActor
    func notifySpatial3DGenerated(image: UIImage) {
        let id = ObjectIdentifier(image)
        generatedImageIds.insert(id)
        // Cap at 4 — covers both slots plus a small backlog from a fast
        // re-cycle without growing unbounded across a long session.
        if generatedImageIds.count > 4 {
            generatedImageIds.removeFirst()
        }
        guard let pending = pendingImageReadyPost,
              let current = currentImage,
              ObjectIdentifier(current) == id else { return }
        pendingImageReadyPost = nil
        spatial3DReadyTimeoutTask?.cancel()
        spatial3DReadyTimeoutTask = nil
        // Don't advance the channel for a session that went hidden (window
        // inactive or panel held off) while its 3D depth map was generating.
        guard effectiveVisible else {
            AppLogger.remoteViewer.debug("imageReady dropped for post \(pending._id, privacy: .private(mask: .hash)) — session hidden")
            return
        }
        AppLogger.remoteViewer.debug("imageReady released for post \(pending._id, privacy: .private(mask: .hash)) — 3D generation completed")
        wsSession?.sendImageReady(postId: pending._id)
    }

    // MARK: - Local Display Sync (receiver)

    /// Adopt a display-sync snapshot from another local slideshow instance.
    /// Images/data are reference-typed so no bitmap copies occur. Only
    /// mirrors cheap live state — pause/play and visibility are not synced.
    func applyLocalDisplaySync(_ payload: LocalDisplaySyncPayload) {
        // Gallery mode only — see broadcast site for rationale.
        guard isGalleryMode else { return }
        // Display Sync OFF → this instance is independent; skip incoming syncs
        guard enableDisplaySync else { return }
        // Engine must be running — don't apply while idle/stopped
        guard state != .idle, state != .stopped else { return }

        isApplyingIncomingSync = true
        defer { isApplyingIncomingSync = false }

        // Mirror the slideshow interval
        if delay != payload.delay {
            delay = payload.delay
        }

        // (No cursor mirroring — the server owns pagination.)

        // Mirror the cached post queue (future query results)
        cachedPosts = payload.cachedPosts

        // Mirror prefetched images by reference (no copy)
        prefetchedImages = payload.prefetched

        // Mirror the currently-displayed post if it differs.
        // Use displayImage so the crossfade is consistent.
        guard let newPost = payload.currentPost,
              let newImage = payload.currentImage,
              let newURL = payload.currentImageURL,
              newPost._id != currentPost?._id else { return }

        // Don't interrupt a navigation in progress (previousImage/jump)
        if hasPendingNavigation { return }

        // If currently in transitioning state, wait — our own displayImage
        // would overlap. Swap directly instead.
        if state == .transitioning {
            currentImage = newImage
            currentPost = newPost
            currentMediaType = payload.currentMediaType
            isCurrentPostAnimatedGIF = payload.isCurrentPostAnimatedGIF
            // Rebuild the Metal texture to match the swapped image so the
            // window view doesn't keep rendering the previous post's texture.
            Task { [weak self] in
                guard let self else { return }
                let tex = await Self.makeTexture(from: newImage)
                // Only apply if the image is still the displayed one — a
                // navigation/sync may have moved on in the meantime.
                if self.currentImage === newImage {
                    self.currentTexture = tex
                }
            }
            return
        }

        isCurrentPostAnimatedGIF = payload.isCurrentPostAnimatedGIF
        Task { [weak self] in
            guard let self else { return }
            self.isApplyingIncomingSync = true
            await self.displayImage(newImage, post: newPost, url: newURL, mediaType: payload.currentMediaType)
            self.isApplyingIncomingSync = false
        }
    }

    // MARK: - Private: WebSocket

    private func setupWebSocket() {
        let wsURL = config.effectiveWsEndpoint
        guard !wsURL.isEmpty else { return }

        // Each viewer instance gets its own logical session id. The
        // underlying WebSocket connection is shared with any other
        // viewers pointed at the same endpoint — see SlideshowSyncHub.
        let session = SlideshowSyncHub.shared.subscribeWS(endpoint: wsURL, sessionId: slideshowSessionId)
        session.onMessage = { [weak self] message in
            self?.handleWSMessage(message)
        }
        // Replay channel binding on every (re)connection. The server
        // forgets which channel a session belongs to when the socket
        // dies, so without this the auto-reconnect succeeds at the
        // protocol level but never receives another `playback` frame
        // and the slideshow gets stuck on the last image.
        session.onConnected = { [weak self] in
            guard let self else { return }
            self.sendSlideshowConfigToServer()
            // Report the actual current scene state, not a blanket `true`.
            // If the WS reconnects while the window is backgrounded or the HA
            // panel is held off (e.g. server-killed connection during sleep),
            // an unconditional present=true here would un-dark a slideshow the
            // user can't see. effectiveVisible captures both cases.
            //
            // The socket re-states every session's presence and each device's
            // aggregate visibility after reconnect, so this is usually a no-op
            // confirmation unless our state changed while disconnected.
            self.scheduleSceneStateReport(self.effectiveVisible)
        }
        wsSession = session

        // If the connection was already alive when we attached (a sibling
        // viewer brought it up first), the session's onConnected won't
        // fire on its own — flip the switch ourselves so the orchestrator
        // gets our slideshowConfig immediately.
        if session.isConnected {
            sendSlideshowConfigToServer()
            scheduleSceneStateReport(effectiveVisible)
        }

        // Push later switches from the shared ModTagManager out to this
        // viewer's WS so any window's preset change reaches the server.
        modTagManager?.addSendHandler(id: engineId) { [weak self] tags in
            self?.wsSession?.sendSetModTags(tags: tags)
        }

        // Same wiring for tag list switches initiated from the viewer
        // ornament. The TagListManager only fires this on user-initiated
        // changes — server-pushed `currentTagList` frames go through a
        // separate path and are not echoed back.
        tagListManager?.addSendHandler(id: engineId) { [weak self] listNumber in
            self?.wsSession?.sendSetTagList(listNumber: listNumber)
        }
    }

    /// Register (or re-register) this session with the orchestrator. The
    /// server creates or joins us to this window's unique channel and
    /// broadcasts a `playback` frame which our handler picks up. Mod tags
    /// ride along so the orchestrator's first refill query already includes
    /// them — no immediate-after refill round-trip from a separate
    /// setModTags. Called once on initial connect and again from
    /// `onConnected` after every auto-reconnect.
    private func sendSlideshowConfigToServer() {
        let intervalMs = max(2000, Int(delay * 1000))
        // No width/height/convert: Hypnos fetches sources at native
        // resolution and downscales on-device (`effectiveDownloadResolution`).
        // Advertising a size or `convert` only mis-keyed the server's prefetch
        // and, under convert, would flip animated posts to mp4.
        wsSession?.sendSlideshowConfig(
            deviceId: slideshowDeviceId,
            interval: intervalMs,
            bright: false,
            ratio: currentRatioValue(),
            modTags: modTagManager?.activeTags ?? []
        )
    }

    /// Advertise the window's raw aspect ratio (width/height). The server owns
    /// the matching tolerance and expands this into its `ratio:lo..hi` query
    /// clause, so the client sends a bare number rather than a baked-in window.
    /// Returns nil if the window hasn't reported a usable size yet, or if
    /// "Fit to Window Aspect Ratio" is off — in which case we must NOT advertise
    /// a ratio, or the server keeps filtering candidates to our aspect (the
    /// width/height we also send drive only server-side image rescaling, never
    /// content selection). Sending nil drops the server's `ratio:lo..hi` clause.
    private func currentRatioValue() -> Double? {
        guard useAspectRatio else { return nil }
        let ratio = windowAspectRatio
        guard ratio.isFinite, ratio > 0 else { return nil }
        return (ratio * 10000).rounded() / 10000
    }

    /// Tracks the ratio we last advertised to the server, so we only re-send
    /// `slideshowConfig` on a meaningfully different aspect (avoids a refill
    /// storm during interactive window resize).
    private var lastSentRatio: Double?
    /// Debounce timer for resize-driven slideshowConfig re-sends. A slow
    /// drag through several ±8% threshold crossings would otherwise fire
    /// one clearAndRefill per crossing on the server.
    private var ratioResendTask: Task<Void, Never>?

    override func updateWindowAspectRatio(_ size: CGSize) {
        let prev = windowAspectRatio
        super.updateWindowAspectRatio(size)
        guard !isGalleryMode else { return }
        let newRatio = windowAspectRatio
        guard newRatio.isFinite, newRatio > 0 else { return }
        // Anchor for comparison: prefer the last value we actually sent, fall
        // back to the previous aspect so the first change after start still
        // triggers a send.
        let anchor = lastSentRatio ?? prev
        guard anchor > 0 else {
            lastSentRatio = newRatio
            sendSlideshowConfigToServer()
            return
        }
        // 8% threshold mirrors a step the server's ±15% range would actually
        // shift the candidate set. Debounce so an interactive drag through
        // multiple crossings only sends once when the user settles.
        guard abs(newRatio - anchor) / anchor > 0.08 else { return }
        ratioResendTask?.cancel()
        ratioResendTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let r = self.windowAspectRatio
            guard r.isFinite, r > 0 else { return }
            self.lastSentRatio = r
            self.sendSlideshowConfigToServer()
        }
    }

    private func handleWSMessage(_ message: RemoteWSMessage) {
        switch message {
        case .tagLists(let lists):
            guard let tlm = tagListManager else { break }
            if !lists.isEmpty && tlm.tagLists != lists {
                tlm.tagLists = lists
                tlm.clampActiveIndex()
                onCatalogReceived?(lists)
                AppLogger.remoteViewer.info("Server pushed tagLists: \(lists.count, privacy: .public) lists")
                showToast("Loaded \(lists.count) tag lists from server")
            }

        case .currentTagList(let index):
            // Standalone (legacy) server list change. The current list is
            // server-tracked, so just apply it.
            if let tlm = tagListManager {
                if tlm.applyServerIndex(index) {
                    AppLogger.remoteViewer.info("Server changed tag list to \(index, privacy: .public)")
                }
            }

        case .showText(let text, let bgColor, let imageUrl):
            onOpenAlertWindow?(text, bgColor, imageUrl)

        case .dismissText:
            onDismissAlertWindow?()

        case .playAudio(let url):
            // Window-independent: AudioServicesPlayAlertSound runs at the
            // app level so the chime fires regardless of which hypnos
            // window (if any) is in the user's current room.
            RemoteNotificationSound.shared.play(remoteURL: url)

        case .stopAudio:
            // No client-side knob today — alert sounds are short and
            // self-terminating. Kept here so the switch stays exhaustive.
            break

        case .sensorUpdate:
            break

        case .refresh:
            // Protocol: `refresh` means "reload" (the web kiosk reloads its
            // page), not "advance". Drop the warm caches so stale lookahead is
            // rebuilt, then let the server drive: reconcileWithServer re-enters
            // .loading only if the server's current differs from ours, and the
            // next playback frame repopulates the queue. A blind goToNextImage
            // here would race the server and surface a wrong-ratio prefetched
            // post — the same bug as the block/next paths.
            cachedPosts.removeAll()
            prefetchedImages.removeAll()
            contentProvider?.resetPagination()
            reconcileWithServer()

        case .playback(let payload):
            handlePlaybackFrame(payload)

        case .searchEmpty(let query):
            AppLogger.remoteViewer.warning("WS searchEmpty: refill returned zero rows for query \"\(query)\"")
            showToast("No images match: \(query)", isError: true)

        case .displayState(let target, let on):
            // HA turned this window's panel off/on. Off pauses the channel
            // (visibility=false) while keeping the current image rendered —
            // no teardown — so the wake that follows resumes without pop-in.
            guard target == slideshowDeviceId else { break }
            handlePanelState(on: on)

        case .fatalAuthError(let reason):
            // Server closed the upgrade with 1008. The WS client has
            // already halted reconnects; surface the reason so the user
            // can fix the Access Token instead of staring at a blank
            // viewer wondering why nothing is loading.
            AppLogger.remoteViewer.error("WS auth rejected: \(reason)")
            showToast(reason, isError: true)
        }
    }

    /// A `playback` frame from the orchestrator. Updates interval, tag
    /// list, merge-driver status, and feeds the engine's queue with the
    /// server's `current` / `next` posts.
    private func handlePlaybackFrame(_ payload: [String: Any]) {
        if let until = playbackSuppressedUntil {
            if Date() < until {
                AppLogger.remoteViewer.info("playback: suppressed (history jump active)")
                return
            }
            playbackSuppressedUntil = nil
        }
        // Interval — the channel timer source of truth. Convert ms → seconds.
        if let intervalMs = payload["interval"] as? Int, intervalMs > 0 {
            let newDelay = TimeInterval(intervalMs) / 1000.0
            if delay != newDelay { delay = newDelay }
        }

        // Tag list — server-authoritative. The backend persists each channel's
        // current list and reports it here; apply it to this window.
        if let listNumber = payload["currentList"] as? Int,
           let tlm = tagListManager {
            _ = tlm.applyServerIndex(listNumber)
        }

        // Merge driver — server tells us who, if anyone, currently holds
        // the displaySync claim and is broadcasting to every channel.
        serverPrimaryDeviceId = payload["mergeDriver"] as? String

        let provider = contentProvider as? RemoteContentProvider
        let current = postFromPlaybackEntry(payload["current"])
        let next = postFromPlaybackEntry(payload["next"])

        let stateStr = "\(state)"
        AppLogger.remoteViewer.info("playback: current=\(current?._id, privacy: .private(mask: .hash)).\(current?.file_ext, privacy: .public) next=\(next?._id, privacy: .private(mask: .hash)).\(next?.file_ext, privacy: .public) primary=\(self.serverPrimaryDeviceId, privacy: .private(mask: .hash)) myDevice=\(self.slideshowDeviceId, privacy: .private(mask: .hash)) engineState=\(stateStr, privacy: .public)")

        // `upcoming` is the server's full look-ahead (typically 4 deep) and is
        // free to consume — the engine prefetches 3 ahead, so feeding it only
        // current+next left the buffer chronically one deep and dependent on the
        // next frame arriving on time. Duplicates are dropped by the provider.
        let upcoming = (payload["upcoming"] as? [Any])?.compactMap(postFromPlaybackEntry) ?? []

        if let cur = current {
            // The server's indexed clip length for a video. Prefer it over the
            // player's demuxer: a live-transcoded clip arrives as fragmented MP4
            // with no duration in its header, so the player reports 0/NaN, and
            // we'd sit out the 10 s watchdog and then report no duration at all —
            // letting the server cut a long clip off at the plain interval.
            if let ms = payload["current"].flatMap(playbackDurationMs) {
                applyServerVideoDuration(ms, for: cur._id)
            }
            // Keep the lookahead warm, then hand the server's current to the
            // engine. The engine is server-paced (no local dwell clock), so
            // setServerCurrent is the sole advance trigger: it advances to
            // `cur` when in a safe state and defers otherwise, converging via
            // reconcileWithServer from onPostTransitioned / onBecameActive.
            // Because the engine only ever transitions to a server `current`,
            // the post it displays — and therefore the id it reports in
            // imageReady — always matches what the server is waiting on.
            let announced = [cur] + (next.map { [$0] } ?? []) + upcoming
            provider?.enqueueFromPlayback(announced)
            // Evict buffered images the server moved past *before* kicking
            // prefetch, so the freed slots refill in the same pass. Without
            // this, stranded entries (double-download races, server skips)
            // accumulate until they fill the buffer and prefetch — and the 3D
            // layer's look-ahead — wedges permanently.
            pruneStalePrefetchedImages(keepingPostIds: Set(announced.map(\._id)))
            // Record the look-ahead so the 3D layer's `peekedNextImage`
            // resolves the real next post (not a stale prefetch-buffer head).
            setServerNext(next)
            triggerPrefetch()
            setServerCurrent(cur)
        } else if let n = next {
            let announced = [n] + upcoming
            provider?.enqueueFromPlayback(announced)
            pruneStalePrefetchedImages(keepingPostIds: Set(announced.map(\._id)))
            setServerNext(n)
            triggerPrefetch()
        }
    }

    /// `durationMs` off a playback entry (present on video posts whose length
    /// the library indexed; absent for images and for a library that indexed 0).
    private func playbackDurationMs(_ raw: Any?) -> Int? {
        guard let dict = raw as? [String: Any] else { return nil }
        if let ms = dict["durationMs"] as? Int { return ms > 0 ? ms : nil }
        if let ms = dict["durationMs"] as? Double, ms > 0 { return Int(ms.rounded()) }
        return nil
    }

    /// Adopt a server-supplied clip length and release any `imageReady` that was
    /// deferred waiting on the player to report one.
    private func applyServerVideoDuration(_ ms: Int, for postId: Int) {
        currentVideoDurationMs = ms
        currentVideoDurationPostId = postId
        // Loop only if the clip fits inside the interval; a longer clip plays
        // through once and the server delays the advance until it ends.
        currentVideoLoops = Double(ms) <= delay * 1000
        AppLogger.remoteViewer.debug("Server-indexed duration for post \(postId, privacy: .private(mask: .hash)): \(ms, privacy: .public) ms")
        guard let pending = pendingVideoImageReadyPost, pending._id == postId else { return }
        videoDurationTimeoutTask?.cancel()
        videoDurationTimeoutTask = nil
        pendingVideoImageReadyPost = nil
        reportImageReady(for: pending)
    }

    /// The clip length we know for `post`, if any. Keyed by id so a duration
    /// recorded for one post can't be reported against another (the server can
    /// announce a new `current` before we finish displaying the previous one).
    private func knownDurationMs(for post: RemotePost) -> Int? {
        guard currentVideoDurationPostId == post._id else { return nil }
        return currentVideoDurationMs
    }

    /// Jump to a post chosen from the shared history grid and suppress
    /// incoming `playback` frames for one full interval so the room's tick
    /// doesn't immediately overwrite the user's selection.
    func jumpToHistoryEntry(_ entry: RemoteHistoryEntry) {
        let post = RemotePost(
            _id: entry.id, file_ext: entry.ext, tags: [],
            rating: nil, image_width: nil, image_height: nil,
            fav_count: nil, md5: nil, parent_id: nil, score: nil,
            ratio: nil, path: nil, duration: nil
        )
        playbackSuppressedUntil = Date().addingTimeInterval(delay)
        jumpToHistoryPost(post)
    }

    private func postFromPlaybackEntry(_ raw: Any?) -> RemotePost? {
        guard let dict = raw as? [String: Any],
              let id = dict["id"] as? Int else { return nil }
        let ext = dict["ext"] as? String ?? ""
        return RemotePost(
            _id: id, file_ext: ext, tags: [],
            rating: nil, image_width: nil, image_height: nil,
            fav_count: nil, md5: nil, parent_id: nil, score: nil,
            ratio: nil, path: nil, duration: nil
        )
    }
}
