#if os(iOS) || os(tvOS)
import UIKit

/// Keeps the screen on while any player is playing.
///
/// Neither of the app's own pictures holds it by itself: the film player
/// feeds a display layer on its own clock, and the video window's Metal path
/// draws frames from an `AVPlayerItemVideoOutput` with no `AVPlayerLayer`, so
/// `preventsDisplaySleepDuringVideoPlayback` never applies and an iPad went
/// dark mid-episode. `UIApplication.isIdleTimerDisabled` is one flag for the
/// whole app, so each player holds by its own key and the flag is on while
/// anyone holds it: a video window pausing must not let the screen sleep
/// under a film still playing, or under a second window in split view.
@MainActor
enum IdleTimerHold {
    private static var holders: Set<ObjectIdentifier> = []

    static func set(_ holding: Bool, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if holding { holders.insert(id) } else { holders.remove(id) }
        let disabled = !holders.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }
}
#endif
