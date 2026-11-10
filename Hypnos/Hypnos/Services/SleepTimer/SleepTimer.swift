/*
 Hypnos - Sleep timer

 One timer for the whole app. When it ends it pauses every player that is
 playing (video windows, the film player, music, the Apple TV player, a
 running slideshow), lets an iPhone, iPad or Apple TV lock itself by
 releasing the screen holds (`IdleTimerHold`: a player holds the screen on
 while it plays, so without this an HDMI-connected iPad would stay lit all
 night), and then puts the person's chosen accessories in the states they
 asked for through RAVEHome: a smart plug on the external display off, the
 lights off, whichever of Home Assistant and HomeKit each lives in.

 Players register a pause closure and are held weakly, so a closed window
 drops out by itself. The deadline is on the continuous clock, so a device
 that slept through it ends the timer the moment the app runs again.
 */

import DebugTrace
import Foundation
import Observation
import RAVEHome

@MainActor
@Observable
final class SleepTimer {
    static let shared = SleepTimer()

    /// The durations offered, in minutes.
    static let presets = [5, 10, 15, 30, 45, 60, 90, 120]

    // MARK: - State

    /// When the running timer ends; nil when none runs.
    private(set) var endDate: Date?

    /// How the last ended timer went, until the next one starts.
    private(set) var lastRun: Run?

    /// The duration Start uses, remembered between launches.
    var defaultMinutes: Int {
        didSet { HypnosDefaults.store.set(defaultMinutes, forKey: Key.minutes) }
    }

    /// Whether the saved accessory actions run when the timer ends.
    var homeActionsEnabled: Bool {
        didSet { HypnosDefaults.store.set(homeActionsEnabled, forKey: Key.actionsEnabled) }
    }

    /// The accessory actions, in the order they run.
    private(set) var homeActions: [HomeActionTarget]

    var isRunning: Bool { endDate != nil }

    /// What one ended timer did.
    struct Run: Equatable {
        let date: Date
        /// How many players it paused.
        let pausedPlayers: Int
        /// Nil while the actions are still running.
        var outcomes: [HomeActionOutcome]?
        var isFinishing: Bool { outcomes == nil }
        var failures: [HomeActionOutcome] { (outcomes ?? []).filter { !$0.succeeded } }
    }

    // MARK: - Private

    private enum Key {
        static let minutes = "sleepTimer.minutes"
        static let actionsEnabled = "sleepTimer.homeActionsEnabled"
        static let actions = "sleepTimer.homeActions"
    }

    private struct Player {
        weak var owner: AnyObject?
        let pause: @MainActor () -> Bool
    }

    @ObservationIgnored private var players: [ObjectIdentifier: Player] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var actionsTask: Task<Void, Never>?
    private let log = AppLogger.app

    private init() {
        let stored = HypnosDefaults.store.integer(forKey: Key.minutes)
        defaultMinutes = stored > 0 ? stored : 30
        homeActionsEnabled = HypnosDefaults.store.object(forKey: Key.actionsEnabled) as? Bool ?? true
        homeActions = (HypnosDefaults.store.data(forKey: Key.actions))
            .flatMap { try? JSONDecoder().decode([HomeActionTarget].self, from: $0) } ?? []
    }

    // MARK: - Words

    /// "30 minutes", "1 hour", "1 hour 30 minutes".
    static func label(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        let h = hours == 1 ? "1 hour" : "\(hours) hours"
        let m = rest == 1 ? "1 minute" : "\(rest) minutes"
        if hours == 0 { return m }
        return rest == 0 ? h : "\(h) \(m)"
    }

    /// What is left, as a bar badge: "42m" while it is long, "9:05" near the
    /// end, so it reads at a glance and ticks only when it matters.
    func remainingBadge(at date: Date = .now) -> String? {
        guard let endDate else { return nil }
        let seconds = max(0, Int(endDate.timeIntervalSince(date).rounded(.up)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds > 600 { return "\((seconds + 59) / 60)m" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Players

    /// Register something that plays. `pause` pauses it if it is playing and
    /// returns whether it did. `owner` is held weakly: when it goes, so does
    /// the registration.
    func register(_ owner: AnyObject, pause: @escaping @MainActor () -> Bool) {
        players[ObjectIdentifier(owner)] = Player(owner: owner, pause: pause)
    }

    func unregister(_ owner: AnyObject) {
        players.removeValue(forKey: ObjectIdentifier(owner))
    }

    // MARK: - Running

    func start(minutes: Int? = nil) {
        let minutes = max(1, minutes ?? defaultMinutes)
        arm(until: Date.now.addingTimeInterval(TimeInterval(minutes) * 60))
        log.info("Sleep timer started for \(minutes, privacy: .public) minutes")
    }

    /// Add time to the running timer, or start one that long.
    func extend(byMinutes minutes: Int) {
        guard let endDate else { return start(minutes: minutes) }
        arm(until: endDate.addingTimeInterval(TimeInterval(minutes) * 60))
    }

    func cancel() {
        guard isRunning else { return }
        ticker?.cancel()
        ticker = nil
        endDate = nil
        log.info("Sleep timer cancelled")
    }

    private func arm(until date: Date) {
        ticker?.cancel()
        lastRun = nil
        endDate = date
        // Bring the homes up now, so they are ready when this ends.
        if homeActionsEnabled, !homeActions.isEmpty {
            SleepHome.shared.prepare(for: Set(homeActions.map(\.source)))
        }
        ticker = Task { [weak self] in
            // The continuous clock keeps counting while the device sleeps.
            let remaining = date.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining), clock: .continuous) }
            guard !Task.isCancelled, let self, self.endDate == date else { return }
            self.finish()
        }
    }

    /// The deadline passed (or the person asked for it now).
    func finish() {
        ticker?.cancel()
        ticker = nil
        endDate = nil

        var paused = 0
        for (id, player) in players {
            guard player.owner != nil else { players.removeValue(forKey: id); continue }
            if player.pause() { paused += 1 }
        }
        #if os(iOS) || os(tvOS)
        IdleTimerHold.releaseAll()
        #endif
        log.info("Sleep timer ended: paused \(paused, privacy: .public) players")

        var run = Run(date: .now, pausedPlayers: paused, outcomes: nil)
        guard homeActionsEnabled, !homeActions.isEmpty else {
            run.outcomes = []
            lastRun = run
            return
        }
        lastRun = run
        runHomeActions()
    }

    // MARK: - Home actions

    /// Run the saved actions now, without pausing anything: the settings
    /// page's Test button, and what `finish` does last.
    func runHomeActions() {
        let targets = homeActions
        guard !targets.isEmpty else { return }
        actionsTask?.cancel()
        let date = lastRun?.date ?? .now
        let paused = lastRun?.pausedPlayers ?? 0
        lastRun = Run(date: date, pausedPlayers: paused, outcomes: nil)
        SleepHome.shared.prepare(for: Set(targets.map(\.source)))
        actionsTask = Task { [weak self] in
            let outcomes = await HomeActionRunner.run(targets, backend: { SleepHome.shared.backend(for: $0) })
            guard !Task.isCancelled, let self else { return }
            self.lastRun = Run(date: date, pausedPlayers: paused, outcomes: outcomes)
            let failed = outcomes.filter { !$0.succeeded }.count
            self.log.info("Sleep timer home actions: \(outcomes.count - failed, privacy: .public) done, \(failed, privacy: .public) failed")
        }
    }

    func setHomeActions(_ actions: [HomeActionTarget]) {
        homeActions = actions
        if let data = try? JSONEncoder().encode(actions) {
            HypnosDefaults.store.set(data, forKey: Key.actions)
        }
    }

    func add(_ action: HomeActionTarget) { setHomeActions(homeActions + [action]) }

    func remove(at offsets: IndexSet) {
        var next = homeActions
        for index in offsets.sorted(by: >) where next.indices.contains(index) { next.remove(at: index) }
        setHomeActions(next)
    }

    func replace(_ action: HomeActionTarget) {
        guard let index = homeActions.firstIndex(where: { $0.id == action.id }) else { return }
        var next = homeActions
        next[index] = action
        setHomeActions(next)
    }
}
