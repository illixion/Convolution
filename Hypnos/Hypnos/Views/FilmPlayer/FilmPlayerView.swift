/*
 Hypnos - film player window

 The film picture and Atmos object audio keep one RAVEFilm clock. Its
 transport uses RAVEUI's RAVEPlayerControls, just like general videos and
 Raven's converted browser video. Sound tuning uses a separate window on visionOS
 and a sheet elsewhere. Mute leaves saved gain levels intact.

 visionOS hangs a one-row control bar under the window, so the window is
 all picture; the bar and the window bar hide together while the film
 plays (tap the picture to bring them back). It offers realtime 3D. A compressed
 sample tap feeds RAVEMedia's clocked SampleBufferFrameSource; the original
 picture renderer stays primed while only its visible surface changes.
 Atmos transport, seeking and progress reporting stay with FilmPlayer.

 Subtitles (FilmSession.subtitles) draw over the 2D picture on its film
 clock. While the picture is stereo they are drawn into it instead, in front
 of its content (StereoSubtitleFeeder): SwiftUI over the stereo video plane
 never shows in front of it (measured on device), and the menus already fade
 the picture for the same reason.

 Switching between 2D and 3D never moves the playhead: both directions
 re-prime the picture at the position the toggle was pressed at.

 The Cinema menu (FilmCinema.swift) opens an immersive space that centres
 the sound on the wearer's head (Room Sound) or also moves the picture onto
 a big screen in it (Big Screen); the window then shows a card instead.

 iOS/macOS use the AirPods tracker for the listener; Recenter is beside the
 transport when tracking is active. tvOS keeps its PHASE stage and focusable
 controls. Head tracking recentres on resume on all three platforms.
 */

import CoreMedia
import DebugTrace
import RAVEFilm
import RAVEMedia
import RAVEUI
import simd
import SwiftUI

struct FilmPlayerView: View {
    static let windowID = "film-player"

    @Bindable private var session = FilmSession.shared
    private var player: FilmPlayer { session.player }
    /// Skip Intro / Skip Credits for the loaded Library title.
    @State private var skipper = MediaSegmentSkipper()
    /// Said for a few seconds when Auto lowers the object audio's quality for the connection.
    @State private var audioNotice: String?
    @State private var audioNoticeTask: Task<Void, Never>?
    @State private var lastAudioTier: FilmAudioGovernor.Tier?
    /// This view's claim on the shared player (`FilmSession.activePlayerView`).
    @State private var viewID = UUID()
    #if os(tvOS) || os(iOS)
    @State private var nowPlaying: FilmNowPlaying?
    #endif

    #if os(visionOS)
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SceneDelegate.self) private var sceneDelegate
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    private var cinema: FilmCinema { .shared }
    @State private var stereoSource: SampleBufferFrameSource?
    /// Set while a 3D film plays as real 3D (eyes cropped from the frame);
    /// nil while a flat film plays as fake-3D.
    @State private var stereoLayout: PackedStereoLayout?
    @State private var mountedDepthModelName: String?
    @State private var showsDepthSetup = false
    @State private var chromeOpen = false
    /// The transport's More popover is open, which keeps the gaze with the
    /// stereo picture still tappable.
    @State private var morePopoverOpen = false
    @State private var menuDismissals = 0
    @State private var chromeVisible = true
    @State private var chromeHolds = 0
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var stereoFailure: String?
    /// When the 3D picture keeps dropping frames: under Auto the picture
    /// steps to the next lower tier the plugin offers (for this film only),
    /// and that is said; at the lowest (or with none, or a fixed choice) the
    /// viewer is told once per film what would help.
    @State private var pictureNotice: String?
    /// The converted tier a Dolby Vision profile 5 film's 3D switched to,
    /// undone when 3D ends.
    @State private var stereoTierForDolbyVision: Int?
    @State private var stereoTierForAutoAI3D: Int?
    @State private var autoAI3DTierAttempted = false
    @State private var stereoTierRequestID = UUID()
    @State private var pictureNoticeTask: Task<Void, Never>?
    @State private var stereoLoadStrikes = 0
    @State private var stereoLoadAdvisedItem: String?
    /// Reports before this don't count: the first seconds of 3D (model
    /// loading, the first decode) and of a new tier (its flush and refill).
    @State private var stereoLoadGraceUntil = Date.distantPast
    /// The subtitles the stereo picture draws, from `StereoSubtitleFeeder`.
    @State private var stereoSubtitles: StereoSubtitleFrame?
    @AppStorage(StereoSubtitleStyle.key) private var stereoSubtitleStyle = StereoSubtitleStyle.inPicture
    @AppStorage(FlatSubtitleStyle.key) private var flatSubtitleStyle = StereoSubtitleStyle.inPicture
    #endif

    var body: some View {
        content
            #if os(visionOS)
            .modifier(PictureCompareOpener())
            #endif
            .onAppear {
                session.activePlayerView = viewID
                session.isPlayerOpen = true
                #if os(tvOS) || os(iOS)
                // Claim Now Playing so the remote's and AirPods' play/pause
                // reach this player (see RAVEFilm's FilmNowPlaying).
                AudioSessionConfig.configureFilmPlayback()
                let nowPlaying = FilmNowPlaying(player: player, title: session.loadedItem?.name ?? "Film")
                nowPlaying.activate()
                self.nowPlaying = nowPlaying
                #endif
            }
            .onDisappear {
                #if os(visionOS)
                stopStereo(keepingPosition: false)
                #endif
                // A window closing after the next film window appeared (seen
                // on reopening a film) leaves the player to that one.
                guard session.activePlayerView == viewID else { return }
                session.activePlayerView = nil
                player.pause()
                session.isPlayerOpen = false
                session.saveSound()
                #if os(visionOS)
                closeCinema()
                #endif
                #if os(tvOS) || os(iOS)
                nowPlaying?.deactivate()
                nowPlaying = nil
                AudioSessionConfig.configureMixedPlayback()
                UIApplication.shared.isIdleTimerDisabled = false
                #endif
            }
            #if os(tvOS) || os(iOS)
            .onChange(of: session.loadedItem?.name) { _, name in
                if let name { nowPlaying?.setTitle(name) }
            }
            // The display layer's preventsDisplaySleepDuringVideoPlayback
            // doesn't hold the screen on for a picture fed on our own clock
            // (the iPad slept mid-film), so the player holds it while playing.
            .onChange(of: player.isPlaying, initial: true) { _, playing in
                UIApplication.shared.isIdleTimerDisabled = playing
            }
            #endif
            #if os(visionOS)
            .sheet(isPresented: $showsDepthSetup) {
                DepthModelSetupSheet(onModelReady: { startStereo() })
            }
            .alert("3D unavailable", isPresented: Binding(
                get: { stereoFailure != nil }, set: { if !$0 { stereoFailure = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(stereoFailure ?? "") }
            .onChange(of: session.loadedItem?.id) { _, _ in stopStereo(keepingPosition: false) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { clearLostHolds() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { notification in
                guard let scene = notification.object as? UIWindowScene,
                      scene === sceneDelegate.windowScene else { return }
                stopStereo(keepingPosition: false)
                guard session.activePlayerView == viewID else { return }
                session.activePlayerView = nil
                session.isPlayerOpen = false
                player.pause()
                session.saveSound()
                closeCinema()
            }
            // AI 3D draws in the window, so the big screen plays 2D.
            .onChange(of: cinema.mode) { _, mode in
                if mode == .bigScreen { stopStereo() }
            }
            .onChange(of: cinema.screenTaps) { toggleChrome() }
            // A 3D film opens in 3D once the server says it is one, and
            // replaces a fake-3D picture the user started before it knew.
            // Initial too: a Blu-ray disc knows it is 3D before the window opens.
            .onChange(of: session.stereoFormat, initial: true) { _, format in
                guard format != nil, stereoLayout == nil else { return }
                stopStereo(keepingPosition: false)
                startStereo()
            }
            .onChange(of: appModel.realtimeDepthModelName) { _, name in
                if stereoSource != nil, stereoLayout == nil, mountedDepthModelName != name {
                    // startStereo re-primes at the current position itself.
                    stopStereo(keepingPosition: false)
                    startStereo()
                }
            }
            // Stable Depth is read when the realtime source is built.
            .onChange(of: appModel.stableDepth) { _, _ in
                if stereoSource != nil, stereoLayout == nil {
                    stopStereo(keepingPosition: false)
                    startStereo()
                }
            }
            .task(id: stereoSource.map(ObjectIdentifier.init)) {
                guard let source = stereoSource else { return }
                while !Task.isCancelled {
                    if source.decodeFailure != nil {
                        stopStereo()
                        stereoFailure = "This video's picture could not be converted. Playback continues in 2D."
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            #endif
            // Library-feature progress sync for the Atmos/FilmPlayer route —
            // a no-op unless the item currently loaded came from the Library
            // tab (i.e. `session.loadedItem`'s id is a real Jellyfin item;
            // `FilmPlayer`'s own `currentTime`/`duration`/`isPlaying` are
            // plain `@Observable` properties with no publisher, so this
            // polls rather than subscribes — see `LibraryPlaybackCoordinator`'s
            // header comment for the equivalent generic-player version).
            .task(id: session.loadedItem?.id) {
                await reportFilmPlaybackProgress()
            }
            .task(id: session.loadedItem?.id) {
                await skipper.load(itemId: FilmSession.isServerItem(session.loadedItem?.id) ? session.loadedItem?.id : nil)
            }
            .onChange(of: player.audioQuality) { noteAudioQuality() }
            .animation(.easeInOut(duration: 0.2), value: audioNotice)
    }

    /// Auto lowering the sound for the link is said, and a fixed choice
    /// never changes, so only a step down under Auto speaks (the first
    /// choice at the start, and every step back up, are not news).
    private func noteAudioQuality() {
        guard ObjectAudioQuality.preferred == .auto, let tier = ObjectAudioQuality.autoGovernor.tier else {
            lastAudioTier = nil
            return
        }
        defer { lastAudioTier = tier }
        guard let last = lastAudioTier, tier.rawValue > last.rawValue else { return }
        let encoding = ObjectAudioQuality.autoGovernor.currentEncoding.summary
        AppLogger.filmPlayer.info("Auto lowered the object audio to \(encoding, privacy: .public)")
        audioNotice = "Sound reduced to \(encoding) for this connection"
        audioNoticeTask?.cancel()
        audioNoticeTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { audioNotice = nil }
        }
    }

    #if os(visionOS)
    /// About 6 s of a 3D picture showing under three quarters of its frames
    /// (three overloaded reports in a row). Under Auto the picture steps to
    /// 1080p (the conversion's cost follows the picture's size), then
    /// 20 s pass before the next reports count; otherwise the viewer is told
    /// once per film.
    private func noteStereoPerformance(_ sample: StereoPerformance) {
        guard player.isPlaying, !chromeOpen, !player.video.isChangingPictureTier,
              Date.now >= stereoLoadGraceUntil, sample.isOverloaded else {
            stereoLoadStrikes = 0
            return
        }
        stereoLoadStrikes += 1
        AppLogger.filmPlayer.info("3D picture dropping frames: \(Int(sample.deliveredFraction * 100), privacy: .public)% of \(sample.sourceFramesPerSecond, format: .fixed(precision: 1), privacy: .public) fps shown (\(self.stereoLoadStrikes, privacy: .public)/3)")
        guard stereoLoadStrikes >= 3 else { return }
        stereoLoadStrikes = 0
        stereoLoadGraceUntil = .now.addingTimeInterval(20)

        let current = player.video.pictureHeight
        if FilmPictureQuality.preferred == .auto,
           let lower = FilmPictureQuality.stepDown(from: current, offering: player.video.offeredPictureHeights) {
            let tier = FilmPictureQuality.name(of: lower)
            AppLogger.filmPlayer.info("3D couldn't keep up at \(FilmPictureQuality.name(of: current), privacy: .public); stepping to \(tier, privacy: .public)")
            showPictureNotice("Picture lowered to \(tier) so 3D plays smoothly")
            Task {
                if await !player.video.setPictureHeight(lower) {
                    AppLogger.filmPlayer.error("Couldn't step the picture to \(tier, privacy: .public)")
                }
                // The new tier's flush and refill don't count either.
                stereoLoadGraceUntil = .now.addingTimeInterval(20)
            }
            return
        }
        let item = session.loadedItem?.id ?? ""
        guard stereoLoadAdvisedItem != item else { return }
        stereoLoadAdvisedItem = item
        showPictureNotice(stereoLayout == nil
            ? "AI 3D can't keep up with this film's picture. 2D plays smoothly."
            : "3D can't keep up with this film's picture. 2D plays smoothly.")
    }

    private func showPictureNotice(_ text: String) {
        pictureNotice = text
        pictureNoticeTask?.cancel()
        pictureNoticeTask = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { pictureNotice = nil }
        }
    }
    #endif

    private var hasPictureNotice: Bool {
        #if os(visionOS)
        pictureNotice != nil
        #else
        false
        #endif
    }

    /// What hangs beside the controls: the audio and picture notices and the
    /// skip button.
    private func prompt(controlsVisible: Bool) -> AnyView? {
        let skip = skipButton(controlsVisible: controlsVisible)
        guard audioNotice != nil || hasPictureNotice || skip != nil else { return nil }
        return AnyView(HStack(spacing: 12) {
            audioNotice.map { StreamQualityNotice(text: $0, systemImage: "waveform") }
            #if os(visionOS)
            pictureNotice.map { StreamQualityNotice(text: $0, systemImage: "gauge.with.dots.needle.33percent") }
            #endif
            skip
        })
    }

    /// The skip button to show now, if any. Platforms whose controls never
    /// hide offer it for the whole segment.
    private func skipButton(controlsVisible: Bool) -> SkipSegmentButton? {
        guard let segment = skipper.offered(at: player.currentTime, controlsVisible: controlsVisible) else { return nil }
        return SkipSegmentButton(segment: segment) {
            AppLogger.filmPlayer.info("Skipping \(segment.kind.rawValue, privacy: .public)")
            player.seek(to: MediaSegmentSkipper.target(for: segment, duration: player.duration))
        }
    }

    private func reportFilmPlaybackProgress() async {
        guard let itemId = session.loadedItem?.id, FilmSession.isServerItem(itemId),
              let library = LibraryService.current() else { return }
        var started = false
        var lastPosition: Double = 0
        defer {
            if started {
                // The position at close, not at the last 10 s sample.
                let position = Self.safeStopPosition(current: player.currentTime, lastReported: lastPosition)
                Task { await library.reportPlaybackStopped(itemId: itemId, positionSeconds: position) }
            }
        }
        while !Task.isCancelled {
            let position = player.currentTime
            if !started, position > 0 {
                started = true
                await library.reportPlaybackStarted(itemId: itemId, positionSeconds: position)
            } else if started {
                await library.reportPlaybackProgress(itemId: itemId, positionSeconds: position, isPaused: !player.isPlaying)
            }
            lastPosition = position
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Where a stop report puts the resume point. A playhead found back at
    /// the start after a minute or more of reported progress is far more
    /// likely a player fault than the user rewinding before closing, and
    /// writing it would erase their place; the last good position is kept.
    static func safeStopPosition(current: Double, lastReported: Double) -> Double {
        guard current < 5, lastReported > 60 else { return current }
        AppLogger.filmPlayer.error("Playhead at \(current, format: .fixed(precision: 1))s on close after \(lastReported, format: .fixed(precision: 1))s reported; keeping the reported position")
        return lastReported
    }

    private var pictureAspect: CGFloat? { player.video.format.flatMap(Self.aspect(of:)) }

    private static func aspect(of format: CMVideoFormatDescription) -> CGFloat? {
        let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
        return size.width > 0 && size.height > 0 ? size.width / size.height : nil
    }

    private var subtitleOverlay: some View {
        SubtitleOverlay(controller: session.subtitles, pictureAspect: pictureAspect) { player.currentTime }
    }

    @ViewBuilder
    private var content: some View {
        #if os(visionOS)
        ZStack(alignment: .bottom) {
            Group {
                // RealityKit's video plane (HDR as AVKit shows it). Hidden,
                // not removed, under the stereo picture so it stays fed; dimmed
                // under an open menu, which the plane would otherwise cover.
                // A tap on it toggles the chrome.
                FilmVideoView(player: player.video, squareCorners: !appModel.roundedCorners,
                              opacity: stereoSource != nil ? 0 : (chromeOpen ? 0.12 : 1),
                              takesInput: stereoSource == nil && (!chromeOpen || (morePopoverOpen && chromeHolds == 1)),
                              showsPicture: !cinema.screenAttached,
                              onTap: { toggleChrome() })
                    // The audio stage contributes no window depth. It remains
                    // mounted when only the picture changes to stereo, and
                    // moves into the cinema space while that is open.
                    .background {
                        ZStack {
                            if !cinema.isOpen {
                                FilmStageView(player: player, listenerDistance: session.listenerPlacement,
                                              onWindowScale: { session.windowScale = $0 })
                            }
                            FilmWindowMarker()
                        }
                        .frame(depth: 0)
                    }
                if cinema.screenAttached {
                    FilmBigScreenCard(onTap: { toggleChrome() })
                }
                if let source = stereoSource {
                    RAVEExternalStereoVideoView(
                        source: source, settings: session.stereoSettings, chromeOpen: chromeOpen,
                        chromeTakesInput: morePopoverOpen && chromeHolds == 1,
                        packedStereo: stereoLayout,
                        squareCorners: !appModel.roundedCorners,
                        subtitles: stereoSubtitles,
                        onUnavailable: { failure in
                            guard stereoSource === source else { return }
                            stopStereo()
                            stereoFailure = failure == .needsSystemRenderer
                                ? Self.dolbyVisionOriginalIn3D
                                : "The 3D renderer is unavailable. Playback continues in 2D."
                        },
                        onToggleChrome: { toggleChrome() },
                        onPerformance: { noteStereoPerformance($0) }
                    )
                    .background {
                        if stereoSubtitleStyle == .inPicture {
                            StereoSubtitleFeeder(controller: session.subtitles, filmTime: { player.currentTime },
                                                 frame: $stereoSubtitles)
                        }
                    }
                }
                if stereoSource == nil, flatSubtitleStyle == .inPicture, !cinema.screenAttached {
                    subtitleOverlay
                }
            }
        }
        // The controls hang under the window, so the window is all picture;
        // they and the window bar hide together while the film plays.
        .persistentSystemOverlays(chromeVisible ? .visible : .hidden)
        .ornament(visibility: PlayerOrnamentStack<EmptyView>.isVisible(
                      subtitles: bandSubtitles, controlsVisible: chromeVisible,
                      hasPrompt: prompt(controlsVisible: chromeVisible) != nil) ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            PlayerOrnamentStack(
                subtitles: bandSubtitles, controlsVisible: chromeVisible,
                prompt: prompt(controlsVisible: chromeVisible),
                gap: stereoSource == nil ? 12 : VideoWindowView.stereoControlsGap,
                filmTime: { player.currentTime }
            ) {
            FilmTransport(player: player, stereoEnabled: stereoSource != nil,
                          onToggle3D: cinema.mode == .bigScreen ? nil : { stereoSource == nil ? startStereo() : stopStereo() },
                          onModalChanged: { open in
                              chromeOpen = open
                              holdChrome(open)
                          },
                          onMoreChanged: { morePopoverOpen = $0 },
                          menuDismissal: menuDismissals,
                          onInteraction: { revealChrome() },
                          onHold: { holdChrome($0) })
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .onAppear { revealChrome() }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { scheduleChromeHide() } else { revealChrome() }
        }
        #elseif os(tvOS)
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            FilmVideoView(player: player.video)
                .background {
                    FilmPhaseStageView(player: player, headTracking: session.headTracking,
                                       recenterRequest: session.recenterRequest)
                }
                .overlay { subtitleOverlay }
            FilmTransport(player: player).frame(width: 820).padding(.bottom, 40)
        }
        .overlay(alignment: .bottomTrailing) {
            if let prompt = prompt(controlsVisible: true) {
                prompt
                    .padding(.trailing, 90)
                    .padding(.bottom, 60)
            }
        }
        .onPlayPauseCommand { player.isPlaying ? player.pause() : player.play() }
        #else
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            FilmVideoView(player: player.video)
                .background {
                    FilmStageView(player: player) { HeadphoneHeadTracker.shared.orientation }
                }
                .overlay { subtitleOverlay }
                // The layer is sized to the picture and centred here rather
                // than left to its video gravity, which on iPad drew the
                // picture against the top of the screen.
                .aspectRatio(pictureAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            FilmTransport(player: player).padding(16)
        }
        .overlay(alignment: .bottomTrailing) {
            if let prompt = prompt(controlsVisible: true) {
                prompt
                    .padding(.trailing, 24)
                    .padding(.bottom, 140)
            }
        }
        .onAppear { if session.headTracking { HeadphoneHeadTracker.shared.start() } }
        .onDisappear { HeadphoneHeadTracker.shared.stop() }
        .onChange(of: session.headTracking) { _, enabled in
            if enabled { HeadphoneHeadTracker.shared.start() }
            else { HeadphoneHeadTracker.shared.stop() }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { HeadphoneHeadTracker.shared.recenter() }
        }
        #endif
    }

    #if os(visionOS)
    /// The subtitles to hang under a stereo picture, if set to show there.
    private var bandSubtitles: SubtitleController? {
        session.subtitles.selected != nil
            && (stereoSource != nil ? stereoSubtitleStyle : flatSubtitleStyle) == .belowPicture
            ? session.subtitles : nil
    }

    // MARK: Chrome auto-hide

    private static let chromeHideDelay: Duration = .seconds(4)

    private func toggleChrome() {
        // With a menu open a tap on the picture only closes it: the system
        // has closed a real menu by now, the More popover closes on
        // `menuDismissals`, and holds that never let go are dropped (see
        // `clearLostHolds`).
        if chromeOpen || chromeHolds > 0 {
            clearLostHolds()
            menuDismissals += 1
            revealChrome()
            return
        }
        if chromeVisible {
            chromeHideTask?.cancel()
            chromeVisible = false
        } else {
            revealChrome()
        }
    }

    private func revealChrome() {
        chromeVisible = true
        scheduleChromeHide()
    }

    /// Menus hold the chrome from their content's appear and disappear, and
    /// one the system closes while the window is away (the headset sleeping,
    /// another app's immersive space) never lets go: the picture stayed
    /// dimmed and the chrome pinned (device, 2026-10-07).
    private func clearLostHolds() {
        chromeOpen = false
        morePopoverOpen = false
        chromeHolds = 0
    }

    /// A menu, sheet or scrub is holding the chrome up (true) or let go.
    private func holdChrome(_ held: Bool) {
        chromeHolds = max(0, chromeHolds + (held ? 1 : -1))
        if held {
            chromeHideTask?.cancel()
            chromeVisible = true
        } else {
            scheduleChromeHide()
        }
    }

    /// Hides after a quiet spell, only while playing: a paused film keeps
    /// its controls, the way the system player does.
    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        guard chromeHolds == 0 else { return }
        chromeHideTask = Task {
            try? await Task.sleep(for: Self.chromeHideDelay)
            guard !Task.isCancelled, player.isPlaying, chromeHolds == 0 else { return }
            chromeVisible = false
        }
    }

    static let dolbyVisionOriginalIn3D = "This film's Dolby Vision picture plays in 3D only as the server's converted copy. Playback continues in 2D."

    /// The cinema space belongs to this window: it closes with it.
    private func closeCinema() {
        guard cinema.isOpen else { return }
        Task { await dismissImmersiveSpace() }
    }

    private func startStereo() {
        guard stereoSource == nil, cinema.mode != .bigScreen else { return }
        // A 3D film already has both eyes; only a flat one needs depth.
        let layout = session.stereoFormat?.packedLayout(eyesReversed: false)
        guard layout != nil || CoreMLDepthProvider.hasAvailableModel(role: .realtime) else {
            showsDepthSetup = true
            return
        }
        // Under Auto, fetch the plugin's 1080p picture before starting AI 3D.
        // The flat film returns to its original picture when 3D ends.
        if layout == nil, FilmPictureQuality.preferred == .auto,
           !autoAI3DTierAttempted, player.video.pictureHeight == nil,
           player.video.offeredPictureHeights.contains(1080) {
            autoAI3DTierAttempted = true
            let requestID = UUID()
            stereoTierRequestID = requestID
            let itemID = session.loadedItem?.id
            Task {
                let changed = await player.video.setPictureHeight(1080)
                guard stereoTierRequestID == requestID, session.loadedItem?.id == itemID else {
                    if changed, session.loadedItem?.id == itemID {
                        _ = await player.video.setPictureHeight(nil)
                    }
                    return
                }
                if changed {
                    stereoTierForAutoAI3D = 1080
                }
                startStereo()
            }
            return
        }
        // Dolby Vision profile 5 shows right only through the system's own
        // renderer, which the 3D picture isn't. The plugin's lower tiers are
        // that picture converted to HDR10 on the server, so 3D plays one,
        // and leaving 3D goes back to the original.
        if player.video.index?.needsSystemRenderer == true, player.video.pictureHeight == nil {
            guard let tier = FilmPictureQuality.stepDown(from: nil, offering: player.video.offeredPictureHeights) else {
                stereoFailure = player.video.isOffline
                    ? "This download has only the film's Dolby Vision picture, which can't play in 3D. Playback continues in 2D."
                    : "This film's Dolby Vision picture needs converting on the server for 3D, and the server can't. Playback continues in 2D."
                return
            }
            stereoTierForDolbyVision = tier
            Task {
                guard await player.video.setPictureHeight(tier) else {
                    stereoTierForDolbyVision = nil
                    stereoFailure = "The converted picture for 3D couldn't be loaded. Playback continues in 2D."
                    return
                }
                startStereo()
            }
            return
        }
        stereoLayout = layout
        let source = SampleBufferFrameSource(timebase: player.video.timebase)
        player.video.onSampleBuffer = { source.submit($0) }
        player.video.onFlush = { source.reset() }
        session.stereoTapOwner = ObjectIdentifier(source)
        mountedDepthModelName = appModel.realtimeDepthModelName
        stereoSource = source
        session.stereoEnabled = true
        stereoLoadStrikes = 0
        stereoLoadGraceUntil = .now.addingTimeInterval(5)
        // Re-prime from the keyframe containing the current position. The film
        // transport keeps its play/pause intent and re-anchors Atmos with it.
        player.seek(to: player.currentTime)
    }

    /// `keepingPosition` false only when something else positions the
    /// picture next: a different film loading, or 3D restarting at once.
    private func stopStereo(keepingPosition: Bool = true) {
        stereoTierRequestID = UUID()
        guard let source = stereoSource else {
            autoAI3DTierAttempted = false
            return
        }
        source.close()
        let position = player.currentTime
        if stereoTierForDolbyVision != nil, keepingPosition, player.video.pictureHeight == stereoTierForDolbyVision {
            // Back to the original Dolby Vision picture, which the flat
            // (system) renderer shows as it is.
            Task { _ = await player.video.setPictureHeight(nil) }
        } else if stereoTierForAutoAI3D != nil, keepingPosition,
                  FilmPictureQuality.preferred == .auto,
                  player.video.pictureHeight == stereoTierForAutoAI3D {
            Task { _ = await player.video.setPictureHeight(nil) }
        }
        stereoTierForDolbyVision = nil
        if keepingPosition || player.video.pictureHeight != stereoTierForAutoAI3D {
            stereoTierForAutoAI3D = nil
        }
        autoAI3DTierAttempted = false
        stereoSource = nil
        stereoLayout = nil
        mountedDepthModelName = nil
        // Another window's 3D may have taken the player since; that stays.
        guard session.stereoTapOwner == ObjectIdentifier(source) else { return }
        session.stereoTapOwner = nil
        player.video.onSampleBuffer = nil
        player.video.onFlush = nil
        session.stereoEnabled = false
        // The flat picture sat hidden while the stereo one showed; re-prime it
        // at the position the toggle was pressed at, so leaving 3D lands
        // exactly where 3D was, whatever the hidden renderer did meanwhile.
        guard keepingPosition, player.video.isLoaded else { return }
        AppLogger.filmPlayer.info("Leaving 3D at \(position, format: .fixed(precision: 2))s")
        player.seek(to: position)
    }
    #endif
}

#if os(tvOS)
/// The object audio's tuning with the remote: pickers and steps instead of
/// the other platforms' sliders. Every change applies live and is saved.
struct TVFilmSoundSettings: View {
    @Bindable private var session = FilmSession.shared

    /// Room dimensions (half-width, half-depth, ceiling above the ears).
    private enum RoomSize: String, CaseIterable, Identifiable {
        case small = "Small", medium = "Medium", large = "Large"
        var id: String { rawValue }
        var dimensions: SIMD3<Float> {
            switch self {
            case .small: SIMD3(1.5, 1.8, 1.2)
            case .medium: SIMD3(2.0, 2.5, 1.6)
            case .large: SIMD3(3.0, 3.5, 2.2)
            }
        }
    }

    private static let reverbLevels: [(title: String, db: Float)] = [
        ("Off", -40), ("Low", -24), ("Medium", -12), ("High", -6), ("Very High", -2),
    ]
    private static let bassLevels: [Float] = [-12, -6, -3, 0, 3, 6]

    var body: some View {
        @Bindable var player = session.player
        NavigationStack {
            Form {
                Section {
                    Picker("Room", selection: $player.reverbPreset) {
                        ForEach(RAVEReverbPreset.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Reverb", selection: $player.reverbDB) {
                        ForEach(Self.reverbLevels, id: \.db) { Text($0.title).tag($0.db) }
                        if !Self.reverbLevels.contains(where: { $0.db == player.reverbDB }) {
                            Text(String(format: "%.0f dB", player.reverbDB)).tag(player.reverbDB)
                        }
                    }
                    Picker("Room Size", selection: roomSize) {
                        ForEach(RoomSize.allCases) { Text($0.rawValue).tag(Optional($0)) }
                        if roomSize.wrappedValue == nil { Text("Custom").tag(RoomSize?.none) }
                    }
                } footer: {
                    Text("The room the film's sound plays in: its reverb and how far away its speakers seem.")
                }
                Section {
                    Picker("Bass", selection: $player.lfeGainDB) {
                        ForEach(Self.bassLevels, id: \.self) { Text(String(format: "%+.0f dB", $0)).tag($0) }
                        if !Self.bassLevels.contains(player.lfeGainDB) {
                            Text(String(format: "%+.0f dB", player.lfeGainDB)).tag(player.lfeGainDB)
                        }
                    }
                    Toggle("Head Tracking", isOn: $session.headTracking)
                    Button("Recenter") { session.recenterRequest += 1 }
                        .disabled(!session.headTracking)
                } footer: {
                    Text("Head tracking keeps the sound at the TV as you turn your head, on AirPods that support it. Recenter while facing the TV if the sound drifts to one side; it also recentres whenever you resume playback.")
                }
                Section {
                    LabeledContent("Picture Offset", value: String(format: "%+.0f ms", player.avOffsetMs))
                    HStack {
                        Button("Earlier") { player.avOffsetMs -= 10 }
                        Button("Later") { player.avOffsetMs += 10 }
                        Button("Reset") { player.avOffsetMs = 0 }
                    }
                } footer: {
                    Text("Moves the picture against the sound if speech looks out of step.")
                }
                if session.subtitles.selected != nil {
                    Section("Subtitles") { SubtitleDelayControl(controller: session.subtitles) }
                }
                if !player.video.offeredPictureHeights.isEmpty {
                    Section("Picture") { FilmPictureQualityPicker(player: player.video) }
                }
                Section("Objects") { FilmObjectMapPanel(player: player) }
            }
            .navigationTitle("Sound")
        }
        .onChange(of: player.reverbPreset) { session.saveSound() }
        .onChange(of: player.reverbDB) { session.saveSound() }
        .onChange(of: player.lfeGainDB) { session.saveSound() }
        .onChange(of: player.avOffsetMs) { session.saveSound() }
        .onChange(of: session.headTracking) { session.saveSound() }
    }

    private var roomSize: Binding<RoomSize?> {
        let player = session.player
        return Binding {
            let current = SIMD3(player.roomHalfWidth, player.roomHalfDepth, player.roomHeight)
            return RoomSize.allCases.first { simd_length($0.dimensions - current) < 0.01 }
        } set: { size in
            guard let size else { return }
            player.roomHalfWidth = size.dimensions.x
            player.roomHalfDepth = size.dimensions.y
            player.roomHeight = size.dimensions.z
            session.saveSound()
        }
    }
}
#endif

/// The FilmPlayer adapter for the same controls used by general videos and
/// Raven. It samples the timebase; a scrub preview lives in the SDK controls.
struct FilmTransport: View {
    let player: FilmPlayer
    var stereoEnabled = false
    var onToggle3D: (() -> Void)?
    var onModalChanged: (Bool) -> Void = { _ in }
    /// The More popover alone (it also reports through `onModalChanged`).
    var onMoreChanged: (Bool) -> Void = { _ in }
    /// Bumped by the host to close the More popover.
    var menuDismissal = 0
    /// Any touch of the controls, so auto-hide can restart its countdown.
    var onInteraction: () -> Void = {}
    /// A scrub holding the controls up (true) or done.
    var onHold: (Bool) -> Void = { _ in }
    @Bindable private var session = FilmSession.shared
    @State private var now = 0.0
    /// One of the bar's menus is open: the bar then reads nothing that moves
    /// (the clock stops updating `now`, the buffered position isn't read),
    /// since every update re-renders and re-lays out the bar, and an open
    /// visionOS menu redrew with it each time (device, 2026-10-08).
    @State private var menuOpen = false
    @State private var showsSound = false
    #if os(visionOS)
    @OpenWindowProxy private var openWindow
    #endif

    var body: some View {
        RAVEPlayerControls(
            // While a menu is open the bar reads nothing that moves (see `menuOpen`):
            // the buffered position updates twice a second too.
            state: RAVEPlayerControlState(currentTime: now, duration: player.duration,
                bufferedUntil: menuOpen ? now : player.video.bufferedUntil, isPlaying: player.isPlaying, isMuted: player.isMuted,
                volume: Double(player.volume)),
            togglePlayback: { player.isPlaying ? player.pause() : player.play() },
            seek: { player.seek(to: $0) }, toggleMute: { player.isMuted.toggle() },
            onInteraction: onInteraction,
            onScrubbingChanged: onHold,
            layout: Self.layout,
            onMenuChanged: { open in
                onMoreChanged(open)
                onModalChanged(open)
            },
            setVolume: { value in
                player.volume = Float(value)
                PlayerVolume.saved = value
            },
            menuDismissal: menuDismissal
        ) {
            PlayerAccessoryLayout {
                playbackItems
                soundAndPictureButton
            } menu: {
                PlayerPopoverSectionHeader("Playback")
                playbackItems
                Divider()
                PlayerPopoverSectionHeader("Sound and Picture")
                #if os(visionOS)
                if stereoEnabled {
                    PlayerStepRow(title: "Convergence",
                                  value: String(format: "%.2f", session.stereoSettings.convergence),
                                  decrease: { nudgeConvergence(-0.05) }, increase: { nudgeConvergence(0.05) })
                }
                #endif
                if session.subtitles.selected != nil {
                    PlayerStepRow(title: "Subtitle Timing",
                                  value: String(format: "%+.1f s", session.subtitles.delay),
                                  decrease: { session.subtitles.delay -= 0.5 },
                                  increase: { session.subtitles.delay += 0.5 },
                                  reset: session.subtitles.delay == 0 ? nil : { session.subtitles.delay = 0 })
                }
                soundAndPictureButton
            }
        }
        .sheet(isPresented: $showsSound) {
            #if os(tvOS)
            TVFilmSoundSettings()
            #else
            FilmAdjustmentsView()
                .toolbar { Button("Done") { showsSound = false } }
            #endif
        }
        .onChange(of: showsSound) { _, showing in
            onModalChanged(showing)
            if !showing { session.saveSound() }
        }
        // The host closes every menu with this; a menu that never reported
        // closing mustn't leave the clock stopped.
        .onChange(of: menuDismissal) { menuOpen = false }
        .task {
            while !Task.isCancelled {
                if !menuOpen { now = player.currentTime }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// A 3D film plays its own two eyes; a 2D one gets AI 3D.
    private var isStereoFilm: Bool { session.stereoFormat != nil }
    private var stereoMode: String { isStereoFilm ? "3D" : "AI 3D" }

    /// 2D or 3D, the bar's badge naming the one in force, as in the video
    /// window; picking the other switches.
    private func viewModeMenu(toggle: @escaping () -> Void) -> some View {
        PlayerChoiceMenu(title: "View Mode", systemImage: isStereoFilm ? "view.3d" : "wand.and.sparkles",
                         badge: stereoEnabled ? stereoMode : "2D", badgeIsActive: stereoEnabled,
                         onOpenChanged: menuChanged) { close in
            ForEach([false, true], id: \.self) { stereo in
                Button {
                    close()
                    if stereo != stereoEnabled { toggle() }
                } label: {
                    Label(stereo ? stereoMode : "2D", systemImage: "checkmark")
                        .labelStyle(CheckmarkLabelStyle(isChecked: stereo == stereoEnabled))
                }
            }
        }
        .accessibilityIdentifier("player.viewMode")
    }

    @ViewBuilder private var playbackItems: some View {
        if let onToggle3D {
            viewModeMenu(toggle: onToggle3D)
        }
        #if os(visionOS)
        FilmCinemaMenu(onOpenChanged: menuChanged)
        #endif
        if player.audioTracks.count > 1 {
            FilmAudioTrackMenu(player: player, onOpenChanged: menuChanged)
        }
        if player.audioEncoding != nil {
            ObjectAudioQualityMenu(player: player, onOpenChanged: menuChanged)
        }
        if !player.video.offeredPictureHeights.isEmpty {
            FilmPictureQualityMenu(player: player.video, onOpenChanged: menuChanged)
        }
        if !session.subtitles.tracks.isEmpty {
            SubtitleMenu(controller: session.subtitles, onOpenChanged: menuChanged)
        }
        #if os(iOS) || os(macOS)
        if session.headTracking, HeadphoneHeadTracker.shared.isTracking {
            Button { HeadphoneHeadTracker.shared.recenter() } label: {
                Label("Recenter Audio", systemImage: "scope").ravePlayerAccessoryLabel()
            }
            .help("Recenter audio while facing the picture")
        }
        #elseif os(tvOS)
        if session.headTracking, player.audio != nil {
            Button { session.recenterRequest += 1 } label: {
                Label("Recenter Audio", systemImage: "scope").ravePlayerAccessoryLabel()
            }
        }
        #endif
    }

    private var soundAndPictureButton: some View {
        Button {
            #if os(visionOS)
            openWindow(id: FilmAdjustmentsView.windowID)
            #else
            showsSound = true
            #endif
        } label: {
            Label("Sound and Picture…", systemImage: "slider.horizontal.3").ravePlayerAccessoryLabel()
        }
        .help("Sound and picture adjustments")
    }

    #if os(visionOS)
    private func nudgeConvergence(_ delta: Double) {
        session.stereoSettings.convergence = min(max(session.stereoSettings.convergence + delta, 0), 1)
    }
    #endif

    private func menuChanged(_ open: Bool) {
        menuOpen = open
        onModalChanged(open)
    }

    #if os(visionOS)
    /// One row under the window: every row of height is window the film
    /// doesn't get.
    private static var layout: RAVEPlayerControlsLayout { .compact }
    #else
    private static var layout: RAVEPlayerControlsLayout { .stacked }
    #endif
}

/// A separate visionOS window: a sheet shares the stereo picture's depth
/// region and can be occluded by it. Other platforms present this as a sheet.
struct FilmAdjustmentsView: View {
    static let windowID = "film-adjustments"
    @Bindable private var session = FilmSession.shared

    var body: some View {
        NavigationStack {
            #if os(visionOS) || os(macOS)
            HStack(spacing: 0) {
                Form { controls }
                    .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Objects").font(.headline)
                    FilmObjectMapPanel(player: session.player)
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 820, minHeight: 520)
            .navigationTitle("Sound and Picture")
            #else
            Form {
                controls
                Section("Objects") { FilmObjectMapPanel(player: session.player) }
            }
            .navigationTitle("Sound and Picture")
            #endif
        }
        .onDisappear { session.saveSound() }
    }

    @ViewBuilder private var controls: some View {
        #if os(iOS) || os(macOS)
        Section("Head Tracking") {
            Toggle("Head Tracking", isOn: $session.headTracking)
            FilmHeadTrackingRow()
        }
        #endif
        #if os(visionOS)
        if session.stereoEnabled {
            Section("3D") {
                Slider(value: $session.stereoSettings.convergence, in: 0...1)
                Text("Convergence: higher pushes the scene back; at 1 nothing crosses the window frame.")
                    .font(.caption)
            }
        }
        #endif
        if session.subtitles.selected != nil {
            Section("Subtitles") {
                SubtitleDelayControl(controller: session.subtitles)
                #if os(visionOS)
                if session.stereoEnabled { StereoSubtitleSettings(subtitles: session.subtitles) } else { FlatSubtitleSettings() }
                #endif
            }
        }
        if !session.player.video.offeredPictureHeights.isEmpty {
            Section("Picture") { FilmPictureQualityPicker(player: session.player.video) }
        }
        Section("Room") { FilmRoomPicker() }
        Section("Sound") { FilmTuning() }
        Section("Telemetry") { FilmTelemetry(player: session.player) }
    }
}

/// The room the film plays in on a RealityKit stage: the system's acoustics
/// (on visionOS, the room the wearer is in, which a window can't change) or
/// one of `FilmRoomReverb`'s. The Reverb slider sets how much of either.
struct FilmRoomPicker: View {
    @Bindable private var session = FilmSession.shared

    private enum Choice: Hashable {
        case system
        case preset(RAVEReverbPreset)
    }

    var body: some View {
        let player = session.player
        let choice = Binding<Choice> {
            player.roomSource == .system ? .system : .preset(player.reverbPreset)
        } set: { choice in
            switch choice {
            case .system:
                player.roomSource = .system
            case .preset(let preset):
                player.roomSource = .virtual
                player.reverbPreset = preset
            }
            session.saveSound()
        }
        Picker("Room", selection: choice) {
            #if os(visionOS)
            Text("Your Room").tag(Choice.system)
            #else
            Text("System").tag(Choice.system)
            #endif
            ForEach(RAVEReverbPreset.allCases) { preset in
                Text(preset == .none ? "Open Air" : preset.title).tag(Choice.preset(preset))
            }
        }
        #if os(visionOS)
        Text("Your Room is how visionOS hears the room you're in. The others replace it with a room of the film's own; Open Air has none.")
            .font(.caption)
        #endif
    }
}

struct FilmTuning: View {
    @Bindable private var session = FilmSession.shared

    var body: some View {
        @Bindable var player = session.player
        Group {
            slider("Master", value: $player.masterGainDB, in: -24 ... 12, unit: "dB")
            slider("LFE", value: $player.lfeGainDB, in: -24 ... 10, unit: "dB")
            slider("Reverb", value: $player.reverbDB, in: -40 ... 0, unit: "dB")
            slider("Room half-width", value: $player.roomHalfWidth, in: 0.5 ... 5, unit: "m")
            slider("Room half-depth", value: $player.roomHalfDepth, in: 0.5 ... 5, unit: "m")
            slider("Ceiling above ears", value: $player.roomHeight, in: 0 ... 3, unit: "m")
            #if os(visionOS)
            Toggle("Follow the window's distance", isOn: Binding {
                session.listenerDistanceAuto
            } set: { auto in
                // Manual starts where the guess was, so the sound doesn't jump.
                if !auto { session.listenerDistance = min(max(session.listenerPlacement.metres(windowScale: session.windowScale), 0.3), 12) }
                session.listenerDistanceAuto = auto
            })
            if session.listenerDistanceAuto {
                Text(String(format: "You, in front of the window: about %.1f m (window scaled ×%.2f)",
                            session.listenerPlacement.metres(windowScale: session.windowScale), session.windowScale))
                    .font(.caption)
            } else {
                slider("You, in front of the window", value: $session.listenerDistance, in: 0.3 ... 12, unit: "m")
            }
            if FilmCinema.shared.isOpen {
                Text("Cinema is open: the sound is centred on your head, so these are a fallback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FilmCinemaSettings()
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Picture offset: %+.0f ms", player.avOffsetMs)).font(.caption)
                #if !os(tvOS)
                Slider(value: $player.avOffsetMs, in: -300 ... 300, step: 10)
                #endif
            }
            Toggle("Flatten heights (A/B vs no height)", isOn: $player.flattenHeights)
        }
    }

    // Not reachable on tvOS — this view is only built from the visionOS
    // ornament section and the iOS Form tool sheet, never the tvOS film
    // player (see TVFilmPlayerView) — but `Slider` still has to typecheck
    // for a tvOS build of the module.
    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(String(format: "%.1f", value.wrappedValue)) \(unit)").font(.caption)
            #if !os(tvOS)
            Slider(value: value, in: range)
            #endif
        }
    }
}

#if os(iOS) || os(macOS)
/// Status, Recenter and latency prediction for the AirPods head tracking.
struct FilmHeadTrackingRow: View {
    @Bindable private var tracker = HeadphoneHeadTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tracker.status)
                    Text(String(format: "yaw %+.0f°  pitch %+.0f°", tracker.yawDegrees, tracker.pitchDegrees))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Recenter") { tracker.recenter() }
                    .buttonStyle(.bordered)
                    .disabled(!tracker.isTracking)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Prediction: \(Int(tracker.predictionMs)) ms (route reports \(Int(tracker.reportedLatencyMs)) ms)")
                    .font(.caption)
                HStack {
                    Slider(value: $tracker.predictionMs, in: 0 ... 400, step: 10)
                    Button("Default") { tracker.useReportedLatency() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}
#endif

struct FilmTelemetry: View {
    let player: FilmPlayer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                Text(player.video.formatSummary)
                Text(String(format: "Video: %@ · segment %d · last seek %.0f ms",
                            player.video.status, player.video.currentSegment, player.video.lastSeekLatency * 1000))
                Text("Audio: \(player.audioStatus) · \(player.clockReport)")
                Text(String(format: "Output latency %.0f ms · skew %@", player.outputLatency * 1000,
                            player.scheduledSkewMs.map { String(format: "%+.0f ms", $0) } ?? "—"))
            }
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
            .selectableText()
        }
    }
}

/// A menu row whose checkmark shows only on the chosen one, keeping the
/// titles aligned.
struct CheckmarkLabelStyle: LabelStyle {
    let isChecked: Bool

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.opacity(isChecked ? 1 : 0)
        }
    }
}
