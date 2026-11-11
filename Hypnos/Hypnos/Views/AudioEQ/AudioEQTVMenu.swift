#if os(tvOS)
import RAVEMedia
import UIKit

/// The equalizer in the Apple TV player's transport bar, which only takes UIKit menus: the switch and
/// the presets. (The graph editor needs a pointer; Settings → Equalizer picks a preset too.) Built
/// inside the bar's observation tracking (`refreshTransportBar`), so reading the curve here is what
/// rebuilds the menu when it changes.
enum AudioEQTVMenu {
    @MainActor static func make(coverage: EQAttachResult?) -> UIMenu {
        let eq = AudioEQ.shared
        var children: [UIMenuElement] = []
        if let note = AudioEQ.explanation(for: coverage) {
            children.append(UIAction(title: note, attributes: .disabled) { _ in })
        }
        children.append(UIAction(title: "Equalizer", image: UIImage(systemName: "slider.vertical.3"),
                                 state: eq.settings.enabled ? .on : .off) { _ in
            Task { @MainActor in AudioEQ.shared.setEnabled(!AudioEQ.shared.settings.enabled) }
        })
        children.append(UIMenu(options: .displayInline, children: (EQPreset.builtIns + eq.customPresets).map { preset in
            UIAction(title: preset.name, state: eq.matches(preset) ? .on : .off) { _ in
                Task { @MainActor in AudioEQ.shared.apply(preset) }
            }
        }))
        return UIMenu(title: "Equalizer", image: UIImage(systemName: "slider.vertical.3"), children: children)
    }
}
#endif
