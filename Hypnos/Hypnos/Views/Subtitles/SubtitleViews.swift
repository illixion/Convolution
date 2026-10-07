/*
 Hypnos - the subtitle menu and overlay every player shows

 `SubtitleMenu` is a player-controls accessory: Off, then each track, with
 image tracks listed but disabled. `SubtitleOverlay` draws the selected
 track on the player's clock through RAVEUI, applying the timing offset.
 A stereo picture draws them into the picture instead (`StereoSubtitleFeeder`).
 */

import RAVEMedia
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
/// Where the HDR luminance of subtitles drawn into a stereo picture is kept.
enum SubtitleHDRBrightness {
    static let key = "subtitles.hdrWhiteNits"
    static let defaultNits = RAVEStereoSubtitleFrame.defaultHDRWhiteNits
    static let range: ClosedRange<Double> = 80 ... 1000
}

/// The white of subtitles drawn into a stereo HDR picture, in nits. An SDR
/// picture's subtitles are plain white whatever this says.
struct SubtitleHDRBrightnessControl: View {
    @AppStorage(SubtitleHDRBrightness.key) private var nits = SubtitleHDRBrightness.defaultNits

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HDR subtitle brightness: \(Int(nits)) nits").font(.caption)
            Slider(value: $nits, in: SubtitleHDRBrightness.range, step: 10)
            Text("For HDR videos in 3D. \(Int(SubtitleHDRBrightness.defaultNits)) nits matches HDR reference white.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Feeds a stereo player the subtitles to draw into its picture.
///
/// SwiftUI drawn over a stereo video plane never comes out in front of it
/// (device, 2026-10-07), and a band hung under the window sat at the window's
/// depth while the picture's content reads nearer, so it was covered from an
/// angle. The pump draws the text into both eyes instead, in front of the
/// content behind it (RAVEMedia's StereoSubtitles.swift); this renders the
/// cues showing into images for it, sized for the eye they're drawn into.
/// Draws nothing itself.
struct StereoSubtitleFeeder: View {
    let controller: SubtitleController
    let filmTime: @MainActor () -> Double
    @Binding var frame: RAVEStereoSubtitleFrame?

    @AppStorage(SubtitleHDRBrightness.key) private var hdrWhiteNits = SubtitleHDRBrightness.defaultNits
    @State private var version = 0

    var body: some View {
        RAVESubtitleCues(track: controller.cues, time: { controller.cueTime(forFilmTime: filmTime()) }) { showing in
            Color.clear
                .onChange(of: showing, initial: true) { _, cues in publish(cues) }
                .onChange(of: hdrWhiteNits) { publish(showing) }
                .onChange(of: controller.selected) { publish(showing) }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onDisappear { frame = nil }
    }

    private func publish(_ cues: [RAVESubtitleCue]) {
        guard controller.selected != nil else {
            frame = nil
            return
        }
        version += 1
        frame = RAVEStereoSubtitleFrame(version: version, hdrWhiteNits: hdrWhiteNits) { eyeSize in
            Self.render(cues, eyeSize: eyeSize)
        }
    }

    /// The flat players' styling at the flat players' proportions: text a
    /// twentieth of the picture's height, one image per edge.
    @MainActor
    static func render(_ cues: [RAVESubtitleCue], eyeSize: CGSize) -> [RAVEStereoSubtitle] {
        let fontSize = max(eyeSize.height * 0.05, 14)
        let groups: [(RAVEStereoSubtitle.Placement, [RAVESubtitleCue])] = [
            (.top, cues.filter { $0.placement == .top }),
            (.bottom, cues.filter { $0.placement == .bottom })
        ]
        return groups.compactMap { placement, group in
            guard !group.isEmpty else { return nil }
            let renderer = ImageRenderer(content: RAVESubtitleText(cues: group, fontSize: fontSize))
            renderer.proposedSize = ProposedViewSize(width: eyeSize.width, height: nil)
            // A point per eye pixel: the image is drawn 1:1 into the eye.
            renderer.scale = 1
            guard let image = renderer.cgImage else { return nil }
            return RAVEStereoSubtitle(image: image, placement: placement, referenceEyeHeight: eyeSize.height)
        }
    }
}

/// What hangs under a player window: the controls, a gap below its edge.
/// A hidden bar takes no input.
struct PlayerOrnamentStack<Controls: View>: View {
    let controlsVisible: Bool
    /// Space between the window's bottom edge and the controls.
    let gap: CGFloat
    @ViewBuilder let controls: Controls

    var body: some View {
        controls
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .padding(.top, gap)
    }
}
#endif
