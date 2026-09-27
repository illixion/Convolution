/*
 Hypnos - Video Window View

 Window view for video playback.
 Handles two modes:
 - Pushed (wasPushed=true): opened via pushWindow from gallery, dismiss returns to gallery.
   Shows full ornament with navigation, rating, share, adjustments, flip, pop-out.
 - Standalone (wasPushed=false): opened via openWindow as independent pop-out window.
   Shows same ornament as pushed, but without pop-out button (matching photo viewer pattern).

 All per-window state lives in `VideoWindowModel` (created with @State here, like
 PhotoWindowModel), so multiple video windows are fully independent.
 */

import RAVEMedia
import os
import RAVEUI
import SwiftUI

struct VideoWindowView: View {
    let windowValue: VideoWindowValue
    @State private var windowModel: VideoWindowModel
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    /// THIS window's scene (used for aspect-ratio locking). Reading it from the
    /// environment avoids the multi-window bug of resizing an arbitrary
    /// foreground-active scene.
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    /// One-shot follow-up after an aspect-lock request: verifies what size the
    /// system actually granted and re-locks if it was clamped (tall videos).
    @State private var aspectRelockTask: Task<Void, Never>?

    /// Debounced mirror of the window's settled size into
    /// `RestoredWindowTracker`, so "save the current window arrangement" can read
    /// this window's live geometry. Debounced because a resize drag emits a
    /// geometry change per frame and each write hits UserDefaults.
    @State private var sizeWritebackTask: Task<Void, Never>?
    /// Whether the Library resume seek has run (see `applyStartPositionIfNeeded`).
    @State private var appliedStartPosition = false

    /// True once a group-restored size has been consumed by the aspect lock.
    /// The lock runs again on every prev/next, and after the first video the
    /// window is at the user's live size — re-applying the saved box would undo
    /// any resize they've since made.
    @State private var didApplyRestoredSize = false

    /// Reserved space below the video so the bottom ornament (which floats at the
    /// window's bottom edge) doesn't overlap the video. Larger for fake-3D, whose
    /// two-row ornament is taller and needs more clearance from the video plane.
    private var ornamentBottomPadding: CGFloat {
        windowModel.shouldUsePseudo3D ? 120 : 60
    }

    /// Depth offset (points, toward the viewer) applied to the fake-3D chrome.
    /// Kept at 0 so the ornament stays coplanar with the visionOS window
    /// controls on the window plane; the video is brought back to that same
    /// plane by `Pseudo3DVideoPlayerView.videoPlaneZRecess` (its front-aligned
    /// zero-depth slab measured ~9cm proud of the chrome on-device). An earlier
    /// 20cm forward push here floated the ornament off the controls plane and
    /// cast its silhouette over the window controls below. Tunable: nudge a few
    /// points forward only if residual stereo pop-out makes the chrome read as
    /// slightly behind near subjects.
    private let pseudo3DChromeZOffset: CGFloat = 0

    /// Upward lift (points) for the taller two-row fake-3D ornament so its lower
    /// transport row keeps clear of the visionOS window controls below the
    /// window. With the chrome now coplanar (no forward push) this is pure bottom
    /// padding rather than parallax compensation. visionOS points map to real cm
    /// at ~10 points/cm, so 50 ≈ 5cm.
    private let pseudo3DChromeBottomLift: CGFloat = 50

    init(windowValue: VideoWindowValue, appModel: AppModel) {
        // Re-resolve local file URLs in case this is a visionOS scene restoration
        // where the sandbox container UUID has changed since the window was saved.
        let resolved = windowValue.resolvingLocalFileURLs()
        self.windowValue = resolved
        _windowModel = State(initialValue: VideoWindowModel(windowValue: resolved, appModel: appModel))
    }

    private var video: GalleryVideo { windowModel.video }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Group {
                    if appModel.allWindowsHidden {
                        Color.clear
                    } else if windowModel.shouldUse3DMode {
                        StereoscopicVideoView(
                            video: video,
                            windowModel: windowModel,
                            initialSettings: windowModel.video3DSettings,
                            onRevertTo2D: {
                                windowModel.stereoscopicOverride = false
                            },
                            onSettingsChanged: { newSettings in
                                windowModel.video3DSettings = newSettings
                            }
                        )
                        .id("\(video.id)_3d")
                    } else if windowModel.shouldUsePseudo3D {
                        Pseudo3DVideoPlayerView(
                            videoURL: windowModel.authenticatedStreamURL,
                            isRoomActive: windowModel.isInActiveRoom,
                            // Recede the video (in-scene) while a menu/popover is
                            // open so it doesn't occlude the presented chrome.
                            chromeOpen: windowModel.isChromeModalOpen,
                            onVideoSizeKnown: { size in
                                lockWindowToVideoAspectRatio(videoSize: size)
                            },
                            visualAdjustments: windowModel.effectiveVideoAdjustments,
                            settings: windowModel.effectivePseudo3DSettings,
                            depthMode: windowModel.pseudo3DDepthMode,
                            startAtSeconds: windowModel.pseudo3DEngageResumeTime,
                            startPaused: windowModel.pseudo3DEngagePaused,
                            isFlipped: windowModel.isFlipped,
                            loopController: windowModel.loopController,
                            playbackModel: windowModel,
                            // Current window mute state, so engaging fake-3D
                            // mid-watch keeps the user's unmute.
                            startMuted: windowModel.isMuted,
                            onPlaybackError: {
                                // Fall back to the flat native player if the
                                // stereo pipeline can't decode this source.
                                windowModel.disablePseudo3D()
                            },
                            // A 2D transparent overlay can't catch gaze over a
                            // RealityView, so the tap-to-toggle lives inside it as
                            // a RealityKit tap target instead.
                            onToggleUI: {
                                windowModel.toggleUIVisibility()
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("\(video.id)_pseudo3d")
                    } else {
                        switch windowModel.playbackRenderer {
                        case .resolving:
                            ProgressView("Loading video...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .id("\(video.id)_resolving")

                        case .nativeMetal:
                            NativeMetalVideoPlayerView(
                                videoURL: windowModel.authenticatedStreamURL,
                                isRoomActive: windowModel.isInActiveRoom,
                                onVideoSizeKnown: { size in
                                    lockWindowToVideoAspectRatio(videoSize: size)
                                },
                                visualAdjustments: windowModel.effectiveVideoAdjustments,
                                loopController: windowModel.loopController,
                                playbackModel: windowModel,
                                startMuted: windowModel.isMuted,
                                onPlaybackError: {
                                    windowModel.forceWebKitPlayback()
                                }
                            )
                            // Preserve aspect (the Metal renderer stretches the
                            // texture to fill its view). If the window can't match
                            // the video's aspect, this letterboxes rather than
                            // stretching — the fix for tall videos appearing wide.
                            .aspectRatio(windowModel.videoAspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id("\(video.id)_native")

                        case .webKit:
                            #if canImport(WebKit)
                            WebVideoPlayerView(
                                videoURL: windowModel.authenticatedStreamURL,
                                // Native Safari controls are off; our SwiftUI
                                // control bar drives playback via the JS bridge.
                                showControls: false,
                                isRoomActive: windowModel.isInActiveRoom,
                                onVideoSizeKnown: { size in
                                    lockWindowToVideoAspectRatio(videoSize: size)
                                },
                                visualAdjustments: windowModel.effectiveVideoAdjustments,
                                loopController: windowModel.loopController,
                                playbackModel: windowModel,
                                startMuted: windowModel.isMuted,
                                // WebKit couldn't decode the original file (or
                                // lost the connection for good): fall forward to
                                // Stash's server-side transcode.
                                onSourceUnplayable: {
                                    windowModel.handleSourceUnplayable()
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id("\(video.id)_web")
                            #else
                            // No WebKit on tvOS, so no fallback decoder either —
                            // if AVFoundation can't play the source natively,
                            // there is nothing left to try. See Hypnos/CLAUDE.md
                            // "tvOS" for the gap.
                            ContentUnavailableView(
                                "Can't Play This Video",
                                systemImage: "exclamationmark.triangle",
                                description: Text("This format needs a decoder that isn't available on Apple TV.")
                            )
                            .id("\(video.id)_unplayable")
                            #endif
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fake-3D handles the mirror inside the warp shader; mirroring
                // the RealityView container would invert the stereo pair too.
                .scaleEffect(x: (windowModel.isFlipped && !windowModel.shouldUsePseudo3D) ? -1 : 1, y: 1)
                .brightness(windowModel.shouldUse3DMode ? windowModel.effectiveVideoAdjustments.brightness : 0)
                .contrast(windowModel.shouldUse3DMode ? windowModel.effectiveVideoAdjustments.contrast : 1)
                .saturation(windowModel.shouldUse3DMode ? windowModel.effectiveVideoAdjustments.saturation : 1)
                .opacity(
                    windowModel.shouldUse3DMode || windowModel.playbackRenderer == .nativeMetal
                        ? windowModel.effectiveVideoAdjustments.opacity
                        : 1
                )
                .overlay {
                    // Transparent tap target over the video surface. Keep it
                    // present when chrome is visible too so tapping the video
                    // toggles controls both ways; transport controls are in a
                    // higher ZStack layer and still receive their own input.
                    // The pseudo-3D RealityView can't be toggled by a 2D overlay
                    // (gaze targets the 3D plane), so it carries its own tap
                    // target via onToggleUI instead.
                    //
                    // Exclude 3D (MV-HEVC) mode too: its in-window content is only
                    // progress/error/loading overlays (the video itself plays in the
                    // immersive space). The error overlay carries interactive Retry /
                    // Play as 2D buttons, and a tap target stacked above them would
                    // swallow those taps into a UI toggle instead.
                    if !appModel.allWindowsHidden, !windowModel.shouldUsePseudo3D, !windowModel.shouldUse3DMode {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture {
                                windowModel.toggleUIVisibility()
                            }
                    }
                }

                Spacer()
                    .frame(height: ornamentBottomPadding)
            }

            // Toast notification (A-B loop feedback)
            if let toast = windowModel.loopController.toastMessage {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(windowModel.loopController.toastIsError ? Color.red.opacity(0.85) : Color.black.opacity(0.7))
                            )
                        Spacer()
                    }
                    .padding(.bottom, ornamentBottomPadding + 96)
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut, value: windowModel.loopController.toastMessage)
            }

            // "3D ready" pill — this video's background depth conversion
            // finished (same capsule pattern as the photo 3D-restore prompt).
            if windowModel.showDepthReadyPrompt {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text(windowModel.depthReadyPromptMessage)
                            .font(.callout)
                            .lineLimit(1)

                        Button {
                            windowModel.engageCachedPseudo3D()
                        } label: {
                            Text("Watch in 3D")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            windowModel.dismissDepthReadyPrompt()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassBackgroundEffect(in: Capsule())
                    .padding(.bottom, ornamentBottomPadding + 96) // clear the ornament
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: windowModel.showDepthReadyPrompt)
            }

            // Custom playback controls (2D players only). In fake-3D the
            // transport is folded into the ornament (showTransport) so it shares
            // the chrome's depth instead of floating at the window plane.
            if !appModel.allWindowsHidden, !windowModel.shouldUse3DMode,
               !windowModel.shouldUsePseudo3D, !windowModel.isUIHidden {
                VStack {
                    Spacer()
                    VideoControlBar(windowModel: windowModel)
                        .padding(.horizontal, 24)
                        .padding(.bottom, ornamentBottomPadding + 12)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: windowModel.isUIHidden)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            recordWindowSize(newSize)
        }
        .persistentSystemOverlays(windowModel.isWindowControlsHidden ? .hidden : .visible)
        .hidesStatusBar(windowModel.isUIHidden)
        .ornament(
            visibility: windowModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                videoOrnament
                    // Lift the taller two-row ornament so its transport row
                    // clears the visionOS window controls beneath the window.
                    .padding(.bottom, windowModel.shouldUsePseudo3D ? pseudo3DChromeBottomLift : 0)
                    // Keep the fake-3D chrome coplanar with the video (which is
                    // pinned to the front glass via .frame(depth:0,.front)) and
                    // the window controls — see pseudo3DChromeZOffset. 0 = no
                    // forward push; the constant stays for on-device fine-tuning.
                    .offset(z: windowModel.shouldUsePseudo3D ? pseudo3DChromeZOffset : 0)
            }
        )
        .sheet(isPresented: $windowModel.showVideo3DSettingsSheet) {
            Video3DSettingsSheet(
                initialSettings: windowModel.video3DSettings,
                onApply: { settings in
                    Task {
                        await Video3DSettingsTracker.shared.saveSettings(
                            videoId: video.identity,
                            settings: settings
                        )
                    }
                    windowModel.video3DSettings = settings
                    windowModel.stereoscopicOverride = true
                },
                onCancel: nil
            )
        }
        .sheet(isPresented: $windowModel.showDepthModelSetup) {
            // First-run fake-3D: no depth model installed. Pick/download one,
            // then re-enter the engage flow (which now asks realtime vs
            // pre-processed).
            DepthModelSetupSheet(onModelReady: {
                windowModel.requestPseudo3D()
            })
        }
        .alert("Convert to 3D", isPresented: $windowModel.showPseudo3DModePrompt) {
            Button("Real-Time") {
                windowModel.engageRealtimePseudo3D()
            }
            Button("Pre-Process") {
                windowModel.startDepthPreprocessing()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Real-time starts instantly and plays at 30fps. Pre-process analyzes the whole video in the background first (about as long as the video), then plays at up to 60fps with steadier depth — you'll be notified when it's ready.")
        }
        .onChange(of: DepthConversionManager.shared.lastCompleted) { _, completed in
            guard let completed, completed.videoIdentity == video.identity else { return }
            windowModel.presentDepthReadyPrompt()
        }
        .onChange(of: DepthConversionManager.shared.lastError) { _, failure in
            guard let failure, failure.videoIdentity == video.identity else { return }
            windowModel.depthConversionFailureMessage = failure.message
        }
        .alert(
            "3D Conversion Failed",
            isPresented: Binding(
                get: { windowModel.depthConversionFailureMessage != nil },
                set: { if !$0 { windowModel.depthConversionFailureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(windowModel.depthConversionFailureMessage ?? "")
        }
        .onAppear {
            // Wall-snapped pop-outs restored by visionOS after a reboot come
            // back with the same windowValue UUID. Repeat appearances of the
            // same UUID are treated as system-restored — start with ornaments
            // hidden instead of arming the reveal timer.
            if !windowValue.wasPushed, RestoredWindowTracker.isRestored(windowValue.id) {
                windowModel.isRestoredPopOut = true
                windowModel.isUIHidden = true
                windowModel.isWindowControlsHidden = true
            } else {
                if !windowValue.wasPushed {
                    RestoredWindowTracker.markSeen(windowValue.id)
                }
                windowModel.startAutoHideTimer()
            }
            windowModel.start()
        }
        .onDisappear {
            aspectRelockTask?.cancel()
            sizeWritebackTask?.cancel()
            windowModel.cleanup()
            restoreWindowResizing()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            AppLogger.videoWindow.info(
                "[\(windowModel.videoDisplayName, privacy: .public)] scenePhase: \(phaseLabel(oldPhase), privacy: .public) → \(phaseLabel(newPhase), privacy: .public)"
            )
            windowModel.handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        // Library-feature progress sync: a no-op for every other source
        // (Stash/Nextcloud/Photos/Local) — gated on the synthetic
        // "jellyfin:" identity `LibraryPlaybackCoordinator.makeGalleryVideo`
        // stamps onto a Jellyfin item's adapter `GalleryVideo`. Restarts
        // (and reports a stop for the previous video) whenever `video`
        // changes, and reports a final stop when the window closes — see
        // the coordinator's doc comment for the exact start/progress/stopped
        // sequence this drives.
        .task(id: video.identity) {
            await applyStartPositionIfNeeded()
            await LibraryPlaybackCoordinator.reportGenericPlaybackProgress(
                video: video,
                currentTime: { windowModel.currentTime },
                isPaused: { windowModel.isPaused }
            )
        }
    }

    /// Seeks to `windowValue.startSeconds` (the Library's Resume) once the
    /// renderer is ready to take a seek, for the video the window opened
    /// with only. Gives up quietly after 30 s: a player that never became
    /// ready has bigger problems than a missed resume point.
    private func applyStartPositionIfNeeded() async {
        guard !appliedStartPosition,
              let start = windowValue.startSeconds, start > 0,
              video.identity == windowValue.video.identity
        else { return }
        appliedStartPosition = true
        for _ in 0..<120 {
            if windowModel.duration > 0, let seek = windowModel.seekCommand {
                seek(start)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }

    // MARK: - Ornament

    /// Unified ornament for both pushed and standalone windows.
    /// Only the pop-out button differs (hidden for standalone), matching photo viewer pattern.
    private var videoOrnament: some View {
        VideoOrnamentsView(
            windowModel: windowModel,
            showTransport: windowModel.shouldUsePseudo3D,
            onGalleryButtonTap: {
                appModel.showMainWindow(openWindow: openWindow)
            },
            onPopOut: windowValue.wasPushed ? {
                let newValue = VideoWindowValue(
                    video: windowModel.video,
                    // Preserve a static (Local) navigation list across pop-out.
                    galleryVideos: windowModel.usesStaticGalleryList ? windowModel.galleryVideos : nil,
                    stereoscopicOverride: windowModel.stereoscopicOverride,
                    video3DSettings: windowModel.video3DSettings,
                    pseudo3DEnabled: windowModel.pseudo3DEnabled,
                    // Only carry a *genuine* per-window override. Snapshotting
                    // an unmodified value would persist whatever `.default` is
                    // today, and since `effectivePseudo3DSettings` decides
                    // per-window-vs-global on `isModified`, a later change to
                    // that default would make the baked-in old value start
                    // counting as modified and shadow the global. nil keeps the
                    // window following the global, which is what it was doing.
                    pseudo3DSettings: windowModel.pseudo3DSettings.isModified
                        ? windowModel.pseudo3DSettings : nil
                )
                openWindow(id: "video-detail", value: newValue)
                dismissWindow()
            } : nil
        )
    }

    // MARK: - Window Aspect Ratio

    private var resolvedWindowScene: PlatformWindowScene? {
        if let sceneDelegate { return sceneDelegate.windowScene }
        #if os(macOS)
        return nil
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        #endif
    }

    /// Lock the window's resize aspect ratio to the video's native dimensions
    /// (reported by the HTML video element's loadedmetadata event).
    private func lockWindowToVideoAspectRatio(videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }

        let videoAspectRatio = videoSize.width / videoSize.height
        windowModel.videoAspectRatio = videoAspectRatio

        // The letterbox above is all a fixed-size window needs; the rest of
        // this method resizes the window to the video, which only visionOS allows.
        guard PlatformCapabilities.supportsWindowResizing,
              let windowScene = resolvedWindowScene else { return }

        // Fit the video area into a bounded box. The default box is square, so
        // the LONGER side is what gets capped: fixing width at 1200 meant a tall
        // (e.g. 1080x1920) video requested a ~2200pt window; visionOS clamps that
        // height, leaving a window wider than the video — and the Metal renderer
        // stretches the frame to fill it. Capping the longer side keeps the
        // requested window within limits and correctly proportioned for portrait,
        // square, and landscape alike.
        //
        // A window restored from a saved group instead fits the video inside the
        // geometry it was saved at, so the arrangement comes back as it was.
        // Consumed once — see `didApplyRestoredSize`.
        let maxVideoDimension: CGFloat = 1200
        var box = CGSize(width: maxVideoDimension, height: maxVideoDimension)
        if !didApplyRestoredSize,
           let saved = windowValue.restoredSize?.cgSize,
           saved.width > 2, saved.height > 2 {
            box = CGSize(width: saved.width, height: max(saved.height - ornamentBottomPadding, 100))
            didApplyRestoredSize = true
            AppLogger.videoWindow.info("Aspect lock: fitting video into restored group size \(Int(saved.width))x\(Int(saved.height))")
        }

        let videoWidth: CGFloat
        let videoHeight: CGFloat
        if box.height * videoAspectRatio <= box.width {
            videoHeight = box.height
            videoWidth = box.height * videoAspectRatio
        } else {
            videoWidth = box.width
            videoHeight = box.width / videoAspectRatio
        }
        let totalHeight = videoHeight + ornamentBottomPadding
        let windowSize = CGSize(width: videoWidth, height: totalHeight)

        AppLogger.videoWindow.info("Aspect lock: video \(Int(videoSize.width))x\(Int(videoSize.height)), requesting window \(Int(windowSize.width))x\(Int(windowSize.height)) (pad \(Int(self.ornamentBottomPadding)))")
        WindowGeometry.request(windowScene, size: windowSize, restriction: .uniform)

        // visionOS may clamp the granted size — portrait videos hit the
        // platform's max window height long before landscape ones hit the
        // width limit. A clamp under .uniform locks in a ratio that no longer
        // matches the video: permanent letterbox bands between the video and
        // the chrome, and no room left to enlarge. Read back what was actually
        // granted and, if it differs, re-lock to a video-true size that fits
        // inside the grant so the locked ratio always matches the content.
        aspectRelockTask?.cancel()
        aspectRelockTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let scene = resolvedWindowScene else { return }
            let granted = scene.effectiveGeometrySize
            AppLogger.videoWindow.info("Aspect lock readback: granted \(Int(granted.width))x\(Int(granted.height))")
            guard granted.width > 0, granted.height > 0,
                  abs(granted.width - windowSize.width) > 2 || abs(granted.height - windowSize.height) > 2
            else { return }
            let availableHeight = max(granted.height - ornamentBottomPadding, 100)
            let fit = min(granted.width / videoWidth, availableHeight / videoHeight)
            let corrected = CGSize(
                width: (videoWidth * fit).rounded(.down),
                height: (videoHeight * fit + ornamentBottomPadding).rounded(.down)
            )
            AppLogger.videoWindow.info(
                "Aspect lock clamped: requested \(Int(windowSize.width))x\(Int(windowSize.height)), granted \(Int(granted.width))x\(Int(granted.height)); re-locking to \(Int(corrected.width))x\(Int(corrected.height))"
            )
            WindowGeometry.request(scene, size: corrected, restriction: .uniform)
        }
    }

    private func restoreWindowResizing() {
        WindowGeometry.request(resolvedWindowScene, restriction: .freeform, animated: true)
    }

    // MARK: - Live Size Reporting

    /// Debounced write of the settled window size into `RestoredWindowTracker`,
    /// which is where saved window groups read each open window's geometry from.
    /// Only standalone windows are tracked — a pushed window isn't independently
    /// restorable, so it has no group entry to size.
    private func recordWindowSize(_ size: CGSize) {
        guard !windowValue.wasPushed, WindowSizePersistence.isPlausible(size) else { return }
        sizeWritebackTask?.cancel()
        sizeWritebackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            RestoredWindowTracker.setWindowSize(size, for: windowValue.id)
        }
    }

    private func phaseLabel(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
