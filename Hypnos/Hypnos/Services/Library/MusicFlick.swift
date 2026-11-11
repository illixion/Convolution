/*
 Hypnos - Music section: when a flick of the song's name skips it.

 The rules of the gesture, apart from the view that draws it (`MusicTrackLabels`) so they can be checked: the
 flick is deliberately hard to make by accident. A drag only counts if it is mostly sideways, has to pull the
 name most of the way across and still be there when the finger lifts, and goes nowhere where there is no song
 to go to. Speed alone never skips.
 */

import CoreGraphics
import Foundation

enum MusicFlick {
    /// How far the name has to be pulled to skip, for a block `width` points wide: most of the way across, and
    /// never less than 120 points however narrow the block is.
    static func commitDistance(width: CGFloat) -> CGFloat { max(120, width * 0.45) }

    /// Whether a drag that has just begun is a sideways one: at least twice as far across as down. Decided once,
    /// at the start, so a scroll or a sheet being dragged down never turns into a skip halfway.
    static func startsSideways(dx: CGFloat, dy: CGFloat) -> Bool { abs(dx) > abs(dy) * 2 }

    /// Whether the pull so far is past the point of no return: far enough, still mostly sideways (three times as
    /// far across as down) and with a song to go to. This is what the tick and the peeking song announce.
    static func isArmed(dx: CGFloat, dy: CGFloat, width: CGFloat, canGo: Bool) -> Bool {
        canGo && abs(dx) >= commitDistance(width: width) && abs(dx) >= abs(dy) * 3
    }

    /// How far the name has moved for a drag of `dx`: one to one up to the threshold, then it drags; where there
    /// is no song to go to it only stretches.
    static func travel(dx: CGFloat, width: CGFloat, canGo: Bool) -> CGFloat {
        let magnitude = abs(dx)
        let moved = canGo
            ? min(magnitude, commitDistance(width: width)) + max(0, magnitude - commitDistance(width: width)) * 0.25
            : magnitude * 0.18
        return dx < 0 ? -moved : moved
    }

    enum Outcome: Equatable {
        /// Go to the next song (`forward`) or the previous one.
        case skip(forward: Bool)
        case cancel
    }

    /// What lifting the finger after a sideways drag does.
    static func outcome(dx: CGFloat, dy: CGFloat, width: CGFloat, hasNext: Bool, hasPrevious: Bool) -> Outcome {
        let forward = dx < 0
        guard forward ? hasNext : hasPrevious, isArmed(dx: dx, dy: dy, width: width, canGo: true) else { return .cancel }
        return .skip(forward: forward)
    }
}
