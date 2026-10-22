/*
 Hypnos - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.
 All per-window state is read from VideoWindowModel so multiple video windows are
 independent. Styled to match PhotoOrnamentView.

 Bar layout: [Gallery] | [< N/M >] | [ViewMode: icon + 2D/3D/AI 3D v] [Subtitles v] [Quality v] [A-B] |
 [Info] [Share] | [... More v]. The title is the window's own, in its top-left
 corner (`PlayerTitleButton`, VideoWindowView).
 Playback and feature actions share RAVEUI's player controls in one ornament
 in both 2D and fake-3D. The immersive scene owns its own transport.
 The More menu holds Flip, All Adjustments (the standalone video-adjustments
 window), Slideshow, and Pop Out (pushed only).
 When the bar is too narrow, the compact bar's own More popover shows the
 same accessories as grouped rows instead (`menuSections`): Playback,
 Picture (flip, convergence and subtitle timing nudged in place), Window.
 */

import RAVEMedia
import RAVEUI
import SwiftUI

/// Footprint a spinner is pinned to when it stands in for a glyph in the
/// ornament bar, so the bar's height doesn't change while one is showing.
/// Matches `PhotoOrnamentView`'s.
private let videoOrnamentGlyphSize: CGFloat = 22

struct VideoOrnamentsView: View {
    @Bindable var windowModel: VideoWindowModel
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow
    @Environment(\.openURL) private var openURL
    @State private var depthModels = DepthModelManager.shared
    #if !os(visionOS)
    /// Set while the ornament's horizontal scroller is being dragged; see
    /// `EnvironmentValues.ornamentIsScrolling`.
    @Environment(\.ornamentIsScrolling) private var ornamentIsScrolling
    #endif

    /// Action to show the main gallery window
    var onGalleryButtonTap: () -> Void
    /// Custom pop-out action (used by pushed windows to open a new window and dismiss self)
    var onPopOut: (() -> Void)? = nil

    private var video: GalleryVideo { windowModel.video }

    var body: some View {
        chromeObservers(bar)
    }

    @ViewBuilder
    private var bar: some View {
        if windowModel.usesImmersiveStereo {
            // Immersive playback owns its own transport in the immersive scene.
            HStack(spacing: RAVEChromeMetrics.spacing) { ornamentItems(isImmersive: true) }
                .padding(12).glassBackgroundEffect()
        } else {
            VideoControlBar(windowModel: windowModel, pinned: cinemaButton) { ornamentItems(isImmersive: false) }
        }
    }

    /// The Cinema button, kept on the bar.
    private var cinemaButton: AnyView? {
        #if os(visionOS)
        AnyView(CinemaButton(owner: .video(ObjectIdentifier(windowModel)),
                             bigScreenAvailable: windowModel.playbackRenderer == .nativeMetal || windowModel.canUseTranscodedStream,
                             dismissal: windowModel.menuDismissals,
                             onOpenChanged: { windowModel.ornamentMenu("Cinema", opened: $0) }))
        #else
        nil
        #endif
    }

    /// The window's feature buttons: inline on the bar, or grouped rows in
    /// the compact bar's "More" popover when they don't fit.
    private func ornamentItems(isImmersive: Bool) -> some View {
        PlayerAccessoryLayout {
            barItems(isImmersive: isImmersive)
        } menu: {
            menuSections
        }
    }

    /// On the bar: icons, the quickest choices first.
    @ViewBuilder
    private func barItems(isImmersive: Bool) -> some View {
            galleryButton

            // Prev/next only browse something: a lone video (a Library film)
            // has nowhere to go.
            if windowModel.videoCount > 1 {
                Divider()
                    .frame(height: 24)
                previousButton
                videoCounter
                nextButton
            }

            Divider()
                .frame(height: 24)

            viewModeMenu
            subtitleMenu
            qualityMenu
            speedMenu
            // The immersive scene has its own transport, loop included.
            if !isImmersive {
                LoopControls(windowModel: windowModel)
            }

            // Info button (rating & metadata). Stash-only: the sheet fetches
            // scene detail by id and edits it through GraphQL, so there is
            // nothing for it to show for a local file or a stream. The photo
            // ornament already gates its Info button the same way on
            // `image.stashId != nil`.
            Divider()
                .frame(height: 24)
            if video.stashId != nil {
                infoButton
            }
            shareButton

            // More menu (flip, adjustments, slideshow, pop out)
            Divider()
                .frame(height: 24)

            moreMenu

            // Depth-conversion status for THIS video — visible at a glance
            // without keeping the ViewMode menu open. Isolated in its own view
            // so its continuous observation of DepthConversionManager doesn't
            // re-run THIS body (which holds the Menu) — a parent that observes
            // the manager recreates the Menu ~30-60×/sec, refreshing the open
            // dropdown and dropping taps.
            ConversionStatusRow(videoIdentity: video.identity)
    }

    /// In the More popover: one level of grouped rows, with the settings
    /// people reach for mid-film (flip, convergence, subtitle timing) right
    /// here rather than in the Adjustments window.
    @ViewBuilder
    private var menuSections: some View {
        PlayerPopoverSectionHeader("Playback")
        viewModeMenu
        subtitleMenu
        qualityMenu
        speedMenu
        LoopControls(windowModel: windowModel)
        ConversionStatusRow(videoIdentity: video.identity)

        Divider()
        PlayerPopoverSectionHeader("Picture")
        flipButton
        if windowModel.shouldUsePseudo3D {
            let convergence = windowModel.effectivePseudo3DSettings.convergence
            PlayerStepRow(title: "Convergence", value: String(format: "%.2f", convergence),
                          decrease: { nudgeConvergence(-0.05) }, increase: { nudgeConvergence(0.05) })
        }
        if windowModel.subtitles.selected != nil {
            PlayerStepRow(title: "Subtitle Timing",
                          value: String(format: "%+.1f s", windowModel.subtitles.delay),
                          decrease: { windowModel.subtitles.delay -= 0.5 },
                          increase: { windowModel.subtitles.delay += 0.5 },
                          reset: windowModel.subtitles.delay == 0 ? nil : { windowModel.subtitles.delay = 0 })
        }
        adjustmentsButton(close: {})

        Divider()
        PlayerPopoverSectionHeader("Window")
        if windowModel.videoCount > 1 {
            HStack(spacing: 4) {
                previousButton
                videoCounter
                nextButton
            }
        }
        galleryButton
        if video.stashId != nil {
            infoButton
        }
        shareButton
        windowItems(close: {})
    }

    private var galleryButton: some View {
        Button(action: onGalleryButtonTap) {
            OrnamentGlyph(title: windowModel.wasPushed ? "Videos" : "Gallery", systemImage: "square.grid.2x2")
        }
        .raveChromeButtonStyle()
        .help(windowModel.wasPushed ? "Videos" : "Show Gallery")
    }

    private var previousButton: some View {
        Button {
            windowModel.previousVideo()
        } label: {
            OrnamentGlyph(title: "Previous Video", systemImage: "chevron.left")
        }
        .raveChromeButtonStyle()
        .disabled(!windowModel.hasPreviousVideo)
    }

    private var nextButton: some View {
        Button {
            windowModel.nextVideo()
        } label: {
            OrnamentGlyph(title: "Next Video", systemImage: "chevron.right")
        }
        .raveChromeButtonStyle()
        .disabled(!windowModel.hasNextVideo)
    }

    private var videoCounter: some View {
        Text("\(windowModel.currentVideoPosition) / \(windowModel.videoCount)")
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(minWidth: 60)
    }

    @ViewBuilder
    private var subtitleMenu: some View {
        if !windowModel.subtitles.tracks.isEmpty {
            SubtitleMenu(controller: windowModel.subtitles, onOpenChanged: { chromeMenu("Subtitles", opened: $0) })
        }
    }

    @ViewBuilder
    private var qualityMenu: some View {
        if windowModel.offersQualityChoice {
            StreamQualityMenu(selected: windowModel.qualityPreference, label: windowModel.qualityLabel,
                              badge: windowModel.qualityBadge,
                              isChanging: windowModel.isChangingQuality,
                              onOpenChanged: { chromeMenu("Quality", opened: $0) }) { quality in
                windowModel.setQuality(quality)
            }
        }
        #if HYPNOS_YOUTUBE
        if windowModel.youTubeID != nil {
            YouTubeQualityMenu(selected: windowModel.youTubeQuality, label: windowModel.youTubeQualityLabel,
                               badge: windowModel.youTubeQualityBadge,
                               onOpenChanged: { chromeMenu("Quality", opened: $0) }) { quality in
                windowModel.setYouTubeQuality(quality)
            }
        }
        #endif
    }

    private var speedMenu: some View {
        PlaybackSpeedMenu(speed: windowModel.playbackSpeed, onOpenChanged: { chromeMenu("Speed", opened: $0) }) { speed in
            windowModel.setPlaybackSpeed(speed)
        }
    }

    private var flipButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { windowModel.toggleFlip() }
        } label: {
            Label(windowModel.isFlipped ? "Unflip" : "Flip Horizontally",
                  systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
    }

    private func nudgeConvergence(_ delta: Double) {
        var settings = windowModel.effectivePseudo3DSettings
        settings.convergence = min(max(settings.convergence + delta, 0), 1)
        windowModel.pseudo3DSettings = settings
    }

    /// Modifiers the feature buttons share, wherever they are shown.
    private func chromeObservers(_ content: some View) -> some View {
        content
        #if !os(visionOS)
        // The bar scrolls when it is wider than the screen, and a scroll is
        // not a button press — without this the chrome auto-hides out from
        // under the finger mid-drag. The signal comes from the scroller
        // (`\.ornamentIsScrolling`) rather than from a drag gesture here: a
        // zero-distance DragGesture on the scroller's content takes the touch
        // at touch-down and the pan never starts, which is what made the
        // controls past the right edge unreachable.
        .onChange(of: ornamentIsScrolling) { _, isScrolling in
            if isScrolling { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        #endif
        .onChange(of: windowModel.showMediaInfo) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: windowModel.showAdjustments) { _, isOpen in
            // Adjustments now presents as a side ornament (VideoWindowView), so
            // it never overlaps the video; just pause auto-hide while it's open.
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: windowModel.showShareSheet) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
    }

    // MARK: - Info Button

    private var infoButton: some View {
        Button {
            windowModel.showMediaInfo.toggle()
        } label: {
            OrnamentGlyph(title: "Info", systemImage: video.rating100 != nil ? "info.circle.fill" : "info.circle")
                .foregroundColor(video.rating100 != nil ? .yellow : nil)
        }
        .raveChromeButtonStyle()
        .help("Info")
        .sheet(isPresented: $windowModel.showMediaInfo) {
            MediaDetailSheet(
                // Only reachable when `stashId` is non-nil — the Info button is
                // hidden otherwise, since there is no scene on the server to
                // fetch detail for.
                mediaType: .scene(stashId: video.stashId ?? ""),
                onDelete: {
                    let identity = video.identity
                    appModel.galleryVideos.removeAll { $0.identity == identity }
                    windowModel.galleryVideos.removeAll { $0.identity == identity }
                    dismissWindow()
                },
                onSaved: { newRating in
                    // Locate by identity, not stashId: comparing two optionals
                    // would match the first nil-stashId video in the snapshot
                    // rather than this one.
                    let identity = video.identity
                    windowModel.video.rating100 = newRating
                    if let idx = windowModel.galleryVideos.firstIndex(where: { $0.identity == identity }) {
                        windowModel.galleryVideos[idx].rating100 = newRating
                    }
                }
            )
        }
    }

    // MARK: - Share

    private var shareButton: some View {
        Button {
            Task { await windowModel.shareVideo() }
        } label: {
            Group {
                if windowModel.isPreparingShare {
                    // Pinned to the icon's footprint: a bare ProgressView is
                    // taller than a .title3 glyph and scaleEffect only scales
                    // rendering, not layout, so the ornament bar would grow
                    // while a share is being prepared.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: videoOrnamentGlyphSize, height: videoOrnamentGlyphSize)
                } else {
                    OrnamentGlyph(title: "Share", systemImage: "square.and.arrow.up")
                }
            }
            .font(.title3)
        }
        .raveChromeButtonStyle()
        .disabled(windowModel.isPreparingShare)
        .help("Share")
        .sheet(isPresented: Binding(
            get: { windowModel.shareFileURL != nil },
            set: { if !$0 { windowModel.shareFileURL = nil } }
        )) {
            windowModel.startAutoHideTimer()
        } content: {
            // No share sheet on tvOS (see PhotoOrnamentView's Share button
            // for the same note) — this ornament isn't part of the tvOS root
            // UI's video player anyway.
            #if !os(tvOS) && !os(macOS)
            if let url = windowModel.shareFileURL {
                ActivityViewController(
                    activityItems: [url],
                    isPresented: Binding(
                        get: { windowModel.shareFileURL != nil },
                        set: { if !$0 { windowModel.shareFileURL = nil } }
                    )
                )
            }
            #endif
        }
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        MoreOptionsControl(highlighted: moreMenuHighlighted,
                           onOpenChanged: { opened, asPopover in
                               chromeMenu(asPopover ? "More Options popover" : "More Options", opened: opened)
                           }) { close in
            Button {
                close()
                withAnimation(.easeInOut(duration: 0.3)) { windowModel.toggleFlip() }
            } label: {
                Label(windowModel.isFlipped ? "Unflip" : "Flip Horizontally",
                      systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            adjustmentsButton(close: close)
            Divider()
            windowItems(close: close)
        }
    }

    /// Opens the standalone Adjustments window (repositionable, never
    /// overlaps the video). showAdjustments pauses auto-hide.
    private func adjustmentsButton(close: @escaping () -> Void) -> some View {
        Button {
            close()
            appModel.videoAdjustmentsTarget = windowModel
            windowModel.showAdjustments = true
            openWindow(id: "video-adjustments")
        } label: {
            Label("All Adjustments…", systemImage: "slider.horizontal.3")
        }
    }

    /// Slideshow, Pop Out (pushed only) and the Safari fallback.
    @ViewBuilder
    private func windowItems(close: @escaping () -> Void) -> some View {
        Button {
            close()
            launchVideoSlideshow()
        } label: {
            Label("Slideshow", systemImage: "play.fill")
        }

        if windowModel.wasPushed, onPopOut != nil {
            Button {
                close()
                onPopOut?()
            } label: {
                Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.forward")
            }
        }

        // Last-resort fallback for a web-sourced stream the in-app
        // players (native + WebKit) can't decode — open it in Safari.
        if isRemoteStream, !windowModel.offersQualityChoice {
            Button {
                close()
                openURL(windowModel.video.streamURL)
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
        }
    }

    /// Whether this window is playing a remote http(s) stream (vs a local file).
    private var isRemoteStream: Bool {
        let scheme = windowModel.video.streamURL.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Whether the More menu button should show a highlight
    private var moreMenuHighlighted: Bool {
        windowModel.effectiveVideoAdjustments.isModified || windowModel.isFlipped
    }

    private func chromeMenu(_ name: String, opened: Bool) {
        windowModel.ornamentMenu(name, opened: opened)
    }

    // MARK: - Helpers

    private func launchVideoSlideshow() {
        // Run the slideshow over the same video source/filter this window is browsing.
        appModel.startVideoSlideshow(
            videoSource: windowModel.videoSource,
            filter: windowModel.snapshotFilter
        )
    }

    // MARK: - View Mode Menu

    @ViewBuilder
    private var viewModeMenu: some View {
        Menu {
            // Pause auto-hide + flag chrome open (recedes fake-3D so this menu
            // isn't occluded), same pattern as the More menu.
            Group {
            // The three modes behave like a radio group: exactly one carries
            // the checkmark, selecting another switches directly (each engage
            // path turns the other modes off), and re-selecting the active
            // one is a no-op — leaving a mode means picking a different one.
            modeButton("2D", mode: .flat) {
                windowModel.set2DMode()
            }

            if PlatformCapabilities.supportsImmersiveSpaces {
                Divider()

                // A stereo video plays live in the window; Immersive 3D
                // downloads and converts it first for the immersive screen.
                modeButton(ViewMode.stereoscopic.title, mode: .stereoscopic) {
                    Task { await windowModel.enable3DMode() }
                }

                modeButton(ViewMode.immersive.title, mode: .immersive) {
                    Task { await windowModel.enable3DMode(immersive: true) }
                }

                if windowModel.shouldUse3DMode {
                    Divider()

                    Button {
                        windowModel.showVideo3DSettingsSheet = true
                    } label: {
                        Label("Edit 3D Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }

            // Fake-3D conversion of a mono video: realtime inference or
            // pre-processed cached depth. Needs an AVFoundation-decodable
            // source — either already native, or reachable by swapping to the
            // Stash server transcode (how WebM qualifies). The whole pipeline
            // is the RAVEMedia stereo pump, which is visionOS-only.
            if PlatformCapabilities.supportsStereoVideo {
                Divider()

                // Named apart from "3D": this is depth estimated from a 2D
                // picture, not a 3D movie's own two eyes. Two items rather
                // than one with a follow-up prompt, so Pre-Processed can be
                // chosen while Real-Time is already playing: the conversion
                // runs and the window switches over at the safe point.
                modeButton(ViewMode.ai3DRealtime.title, subtitle: windowModel.pseudo3DAvailable
                           ? "Starts instantly" : "Not available for this video",
                           mode: .ai3DRealtime) {
                    windowModel.requestRealtimePseudo3D()
                }
                .disabled(!windowModel.pseudo3DAvailable)

                modeButton(ViewMode.ai3DPreprocessed.title, subtitle: windowModel.pseudo3DAvailable
                           ? "Analyzes the video first, then plays smoother" : nil,
                           mode: .ai3DPreprocessed) {
                    windowModel.requestPreprocessedPseudo3D()
                }
                .disabled(!windowModel.pseudo3DAvailable)

                // Background depth conversion for THIS video: status + cancel.
                // Isolated in its own view so its observation of the (continuously
                // updating) DepthConversionManager doesn't re-run this menu's body
                // — that recreates the whole Menu and makes the open dropdown drop
                // taps. The subview shows the phase *kind* only (no live %) so even
                // its own updates don't reflow the menu items.
                ConversionMenuStatus(videoIdentity: video.identity)

                // (No depth-strength presets: strength is fixed at the Subtle
                // level — anything above it demands more vergence than comfortably
                // fuses. Convergence stays adjustable in the Adjustments window.)

                // Depth-model pickers, one per pipeline, shown whenever fake-3D
                // is available. Real-Time live-reloads a playing fake-3D video;
                // Pre-Process picks the model future conversions (and the engage
                // flow's cache lookup) use — changing it here means the next
                // Convert to 3D offers a fresh conversion with that model.
                if windowModel.pseudo3DAvailable {
                    depthModelMenu(
                        "Depth Model (Real-Time)",
                        preference: appModel.realtimeDepthModelName
                    ) { appModel.realtimeDepthModelName = $0 }
                    depthModelMenu(
                        "Depth Model (Pre-Process)",
                        preference: appModel.preprocessDepthModelName
                    ) { appModel.preprocessDepthModelName = $0 }
                }
            }
            }
            // Silent inside the bar's More menu, which reports for it.
            .ravePlayerMenuReporting { chromeMenu("View Mode", opened: $0) }
        } label: {
            // A badge naming the mode in force ("2D", "AI 3D"), filled
            // while a 3D mode is on.
            ViewModeGlyph(mode: currentViewMode.badge, systemImage: currentViewMode.systemImage,
                          isActive: windowModel.shouldUse3DMode || windowModel.shouldUsePseudo3D)
        }
        // Match the other borderless ornament buttons: the default Menu style
        // renders a raised glass capsule that reads as "always highlighted"
        // (with a tiny disclosure glyph) even in 2D. Borderless keeps it flat,
        // so the only highlight comes from the active-mode background above.
        .menuStyle(.button)
        .raveChromeButtonStyle()
        .help("View Mode")
    }

    /// The three window viewing modes, mutually exclusive by construction
    /// (shouldUsePseudo3D already excludes shouldUse3DMode).
    private enum ViewMode {
        case flat, stereoscopic, immersive, ai3DRealtime, ai3DPreprocessed

        /// The menu item's name. Variants go in parentheses after the
        /// mode, as in the photo viewer's "RealityKit 3D (Immersive)".
        var title: String {
            switch self {
            case .flat: "2D"
            case .stereoscopic: "3D"
            case .immersive: "3D (Immersive)"
            case .ai3DRealtime: "AI 3D (Real-Time)"
            case .ai3DPreprocessed: "AI 3D (Pre-Processed)"
            }
        }

        /// The bar's badge: short enough for the bar.
        var badge: String {
            switch self {
            case .flat, .stereoscopic: title
            case .immersive: "Immersive"
            case .ai3DRealtime, .ai3DPreprocessed: "AI 3D"
            }
        }

        var systemImage: String {
            switch self {
            case .flat: "rectangle"
            case .stereoscopic: "view.3d"
            case .immersive: "inset.filled.pano"
            case .ai3DRealtime, .ai3DPreprocessed: "wand.and.sparkles"
            }
        }
    }

    private var currentViewMode: ViewMode {
        if windowModel.usesImmersiveStereo { return .immersive }
        if windowModel.shouldUse3DMode { return .stereoscopic }
        if windowModel.shouldUsePseudo3D {
            if case .cached = windowModel.pseudo3DDepthMode { return .ai3DPreprocessed }
            return .ai3DRealtime
        }
        return .flat
    }

    /// Radio-style mode item: checkmark on the active mode only; selecting
    /// the already-active mode does nothing.
    /// Picking a mode also closes the bar's More popover, so the change is
    /// seen with nothing in front of it: a stereo picture engaged under an
    /// open popover would start dimmed and flat, and its follow-up prompt
    /// (Real-Time or Pre-Process) would open over the popover.
    private func modeButton(_ title: String, subtitle: String? = nil, mode: ViewMode,
                            action: @escaping () -> Void) -> some View {
        Button {
            guard currentViewMode != mode else { return }
            windowModel.closeOrnamentMenus(reason: "view mode chosen")
            action()
        } label: {
            // A menu item reads its first Text as the title, the second as
            // the subtitle under it.
            HStack {
                Text(title)
                if let subtitle { Text(subtitle) }
                if currentViewMode == mode {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// Effective model shown as selected for a role: the explicit preference
    /// if it's installed, otherwise the first installed model (what
    /// findModelURL loads).
    private func effectiveDepthModelName(preference: String) -> String {
        if !preference.isEmpty, depthModels.installedNames.contains(preference) { return preference }
        return depthModels.installedNames.first ?? ""
    }

    /// Depth-model submenu for one role: pick among installed models, and
    /// download any offered variant that isn't installed yet.
    @ViewBuilder
    private func depthModelMenu(
        _ title: String,
        preference: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu(title) {
            ForEach(depthModels.installedNames, id: \.self) { name in
                Button {
                    onSelect(name)
                } label: {
                    HStack {
                        Text(DepthModelManager.displayName(for: name))
                        if effectiveDepthModelName(preference: preference) == name {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            let downloadable = DepthModelManager.variants.filter { !depthModels.isInstalled($0) }
            if !downloadable.isEmpty {
                Divider()
                ForEach(downloadable) { variant in
                    Button {
                        Task { await depthModels.download(variant) }
                    } label: {
                        Label(
                            depthModels.isDownloading(variant)
                                ? "Downloading \(variant.displayName)…"
                                : "Download \(variant.displayName)",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(depthModels.isDownloading(variant))
                }
            }
        }
    }
}

/// Ornament-row depth-conversion status (spinner + live label). Kept in its own
/// view so that observing the continuously-updating DepthConversionManager
/// invalidates only this small view, not the parent ornament that holds the
/// ViewMode Menu (a parent that re-renders recreates the Menu and drops taps on
/// the open dropdown).
private struct ConversionStatusRow: View {
    let videoIdentity: String
    @State private var conversions = DepthConversionManager.shared

    var body: some View {
        if let phase = conversions.phase(for: videoIdentity) {
            Divider()
                .frame(height: 24)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(phase.label)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        } else if conversions.isProcessing(videoIdentity: videoIdentity) {
            Divider()
                .frame(height: 24)
            Text("Conversion queued")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// In-menu depth-conversion status + cancel, isolated for the same reason as
/// ConversionStatusRow. Shows the phase *kind* only (no live percentage) so its
/// own updates never reflow the surrounding menu items.
private struct ConversionMenuStatus: View {
    let videoIdentity: String
    @State private var conversions = DepthConversionManager.shared

    private var statusLabel: String? {
        if let phase = conversions.phase(for: videoIdentity) {
            switch phase {
            case .downloading: return "Downloading…"
            case .converting: return "Preparing AI 3D…"
            case .refining: return "Refining AI 3D…"
            }
        }
        if conversions.isProcessing(videoIdentity: videoIdentity) {
            return "Conversion queued"
        }
        return nil
    }

    var body: some View {
        if let statusLabel {
            Text(statusLabel)
            Button(role: .destructive) {
                conversions.cancel(videoIdentity: videoIdentity)
            } label: {
                Label("Cancel Conversion", systemImage: "xmark.circle")
            }
        }
    }
}

/// "More Options": a menu on the bar, a nested popover inside the compact
/// bar's "More" popover.
///
/// A Menu inside that popover was rebuilt with every playhead update (the bar
/// reads the current time, and the popover's content is the bar's
/// accessories), so its dropdown refreshed every frame and lost its gaze
/// hover. A popover's own content updates only with what it reads.
private struct MoreOptionsControl<Items: View>: View {
    let highlighted: Bool
    /// Opened or closed, and whether as the popover (which leaves the
    /// stereo picture tappable) or the menu.
    let onOpenChanged: (_ opened: Bool, _ asPopover: Bool) -> Void
    /// The items; each calls the passed closure to close the popover first.
    @ViewBuilder let items: (_ close: @escaping () -> Void) -> Items

    @Environment(\.ravePlayerControlsInMenu) private var inMenu
    @State private var showsPopover = false

    var body: some View {
        #if os(tvOS)
        // tvOS has no popovers; its "More" is still a Menu.
        menu
        #else
        if inMenu {
            Button { showsPopover.toggle() } label: {
                Label("More Options", systemImage: "ellipsis.circle")
            }
            .popover(isPresented: $showsPopover, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 4) {
                    items { showsPopover = false }
                }
                .buttonStyle(PlayerPopoverRowStyle())
                .padding(12)
                .frame(minWidth: 220)
            }
            .onChange(of: showsPopover) { _, open in onOpenChanged(open, true) }
            .onDisappear {
                if showsPopover { onOpenChanged(false, true) }
                showsPopover = false
            }
        } else {
            menu
        }
        #endif
    }

    private var menu: some View {
            Menu {
                Group { items {} }
                    .ravePlayerMenuReporting { onOpenChanged($0, false) }
            } label: {
                OrnamentGlyph(title: "More Options", systemImage: "ellipsis.circle")
                    .padding(6)
                    .background(highlighted ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
            }
            .menuStyle(.button)
            .raveChromeButtonStyle()
            .help("More")
    }
}

/// A feature button's icon: the glyph on the bar, title and glyph inside the
/// compact bar's "More" popover.
/// The View Mode button: the mode's icon and name on the bar, so what the
/// picture is doing reads at a glance; a labelled row in the More popover.
private struct ViewModeGlyph: View {
    let mode: String
    let systemImage: String
    var isActive = false
    @Environment(\.ravePlayerControlsInMenu) private var inMenu

    var body: some View {
        if inMenu {
            Label("View Mode: \(mode)", systemImage: systemImage)
        } else {
            PlayerBadge(text: mode, isActive: isActive)
                .accessibilityLabel("View Mode: \(mode)")
        }
    }
}

private struct OrnamentGlyph: View {
    let title: String
    let systemImage: String
    @Environment(\.ravePlayerControlsInMenu) private var inMenu

    var body: some View {
        if inMenu {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage).font(.title3)
        }
    }
}
