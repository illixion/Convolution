/*
 Hypnos - the listening volume the player controls' slider sets
 */

import Foundation

/// One volume for every video window and the film player, remembered between
/// launches. Mute is separate and per window; this is how loud unmuted is.
enum PlayerVolume {
    private static let key = "player.volume"

    static var saved: Double {
        get {
            guard HypnosDefaults.store.object(forKey: key) != nil else { return 1 }
            return min(max(HypnosDefaults.store.double(forKey: key), 0), 1)
        }
        set { HypnosDefaults.store.set(min(max(newValue, 0), 1), forKey: key) }
    }
}
