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
                .labelStyle(.iconOnly).ravePlayerControlLabel()
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
/// Subtitles on their own glass panel hanging below the window, used while
/// the picture is stereo: SwiftUI drawn over a stereo video plane can't come
/// out in front of it, and text at the picture's depth would fight the scene.
struct SubtitlePanel: View {
    let controller: SubtitleController
    let filmTime: @MainActor () -> Double

    var body: some View {
        RAVESubtitlePanel(track: controller.cues, fontSize: 30) {
            controller.cueTime(forFilmTime: filmTime())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(width: 1000)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28))
    }
}

extension View {
    /// Hangs `SubtitlePanel` below the window while `isShown`.
    func subtitlePanel(_ controller: SubtitleController, isShown: Bool,
                       filmTime: @escaping @MainActor () -> Double) -> some View {
        ornament(visibility: isShown && controller.selected != nil ? .visible : .hidden,
                 attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            SubtitlePanel(controller: controller, filmTime: filmTime)
                // Clear of the window bar and resize controls under the window.
                .padding(.top, 60)
        }
    }
}
#endif
