import DebugTrace
import Foundation
import os

/// Surfaces the system's local-network access prompt ahead of the first real
/// LAN request, so that request succeeds instead of failing against an
/// undetermined permission.
///
/// There is no public API to *query* or *request* local-network access, so the
/// only lever is to touch something that needs it and let the system prompt.
/// `ProcessInfo.processInfo.hostName` is the cheapest such thing: it resolves
/// the device's own name over mDNS.
///
/// Two properties of that call are the whole reason this type exists:
///
/// - **It is synchronous and it blocks until the user answers.** While the
///   permission is undetermined the resolution stalls, and the calling thread
///   stalls with it — potentially for as long as the alert is on screen.
/// - **The alert is presented on the app's own window scene.** So blocking the
///   main thread from `didFinishLaunchingWithOptions`, before any scene has
///   connected, deadlocks: no scene means no alert, no alert means the call
///   never returns, and the app sits on a black screen. Backgrounding and
///   returning breaks the tie only because it gives UIKit a chance to attach
///   the scene behind the stuck launch. visionOS's scene lifecycle happens to
///   dodge this; iOS does not.
///
/// So the prewarm runs **off the main thread** and **only once the UI is
/// already on screen**, and only for users who actually have a LAN-dependent
/// feature configured — a Photos-only user should never see the prompt.
enum LocalNetworkPermission {
    private static let hasPrewarmed = OSAllocatedUnfairLock(initialState: false)

    /// Triggers the prompt at most once per process. Safe to call from
    /// anywhere; returns immediately and never blocks the caller.
    ///
    /// - Parameter reason: logged, so the console says which feature asked.
    static func prewarm(reason: String) {
        let alreadyRan = hasPrewarmed.withLock { ran -> Bool in
            defer { ran = true }
            return ran
        }
        guard !alreadyRan else { return }

        AppLogger.app.info("Local network prewarm requested (\(reason, privacy: .public))")

        // Detached and off-main on purpose — see the type comment. This task
        // may stay parked for as long as the alert is up.
        Task.detached(priority: .utility) {
            let hostName = ProcessInfo.processInfo.hostName
            AppLogger.app.info("Local network prewarm completed (host: \(hostName, privacy: .private))")
        }
    }
}
