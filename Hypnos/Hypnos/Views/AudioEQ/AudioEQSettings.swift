import RAVEMedia
import SwiftUI

/// Settings → Equalizer: the one curve every player uses. The graph editor is a sheet (not on tvOS,
/// which has no pointer: there the presets are the control).
struct AudioEQSettingsSections: View {
    @Bindable private var eq = AudioEQ.shared
    @State private var showsEditor = false

    private var presets: [EQPreset] { EQPreset.builtIns + eq.customPresets }

    /// The preset in force, or nil for a hand-made curve.
    private var presetSelection: Binding<UUID?> {
        Binding(
            get: { presets.first { eq.matches($0) }?.id },
            set: { id in
                guard let preset = presets.first(where: { $0.id == id }) else { return }
                eq.apply(preset)
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Equalizer", isOn: Binding(get: { eq.settings.enabled }, set: { eq.setEnabled($0) }))
            Picker("Preset", selection: presetSelection) {
                if presetSelection.wrappedValue == nil { Text("Custom").tag(UUID?.none) }
                ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(!eq.settings.enabled)
            #if !os(tvOS)
            Button("Edit Equalizer…") { showsEditor = true }
            #endif
        } header: {
            Text("Equalizer")
        } footer: {
            Text("One curve for everything you play: videos, films, music and streams. It is also on each player's bar.")
        }
        .onAppear { eq.reloadPresets() }
        #if !os(tvOS)
        .sheet(isPresented: $showsEditor, onDismiss: { eq.reloadPresets() }) { AudioEQEditorSheet() }
        #endif
    }
}

/// The page, for platforms that give each settings page its own form.
struct AudioEQSettingsPage: View {
    var body: some View {
        SettingsPage("Equalizer") { AudioEQSettingsSections() }
    }
}
