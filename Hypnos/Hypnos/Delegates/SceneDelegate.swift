/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The delegate class for the scene.
*/

import DebugTrace
import SwiftUI

// macOS has no `UIScene`/`UIWindowSceneDelegate` at all — a `Window`/
// `WindowGroup` scene maps straight to a real `NSWindow`, with no delegate
// object in between. The scene-lifecycle logging and `windowScene` tracking
// below are meaningless there (and already no-ops for window-geometry
// purposes — see `PlatformWindowScene` in `Support/PlatformShims.swift`), but
// `@Environment(SceneDelegate.self)` is read from several shared views, so
// macOS gets a minimal stand-in that only carries the cross-platform static
// pieces (the incoming-shared-URL backlog) that `IncomingURLHandler` needs on
// every platform.
#if os(macOS)
@Observable class SceneDelegate: NSObject {
    weak var windowScene: PlatformWindowScene?
}
#else
@Observable class SceneDelegate: NSObject, UIWindowSceneDelegate {
    weak var windowScene: UIWindowScene?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            AppLogger.views.warning("Unable to get the window scene in the Scene Delegate")
            return
        }
        self.windowScene = windowScene
        logScene("willConnect", scene: windowScene)

        // Share-sheet cold launch: when Files.app opens us with a file
        // selected, the URL arrives here, not via SwiftUI's .onOpenURL on
        // an already-running scene. Forward it through the same
        // notification pipeline used for warm shares.
        if !connectionOptions.urlContexts.isEmpty {
            SceneDelegate.deliverSharedURLs(connectionOptions.urlContexts.map { $0.url })
        }
    }

    /// Warm-share path: Files.app sending a file while the app is already
    /// running. With a custom UIWindowSceneDelegate, SwiftUI's `.onOpenURL`
    /// doesn't fire unless we explicitly forward the context.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegate.deliverSharedURLs(URLContexts.map { $0.url })
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        logScene("didBecomeActive", scene: scene)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        logScene("willResignActive", scene: scene)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        logScene("willEnterForeground", scene: scene)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        logScene("didEnterBackground", scene: scene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        logScene("didDisconnect", scene: scene)
    }

    private func logScene(_ event: String, scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let sceneSize = windowScene.effectiveGeometry.coordinateSpace.bounds.size
        let visibleWindows = windowScene.windows.filter { !$0.isHidden && $0.alpha > 0 }.count
        AppLogger.windowState.info(
            "[Scene \(windowScene.session.persistentIdentifier, privacy: .public)] \(event, privacy: .public) activation=\(String(describing: windowScene.activationState), privacy: .public) scene=\(Int(sceneSize.width), privacy: .public)x\(Int(sceneSize.height), privacy: .public) windows=\(windowScene.windows.count, privacy: .public) visible=\(visibleWindows, privacy: .public)"
        )
    }
}
#endif

extension SceneDelegate {
    /// Broadcast notification consumed by every mounted `IncomingURLHandler`.
    /// Posted on the main queue so SwiftUI observers receive it on the main actor.
    static let sharedURLNotification = Notification.Name("Hypnos.sharedURLReceived")

    /// Cold-launch backlog. `scene(_:willConnectTo:)` runs *before* any SwiftUI
    /// scene root has mounted its `.onReceive`, so a share that launches the app
    /// posts into the void — the notification is fire-and-forget and nothing
    /// replays it. Every delivered URL is therefore also parked here and drained
    /// by the first handler to appear (`drainPendingURLs`), which is what makes
    /// "share a file into the not-running app" work at all. Warm shares hit a
    /// live observer first and `consumePending` removes them from the backlog so
    /// a later-mounting window can't reopen them.
    private static let pendingLock = NSLock()
    // `nonisolated(unsafe)`: every access goes through `pendingLock` above,
    // so this is ordinary lock-protected shared state, not a data race —
    // the same shape as `PlatformImage.swift`'s associated-object keys.
    private nonisolated(unsafe) static var pendingURLs: [URL] = []

    /// Take (and clear) any URLs delivered before a handler was listening.
    static func drainPendingURLs() -> [URL] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
    }

    /// Drop a URL from the backlog once a live handler has taken ownership of it.
    static func consumePending(_ url: URL) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        pendingURLs.removeAll { $0 == url }
    }

    fileprivate static func deliverSharedURLs(_ urls: [URL]) {
        pendingLock.lock()
        pendingURLs.append(contentsOf: urls)
        pendingLock.unlock()

        for url in urls {
            AppLogger.sharedMedia.info("SceneDelegate received shared URL: \(url.lastPathComponent)")
            NotificationCenter.default.post(name: sharedURLNotification, object: url)
        }
    }
}
