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
 */

import Foundation

public final class OnScreenCoreMLTurn: @unchecked Sendable {
    public static let shared = OnScreenCoreMLTurn()

    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Waits until no other model is running, then holds the turn; pair
    /// with `release()`. Not cancellable: a prediction already started
    /// cannot be stopped, and the next one must wait for it either way.
    public func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = lock.withLock { () -> Bool in
                if busy { waiters.append(continuation); return false }
                busy = true
                return true
            }
            if granted { continuation.resume() }
        }
    }

    /// Passes the turn to the next waiter, or frees it.
    public func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }

    /// Runs `body` holding the turn.
    public func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
