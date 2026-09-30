import RAVEUI
import SwiftUI

/// App-specific loop actions around the SDK's source-independent transport.
/// The same bar is used by WebKit, Metal and the stereo engine; command
/// closures always belong to the active renderer, never to the UI.
struct VideoControlBar<Accessories: View>: View {
    @Bindable var windowModel: VideoWindowModel
    private let accessories: Accessories

    init(windowModel: VideoWindowModel, @ViewBuilder accessories: () -> Accessories) {
        self.windowModel = windowModel
        self.accessories = accessories()
    }

    var body: some View {
        RAVEPlayerControls(
            state: RAVEPlayerControlState(
                currentTime: windowModel.currentTime, duration: windowModel.duration,
                bufferedUntil: windowModel.bufferedEnd, isPlaying: !windowModel.isPaused,
                isMuted: windowModel.isMuted,
                markers: [windowModel.loopController.pointA, windowModel.loopController.pointB].compactMap { $0 }
            ),
            togglePlayback: { windowModel.togglePlayPause() },
            seek: { windowModel.endScrub(at: $0) },
            toggleMute: { windowModel.toggleMute() },
            onInteraction: { if !windowModel.isScrubbing { windowModel.startAutoHideTimer() } },
            onScrubbingChanged: { editing in
                if editing { windowModel.beginScrub() }
                else { windowModel.isScrubbing = false; windowModel.startAutoHideTimer() }
            }
        ) {
            accessories
            Button {
                windowModel.startAutoHideTimer()
                Task { await windowModel.loopController.handleButtonTap() }
            } label: {
                Label(windowModel.loopController.helpText, systemImage: windowModel.loopController.iconName)
                    .labelStyle(.iconOnly).ravePlayerControlLabel()
                    .foregroundStyle(windowModel.loopController.isEngaged ? Color.accentColor : .primary)
            }
            .help(windowModel.loopController.helpText)
            if windowModel.loopController.pointA != nil {
                Button {
                    windowModel.loopController.clear()
                    windowModel.startAutoHideTimer()
                } label: {
                    Label("Clear A-B Loop", systemImage: "xmark.circle").labelStyle(.iconOnly).ravePlayerControlLabel()
                }
            }
        }
    }

}
