//
//  PrivateSpatial3DTuningPage.swift
//  Hypnos
//
//  Settings → Developer → Spatial 3D Tuning, for the sideload-only private
//  RealityKit 3D knobs (PrivateSpatial3DTuning.swift). Compiled out unless
//  HYPNOS_PRIVATE_API is defined.
//

#if HYPNOS_PRIVATE_API && os(visionOS)

import SwiftUI

/// The row on the Developer page.
struct PrivateSpatial3DTuningSection: View {
    var body: some View {
        Section {
            NavigationLink {
                PrivateSpatial3DTuningPage()
            } label: {
                Label("Spatial 3D Tuning", systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("Undocumented RealityKit 3D settings: per-picture component values and the system renderer's own tuning. Sideload builds only.")
        }
    }
}

struct PrivateSpatial3DTuningPage: View {
    @State private var store = PrivateSpatial3DTuningStore.shared

    var body: some View {
        SettingsPage("Spatial 3D Tuning") {
            Section {
                Toggle("Enable Tuning", isOn: $store.isEnabled)
                if store.needsRelaunch {
                    Label("Some changes apply after relaunching the app.", systemImage: "arrow.clockwise")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Private API, reached by symbol and by CoreRE's own defaults keys (visionOS 27.2). Raw Splat 3D in the photo viewer's 3D menu works with this off. Unset values leave the system's own; none of the renderer values persist outside this app's run.")
            }

            if store.isEnabled {
                componentSection
                ForEach(RendererKnobCatalog.groups) { group in
                    rendererSection(group)
                }
                Section {
                    Button("Reset All", role: .destructive) { store.reset() }
                        .disabled(store.settings.isNoOp && store.rendererOverrides.isEmpty)
                }
            }
        }
    }

    // MARK: - Component knobs

    @ViewBuilder
    private var componentSection: some View {
        let available = store.availableComponentKnobs
        Section {
            if available.contains(\.renderTwoPass) {
                boolOverride("Two-Pass Rendering", \.renderTwoPass, seed: true,
                             caption: "Off draws every RealityKit 3D picture as its raw splats, like Raw Splat 3D does for one window.")
            }
            floatOverride("Collapse Strength", \.collapseStrength, range: 0...1, seed: 0,
                          caption: "Flattens the depth: 0 is stock, 1 is flat.")
            if available.contains(\.depthPatching) {
                boolOverride("Depth Patching", \.depthPatching, seed: true,
                             caption: "Fills the holes behind foreground edges. New in visionOS 27, not yet compared on device.")
            }
            if available.contains(\.lockMeshToImageAspect) {
                boolOverride("Lock Mesh to Image Aspect", \.lockMeshToImageAspect, seed: true,
                             caption: "Keeps the scene's mesh at the picture's aspect ratio. Not yet compared on device.")
            }
            repositionOverride
        } header: {
            Text("Per Picture")
        } footer: {
            Text("Stored on each picture's component. Applies the next time a picture enters 3D or switches viewing mode.")
        }
    }

    @ViewBuilder
    private var repositionOverride: some View {
        let isOn = Binding(
            get: { store.settings.sceneRepositionMode != nil },
            set: { store.settings.sceneRepositionMode = $0 ? .alignToHeadPosition : nil }
        )
        Toggle("Override Immersive Reposition", isOn: isOn)
        if isOn.wrappedValue {
            Picker("Immersive Reposition", selection: Binding(
                get: { store.settings.sceneRepositionMode ?? .alignToViewDepth },
                set: { store.settings.sceneRepositionMode = $0 }
            )) {
                ForEach(PrivateSceneRepositionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func boolOverride(
        _ title: String,
        _ keyPath: WritableKeyPath<PrivateSpatial3DSettings, Bool?>,
        seed: Bool,
        caption: String
    ) -> some View {
        let isOn = Binding(
            get: { store.settings[keyPath: keyPath] != nil },
            set: { store.settings[keyPath: keyPath] = $0 ? seed : nil }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Override \(title)", isOn: isOn)
            if isOn.wrappedValue {
                Toggle(title, isOn: Binding(
                    get: { store.settings[keyPath: keyPath] ?? seed },
                    set: { store.settings[keyPath: keyPath] = $0 }
                ))
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func floatOverride(
        _ title: String,
        _ keyPath: WritableKeyPath<PrivateSpatial3DSettings, Float?>,
        range: ClosedRange<Float>,
        seed: Float,
        caption: String
    ) -> some View {
        let isOn = Binding(
            get: { store.settings[keyPath: keyPath] != nil },
            set: { store.settings[keyPath: keyPath] = $0 ? seed : nil }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Override \(title)", isOn: isOn)
            if let value = store.settings[keyPath: keyPath] {
                HStack {
                    Slider(value: Binding(
                        get: { value },
                        set: { store.settings[keyPath: keyPath] = $0 }
                    ), in: range)
                    Text(String(format: "%.2f", value)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Renderer knobs

    private func rendererSection(_ group: RendererKnobGroup) -> some View {
        Section {
            ForEach(group.knobs) { knob in
                RendererKnobRow(knob: knob, value: Binding(
                    get: { store.rendererOverrides[knob.key] },
                    set: { store.rendererOverrides[knob.key] = $0 }
                ))
            }
        } header: {
            Text(group.title)
        } footer: {
            Text(group.footer)
        }
    }
}

/// One renderer override: off means unset (the system's value), on reveals the
/// control seeded with a neutral value.
private struct RendererKnobRow: View {
    let knob: RendererKnob
    @Binding var value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch knob.kind {
            case .toggle:
                // Three states: unset, on, off.
                Picker(knob.title, selection: Binding<Int>(
                    get: { value.map { $0 != 0 ? 1 : 0 } ?? -1 },
                    set: { value = $0 < 0 ? nil : Double($0) }
                )) {
                    Text("Default").tag(-1)
                    Text("On").tag(1)
                    Text("Off").tag(0)
                }
            case .slider(let range):
                overrideToggle
                if let v = value {
                    HStack {
                        Slider(value: Binding(get: { v }, set: { value = $0 }), in: range)
                        Text(String(format: "%.3f", v)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            case .integer(let range):
                overrideToggle
                if let v = value {
                    Stepper(value: Binding(get: { Int(v) }, set: { value = Double($0) }), in: range) {
                        HStack {
                            Text(knob.title)
                            Spacer()
                            Text("\(Int(v))").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            let note = [knob.caption, knob.scope.note].filter { !$0.isEmpty }.joined(separator: " ")
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var overrideToggle: some View {
        Toggle(knob.title, isOn: Binding(
            get: { value != nil },
            set: { value = $0 ? knob.seed : nil }
        ))
    }
}

#endif
