/*
 Hypnos - Mod Tag Manager

 Local catalog of "mod tag" presets — extra tag clauses appended to the
 RoboFrame orchestrator's DuckDB query for the active channel. Mirrors
 TagListManager UI/UX (Menu picker in the ornament, editor in the Remote
 tab), but the catalog and the user's active selection both live entirely
 on this device. There is no server-side mod-tag catalog; the server
 only learns the active mod tags via slideshowConfig (on connect) or
 setModTags (on switch).

 All viewer windows share a single ModTagManager so mod tag switches are
 synchronized across windows on the same RoboFrame instance.
 */

import DebugTrace
import Foundation

@MainActor
@Observable
class ModTagManager {
    // MARK: - Mod Tag Lists (catalog)

    /// User-curated catalog of mod-tag presets. Each entry is an array of
    /// tag strings appended to the active channel's query.
    var modTagLists: [[String]] = [] {
        didSet { save() }
    }

    /// The currently active preset index, or nil for "no mod tags".
    private(set) var activeIndex: Int? = nil

    /// User preference for which preset to apply on launch. nil = pick up
    /// from `lastActiveIndex`, or no mod tags if there's nothing recorded.
    var defaultIndex: Int? = nil {
        didSet { save() }
    }

    /// Recovery hint across launches.
    private(set) var lastActiveIndex: Int? = nil

    // MARK: - Change notification

    /// View-layer change handlers — registered per window so each ornament
    /// updates when the active preset changes elsewhere.
    private var changeHandlers: [UUID: () -> Void] = [:]

    /// Network senders — one per RemoteViewerModel. Called with the new
    /// active tags after a switch so each connected viewer can push
    /// `setModTags` to its WebSocket. (Multiple viewers sharing a WS will
    /// each fire; the orchestrator's setModTags handler is idempotent.)
    private var sendHandlers: [UUID: ([String]) -> Void] = [:]

    /// Bumped on each switch for lightweight onChange-of: subscriptions.
    var changeVersion: Int = 0

    // MARK: - Computed

    /// The active mod tags. Empty when no preset is selected.
    var activeTags: [String] {
        guard let idx = activeIndex, idx >= 0, idx < modTagLists.count else { return [] }
        return modTagLists[idx]
    }

    /// True when at least one preset is currently applied.
    var isActive: Bool { activeIndex != nil }

    // MARK: - Init

    init() {}

    func initialize() {
        let preferred = defaultIndex ?? lastActiveIndex
        if let idx = preferred, idx >= 0, idx < modTagLists.count {
            activeIndex = idx
        } else {
            activeIndex = nil
        }
    }

    // MARK: - Registration

    func addChangeHandler(id: UUID, _ handler: @escaping () -> Void) {
        changeHandlers[id] = handler
    }
    func removeChangeHandler(id: UUID) {
        changeHandlers[id] = nil
    }
    func addSendHandler(id: UUID, _ handler: @escaping ([String]) -> Void) {
        sendHandlers[id] = handler
    }
    func removeSendHandler(id: UUID) {
        sendHandlers[id] = nil
    }

    // MARK: - Switching

    /// Activate a specific preset, or pass `nil` to clear the active set.
    func switchToPreset(_ index: Int?) {
        let target: Int? = (index != nil && index! >= 0 && index! < modTagLists.count) ? index : nil
        guard target != activeIndex else { return }
        activeIndex = target
        if let idx = target { lastActiveIndex = idx }
        changeVersion += 1
        save()
        notifyChangeHandlers()
        notifySendHandlers()
    }

    func clearActive() { switchToPreset(nil) }

    // MARK: - Persistence

    private static let modTagListsKey = "modTagManager.modTagLists"
    private static let defaultIndexKey = "modTagManager.defaultIndex"
    private static let lastActiveIndexKey = "modTagManager.lastActiveIndex"

    func save() {
        if let data = try? JSONEncoder().encode(modTagLists) {
            UserDefaults.standard.set(data, forKey: Self.modTagListsKey)
        }
        if let idx = defaultIndex {
            UserDefaults.standard.set(idx, forKey: Self.defaultIndexKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultIndexKey)
        }
        if let idx = lastActiveIndex {
            UserDefaults.standard.set(idx, forKey: Self.lastActiveIndexKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastActiveIndexKey)
        }
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: Self.modTagListsKey),
           let lists = try? JSONDecoder().decode([[String]].self, from: data) {
            modTagLists = lists
        }
        if UserDefaults.standard.object(forKey: Self.defaultIndexKey) != nil {
            defaultIndex = UserDefaults.standard.integer(forKey: Self.defaultIndexKey)
        } else {
            defaultIndex = nil
        }
        if UserDefaults.standard.object(forKey: Self.lastActiveIndexKey) != nil {
            lastActiveIndex = UserDefaults.standard.integer(forKey: Self.lastActiveIndexKey)
        } else {
            lastActiveIndex = nil
        }
        initialize()
        AppLogger.remoteViewer.info("ModTagManager loaded: \(self.modTagLists.count, privacy: .public) presets, active=\(self.activeIndex.map(String.init) ?? "nil", privacy: .public)")
    }

    // MARK: - Private

    private func notifyChangeHandlers() {
        for handler in changeHandlers.values { handler() }
    }

    private func notifySendHandlers() {
        let tags = activeTags
        for handler in sendHandlers.values { handler(tags) }
    }
}
