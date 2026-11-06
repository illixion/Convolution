/*
 Hypnos - how text subtitles look

 One saved look for every player (`subtitles.style`, a `RAVESubtitleStyle` as
 JSON): size, lettering, text and plate colours with opacity, an edge, and the
 distance from the picture's edge. RAVEUI's `RAVESubtitleText` reads it from
 the environment, so `.subtitleStyled()` on a player's subtitle view is all a
 caller needs; the stereo renderer passes it in by hand (`SubtitleAppearance.style`).

 `SubtitleAppearanceEditor` is the form: Settings → Subtitles shows it, and the
 subtitle menu opens it in a sheet beside the track choice. Bitmap subtitles
 (a disc's PGS) are pictures and keep their own look.
 */

import RAVEUI
import SwiftUI

enum SubtitleAppearance {
    static let key = "subtitles.style"

    static func style(fromJSON json: String) -> RAVESubtitleStyle {
        RAVESubtitleStyle(json: json) ?? .standard
    }

    /// The looks offered as one tap.
    static let presets: [(name: String, style: RAVESubtitleStyle)] = {
        var classic = RAVESubtitleStyle()
        classic.textColor = .yellow
        classic.backgroundOpacity = 0
        classic.edge = .outline
        classic.weight = .bold
        var contrast = RAVESubtitleStyle()
        contrast.textColor = .yellow
        contrast.backgroundOpacity = 0.9
        contrast.weight = .bold
        contrast.sizeScale = 1.3
        var large = RAVESubtitleStyle()
        large.sizeScale = 1.6
        large.backgroundOpacity = 0.75
        return [("Default", .standard), ("Classic", classic), ("High Contrast", contrast), ("Large", large)]
    }()
}

private struct SubtitleStyledModifier: ViewModifier {
    @AppStorage(SubtitleAppearance.key) private var json = ""

    func body(content: Content) -> some View {
        content.environment(\.raveSubtitleStyle, SubtitleAppearance.style(fromJSON: json))
    }
}

extension View {
    /// Draws the subtitles below this view in the viewer's saved look.
    func subtitleStyled() -> some View { modifier(SubtitleStyledModifier()) }
}

struct SubtitleAppearanceEditor: View {
    @AppStorage(SubtitleAppearance.key) private var json = ""
    #if os(visionOS)
    @AppStorage(SubtitleHDRBrightness.key) private var nits = SubtitleHDRBrightness.defaultNits
    #endif

    private var style: Binding<RAVESubtitleStyle> {
        Binding(get: { SubtitleAppearance.style(fromJSON: json) },
                set: { json = $0 == .standard ? "" : $0.json })
    }

    var body: some View {
        Section("Preview") {
            SubtitlePreview(style: style.wrappedValue)
                .listRowInsets(EdgeInsets())
            SubtitleChoice("Preset", selection: presetBinding,
                           options: [("Custom", "")] + SubtitleAppearance.presets.map { ($0.name, $0.name) })
        }
        Section("Text") {
            SubtitleStyleSlider(title: "Size", value: style.sizeScale, range: RAVESubtitleStyle.sizeRange, step: 0.1,
                                format: { "\(Int(($0 * 100).rounded()))%" })
            SubtitleChoice("Weight", selection: style.weight,
                           options: RAVESubtitleStyle.Weight.allCases.map { ($0.rawValue.capitalized, $0) })
            SubtitleChoice("Font", selection: style.design,
                           options: [("Standard", .standard), ("Serif", .serif), ("Rounded", .rounded), ("Monospaced", .monospaced)])
            SubtitleColorRow(title: "Color", color: style.textColor)
            SubtitleStyleSlider(title: "Opacity", value: style.textOpacity, range: 0.1 ... 1, step: 0.05,
                                format: { "\(Int(($0 * 100).rounded()))%" })
            SubtitleChoice("Edge", selection: style.edge,
                           options: [("None", .none), ("Drop Shadow", .dropShadow), ("Outline", .outline)])
            if style.wrappedValue.edge != .none {
                SubtitleColorRow(title: "Edge Color", color: style.edgeColor)
            }
        }
        Section("Background") {
            SubtitleColorRow(title: "Color", color: style.backgroundColor)
            SubtitleStyleSlider(title: "Opacity", value: style.backgroundOpacity, range: 0 ... 1, step: 0.05,
                                format: { $0 == 0 ? "None" : "\(Int(($0 * 100).rounded()))%" })
        }
        Section {
            SubtitleStyleSlider(title: "Distance from Edge", value: style.marginScale, range: RAVESubtitleStyle.marginRange,
                                step: 0.1, format: { "\(Int(($0 * 100).rounded()))%" })
            #if os(visionOS)
            SubtitleStyleSlider(title: "HDR Brightness (3D)", value: $nits, range: SubtitleHDRBrightness.range, step: 10,
                                format: { "\(Int($0)) nits" })
            #endif
        } header: {
            Text("Position")
        } footer: {
            #if os(visionOS)
            Text("HDR brightness is for subtitles drawn into a 3D picture of an HDR video; \(Int(SubtitleHDRBrightness.defaultNits)) nits matches HDR reference white. Where subtitles show in 3D is in the video's Adjustments.")
            #else
            Text("Applies to every video's text subtitles. A disc's picture subtitles keep their own look.")
            #endif
        }
        Section {
            Button("Reset to Default", role: .destructive) {
                json = ""
                #if os(visionOS)
                nits = SubtitleHDRBrightness.defaultNits
                #endif
            }
            .disabled(json.isEmpty)
        }
    }

    private var presetBinding: Binding<String> {
        Binding(get: { SubtitleAppearance.presets.first { $0.style == style.wrappedValue }?.name ?? "" },
                set: { name in
                    if let preset = SubtitleAppearance.presets.first(where: { $0.name == name }) { style.wrappedValue = preset.style }
                })
    }
}

/// Settings → Subtitles.
struct SubtitleSettingsPage: View {
    var body: some View {
        SettingsPage("Subtitles") { SubtitleAppearanceEditor() }
    }
}

/// The saved look over a picture-like backdrop, as it will be drawn.
private struct SubtitlePreview: View {
    let style: RAVESubtitleStyle

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            VStack {
                Spacer()
                RAVESubtitleText(cues: [Self.sample], fontSize: 20)
                    .padding(.bottom, 20 * style.marginScale)
            }
        }
        .environment(\.raveSubtitleStyle, style)
        .frame(height: 150)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle preview")
    }

    private static let sample = RAVESubtitleCue(start: 0, end: 1, text: AttributedString("This is how subtitles look.\nSecond line of the same caption."))
}

/// A choice among named options: a menu picker, or on tvOS (where a Picker
/// stalls focus in Settings) a title and full-width checkmarked rows.
private struct SubtitleChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(name: String, value: Value)]
    var isSelected: ((Value) -> Bool)?

    init(_ title: String, selection: Binding<Value>, options: [(String, Value)], isSelected: ((Value) -> Bool)? = nil) {
        self.title = title
        _selection = selection
        self.options = options.map { (name: $0.0, value: $0.1) }
        self.isSelected = isSelected
    }

    var body: some View {
        #if os(tvOS)
        Text(title).font(.headline)
        ForEach(options.indices, id: \.self) { index in
            Button { selection = options[index].value } label: {
                HStack {
                    Text(options[index].name)
                    Spacer()
                    if isSelected?(options[index].value) ?? (selection == options[index].value) { Image(systemName: "checkmark") }
                }
            }
        }
        #else
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { Text(options[$0].name).tag(options[$0].value) }
        }
        #endif
    }
}

private struct SubtitleStyleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        #if os(tvOS)
        let stops = (0 ..< 6).map { range.lowerBound + (range.upperBound - range.lowerBound) * Double($0) / 5 }
        SubtitleChoice(title, selection: $value, options: stops.map { (format($0), $0) },
                       isSelected: { abs($0 - value) < (range.upperBound - range.lowerBound) / 10 })
        #else
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
        }
        #endif
    }
}

/// Swatches, and on platforms that have one the system color picker.
private struct SubtitleColorRow: View {
    let title: String
    @Binding var color: RAVESubtitleStyle.RGB
    @Environment(\.self) private var environment

    var body: some View {
        #if os(tvOS)
        SubtitleChoice(title, selection: $color,
                       options: RAVESubtitleStyle.RGB.swatches.map { (Self.name(of: $0), $0) })
        #else
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                ColorPicker(title, selection: pickerBinding, supportsOpacity: false)
                    .labelsHidden()
            }
            HStack(spacing: 10) {
                ForEach(RAVESubtitleStyle.RGB.swatches, id: \.self) { swatch in
                    Button { color = swatch } label: {
                        Circle().fill(swatch.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                            .overlay { if swatch == color { Image(systemName: "checkmark").font(.caption.bold())
                                .foregroundStyle(swatch == .white || swatch == .yellow ? .black : .white) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.name(of: swatch))
                }
            }
        }
        #endif
    }

    #if !os(tvOS)
    private var pickerBinding: Binding<Color> {
        Binding(get: { color.color },
                set: { new in
                    let resolved = new.resolve(in: environment)
                    color = .init(Double(min(max(resolved.red, 0), 1)), Double(min(max(resolved.green, 0), 1)),
                                  Double(min(max(resolved.blue, 0), 1)))
                })
    }
    #endif

    private static func name(of rgb: RAVESubtitleStyle.RGB) -> String {
        switch rgb {
        case .white: "White"
        case .yellow: "Yellow"
        case .cyan: "Cyan"
        case .green: "Green"
        case .pink: "Pink"
        case .orange: "Orange"
        case .gray: "Gray"
        case .black: "Black"
        default: "Custom"
        }
    }
}

#if !os(tvOS)
/// The editor in a sheet, for the subtitle menu.
struct SubtitleAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { SubtitleAppearanceEditor() }
                .formStyle(.grouped)
                .navigationTitle("Subtitle Appearance")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}
#endif
