/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The delegate class for the application.
*/

import DebugTrace
import RAVEUI
import SwiftUI

// macOS has no `UIApplicationDelegate`/scene-session machinery — a `Window`/
// `WindowGroup` scene maps straight to a real `NSWindow`, there is no
// "restore a scene, then decide whether to summon a main window" dance (a
// closed Mac window is just gone, and Cmd+N/the Dock icon already reopen one
// the ordinary AppKit way), and this app doesn't yet route macOS's windows
// through `RAVEWindowSessionRegistry` (see Hypnos/CLAUDE.md "macOS" — a known
// gap, not a port of this file's visionOS/iOS logic). What does carry over
// unchanged is the one-time app-launch housekeeping: local media directories
// and the shared-media cache exist on every platform.
#if os(macOS)
@Observable
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await LocalMediaSource.shared.ensureDirectoriesExist()
        }
        Task {
            await SharedMediaCache.shared.cleanupOrphanedEntries()
        }
    }
}
#else
@Observable
class AppDelegate: NSObject, UIApplicationDelegate {
    /// Tracks whether we've already handled the initial activation so a
    /// gaze-suspended app resuming on look-back doesn't re-summon the main
    /// window.
    private var didHandleInitialActivation = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Route the shared window-session registry's diagnostics into our logger.
        Task { @MainActor in
            RAVEWindowSessionRegistry.shared.log = { message in
                AppLogger.windowState.info("\(message, privacy: .public)")
            }
        }

        // Ensure local media directories exist so the app shows up in Files app
        Task {
            await LocalMediaSource.shared.ensureDirectoriesExist()
        }
        // Clean up orphaned shared media cache entries from previous sessions
        Task {
            await SharedMediaCache.shared.cleanupOrphanedEntries()
        }
        return true
    }

    /// Fires once per process lifetime on the first `didBecomeActive`. If the
    /// only restored scenes are pop-outs (main window was previously closed),
    /// summon a main window so the user has a way to navigate the app.
    /// Subsequent activations — including gaze-resume after visionOS suspends
    /// the process — are ignored, which prevents the main window from popping
    /// up unexpectedly when the user merely looks back at a wall-pinned window.
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !didHandleInitialActivation else { return }
        didHandleInitialActivation = true
        Task { @MainActor in
            // Give SwiftUI a moment to attach restored scenes and run their
            // onAppear so `mainWindowCount` reflects reality.
            try? await Task.sleep(for: .milliseconds(400))
            RAVEWindowSessionRegistry.shared.ensureMainWindowVisible()
        }
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }
}
#endif
