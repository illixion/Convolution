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

    private var liveState: RAVEPlayerControlState {
        RAVEPlayerControlState(
            currentTime: windowModel.currentTime, duration: windowModel.duration,
            bufferedUntil: windowModel.bufferedEnd, isPlaying: !windowModel.isPaused,
            isMuted: windowModel.isMuted, volume: windowModel.volume,
            markers: [windowModel.loopController.pointA, windowModel.loopController.pointB].compactMap { $0 },
            details: windowModel.pictureDetails,
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

    var body: some View {
        RAVEPlayerControls(
            state: frozenState ?? liveState,
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
            pinned: pinned
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
