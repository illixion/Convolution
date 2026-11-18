/*
 On-screen text: one Core ML workload at a time.

 Kokoro's synthesis and Vision's text recognition both run Core ML models
 (Espresso's E5RT runtime, its CPU work in libBNNS). A Vision Pro on
 visionOS 27.2 crashed in libBNNS (`BnnsCpuInferenceOperation`, an
 uncatchable trap) 22 minutes into a narrated video with a Kokoro voice,
 while both were running side by side. FluidAudio traced the same crash
 family to concurrent predictions corrupting shared E5RT/BNNS state
 (FluidAudio #661), and on a headset Vision's warm-up has hung while
 Kokoro's models compiled. So everything here that runs a model takes
 this turn first: a Kokoro line (all seven stages), a Kokoro load or
 unload, and each frame Vision reads. Waiters are served in order.

 A Kokoro line holds it for well under a second on a Vision Pro, and the
 reader works 8 s ahead of the playhead, so a frame waiting for a line
 costs nothing visible.

 **A call that never returns must not freeze everything behind it** (device,
 2026-11-18: a frame read sat behind a model call for 45 s, and with the
 video held for the reader, the video stood still). So a waiter can give up
 (`timeout`), and a holder declares how long it may hold (`patience`): a
 waiter that has timed out against a holder past its patience takes the turn
 from it. The abandoned call is presumably dead, not computing, so running
 beside it is the lesser risk; if it does return, its release is ignored.
 */

import Foundation

public final class OnScreenCoreMLTurn: @unchecked Sendable {
    public static let shared = OnScreenCoreMLTurn()

    /// The turn wasn't free within the waiter's timeout.
    public struct TimedOut: Error, Sendable {}

    private struct Waiter {
        let id: UInt64
        let patience: TimeInterval
        let continuation: CheckedContinuation<UInt64?, Never>
    }

    private let lock = NSLock()
    private var busy = false
    private var holder: UInt64 = 0
    private var heldSince = Date.distantPast
    private var holderPatience: TimeInterval = .infinity
    private var waiters: [Waiter] = []
    private var lastID: UInt64 = 0
    /// How many holders were abandoned (a debug readout).
    public private(set) var abandoned = 0

    public init() {}

    /// Waits until no other model is running, then holds the turn; pair the
    /// returned ticket with `release(_:)`. Not cancellable: a prediction
    /// already started cannot be stopped, and the next one must wait for it
    /// either way. With a `timeout`, gives up and returns nil.
    public func acquire(timeout: TimeInterval? = nil, patience: TimeInterval = .infinity) async -> UInt64? {
        let id = lock.withLock { () -> UInt64 in lastID += 1; return lastID }
        return await withCheckedContinuation { (continuation: CheckedContinuation<UInt64?, Never>) in
            let granted = lock.withLock { () -> Bool in
                if busy {
                    waiters.append(Waiter(id: id, patience: patience, continuation: continuation))
                    return false
                }
                busy = true; holder = id; heldSince = .now; holderPatience = patience
                return true
            }
            if granted { continuation.resume(returning: id); return }
            if let timeout {
                Task.detached { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.giveUp(id)
                }
            }
        }
    }

    /// A waiter's timeout: leaves the queue, and takes the turn from a
    /// holder that has outlived its patience.
    private func giveUp(_ id: UInt64) {
        var resume: [(CheckedContinuation<UInt64?, Never>, UInt64?)] = []
        lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            let me = waiters.remove(at: index)
            resume.append((me.continuation, nil))
            if busy, Date.now.timeIntervalSince(heldSince) > holderPatience {
                abandoned += 1
                if let next = handOff() { resume.append(next) }
            }
        }
        for (continuation, value) in resume { continuation.resume(returning: value) }
    }

    /// Passes the turn to the next waiter, or frees it. Call with the lock held.
    private func handOff() -> (CheckedContinuation<UInt64?, Never>, UInt64?)? {
        if waiters.isEmpty { busy = false; holder = 0; return nil }
        let next = waiters.removeFirst()
        holder = next.id; heldSince = .now; holderPatience = next.patience
        return (next.continuation, next.id)
    }

    /// Ends the hold `ticket` took. A holder that was abandoned meanwhile
    /// has no hold left to end.
    public func release(_ ticket: UInt64) {
        let next = lock.withLock { () -> (CheckedContinuation<UInt64?, Never>, UInt64?)? in
            guard busy, holder == ticket else { return nil }
            return handOff()
        }
        next?.0.resume(returning: next?.1)
    }

    /// Runs `body` holding the turn.
    public func run<T>(_ body: () async throws -> T) async rethrows -> T {
        let ticket = await acquire()!
        defer { release(ticket) }
        return try await body()
    }

    /// Runs `body` holding the turn, or throws `TimedOut` when it isn't free
    /// within `timeout` (nil waits for ever). `patience` is how long this body may hold the turn
    /// before a waiter that has timed out may take it from it.
    public func run<T>(timeout: TimeInterval? = nil, patience: TimeInterval, _ body: () async throws -> T) async throws -> T {
        guard let ticket = await acquire(timeout: timeout, patience: patience) else { throw TimedOut() }
        defer { release(ticket) }
        return try await body()
    }
}
