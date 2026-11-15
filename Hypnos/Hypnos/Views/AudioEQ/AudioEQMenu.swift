import OnScreenText
import RAVEMedia
import RAVEUI
import SwiftUI

/// The equalizer in a player's control bar: an on/off switch, the presets to audition, and (outside
/// the immersive HUD, where presentations aren't allowed) the full editor. The icon becomes an "EQ"
/// badge while the curve is shaping what plays. Every player shows the same menu over the same curve
/// (`AudioEQ.shared`); `coverage` is what *this* player's audio reported, so a stream the equalizer
/// can't reach says so.
struct AudioEQMenu: View {
    /// What the playing item's tap said; nil while unknown, and for audio the EQ always reaches
    /// (the film's objects).
    var coverage: EQAttachResult?
    /// The video window's subtitle controller, for its AI Narration section: nil where the
    /// player can't read its picture, or Settings doesn't offer the feature.
    var narration: SubtitleController?
    #if os(visionOS)
    /// Set where the player has a Cinema: the menu then also holds its modes and Head-Locked Sound,
    /// and is the one "Sound & Cinema" button.
    var cinema: (owner: CinemaOwner, bigScreenAvailable: Bool)?
    #endif
    /// Bumped by the host to close the popover.
    var dismissal = 0
    var onOpenChanged: (Bool) -> Void = { _ in }

    @Bindable private var eq = AudioEQ.shared
    @State private var showsEditor = false
    #if os(visionOS)
    @Environment(\.raveImmersivePlayerPresentation) private var immersive
    /// The Cinema HUD can't present a sheet, so the editor is offered only in a window.
    private var canEdit: Bool { immersive == nil }
    #else
    private var canEdit: Bool { true }
    #endif

    private var unreachable: Bool { AudioEQ.explanation(for: coverage) != nil }

    private var hasCinema: Bool {
        #if os(visionOS)
        cinema != nil
        #else
        false
        #endif
    }

    private var badge: String? {
        #if os(visionOS)
        if let cinema, let mode = CinemaMenuSections.badge(owner: cinema.owner), mode != "Head" { return mode }
        #endif
        if eq.isActive && !unreachable { return "EQ" }
        if narration?.onScreen.enabled == true { return "AI" }
        #if os(visionOS)
        if let cinema { return CinemaMenuSections.badge(owner: cinema.owner) }
        #endif
        return nil
    }

    var body: some View {
        PlayerChoiceMenu(title: hasCinema ? "Sound & Cinema" : "Equalizer",
                         systemImage: hasCinema ? "sparkles.tv" : "slider.vertical.3",
                         badge: badge, badgeIsActive: true,
                         help: helpText, dismissal: dismissal, onOpenChanged: onOpenChanged) { close in
            #if os(visionOS)
            if let cinema {
                CinemaMenuSections(owner: cinema.owner, bigScreenAvailable: cinema.bigScreenAvailable, close: close)
                Divider()
            }
            #endif
            Toggle(isOn: Binding(get: { eq.settings.enabled }, set: { eq.setEnabled($0) })) {
                Label("Equalizer", systemImage: "slider.vertical.3")
            }
            if let note = AudioEQ.explanation(for: coverage) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            // Presets stay open: the point is to compare them while it plays.
            ForEach(EQPreset.builtIns + eq.customPresets) { preset in
                Button {
                    eq.apply(preset)
                } label: {
                    PlayerChoiceRow(preset.name, isChecked: eq.matches(preset))
                }
            }
            if let narration {
                Divider()
                AINarrationSection(controller: narration)
            }
            #if !os(tvOS)
            if canEdit {
                Divider()
                Button {
                    close()
                    showsEditor = true
                } label: {
                    Label("Edit Equalizer…", systemImage: "slider.horizontal.3")
                }
            }
            #endif
        }
        .accessibilityIdentifier(hasCinema ? "player.cinema" : "player.equalizer")
        .onAppear { eq.reloadPresets() }
        #if !os(tvOS)
        .sheet(isPresented: $showsEditor, onDismiss: { eq.reloadPresets() }) { AudioEQEditorSheet() }
        #endif
    }

    private var helpText: String {
        if hasCinema { return "Big screen, how the sound is placed, equalizer and AI Narration" }
        if unreachable { return "Equalizer: can't reach this sound" }
        if narration?.onScreen.enabled == true, !eq.isActive { return "AI Narration is on" }
        return eq.isActive ? "Equalizer: \(AudioEQ.statusLabel)" : "Equalizer"
    }
}

#if !os(tvOS)
/// The full editor over the app's curve, in a sheet. RAVEMedia's `EQEditorView` edits whatever it is
/// bound to; `AudioEQ.shared` saves it, re-trims the preamp and moves every live player.
struct AudioEQEditorSheet: View {
    @Bindable private var eq = AudioEQ.shared

    var body: some View {
        #if os(iOS)
        NavigationStack {
            EQEditorView(settings: $eq.settings, defaults: HypnosDefaults.store)
        }
        #else
        EQEditorView(settings: $eq.settings, defaults: HypnosDefaults.store)
        #endif
    }
}
#endif
