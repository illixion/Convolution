/*
 Hypnos - Restored Window Tracker

 Persists the set of pop-out window value UUIDs that have been opened at least
 once. visionOS restores wall-snapped windows after a reboot with the same
 Codable value (and thus the same UUID), so windows whose UUID is already in
 the set are system-restored rather than user-opened — viewers use this to
 start with ornaments hidden and skip the initial reveal.
 */

import Foundation

@MainActor
enum RestoredWindowTracker {
    private static let defaultsKey = "RestoredWindowTracker.seenWindowIDs"
    private static let maxEntries = 256

    private static var seen: Set<UUID> = loadFromDefaults()

    /// Returns true if this window value has been started before (i.e. visionOS
    /// is restoring it after an app/device launch).
    static func isRestored(_ id: UUID) -> Bool {
        seen.contains(id)
    }

    /// Mark a window value as seen. Call on first `onAppear` so subsequent
    /// restorations of the same window are recognized.
    static func markSeen(_ id: UUID) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        // Bound storage so dismissed pop-outs don't accumulate forever.
        // Pop-out UUIDs that aren't in any restorable scene will eventually
        // age out; the worst case if a still-snapped window is evicted is one
        // extra ornament reveal on next restore.
        if seen.count > maxEntries {
            seen = Set(seen.shuffled().prefix(maxEntries))
        }
        HypnosDefaults.store.set(seen.map(\.uuidString), forKey: defaultsKey)
    }

    private static func loadFromDefaults() -> Set<UUID> {
        guard let raw = HypnosDefaults.store.array(forKey: defaultsKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    // MARK: - Per-window size fallback

    /// UserDefaults-backed window size keyed by window value UUID. Backup for
    /// the `restoredSize` field in the Codable window value: the scene-archive
    /// binding write-back is the primary mechanism, but this survives even if
    /// the archive round-trip drops the mutated value. Bounded like `seen`.
    private static let sizesKey = "RestoredWindowTracker.windowSizes"

    private static var sizes: [String: [Double]] = (
        HypnosDefaults.store.dictionary(forKey: sizesKey) as? [String: [Double]]
    ) ?? [:]

    static func windowSize(for id: UUID) -> CGSize? {
        guard let pair = sizes[id.uuidString], pair.count == 2,
              pair[0] > 2, pair[1] > 2 else { return nil }
        return CGSize(width: pair[0], height: pair[1])
    }

    /// Drop a stored size — used when the persisted geometry is rejected as
    /// degenerate, so the window falls back to the scene default instead of
    /// being restored to a collapsed size again on the next launch.
    static func clearWindowSize(for id: UUID) {
        guard sizes.removeValue(forKey: id.uuidString) != nil else { return }
        HypnosDefaults.store.set(sizes, forKey: sizesKey)
    }

    static func setWindowSize(_ size: CGSize, for id: UUID) {
        sizes[id.uuidString] = [size.width, size.height]
        if sizes.count > maxEntries {
            for key in sizes.keys.shuffled().prefix(sizes.count - maxEntries) {
                sizes.removeValue(forKey: key)
            }
        }
        HypnosDefaults.store.set(sizes, forKey: sizesKey)
    }
}
