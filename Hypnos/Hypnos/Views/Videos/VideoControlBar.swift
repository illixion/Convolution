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
    @AppStorage(PlaybackInfoVisibility.key) private var playbackInfoVisibility = PlaybackInfoVisibility.always
    private var readoutInPanel: Bool { windowModel.playbackInfo.isShown(playbackInfoVisibility) }
    #endif

    private var liveState: RAVEPlayerControlState {
        RAVEPlayerControlState(
            currentTime: windowModel.currentTime, duration: windowModel.duration,
            bufferedUntil: windowModel.bufferedEnd, isPlaying: !windowModel.isPaused,
            isMuted: windowModel.isMuted, volume: windowModel.volume,
            markers: [windowModel.loopController.pointA, windowModel.loopController.pointB].compactMap { $0 },
            // The picture's readout is in the playback info panel, unless
            // that is set to show only when something is off.
            details: readoutInPanel ? nil : windowModel.pictureDetails,
            markedRanges: windowModel.segmentSkipper.markedRanges
        )
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
        guard var state = frozenState else { return liveState }
        state.volume = windowModel.volume
        state.isMuted = windowModel.isMuted
        return state
    }

    var body: some View {
        RAVEPlayerControls(
            state: state,
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
            frozenState = open ? liveState : nil
        }
    }
}

/// The A-B loop: set A, set B (engages), clear. One of the window's
/// accessories, so the More popover can group it with playback.
struct LoopControls: View {
    @Bindable var windowModel: VideoWindowModel

    var body: some View {
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
