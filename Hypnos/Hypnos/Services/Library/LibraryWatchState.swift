/*
 Hypnos - Library feature: keeping watch state current everywhere

 Every Library screen shows watch state it loaded earlier: Up Next's resume
 bars, a detail page's Resume button, an episode row's played badges. Those
 screens live in a tab, under a pushed player (`pushWindow` swaps a window's
 content in place, so the Library stays alive beneath it), or in another
 window altogether, and none of them sees a player close. Nothing reloaded
 them, so pressing Up Next's episode again resumed from where it had been
 *before* the last watch.

 This is the one signal they all follow. It changes once the server has the
 new state, not when a player closes: a player's stop report is sent from a
 Task as it goes away, and a screen that reloads on the close itself fetches
 the position from before it.

 - `revision` bumps after a stop report lands and after a played/favorite
   toggle. Screens key their reloads on it.
 - `settled(itemId:)` lets a Play button wait for a stop report still in
   flight for the same item, so it reads the position that report carries.
 */

import Foundation
import Observation

@MainActor
@Observable
final class LibraryWatchState {
    static let shared = LibraryWatchState()

    /// Bumped whenever the server's watch state changed under us.
    private(set) var revision = 0

    /// Stop reports still on their way to the server, per item.
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    /// Keep active playback shelves current without refreshing the whole
    /// Library for every ten-second progress packet.
    @ObservationIgnored private var lastProgressNotification: [String: (position: Double, date: Date)] = [:]

    private init() {}

    func reportBegan(itemId: String) {
        inFlight[itemId, default: 0] += 1
    }

    func reportLanded(itemId: String) {
        let remaining = (inFlight[itemId] ?? 1) - 1
        inFlight[itemId] = remaining > 0 ? remaining : nil
        lastProgressNotification[itemId] = nil
        revision += 1
    }

    /// Refresh Library screens as playback advances, at most every 30
    /// seconds per title. A stop still refreshes immediately via
    /// `reportLanded(itemId:)`.
    func progressReported(itemId: String, positionSeconds: Double) {
        guard positionSeconds.isFinite, positionSeconds >= 0 else { return }
        let now = Date()
        if let last = lastProgressNotification[itemId],
           now.timeIntervalSince(last.date) < 30,
           positionSeconds - last.position < 30 {
            return
        }
        lastProgressNotification[itemId] = (positionSeconds, now)
        revision += 1
    }

    /// Played or favorite state changed from one of the Library's screens.
    func changed() {
        revision += 1
    }

    /// Returns once no stop report is in flight (for `itemId`, or for any
    /// item when nil: a series' Play doesn't know its episode yet), or after
    /// `timeout`: a server that doesn't answer shouldn't block Play.
    func settled(itemId: String? = nil, timeout: Duration = .seconds(4)) async {
        let deadline = ContinuousClock.now + timeout
        while (itemId.map { inFlight[$0] != nil } ?? !inFlight.isEmpty), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
