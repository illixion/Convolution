import SwiftUI

/// The sleep timer in a player's control bar: a moon that becomes a countdown
/// badge while a timer runs. Picking a length starts the timer (or restarts
/// it); while one runs the menu also offers more time and Cancel. The home
/// actions are chosen in Settings → Sleep Timer.
struct SleepTimerMenu: View {
    @Bindable private var timer = SleepTimer.shared
    var onOpenChanged: (Bool) -> Void = { _ in }

    var body: some View {
        if timer.isRunning {
            // The badge counts down, so only a running timer pays for a clock.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                menu(badge: timer.remainingBadge(at: context.date))
            }
        } else {
            menu(badge: nil)
        }
    }

    private func menu(badge: String?) -> some View {
        PlayerChoiceMenu(title: "Sleep Timer", systemImage: timer.isRunning ? "moon.zzz.fill" : "moon.zzz",
                         badge: badge, badgeIsActive: timer.isRunning,
                         help: helpText, onOpenChanged: onOpenChanged) { close in
            if let end = timer.endDate {
                Text("Ends at \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    close()
                    timer.extend(byMinutes: 15)
                } label: {
                    Label("Add 15 Minutes", systemImage: "plus.circle")
                }
                Button(role: .destructive) {
                    close()
                    timer.cancel()
                } label: {
                    Label("Cancel Timer", systemImage: "xmark.circle")
                }
                Divider()
            }
            ForEach(SleepTimer.presets, id: \.self) { minutes in
                Button {
                    close()
                    timer.start(minutes: minutes)
                } label: {
                    PlayerChoiceRow(SleepTimer.label(minutes: minutes), isChecked: false)
                }
            }
        }
        .accessibilityIdentifier("player.sleepTimer")
    }

    private var helpText: String {
        guard let end = timer.endDate else { return "Pause playback after a while" }
        return "Sleep timer ends at \(end.formatted(date: .omitted, time: .shortened))"
    }
}
