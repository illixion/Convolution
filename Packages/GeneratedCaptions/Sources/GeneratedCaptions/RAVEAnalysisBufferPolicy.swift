import Foundation

/// Media seconds, scaled by playback speed so the reserve covers the same
/// wall time at 0.5× and 2×. Hysteresis prevents repeated play/pause at the
/// readiness frontier; silence advances that frontier just like speech.
public struct RAVEAnalysisBufferPolicy: Sendable {
    public var resumeSeconds: Double = 2.5
    public var lowWaterSeconds: Double = 0.35
    public init() {}
    public func needsHold(playhead: Double, readyThrough: Double, duration: Double,
                          rate: Double, alreadyHolding: Bool, finished: Bool) -> Bool {
        guard !finished, playhead.isFinite else { return false }
        let speed = max(0.25, rate.isFinite ? rate : 1)
        let remaining = duration.isFinite && duration > 0 ? max(0, duration - playhead) : .infinity
        let reserve = (alreadyHolding ? resumeSeconds : lowWaterSeconds) * speed
        return readyThrough - playhead + 0.001 < min(reserve, remaining)
    }
}
