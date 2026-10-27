/*
 Hypnos - the subtitle menu and overlay every player shows

 `SubtitleMenu` is a player-controls accessory: Off, then each track, with
 image tracks other than PGS listed but disabled. `SubtitleOverlay` draws the selected
 track on the player's clock through RAVEUI, applying the timing offset.
 A stereo picture draws them into the picture instead (`StereoSubtitleFeeder`).
 */

import GeneratedCaptions
import RAVEMedia
import RAVEUI
import SwiftUI

struct SubtitleMenu: View {
    let controller: SubtitleController
    @State private var speakerModel = RAVESpeakerModel.shared
    /// The menu opened or closed, for a caller that has to move a stereo
    /// picture out of its way (the same signal the video ornament's menus use).
    var onOpenChanged: (Bool) -> Void = { _ in }

    var body: some View {
        PlayerChoiceMenu(title: "Subtitles",
                         systemImage: controller.selected == nil ? "captions.bubble" : "captions.bubble.fill",
                         help: statusText, onOpenChanged: onOpenChanged) { close in
            Button { close(); controller.select(nil) } label: { item("Off", isSelected: controller.selected == nil) }
            if controller.canGenerate {
                Button { close(); controller.selectGenerated() } label: {
                    item("AI Captions", isSelected: controller.generated.enabled)
                }
                if controller.generated.enabled {
                    if controller.generated.status != "AI captions" {
                        HStack(spacing: 8) {
                            if !controller.generated.isBuffering { ProgressView().controlSize(.small) }
                            Text(controller.generated.status.isEmpty ? "Preparing AI captions…" : controller.generated.status)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("captions.progress.status")
                    }
                    if controller.generated.isBuffering {
                        ProgressView(value: controller.generated.lookaheadProgress)
                            .accessibilityLabel("AI caption audio analyzed ahead")
                        Text(String(format: "%.1f seconds analyzed ahead", controller.generated.analysisBufferedSeconds))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = controller.generated.error {
                Text(error).font(.caption)
            }
            if let progress = speakerModel.progress {
                ProgressView(value: progress) { Text("Downloading Speaker Labels…") }
                Button("Cancel Download") { speakerModel.cancel() }
            } else if !speakerModel.isInstalled {
                Button { speakerModel.download() } label: {
                    item("Download Speaker Labels (97 MB)", isSelected: false)
                }
            }
            if let error = speakerModel.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            ForEach(controller.tracks) { track in
                Button { close(); controller.select(track) } label: {
                    item(controller.menuTitle(of: track), isSelected: controller.selected == track)
                }
                .disabled(!track.isPlayable)
            }
        }
        .accessibilityIdentifier("player.subtitles")
    }

    private var statusText: String {
        if let error = controller.generated.error { return "AI captions failed: \(error)" }
        if let error = controller.error { return "Subtitles failed: \(error)" }
        if controller.isFetching { return "Loading subtitles…" }
        return controller.selected.map { "Subtitles: \($0.title)" } ?? "Subtitles"
    }

    private func item(_ title: String, isSelected: Bool) -> some View {
        PlayerChoiceRow(title, isChecked: isSelected)
    }
}

extension SubtitleController {
    /// A track's row in a subtitle menu. The chosen track says when it is
    /// still on its way (an embedded track's first extraction on the server
    /// can take minutes) or failed.
    func menuTitle(of track: LibrarySubtitleTrack) -> String {
        guard track.isPlayable else { return "\(track.title) (Image, unsupported)" }
        guard selected == track else { return track.title }
        if error != nil { return "\(track.title) (Failed)" }
        if isFetching { return "\(track.title) (Loading…)" }
        return track.title
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
/// Where a stereo picture shows its subtitles.
enum StereoSubtitleStyle: String, CaseIterable, Identifiable {
    /// Drawn into both eyes, in front of the content behind them.
    case inPicture
    /// On a band hung under the window (`SubtitleBand`).
    case belowPicture

    static let key = "subtitles.stereoStyle"
    var id: Self { self }
    var title: String {
        switch self {
        case .inPicture: "In Picture"
        case .belowPicture: "Below Picture"
        }
    }
}

/// Where a flat picture shows its subtitles: over it (`inPicture`) or on the
/// band hung under the window, as a stereo picture can. Its own setting, as
/// a film watched in 2D and in 3D may want them in different places.
enum FlatSubtitleStyle {
    static let key = "subtitles.flatStyle"
}

/// The flat picture's subtitle placement: over the picture or below it.
struct FlatSubtitleSettings: View {
    @AppStorage(FlatSubtitleStyle.key) private var style = StereoSubtitleStyle.inPicture
    @AppStorage(SubtitleBandGap.key) private var bandGap = SubtitleBandGap.defaultPoints

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Subtitles", selection: $style) {
                ForEach(StereoSubtitleStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if style == .belowPicture {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Distance below picture: \(Int(bandGap)) pt").font(.caption)
                    Slider(value: $bandGap, in: SubtitleBandGap.range, step: 4)
                }
            }
        }
    }
}

/// Where the HDR luminance of subtitles drawn into a stereo picture is kept.
enum SubtitleHDRBrightness {
    static let key = "subtitles.hdrWhiteNits"
    static let defaultNits = StereoSubtitleFrame.defaultHDRWhiteNits
    static let range: ClosedRange<Double> = 80 ... 1000
}

/// How far subtitles drawn into a stereo picture sit from the depth chosen
/// for them: -1 (nearer) … 1 (farther), 0 being the automatic depth.
///
/// A disc's bitmap subtitles (PGS) keep their own setting: they are placed
/// where the disc put them, a different height from text subtitles and so
/// against different content, and read at another depth for the same offset.
enum SubtitleStereoDepth {
    static let key = "subtitles.stereoDepth"
    static let discKey = "subtitles.stereoDepthDisc"

    /// The setting for `track`'s kind of subtitles.
    static func key(for track: LibrarySubtitleTrack?) -> String {
        track?.isBitmap == true ? discKey : key
    }
    /// Each eye's shift at the slider's ends, as a fraction of the eye's
    /// width: about four times the automatic margin in front of the content.
    static let fullScale = 0.004

    static func depthOffset(_ value: Double) -> Double { value * fullScale }
}

/// How far the band of subtitles hung under a stereo picture
/// (`StereoSubtitleStyle.belowPicture`) sits below the window's edge.
///
/// It used to be fixed, raised to 84 and then 120 pt because the picture's
/// near content covered it from an angle (device, 2026-10-07). That was
/// before the stereo plane was recessed into the window (RAVESDK 7a79976),
/// so the default is close again and the viewer picks what clears their
/// content.
enum SubtitleBandGap {
    static let key = "subtitles.bandGap"
    static let defaultPoints = 20.0
    static let range: ClosedRange<Double> = 0 ... 160
}

/// The subtitle settings that only mean something in 3D: where they show
/// and, drawn into the picture, their depth and HDR brightness.
struct StereoSubtitleSettings: View {
    /// The player's subtitles: which kind is showing picks the depth setting.
    var subtitles: SubtitleController?
    @AppStorage(StereoSubtitleStyle.key) private var style = StereoSubtitleStyle.inPicture
    @AppStorage(SubtitleStereoDepth.key) private var textDepth = 0.0
    @AppStorage(SubtitleStereoDepth.discKey) private var discDepth = 0.0
    @AppStorage(SubtitleHDRBrightness.key) private var nits = SubtitleHDRBrightness.defaultNits
    @AppStorage(SubtitleBandGap.key) private var bandGap = SubtitleBandGap.defaultPoints

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Subtitles in 3D", selection: $style) {
                ForEach(StereoSubtitleStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if style == .belowPicture {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Distance below picture: \(Int(bandGap)) pt").font(.caption)
                    HStack {
                        Text("Closer").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $bandGap, in: SubtitleBandGap.range, step: 4)
                        Text("Lower").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Reset Distance") { bandGap = SubtitleBandGap.defaultPoints }
                        .font(.caption)
                        .disabled(bandGap == SubtitleBandGap.defaultPoints)
                }
            }
            if style == .inPicture {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(isDisc ? "Disc subtitle depth" : "Subtitle depth"): \(depthLabel)").font(.caption)
                    HStack {
                        Text("Nearer").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: depthBinding, in: -1 ... 1, step: 0.05)
                        Text("Farther").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Reset Depth") { depth = 0 }
                        .font(.caption)
                        .disabled(depth == 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("HDR subtitle brightness: \(Int(nits)) nits").font(.caption)
                    Slider(value: $nits, in: SubtitleHDRBrightness.range, step: 10)
                    Text("For HDR videos. \(Int(SubtitleHDRBrightness.defaultNits)) nits matches HDR reference white.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isDisc: Bool { subtitles?.selected?.isBitmap == true }

    private var depth: Double {
        get { isDisc ? discDepth : textDepth }
        nonmutating set { if isDisc { discDepth = newValue } else { textDepth = newValue } }
    }

    private var depthBinding: Binding<Double> {
        Binding(get: { depth }, set: { depth = $0 })
    }

    private var depthLabel: String {
        depth == 0 ? "Automatic" : "\(Int((abs(depth) * 100).rounded()))% \(depth > 0 ? "farther" : "nearer")"
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
    @Binding var frame: StereoSubtitleFrame?

    @AppStorage(SubtitleHDRBrightness.key) private var hdrWhiteNits = SubtitleHDRBrightness.defaultNits
    @AppStorage(SubtitleStereoDepth.key) private var textDepth = 0.0
    @AppStorage(SubtitleStereoDepth.discKey) private var discDepth = 0.0
    @State private var version = 0

    private var depth: Double { controller.selected?.isBitmap == true ? discDepth : textDepth }

    var body: some View {
        RAVESubtitleCues(track: controller.cues, time: { controller.cueTime(forFilmTime: filmTime()) }) { showing in
            Color.clear
                .onChange(of: showing, initial: true) { _, cues in publish(cues) }
                .onChange(of: hdrWhiteNits) { publish(showing) }
                .onChange(of: textDepth) { publish(showing) }
                .onChange(of: discDepth) { publish(showing) }
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
        frame = StereoSubtitleFrame(version: version, hdrWhiteNits: hdrWhiteNits,
                                        depthOffset: SubtitleStereoDepth.depthOffset(depth)) { eyeSize in
            Self.render(cues, eyeSize: eyeSize)
        }
    }

    /// The flat players' styling at the flat players' proportions: text a
    /// twentieth of the picture's height, one image per edge. A bitmap cue
    /// (a disc's PGS) goes where the disc put it, at its own size.
    @MainActor
    static func render(_ cues: [RAVESubtitleCue], eyeSize: CGSize) -> [StereoSubtitle] {
        let bitmaps = cues.compactMap { cue -> StereoSubtitle? in
            guard let image = cue.image, let cgImage = image.makeImage() else { return nil }
            return StereoSubtitle(image: cgImage, placement: cue.placement == .top ? .top : .bottom,
                                      referenceEyeHeight: eyeSize.height, frame: image.frame)
        }
        let text = cues.filter { $0.image == nil }
        let fontSize = max(eyeSize.height * 0.05, 14)
        let groups: [(StereoSubtitle.Placement, [RAVESubtitleCue])] = [
            (.top, text.filter { $0.placement == .top }),
            (.bottom, text.filter { $0.placement == .bottom })
        ]
        return bitmaps + groups.compactMap { placement, group in
            guard !group.isEmpty else { return nil }
            let renderer = ImageRenderer(content: RAVESubtitleText(cues: group, fontSize: fontSize))
            renderer.proposedSize = ProposedViewSize(width: eyeSize.width, height: nil)
            // A point per eye pixel: the image is drawn 1:1 into the eye.
            renderer.scale = 1
            guard let image = renderer.cgImage else { return nil }
            return StereoSubtitle(image: image, placement: placement, referenceEyeHeight: eyeSize.height)
        }
    }
}

/// The strip under a stereo picture that subtitles show on with
/// `StereoSubtitleStyle.belowPicture`. It hangs under the window with the
/// controls (see `PlayerOrnamentStack`), not inside it: the window has to be
/// the picture alone for its edge to square the picture's corners.
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

/// What hangs under a player window: the subtitle band if there is one,
/// then the controls. The ornament stays up for the subtitles while the
/// controls auto-hide, so they fade in place rather than the band jumping;
/// a hidden bar takes no input. `controlsVisible` is the animated value from
/// `playerChromeOrnament`, so the bar rises into place and sinks away.
///
/// A `prompt` (Skip Intro, Undo) takes the bar's place while it is hidden
/// and hangs under it while it shows, sliding between the two with the bar,
/// so the bar never moves for it. Under the window rather than over the
/// picture: SwiftUI drawn over a stereo picture never shows in front of it.
struct PlayerOrnamentStack<Controls: View>: View {
    var subtitles: SubtitleController? = nil
    let controlsVisible: Bool
    var prompt: AnyView? = nil
    /// Space between the window's bottom edge and the controls. The
    /// subtitle band, when there is one, hangs first at its own adjustable
    /// distance instead (`SubtitleBandGap`).
    let gap: CGFloat
    var filmTime: @MainActor () -> Double = { 0 }
    @ViewBuilder let controls: Controls

    @AppStorage(SubtitleBandGap.key) private var bandGap = SubtitleBandGap.defaultPoints
    @State private var controlsHeight: CGFloat = 0
    /// The last prompt, kept in the tree while it fades out: a removal
    /// transition inside an ornament cut it in a single frame (measured on
    /// the simulator), so the exit is driven by opacity instead.
    @State private var heldPrompt: AnyView?
    @State private var releasePrompt: Task<Void, Never>?

    /// Whether the ornament has anything besides the controls to show.
    static func keepsMounted(subtitles: SubtitleController?, hasPrompt: Bool) -> Bool {
        subtitles != nil || hasPrompt
    }

    var body: some View {
        VStack(spacing: 0) {
            if let subtitles {
                SubtitleBand(controller: subtitles, filmTime: filmTime)
            }
            // The bar's room goes with it as it hides, so a prompt that
            // takes its place sits right under the window rather than a bar's
            // height below it. Measured at its own height, as a collapsed
            // frame would otherwise squeeze it into another layout.
            controls
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { controlsHeight = $0 } }
                .modifier(PlayerChromeReveal(shown: controlsVisible))
                .frame(height: controlsVisible ? (controlsHeight > 0 ? controlsHeight : nil) : 0, alignment: .top)
            if let shownPrompt = prompt ?? heldPrompt {
                shownPrompt
                    .padding(.top, controlsVisible ? 12 : 0)
                    .opacity(prompt != nil ? 1 : 0)
                    .scaleEffect(prompt != nil ? 1 : 0.92, anchor: .top)
                    .allowsHitTesting(prompt != nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .padding(.top, subtitles != nil ? bandGap : gap)
        .animation(.easeInOut(duration: 0.2), value: prompt == nil)
        .onChange(of: prompt == nil, initial: true) { _, gone in
            releasePrompt?.cancel()
            if !gone {
                heldPrompt = prompt
            } else {
                releasePrompt = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled else { return }
                    heldPrompt = nil
                }
            }
        }
    }
}
#endif
