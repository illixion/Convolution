import RAVEUI
import SwiftUI

/// App-specific loop actions around the SDK's source-independent transport.
/// The same bar is used by WebKit, Metal and the stereo engine; command
/// closures always belong to the active renderer, never to the UI.
struct VideoControlBar<Accessories: View>: View {
    @Bindable var windowModel: VideoWindowModel
    private let pinned: AnyView?
    /// The strip's width on visionOS (the window's, within limits); nil
    /// leaves it to the strip.
    private let width: CGFloat?
    private let accessories: Accessories

    /// - Parameter pinned: stays on the strip whatever moves into its More.
    init(windowModel: VideoWindowModel, pinned: AnyView? = nil, width: CGFloat? = nil,
         @ViewBuilder accessories: () -> Accessories) {
        self.windowModel = windowModel
        self.pinned = pinned
        self.width = width
        self.accessories = accessories()
    }

    /// The bar's state as it was when a menu opened. While any ornament menu
    /// is open the bar reads nothing that moves: the player reports the
    /// playhead up to 30 times a second, every report re-rendered this bar
    /// and the accessories in it, and an open visionOS menu redrew (and
    /// dropped taps) with each one. The film player does the same.
    @State private var frozenState: RAVEPlayerControlState?
    #if os(tvOS)
    private var readoutInPanel: Bool { false }
    #else
    @AppStorage(PlaybackInfoVisibility.key, store: HypnosDefaults.store) private var playbackInfoVisibility = PlaybackInfoVisibility.always
    private var readoutInPanel: Bool { windowModel.playbackInfo.isShown(playbackInfoVisibility) }
    #endif

    /// The bar's state now. The body leaves the playhead out (`withTime`
    /// false) and hands the strip a clock instead, which only its timeline
    /// reads: with the playhead in the state, each of its 30 reports a second
    /// re-rendered the whole strip, and the strip measured all six ways of
    /// filling its row each time (main thread 98 % busy with the bar up in the
    /// HUD, starving the forearm remote, 2026-11-14).
    private func liveState(withTime: Bool) -> RAVEPlayerControlState {
        RAVEPlayerControlState(
            currentTime: withTime ? windowModel.currentTime : 0, duration: windowModel.duration,
            bufferedUntil: withTime ? windowModel.bufferedEnd : 0, isPlaying: !windowModel.isPaused,
            isMuted: windowModel.isMuted, volume: windowModel.volume,
            markers: [windowModel.loopController.pointA, windowModel.loopController.pointB].compactMap { $0 },
            // The picture's readout is in the playback info panel, unless
            // that is set to show only when something is off.
            details: readoutInPanel ? nil : windowModel.pictureDetails,
            markedRanges: windowModel.segmentSkipper.markedRanges
        )
    }

    private var clock: RAVEPlayerClock {
        let model = windowModel
        return RAVEPlayerClock { (model.currentTime, model.bufferedEnd) }
    }

    /// Previous and next video beside the transport, when the window browses
    /// a list (a lone Library film has nowhere to go).
    private var navigation: RAVEPlayerNavigation? {
        guard windowModel.videoCount > 1 else { return nil }
        let position = "\(windowModel.currentVideoPosition) of \(windowModel.videoCount)"
        return RAVEPlayerNavigation(
            previous: windowModel.hasPreviousVideo ? { windowModel.previousVideo() } : nil,
            next: windowModel.hasNextVideo ? { windowModel.nextVideo() } : nil,
            previousTitle: "Previous Video (\(position))", nextTitle: "Next Video (\(position))"
        )
    }

    /// Frozen while a menu is open, except the sound: the volume popover
    /// is one of those menus, and its slider and mute must show what they
    /// set as they set it (they lagged a whole menu behind).
    private var state: RAVEPlayerControlState {
        guard var state = frozenState else { return liveState(withTime: false) }
        state.volume = windowModel.volume
        state.isMuted = windowModel.isMuted
        return state
    }

    var body: some View {
        RAVEPlayerControls(
            state: state,
            // Frozen while a menu is open: the state's own playhead then.
            clock: frozenState == nil ? clock : nil,
            togglePlayback: { windowModel.togglePlayPause() },
            seek: { windowModel.endScrub(at: $0) },
            toggleMute: { windowModel.toggleMute() },
            onInteraction: { if !windowModel.isScrubbing { windowModel.startAutoHideTimer() } },
            onScrubbingChanged: { editing in
                if editing { windowModel.beginScrub() }
                else { windowModel.isScrubbing = false; windowModel.startAutoHideTimer() }
            },
            layout: .strip,
            onMenuChanged: { open in windowModel.ornamentMenu("More", opened: open) },
            setVolume: { windowModel.setVolume($0) },
            menuDismissal: windowModel.menuDismissals,
            navigation: navigation,
            pinned: pinned,
            volumeAccessory: windowModel.offersStableAudio
                ? AnyView(StableAudioToggle(windowModel: windowModel)) : nil
        ) {
            accessories
        }
        .frame(width: width)
        .onChange(of: windowModel.openOrnamentMenuCount > 0) { _, open in
            frozenState = open ? liveState(withTime: true) : nil
        }
    }
}

/// Repeat (start over at the end) and the A-B loop: set A, set B
/// (engages), clear. One of the window's
/// accessories, so the More popover can group it with playback.
struct LoopControls: View {
    @Bindable var windowModel: VideoWindowModel

    var body: some View {
        Button {
            windowModel.toggleLoop()
            windowModel.startAutoHideTimer()
        } label: {
            Label(windowModel.loopsAtEnd ? "Repeat: On" : "Repeat: Off",
                  systemImage: windowModel.loopsAtEnd ? "repeat.circle.fill" : "repeat")
                .ravePlayerAccessoryLabel()
                .foregroundStyle(windowModel.loopsAtEnd ? Color.accentColor : .primary)
        }
        .help(windowModel.loopsAtEnd ? "Starts over at the end. Tap to play once." : "Plays once. Tap to start over at the end.")
        .accessibilityIdentifier("video.repeat")
        Button {
            windowModel.startAutoHideTimer()
            Task { await windowModel.loopController.handleButtonTap() }
        } label: {
            Label(windowModel.loopController.helpText, systemImage: windowModel.loopController.iconName)
                .ravePlayerAccessoryLabel()
                .foregroundStyle(windowModel.loopController.isEngaged ? Color.accentColor : .primary)
        }
        .help(windowModel.loopController.helpText)
        if windowModel.loopController.pointA != nil {
            Button {
                windowModel.loopController.clear()
                windowModel.startAutoHideTimer()
            } label: {
                Label("Clear A-B Loop", systemImage: "xmark.circle").ravePlayerAccessoryLabel()
            }
        }
    }
}

/// Stable Audio, under the volume slider: shown when what plays has the
/// copies (`StableAudioSetting`).
struct StableAudioToggle: View {
    @Bindable var windowModel: VideoWindowModel

    var body: some View {
        Toggle(isOn: Binding(get: { windowModel.stableAudioOn },
                             set: { windowModel.setStableAudio($0); windowModel.startAutoHideTimer() })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stable Audio")
                Text("Clear dialogue, even volume")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        #if !os(tvOS)
        .toggleStyle(.switch)
        #endif
        .accessibilityHint("Brings up quiet dialogue and evens out loud scenes")
    }
}
