/*
 Hypnos - tvOS fullscreen video player

 `AVPlayerViewController` rather than the native Metal path used elsewhere
 in the app: on tvOS it already gives the platform's own transport UI,
 scrubbing, and Menu-button dismissal for free, which is exactly the 10-foot
 experience this needs and none of `VideoWindowView`'s ornament/gesture
 machinery is built for a remote anyway (see `Hypnos/CLAUDE.md` "tvOS").

 There is no WebKit fallback on tvOS (`Hypnos/CLAUDE.md` "tvOS"), so this
 plays through AVFoundation only — but it does follow the same two moves the
 other players make before handing AVFoundation a URL:

 1. **Auth.** Every AVFoundation path in this app goes through
    `MediaAuthorization.shared.asset(for:)` (Hypnos commit ea220b7) so a
    Stash server behind a login, or Nextcloud's Basic auth, doesn't 401 —
    building a bare `AVPlayerItem(url:)` here would silently break exactly
    those two sources.
 2. **Stream-URL strategy.** `GalleryVideo.streamURL` is the original file;
    `NativeVideoDecodeProbe` decides whether AVFoundation can actually open
    it (VP9 in MP4 may now decode thanks to the supplemental decoder
    registered at launch — see `HypnosApp.init` — but WebM containers still
    can't). When it can't, and unlike the WebKit-based players elsewhere,
    there is no second player tier here — the *only* fallback is Stash's
    live HLS transcode (`GalleryVideo.transcodeStreamURL`). A source with
    neither simply can't play on tvOS; the view reports that rather than
    presenting a stuck black screen.

 A Photos-sourced video is a `photos-asset:///` identity, not something
 AVPlayer can open at all, so it is resolved to a real file URL first via
 `PhotosAssetStore`, the same as `VideoWindowModel.resolvePlaybackRenderer`.

 Subtitles are the app's own, as in every other player: a
 `SubtitleController` over `SubtitleSource.forVideo` (a Jellyfin item's
 streams, a Stash scene's captions, a local file's sidecars), drawn in the
 player's `contentOverlayView` so they sit inside the picture and under the
 transport bar, and picked from a Subtitles menu in the transport bar.
 AVKit has nothing to offer for most of these anyway: a Jellyfin remux's
 HLS carries no subtitle renditions.

 A YouTube video starts in YouTube's stereo and moves to its 5.1 track when
 YouTube lets that play (`YouTubeSurroundSwap`): the view changes the URL,
 and the player swaps the new item in at the playhead. If it fails, the view
 changes it back to the stereo master.
 */

#if os(tvOS)

import AVKit
import DebugTrace
import GeneratedCaptions
import SwiftUI

struct TVVideoPlayerView: View {
    let video: GalleryVideo

    /// A cap on what an adaptive stream may pick: YouTube's saved quality
    /// while its renditions are unknown (once read, a chosen size plays a
    /// copy of the master holding only it). Other sources aren't capped.
    private var maximumResolution: CGSize {
        #if HYPNOS_YOUTUBE
        if quality.isYouTube, !quality.offersChoice {
            return YouTubeQuality.maximumResolution(height: YouTubeQuality.preferred.height)
        }
        #endif
        return .zero
    }
    /// Optional periodic (position, duration, paused) callback — a no-op
    /// for every existing caller (`TVVideosTabView`'s plain
    /// `TVVideoPlayerView(video:)`); the Library tab wires it to
    /// `GenericProgressReporter` for a Jellyfin-sourced video.
    var onProgress: (Double, Double, Bool) -> Void = { _, _, _ in }
    /// Where to start, in seconds (the Library's Resume); nil plays from
    /// the beginning.
    var startSeconds: Double?
    /// Called once when playback reaches the end (the Library autoplays the
    /// next episode from here). Nil leaves the player on its last frame.
    var onPlayedToEnd: (() -> Void)?
    /// Whether playback starts out looping. On for the Videos tab's clips; off
    /// for YouTube and Library titles, which play once (and, for episodes,
    /// continue to the next). The player's Loop menu item changes it per run.
    var loops = false
    /// The speed playback starts at (the Library carries the last one to the
    /// next episode), and what is told when the viewer picks another.
    var initialSpeed: Double = 1
    var onSpeedChange: (Double) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var resolvedURL: URL?
    /// What the remux playing was opened from, for the file's own subtitles.
    @State private var remuxSource: URL?
    #if HYPNOS_YOUTUBE
    /// While surround plays: what played before it, where a failed swap
    /// goes back to when YouTube's own master can't be cut again.
    @State private var stereoURL: URL?
    /// A rendition's HDR copy failed once already: the next failure is real.
    @State private var droppedHDR = false
    #endif
    /// The transport bar's Quality menu: a Library title's levels, or a
    /// YouTube video's renditions.
    @State private var quality: TVPlayerQuality
    /// A Stash scene's rating, for the transport bar's Rating menu.
    @State private var rating: TVSceneRating?
    @State private var failureMessage: String?
    @State private var skipper = MediaSegmentSkipper()
    @State private var subtitles = SubtitleController()
    /// What the player's Info panel shows (a swipe down while it plays).
    @State private var details: PlayerDetailsLoader
    @State private var artwork: UIImage?

    init(video: GalleryVideo, onProgress: @escaping (Double, Double, Bool) -> Void = { _, _, _ in },
         startSeconds: Double? = nil, onPlayedToEnd: (() -> Void)? = nil, loops: Bool = false,
         initialSpeed: Double = 1, onSpeedChange: @escaping (Double) -> Void = { _ in }) {
        self.video = video
        self.onProgress = onProgress
        self.startSeconds = startSeconds
        self.onPlayedToEnd = onPlayedToEnd
        self.loops = loops
        self.initialSpeed = initialSpeed
        self.onSpeedChange = onSpeedChange
        _details = State(initialValue: PlayerDetailsLoader(fallback: PlayerDetails(video: video)))
        _quality = State(initialValue: TVPlayerQuality(video: video))
        _rating = State(initialValue: video.stashId.map { TVSceneRating(sceneId: $0, identity: video.identity, rating100: video.rating100) })
    }

    var body: some View {
        Group {
            if let resolvedURL {
                TVAVPlayerViewControllerRepresentable(url: resolvedURL, startSeconds: startSeconds, loops: loops,
                                                      initialSpeed: initialSpeed, onSpeedChange: onSpeedChange,
                                                      maximumResolution: maximumResolution,
                                                      segments: skipper.segments,
                                                      details: details.details, artwork: artwork,
                                                      subtitles: subtitles,
                                                      subtitleSource: { [remuxSource] in
                                                          SubtitleSource.forVideo(video, remuxing: remuxSource)
                                                      },
                                                      quality: quality, rating: rating,
                                                      onProgress: onProgress, onPlayedToEnd: onPlayedToEnd) {
                    playbackFailed()
                }
                .ignoresSafeArea()
                // Belt-and-suspenders: `AVPlayerViewController` normally handles
                // its own Menu-button exit when *presented* modally through
                // UIKit, but here it's embedded inside a SwiftUI
                // `fullScreenCover` via a plain representable, not presented
                // itself — verify on-device/simulator that Menu dismisses this,
                // and keep this handler either way.
                .onExitCommand { dismiss() }
            } else if let failureMessage {
                ContentUnavailableView(
                    "Can't Play This Video",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failureMessage)
                )
                .onExitCommand { dismiss() }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onExitCommand { dismiss() }
            }
        }
        .task {
            quality.onSwitch = { url in resolvedURL = url }
            await resolve()
            await quality.start()
            #if HYPNOS_YOUTUBE
            await swapInSurround()
            #endif
        }
        .onChange(of: resolvedURL, initial: true) { _, url in
            quality.streamURL = url
        }
        .onDisappear { quality.stop() }
        .onAppear { rating?.appModel = appModel }
        .task {
            await skipper.load(videoIdentity: video.identity)
        }
        .task(id: video.identity) {
            await details.load(PlayerDetailsSource(video: video), fallback: PlayerDetails(video: video),
                               video: video, stash: appModel.apiClient)
            artwork = await Self.artwork(for: details.details)
        }
    }

    /// The Info panel's picture: a Library title's still or poster, else
    /// the video's thumbnail.
    private static func artwork(for details: PlayerDetails) async -> UIImage? {
        var url = details.artworkURL
        if let item = details.libraryItem, let library = LibraryService.current() {
            url = library.imageURL(item: item, kind: item.kind == .episode ? .primary : .thumb, size: .poster)
                ?? library.imageURL(item: item, kind: .primary, size: .poster)
        }
        guard let url else { return nil }
        return try? await ImageLoader.shared.loadImage(from: url)
    }

    private func resolve() async {
        var source = video.streamURL

        if PhotosAssetURL.isPhotosAsset(source) {
            guard let playable = await PhotosAssetStore.shared.playableURL(for: source) else {
                failureMessage = "This video is no longer available in Photos."
                return
            }
            source = playable
            // A resolved Photos file plays directly — nothing to authenticate
            // and no server transcode to fall back to.
            resolvedURL = source
            return
        }

        let authenticated = MediaAuthorization.shared.authorizedURL(source)
        if await NativeVideoDecodeProbe.canPlayNatively(url: authenticated) {
            AppLogger.videoWindow.info("[tvOS] playing original: \(authenticated.loggableDescription)")
            #if HYPNOS_YOUTUBE
            // The master's renditions, and the saved size's copy of it.
            if quality.isYouTube {
                resolvedURL = await quality.adoptYouTubeMaster(authenticated)
                return
            }
            #endif
            resolvedURL = authenticated
            return
        }

        // An MKV/WebM the player can't open, remuxed to HLS on the device
        // (lossless, ahead of the server's transcode). A Library title only
        // when it plays the file itself, not a stream Jellyfin made for it.
        if LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) == nil
            || JellyfinLibrary.isFileStream(source),
           let remuxed = await MatroskaRemuxService.shared.playlistURL(for: authenticated, fileName: video.fileName) {
            AppLogger.videoWindow.info("[tvOS] playing the original remuxed to HLS")
            remuxSource = authenticated
            resolvedURL = remuxed
            return
        }

        guard let transcode = video.transcodeStreamURL else {
            failureMessage = "This video's format isn't supported on Apple TV, and no server transcode is available."
            return
        }
        AppLogger.videoWindow.info("[tvOS] original undecodable — falling back to server transcode")
        resolvedURL = MediaAuthorization.shared.authorizedURL(transcode)
    }

    /// The stream playing failed. A YouTube surround master goes back to
    /// stereo, and a size's HDR copy to SDR, before the viewer is told.
    private func playbackFailed() {
        #if HYPNOS_YOUTUBE
        if let stereoURL {
            AppLogger.youtube.error("[tvOS] The surround stream failed; back to stereo")
            self.stereoURL = nil
            Task { resolvedURL = await quality.youTubeStereoFallback() ?? stereoURL }
            return
        }
        if quality.isYouTube, !droppedHDR {
            droppedHDR = true
            Task {
                if let sdr = await quality.youTubeDropHDR() {
                    resolvedURL = sdr
                } else {
                    showFailure()
                }
            }
            return
        }
        #endif
        showFailure()
    }

    private func showFailure() {
        failureMessage = "This video's format isn't supported on Apple TV."
        resolvedURL = nil
    }

    #if HYPNOS_YOUTUBE
    /// YouTube's 5.1, once YouTube lets it play: the player swaps it in at
    /// the playhead (the chosen size's copy of it, when one is chosen).
    private func swapInSurround() async {
        guard let playing = resolvedURL,
              let master = quality.youTubeStereoMasterURL ?? (playing.host == "127.0.0.1" ? nil : playing),
              let surround = await YouTubeSurroundSwap.surroundMaster(for: video, playing: master),
              !Task.isCancelled else { return }
        let target = await quality.adoptYouTubeMaster(surround, isSurround: true)
        guard !Task.isCancelled, resolvedURL != nil else { return }
        AppLogger.youtube.info("[tvOS] Switching to surround")
        stereoURL = resolvedURL
        resolvedURL = target
    }
    #endif
}

private struct TVAVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    /// What plays. A new one is swapped in at the playhead.
    let url: URL
    var startSeconds: Double?
    var loops = false
    var initialSpeed: Double = 1
    var onSpeedChange: (Double) -> Void = { _ in }
    /// The largest picture an adaptive stream may pick (zero: no cap).
    var maximumResolution: CGSize = .zero
    /// Offered as the player's own contextual action (Skip Intro) while
    /// the playhead is in one.
    var segments: [LibraryMediaSegment] = []
    /// What the Info panel shows (`AVPlayerItem.externalMetadata`).
    var details: PlayerDetails?
    var artwork: UIImage?
    let subtitles: SubtitleController
    /// Where the video's subtitle tracks come from; read once, when the
    /// player is made.
    var subtitleSource: @MainActor () -> SubtitleSource? = { nil }
    /// The Quality menu's model, told how the stream is doing.
    var quality: TVPlayerQuality?
    /// A Stash scene's rating, for the Rating menu.
    var rating: TVSceneRating?
    var onProgress: (Double, Double, Bool) -> Void = { _, _, _ in }
    var onPlayedToEnd: (() -> Void)?
    var onPlaybackFailed: () -> Void = {}

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // Both observers are queued/dispatched on `.main`, so `Coordinator`
        // (`@unchecked Sendable`, like the app's other cross-boundary bridge
        // types — `SendableAVAsset`, `SendableTexture`) really is only ever
        // touched there; that conformance is what lets it cross into these
        // `@Sendable` NotificationCenter/KVO closures at all.
        let coordinator = context.coordinator
        let startSeconds = startSeconds ?? 0
        coordinator.startSeconds = startSeconds
        coordinator.maximumResolution = maximumResolution
        coordinator.url = url
        let item = coordinator.makeItem(url)
        // An AVQueuePlayer so a looping clip can run through AVPlayerLooper,
        // which queues the next pass ahead of the end: no pause, no gap and
        // no transport UI popping up at the loop point.
        let player = CaptionQueuePlayer()
        controller.player = player
        // The transport bar's speed menu, with the same choices as the
        // other players. It sets the player's `defaultRate`, which `play()`
        // starts at: a loop, a looper's next copy and a swapped-in stream
        // keep the speed because each starts through `play()`.
        controller.speeds = PlaybackSpeed.choices.map { speed in
            AVPlaybackSpeed(rate: Float(speed), localizedName: speed == 1 ? "Normal (1×)" : PlaybackSpeed.label(speed))
        }
        player.defaultRate = Float(initialSpeed)
        coordinator.speed = initialSpeed
        coordinator.onSpeedChange = onSpeedChange
        coordinator.speedObservation = player.observe(\.defaultRate, options: [.new]) { [weak coordinator] player, _ in
            let rate = Double(player.defaultRate)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { coordinator?.speedChanged(to: rate) }
            }
        }

        coordinator.loops = loops
        coordinator.controller = controller
        coordinator.item = item
        coordinator.subtitles = subtitles
        subtitles.bindAnalysisPlayer(player, buffering: { [weak player] held in player?.setAnalysisBuffering(held) })
        coordinator.quality = quality
        coordinator.rating = rating
        coordinator.observePlayback(player, controller: controller)
        // A resume point needs the item's own readiness (below), so only a
        // from-the-start clip takes the gapless looper.
        let useLooper = loops && startSeconds <= 0
        if useLooper {
            let looper = AVPlayerLooper(player: player, templateItem: item)
            coordinator.looper = looper
            coordinator.looperObservation = looper.observe(\.status, options: [.new]) { [weak coordinator] looper, _ in
                guard looper.status == .failed else { return }
                DispatchQueue.main.async { coordinator?.onPlaybackFailed() }
            }
            coordinator.didStart = true
            player.play()
        } else {
            player.insert(item, after: nil)
            // Never park at the end: a parked player shows its controls. The
            // end handler rewinds it when looping is on.
            player.actionAtItemEnd = .none
        }
        // The transport bar's own menus: Subtitles, and a Loop toggle.
        coordinator.observeTransportBar()
        coordinator.observe(item, in: player)

        // Subtitles, drawn in the content overlay: inside the picture, and
        // under the transport bar and info panel rather than over them.
        let picture = TVPlayerPicture()
        coordinator.picture = picture
        subtitles.playhead = { [weak coordinator, weak player] in
            // Until the resume seek is issued the player is still at zero,
            // and a streamed track should start where playback will.
            guard let coordinator, let player, coordinator.didStart else { return startSeconds }
            return coordinator.playhead(of: player)
        }
        let overlay = UIHostingController(rootView: TVSubtitleLayer(controller: subtitles, picture: picture,
                                                                    quality: quality) {
            [weak player, weak coordinator] in
            guard let player else { return 0 }
            return coordinator?.playhead(of: player) ?? player.currentTime().seconds
        })
        overlay.safeAreaRegions = []
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        controller.loadViewIfNeeded()
        if let contentOverlay = controller.contentOverlayView {
            controller.addChild(overlay)
            overlay.view.frame = contentOverlay.bounds
            overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentOverlay.addSubview(overlay.view)
            overlay.didMove(toParent: controller)
        }
        coordinator.pictureObservation = player.observe(\.currentItem?.presentationSize, options: [.initial, .new]) { [weak coordinator] player, _ in
            let size = player.currentItem?.presentationSize ?? .zero
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { coordinator?.picture?.aspect = size.width / size.height }
            }
        }
        subtitles.load(subtitleSource())

        // Library-feature progress sync: every ~5s, report (position,
        // duration, paused) up to the SwiftUI view — a no-op for every
        // caller that doesn't pass `onProgress` (see `TVVideoPlayerView`'s
        // default).
        coordinator.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1),
            queue: .main
        ) { [weak coordinator, weak player] _ in
            guard let coordinator, let player else { return }
            MainActor.assumeIsolated {
                // The swap's playhead while a new stream gets ready: its
                // item starts at zero, which must never reach the server.
                let duration = player.currentItem?.duration.seconds ?? 0
                coordinator.onProgress(coordinator.playhead(of: player), duration.isFinite ? duration : 0,
                                       player.rate == 0)
            }
        }

        // Skip Intro / Skip Credits: the system player's contextual action,
        // the button the Apple TV app shows for the same thing. After a skip
        // the action is "Undo Skip" for a few seconds; a segment undone isn't
        // offered again.
        coordinator.segmentObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak coordinator, weak controller, weak player] time in
            guard let coordinator, let controller, let player else { return }
            if let until = coordinator.undoUntil {
                guard Date.now >= until else { return }
                coordinator.undoUntil = nil
                coordinator.offeredSegment = nil
                controller.contextualActions = []
            }
            let segment = LibrarySegmentSkipPolicy.segment(
                at: time.seconds, in: coordinator.segments.filter { !coordinator.declinedSegments.contains($0) })
            guard segment != coordinator.offeredSegment else { return }
            coordinator.offeredSegment = segment
            guard let segment else {
                controller.contextualActions = []
                return
            }
            let duration = player.currentItem?.duration.seconds ?? 0
            controller.contextualActions = [
                UIAction(title: segment.skipTitle, image: UIImage(systemName: "forward.end.fill")) {
                    [weak player, weak coordinator, weak controller] _ in
                    guard let player else { return }
                    let returnTo = player.currentTime().seconds
                    let target = MediaSegmentSkipper.target(for: segment, duration: duration.isFinite ? duration : 0)
                    player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                    coordinator?.offerUndo(of: segment, returnTo: returnTo, player: player, controller: controller)
                },
            ]
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onPlaybackFailed = onPlaybackFailed
        context.coordinator.onProgress = onProgress
        context.coordinator.onPlayedToEnd = onPlayedToEnd
        context.coordinator.onSpeedChange = onSpeedChange
        context.coordinator.segments = segments
        context.coordinator.showInfo(details, artwork: artwork, on: uiViewController.player)
        if context.coordinator.maximumResolution != maximumResolution {
            context.coordinator.maximumResolution = maximumResolution
            uiViewController.player?.currentItem?.preferredMaximumResolution = maximumResolution
        }
        if context.coordinator.url != url, let player = uiViewController.player as? AVQueuePlayer {
            context.coordinator.swap(to: url, in: player)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onPlaybackFailed: onPlaybackFailed, onProgress: onProgress)
        coordinator.onPlayedToEnd = onPlayedToEnd
        return coordinator
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.statusObservation?.invalidate()
        coordinator.pictureObservation?.invalidate()
        coordinator.speedObservation?.invalidate()
        coordinator.timeControlObservation?.invalidate()
        coordinator.displayObservation?.invalidate()
        // A streamed track keeps the server reading the file until stopped.
        coordinator.subtitles?.bindAnalysisPlayer(nil)
        coordinator.subtitles?.reset()
        coordinator.looperObservation?.invalidate()
        coordinator.looper?.disableLooping()
        if let observer = coordinator.failureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in [coordinator.endObserver, coordinator.jumpObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let timeObserver = coordinator.timeObserver {
            uiViewController.player?.removeTimeObserver(timeObserver)
        }
        if let segmentObserver = coordinator.segmentObserver {
            uiViewController.player?.removeTimeObserver(segmentObserver)
        }
        uiViewController.player?.pause()
        uiViewController.player = nil
    }

    /// `@unchecked Sendable`: every access happens on the main queue (both
    /// observers above are registered with `queue: .main` / dispatched
    /// there), so the unchecked conformance states a real invariant rather
    /// than papering over one, the same shape as `SendableAVAsset` /
    /// `SendableTexture` elsewhere in the app.
    final class Coordinator: @unchecked Sendable {
        var onPlaybackFailed: () -> Void
        var onProgress: (Double, Double, Bool) -> Void
        var onPlayedToEnd: (() -> Void)?
        /// Set once the first play (after any resume seek) has been issued.
        var didStart = false
        /// What the player plays, and how its items are set up.
        var url: URL?
        var startSeconds: Double = 0
        var maximumResolution: CGSize = .zero
        /// Where a swapped-in item starts, and whether it plays, once ready.
        /// Held until the seek there has landed, so what is reported and
        /// shown meanwhile is that playhead, never the new item's zero: a
        /// zero sent as progress would reset the viewer's place on the server.
        private var pendingSwap: (time: CMTime, plays: Bool)?
        private var swapSeekIssued = false
        var loops = false
        /// The speed chosen in the transport bar (the player's `defaultRate`).
        var speed: Double = 1
        var onSpeedChange: (Double) -> Void = { _ in }
        var speedObservation: NSKeyValueObservation?
        var looper: AVPlayerLooper?
        var looperObservation: NSKeyValueObservation?
        var failureObserver: NSObjectProtocol?
        var endObserver: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?
        var timeObserver: Any?
        var segmentObserver: Any?
        var segments: [LibraryMediaSegment] = []
        var offeredSegment: LibraryMediaSegment?
        /// While set, the contextual action is the undo for the last skip.
        var undoUntil: Date?
        /// Segments the viewer went back into: not offered again.
        var declinedSegments: Set<LibraryMediaSegment> = []

        /// After a skip: "Undo Skip" for `LibrarySegmentSkipPolicy.undoSeconds`,
        /// back to where it left from.
        @MainActor func offerUndo(of segment: LibraryMediaSegment, returnTo: Double, player: AVPlayer,
                                  controller: AVPlayerViewController?) {
            undoUntil = .now.addingTimeInterval(LibrarySegmentSkipPolicy.undoSeconds)
            controller?.contextualActions = [
                UIAction(title: "Undo Skip \(segment.name)", image: UIImage(systemName: "arrow.uturn.backward")) {
                    [weak self, weak player, weak controller] _ in
                    guard let self, let player else { return }
                    self.declinedSegments.insert(segment)
                    self.undoUntil = nil
                    self.offeredSegment = nil
                    controller?.contextualActions = []
                    player.seek(to: CMTime(seconds: returnTo, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                },
            ]
        }
        weak var controller: AVPlayerViewController?
        var subtitles: SubtitleController?
        var quality: TVPlayerQuality?
        var rating: TVSceneRating?
        var timeControlObservation: NSKeyValueObservation?
        var displayObservation: NSKeyValueObservation?
        var jumpObserver: NSObjectProtocol?
        private var wasPaused = true
        var picture: TVPlayerPicture?
        var pictureObservation: NSKeyValueObservation?
        /// The item playing (or the one a looper plays copies of).
        var item: AVPlayerItem?
        private var shownInfo: PlayerDetails?
        private var shownArtwork: UIImage?
        private var shownMetadata: [AVMetadataItem]?

        /// An item for `url`, set up as every item here is.
        @MainActor func makeItem(_ url: URL) -> AVPlayerItem {
            let item = AVPlayerItem(asset: MediaAuthorization.shared.asset(for: url))
            item.applySpatialAudioPolicy()
            item.preferredMaximumResolution = maximumResolution
            if let shownMetadata { item.externalMetadata = shownMetadata }
            return item
        }

        /// Plays `url` instead, from the playhead, playing on if it was.
        @MainActor func swap(to url: URL, in player: AVQueuePlayer) {
            // A looper plays copies of the item it was made with.
            guard looper == nil else { return }
            self.url = url
            if didStart {
                // A swap whose item never got ready still holds the playhead.
                pendingSwap = pendingSwap ?? (player.currentTime(), player.timeControlStatus != .paused)
                swapSeekIssued = false
            }
            let item = makeItem(url)
            self.item = item
            observe(item, in: player)
            player.replaceCurrentItem(with: item)
        }

        /// The playhead to report and draw subtitles at: while a swapped-in
        /// stream is getting ready, where it will start.
        @MainActor func playhead(of player: AVPlayer) -> Double {
            if let pendingSwap { return pendingSwap.time.seconds }
            return player.currentTime().seconds
        }

        /// The viewer picked a speed in the transport bar.
        @MainActor func speedChanged(to rate: Double) {
            guard rate > 0, rate != speed else { return }
            speed = rate
            AppLogger.videoWindow.info("[tvOS] Playback speed \(rate, format: .fixed(precision: 2), privacy: .public)x")
            onSpeedChange(rate)
        }

        /// How the stream is doing, for Auto quality: waiting for data while
        /// meaning to play, resuming from a pause, and the first frame.
        @MainActor func observePlayback(_ player: AVQueuePlayer, controller: AVPlayerViewController) {
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                let waiting = status == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay != .noItemToPlay
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.playbackStateChanged(paused: status == .paused, waiting: waiting) }
                }
            }
            displayObservation = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] controller, _ in
                guard controller.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.quality?.notePresented() }
                }
            }
        }

        @MainActor private func playbackStateChanged(paused: Bool, waiting: Bool) {
            // Refilling after a pause is expected, whatever the link.
            if wasPaused, !paused { quality?.noteInterruption() }
            wasPaused = paused
            quality?.noteBuffering(waiting)
        }

        /// Failure, readiness and the end of `item`, replacing the
        /// observers of the item before it.
        @MainActor func observe(_ item: AVPlayerItem, in player: AVQueuePlayer) {
            statusObservation?.invalidate()
            for observer in [failureObserver, endObserver].compactMap({ $0 }) {
                NotificationCenter.default.removeObserver(observer)
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onPlaybackFailed()
            }
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] observedItem, _ in
                switch observedItem.status {
                case .failed:
                    DispatchQueue.main.async {
                        self?.onPlaybackFailed()
                    }
                case .readyToPlay:
                    DispatchQueue.main.async {
                        guard let self, let player else { return }
                        MainActor.assumeIsolated { self.itemIsReady(in: player) }
                    }
                default:
                    break
                }
            }
            if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
            // A seek: the wait for data after one is expected.
            jumpObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.quality?.noteInterruption() }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak player] _ in
                guard let self else { return }
                if self.loops, let player {
                    player.defaultRate = Float(self.speed)
                    player.seek(to: .zero) { _ in player.play() }
                } else {
                    // actionAtItemEnd is .none, so end the way the player would have.
                    player?.pause()
                    self.onPlayedToEnd?()
                }
            }
        }

        /// A swapped-in item picks up where the last one was. Otherwise the
        /// first start: a seek issued before the item is ready is dropped,
        /// so a resume waits for readiness, and playback starts after it so
        /// the resume point is the first frame shown.
        @MainActor private func itemIsReady(in player: AVQueuePlayer) {
            player.defaultRate = Float(speed)
            // Loading the stream isn't stalling.
            quality?.noteInterruption()
            if let swap = pendingSwap {
                guard !swapSeekIssued else { return }
                swapSeekIssued = true
                let item = player.currentItem
                player.seek(to: swap.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            // A newer swap holds its own playhead.
                            guard let self, let player, player.currentItem === item else { return }
                            self.pendingSwap = nil
                            self.swapSeekIssued = false
                            if swap.plays { player.play() }
                        }
                    }
                }
                return
            }
            guard !didStart else { return }
            didStart = true
            guard startSeconds > 0 else { player.play(); return }
            player.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { _ in
                player.play()
            }
        }

        /// The Info panel's title, subtitle, description and art, on every
        /// item the player has (a looper's copies included), when they change.
        @MainActor func showInfo(_ details: PlayerDetails?, artwork: UIImage?, on player: AVPlayer?) {
            guard let details, details != shownInfo || artwork !== shownArtwork else { return }
            shownInfo = details
            shownArtwork = artwork
            let metadata = details.externalMetadata(artwork: artwork)
            shownMetadata = metadata
            var items = (player as? AVQueuePlayer)?.items() ?? []
            if let item, !items.contains(item) { items.append(item) }
            for item in items { item.externalMetadata = metadata }
        }

        init(onPlaybackFailed: @escaping () -> Void, onProgress: @escaping (Double, Double, Bool) -> Void) {
            self.onPlaybackFailed = onPlaybackFailed
            self.onProgress = onProgress
        }

        /// Builds the transport bar's menus, and again whenever the
        /// subtitles they show change (tracks listed, one chosen, loaded,
        /// retimed). Re-armed every time, as observation tracking fires once.
        @MainActor func observeTransportBar() {
            withObservationTracking {
                refreshTransportBar()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.observeTransportBar() }
            }
        }

        @MainActor private func refreshTransportBar() {
            guard let controller else { return }
            controller.transportBarCustomMenuItems = [qualityMenu(), subtitleMenu(), ratingMenu(), loopItem()]
                .compactMap { $0 }
            if subtitles?.selected != nil { silenceSystemSubtitles() }
        }

        /// Off and each track, then the timing offset while one shows.
        /// Absent until the tracks are listed, and for a video with none.
        @MainActor private func subtitleMenu() -> UIMenu? {
            guard let subtitles, !subtitles.tracks.isEmpty || subtitles.canGenerate else { return nil }
            let selected = subtitles.selected
            var items: [UIMenuElement] = [
                UIAction(title: "Off", state: selected == nil ? .on : .off) { _ in subtitles.select(nil) },
            ]
            if subtitles.canGenerate {
                let status = subtitles.generated.status
                let title = subtitles.generated.isBuffering ? "AI Captions (Buffering…)"
                    : status.isEmpty ? "AI Captions" : "AI Captions (\(status))"
                items.append(UIAction(title: title,
                    state: subtitles.generated.enabled ? .on : .off) { _ in subtitles.selectGenerated() })
            }
            let speakerModel = RAVESpeakerModel.shared
            if let progress = speakerModel.progress {
                items.append(UIAction(title: "Downloading Speaker Labels… \(Int(progress * 100))%", attributes: .disabled) { _ in })
                items.append(UIAction(title: "Cancel Speaker Model Download") { _ in speakerModel.cancel() })
            } else if !speakerModel.isInstalled {
                items.append(UIAction(title: "Download Speaker Labels (97 MB)", image: UIImage(systemName: "person.2")) { _ in
                    speakerModel.download()
                })
            }
            for track in subtitles.tracks {
                items.append(UIAction(title: subtitles.menuTitle(of: track),
                                      attributes: track.isPlayable ? [] : .disabled,
                                      state: selected == track ? .on : .off) { _ in subtitles.select(track) })
            }
            if selected != nil {
                items.append(UIMenu(title: String(format: "Timing %+.1f s", subtitles.delay), options: .displayInline, children: [
                    UIAction(title: "Earlier", image: UIImage(systemName: "backward")) { _ in subtitles.delay -= 0.5 },
                    UIAction(title: "Later", image: UIImage(systemName: "forward")) { _ in subtitles.delay += 0.5 },
                    UIAction(title: "Reset Timing", attributes: subtitles.delay == 0 ? .disabled : []) { _ in
                        subtitles.delay = 0
                    },
                ]))
            }
            return UIMenu(title: "Subtitles",
                          image: UIImage(systemName: selected == nil ? "captions.bubble" : "captions.bubble.fill"),
                          children: items)
        }

        /// Quality: a Library title's levels or a YouTube video's renditions,
        /// what plays under the choice in the menu's subtitle. Absent for
        /// every other stream.
        @MainActor private func qualityMenu() -> UIMenu? {
            guard let quality, quality.offersChoice else { return nil }
            // Not the other players' gauge: AVKit's speed menu beside it already is one.
            let image = UIImage(systemName: "sparkles.tv")
            #if HYPNOS_YOUTUBE
            if quality.isYouTube {
                let chosen = quality.youTubeChosenHeight
                var items: [UIMenuElement] = [
                    UIAction(title: "Auto", subtitle: "The best the connection allows",
                             state: chosen == nil ? .on : .off) { _ in quality.chooseYouTube(height: nil) },
                ]
                for rendition in quality.youTubeRenditions {
                    items.append(UIAction(title: rendition.title, state: chosen == rendition.height ? .on : .off) { _ in
                        quality.chooseYouTube(height: rendition.height)
                    })
                }
                return UIMenu(title: "Quality", subtitle: quality.youTubeLabel, image: image, children: items)
            }
            #endif
            let checked = quality.checked
            let items = quality.offered.map { level in
                UIAction(title: level.title, subtitle: quality.detail(of: level),
                         attributes: quality.isChanging ? .disabled : [],
                         state: level == checked ? .on : .off) { _ in quality.choose(level) }
            }
            let playing = checked == .auto ? "Auto · \(quality.libraryLabel)" : quality.libraryLabel
            return UIMenu(title: "Quality", subtitle: playing, image: image, children: items)
        }

        /// A Stash scene's rating: no rating or one to five stars, saved to
        /// the server as the grid's quick actions save one.
        @MainActor private func ratingMenu() -> UIMenu? {
            guard let rating else { return nil }
            let stars = rating.stars
            var items: [UIMenuElement] = [
                UIAction(title: "No Rating", state: stars == 0 ? .on : .off) { _ in rating.rate(0) },
            ]
            for count in 1 ... 5 {
                items.append(UIAction(title: String(repeating: "★", count: count) + String(repeating: "☆", count: 5 - count),
                                      state: stars == count ? .on : .off) { _ in rating.rate(count) })
            }
            return UIMenu(title: "Rating", image: UIImage(systemName: stars > 0 ? "star.fill" : "star"),
                          children: items)
        }

        /// A Loop toggle, since a clip may want looping where the default
        /// is off and the other way round.
        @MainActor private func loopItem() -> UIAction {
            // The transport bar shows only the icon, so the state is the fill.
            UIAction(title: "Loop",
                     image: UIImage(systemName: loops ? "repeat.circle.fill" : "repeat.circle"),
                     state: loops ? .on : .off) { [weak self] _ in
                guard let self else { return }
                loops.toggle()
                if !loops { looper?.disableLooping() }
                refreshTransportBar()
            }
        }

        /// AVKit draws an MP4's own text track when one is selected, which
        /// the system's subtitle setting can do on its own: with ours
        /// showing, it would show twice.
        @MainActor private func silenceSystemSubtitles() {
            guard let item = controller?.player?.currentItem else { return }
            Task { @MainActor in
                guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                      item.currentMediaSelection.selectedMediaOption(in: group) != nil
                else { return }
                item.select(nil, in: group)
            }
        }
    }
}

extension PlayerDetails {
    /// AVKit's Info panel: the title (an episode's series), a subtitle
    /// ("S1 E3 · Title", a studio), the overview with the details' rows under
    /// it, genres, year and art.
    func externalMetadata(artwork: UIImage?) -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol,
                   dataType: String? = nil) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            if let dataType { item.dataType = dataType }
            return item
        }
        var items = [entry(.commonIdentifierTitle, cornerTitle as NSString)]
        let subtitleLine = [cornerSubtitle ?? context ?? subtitle].compactMap { $0 } + facts
        if !subtitleLine.isEmpty {
            items.append(entry(.iTunesMetadataTrackSubTitle, subtitleLine.joined(separator: " · ") as NSString))
        }
        let rowLines = rows.filter { $0.label != "Genres" }.map { "\($0.label): \($0.value)" }
        let description = ([overview].compactMap { $0 } + (rowLines.isEmpty ? [] : [rowLines.joined(separator: "\n")]))
            .joined(separator: "\n\n")
        if !description.isEmpty { items.append(entry(.commonIdentifierDescription, description as NSString)) }
        if let genres = libraryItem?.genres, !genres.isEmpty {
            items.append(entry(.quickTimeMetadataGenre, genres.joined(separator: ", ") as NSString))
        }
        if let year = libraryItem?.year {
            items.append(entry(.commonIdentifierCreationDate, String(year) as NSString))
        }
        if let data = artwork?.jpegData(compressionQuality: 0.85) {
            items.append(entry(.commonIdentifierArtwork, data as NSData, dataType: kCMMetadataBaseDataType_JPEG as String))
        }
        return items
    }
}

/// The playing picture's shape, for placing subtitles inside it.
@MainActor
@Observable
private final class TVPlayerPicture {
    var aspect: CGFloat?
}

/// The subtitles hosted in the player's content overlay, and Auto quality's
/// notice above the picture.
private struct TVSubtitleLayer: View {
    let controller: SubtitleController
    let picture: TVPlayerPicture
    var quality: TVPlayerQuality?
    let time: @MainActor () -> Double

    var body: some View {
        SubtitleOverlay(controller: controller, pictureAspect: picture.aspect, filmTime: time)
            .overlay(alignment: .top) {
                if let notice = quality?.notice {
                    StreamQualityNotice(text: notice)
                        .padding(.top, 60)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: quality?.notice)
    }
}


/// AVKit owns the transport on Apple TV. Its commands remain user intent while
/// an analysis hold parks both sound and picture on the AVPlayer clock.
private final class CaptionQueuePlayer: AVQueuePlayer, @unchecked Sendable {
    private var analysisHeld = false
    private var wantsPlayback = false
    override func play() {
        wantsPlayback = true
        if !analysisHeld { super.play() }
    }
    override func playImmediately(atRate rate: Float) {
        wantsPlayback = rate > 0
        if !analysisHeld { super.playImmediately(atRate: rate) }
    }
    override func pause() { wantsPlayback = false; super.pause() }
    func setAnalysisBuffering(_ held: Bool) {
        analysisHeld = held
        if held { super.pause() }
        else if wantsPlayback { super.play() }
    }
}
#endif
