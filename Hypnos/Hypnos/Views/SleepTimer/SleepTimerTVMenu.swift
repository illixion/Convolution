#if os(tvOS)
import UIKit

/// The sleep timer in the Apple TV player's transport bar, which only takes
/// UIKit menus. Built inside the bar's observation tracking
/// (`refreshTransportBar`), so reading the timer's state here is what rebuilds
/// it when a timer starts, extends or ends.
enum SleepTimerTVMenu {
    @MainActor static func make() -> UIMenu {
        let timer = SleepTimer.shared
        var children: [UIMenuElement] = []
        if let end = timer.endDate {
            children.append(UIAction(title: "Ends at \(end.formatted(date: .omitted, time: .shortened))",
                                     attributes: .disabled) { _ in })
            children.append(UIAction(title: "Add 15 Minutes", image: UIImage(systemName: "plus.circle")) { _ in
                Task { @MainActor in SleepTimer.shared.extend(byMinutes: 15) }
            })
            children.append(UIAction(title: "Cancel Timer", image: UIImage(systemName: "xmark.circle"),
                                     attributes: .destructive) { _ in
                Task { @MainActor in SleepTimer.shared.cancel() }
            })
        }
        children.append(UIMenu(options: .displayInline, children: SleepTimer.presets.map { minutes in
            UIAction(title: SleepTimer.label(minutes: minutes)) { _ in
                Task { @MainActor in SleepTimer.shared.start(minutes: minutes) }
            }
        }))
        // The transport bar shows only the icon, so the state is the fill.
        return UIMenu(title: "Sleep Timer",
                      image: UIImage(systemName: timer.isRunning ? "moon.zzz.fill" : "moon.zzz"),
                      children: children)
    }
}
#endif
