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
            guard UserDefaults.standard.object(forKey: key) != nil else { return 1 }
            return min(max(UserDefaults.standard.double(forKey: key), 0), 1)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: key) }
    }
}
