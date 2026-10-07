/*
 Hypnos - the subtitle menu and overlay every player shows

 `SubtitleMenu` is a player-controls accessory: Off, then each track, with
 image tracks listed but disabled. `SubtitleOverlay` draws the selected
 track on the player's clock through RAVEUI, applying the timing offset.
 */

import RAVEUI
import SwiftUI

struct SubtitleMenu: View {
    let controller: SubtitleController
    /// The menu opened or closed, for a caller that has to move a stereo
    /// picture out of its way (the same signal the video ornament's menus use).
    var onOpenChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Menu {
            Group {
                Button { controller.select(nil) } label: { item("Off", isSelected: controller.selected == nil) }
                ForEach(controller.tracks) { track in
                    Button { controller.select(track) } label: {
                        item(track.isText ? track.title : "\(track.title) (Image, unsupported)",
                             isSelected: controller.selected == track)
                    }
                    .disabled(!track.isText)
                }
            }
            .onAppear { onOpenChanged(true) }
            .onDisappear { onOpenChanged(false) }
        } label: {
            Label("Subtitles", systemImage: controller.selected == nil ? "captions.bubble" : "captions.bubble.fill")
                .ravePlayerAccessoryLabel()
        }
        .help(statusText)
        .accessibilityIdentifier("player.subtitles")
    }

    private var statusText: String {
        if let error = controller.error { return "Subtitles failed: \(error)" }
        if controller.isFetching { return "Loading subtitles…" }
        return controller.selected.map { "Subtitles: \($0.title)" } ?? "Subtitles"
    }

    @ViewBuilder
    private func item(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// The subtitle timing offset: a slider where there is one, steps on tvOS.
struct SubtitleDelayControl: View {
    @Bindable var controller: SubtitleController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Subtitle offset: %+.1f s", controller.delay)).font(.caption)
            #if os(tvOS)
            HStack {
                Button("Earlier") { controller.delay -= 0.1 }
                Button("Later") { controller.delay += 0.1 }
                Button("Reset") { controller.delay = 0 }
            }
            #else
            Slider(value: $controller.delay, in: -10 ... 10, step: 0.1)
            #endif
        }
    }
}

struct SubtitleOverlay: View {
    let controller: SubtitleController
    var pictureAspect: CGFloat?
    let filmTime: @MainActor () -> Double

    var body: some View {
        RAVESubtitleOverlay(track: controller.cues, pictureAspect: pictureAspect) {
            controller.cueTime(forFilmTime: filmTime())
        }
    }
}

#if os(visionOS)
/// The strip under a stereo picture that subtitles move to while it shows:
/// SwiftUI drawn over a stereo video plane never comes out in front of it
/// (device, 2026-10-07), and text at the picture's depth would fight the
/// scene anyway. It hangs under the window with the controls (see
/// `PlayerOrnamentStack`), not inside it: the window has to be the picture
/// alone for its edge to square the picture's corners.
struct SubtitleBand: View {
    static let height: CGFloat = 98

    let controller: SubtitleController
    let filmTime: @MainActor () -> Double

    var body: some View {
        RAVESubtitlePanel(track: controller.cues, fontSize: 30) {
            controller.cueTime(forFilmTime: filmTime())
        }
        .frame(height: Self.height, alignment: .top)
    }
}

/// What hangs under a player window: the subtitle band while a stereo
/// picture has subtitles on, then the controls. The ornament stays up for
/// the subtitles while the controls auto-hide, so they fade in place
/// rather than the band jumping; a hidden bar takes no input.
struct PlayerOrnamentStack<Controls: View>: View {
    let subtitles: SubtitleController?
    let controlsVisible: Bool
    /// Space between the window's bottom edge and whatever hangs first.
    let gap: CGFloat
    let filmTime: @MainActor () -> Double
    @ViewBuilder let controls: Controls

    /// Whether the ornament has anything to show at all.
    static func isVisible(subtitles: SubtitleController?, controlsVisible: Bool) -> Bool {
        controlsVisible || subtitles != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let subtitles {
                SubtitleBand(controller: subtitles, filmTime: filmTime)
            }
            controls
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
        }
        .padding(.top, gap)
    }
}
#endif
