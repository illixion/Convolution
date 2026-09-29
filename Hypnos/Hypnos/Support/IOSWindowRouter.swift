/*
 Hypnos - iOS window router

 On visionOS every viewer is its own window: the gallery `pushWindow`s a photo,
 a share opens a shared-photo window, a RoboFrame `playVideo` frame opens a
 video window, and the console is a singleton `Window`. iOS has one window, so
 this router is what those scene ids resolve to:

 - the value-carrying scenes (`photo-detail`, `video-detail`, `shared-photo`,
   `remote-viewer`, `remote-alert`) become a stack of full-screen covers over
   the gallery, in the order they were opened (`IOSRootView` presents them);
 - the singleton tool windows (`console`, `gpu-memory`, `video-adjustments`)
   become sheets over whatever is showing;
 - `main` dismisses every cover back to the gallery, since there is only one.

 `openWindow(id:value:)` with a value that is already on the stack dismisses
 everything above it — the equivalent of visionOS summoning the existing window
 — so the app's duplicate-open bookkeeping needs no changes here.

 The router is installed at the root by `IOSRootView` and reached through the
 proxies in `WindowActions.swift`; nothing outside those two files talks to it.
 */

#if !os(visionOS)

import DebugTrace
import SwiftUI

/// One entry on the iOS cover stack: the window value a visionOS scene would
/// have been keyed by.
enum IOSWindowDestination: Hashable, Identifiable {
    case photo(PhotoWindowValue)
    case video(VideoWindowValue)
    case sharedPhoto(SharedMediaItem)
    case remoteViewer(RemoteViewerWindowValue)
    case remoteAlert(RemoteAlertWindowValue)

    /// Stable identity, doubling as the token `dismissWindow()` uses to find
    /// the presentation the calling view lives in.
    var id: String {
        switch self {
        case .photo(let value): return "photo-detail:\(value.id.uuidString)"
        case .video(let value): return "video-detail:\(value.id.uuidString)"
        case .sharedPhoto(let item): return "shared-photo:\(item.id)"
        case .remoteViewer(let value): return "remote-viewer:\(value.id.uuidString)"
        case .remoteAlert(let value): return "remote-alert:\(value.id.uuidString)"
        }
    }

    /// The visionOS scene id this destination stands in for.
    var sceneID: String {
        switch self {
        case .photo: return "photo-detail"
        case .video: return "video-detail"
        case .sharedPhoto: return "shared-photo"
        case .remoteViewer: return "remote-viewer"
        case .remoteAlert: return "remote-alert"
        }
    }
}

/// The singleton tool windows, shown as sheets.
enum IOSToolSheet: String, Identifiable {
    case console
    case gpuMemory = "gpu-memory"
    case videoAdjustments = "video-adjustments"
    case filmPlayer = "film-player"

    var id: String { rawValue }
}

@MainActor
@Observable
final class IOSWindowRouter {
    /// The covers over the gallery, bottom first. `IOSRootView` presents one
    /// `fullScreenCover` per entry.
    var path: [IOSWindowDestination] = []

    /// The tool sheet currently presented, if any.
    var sheet: IOSToolSheet?

    /// Incremented whenever something asks for the main window (a viewer's
    /// Gallery button, a tag tapped in an info sheet). `ContentView` watches it
    /// to adopt a pending gallery filter, the job a *new* main window's
    /// `onAppear` does on visionOS.
    private(set) var mainWindowRequests = 0

    // MARK: - Open

    /// Route an `openWindow`/`pushWindow` call. `pushed` records the caller's
    /// intent only — both land on the same stack — and is folded into the
    /// value's `wasPushed` where the value carries one.
    func open(id: String, value: (any Codable & Hashable)?, pushed: Bool) {
        switch id {
        case "main":
            popToRoot()
            mainWindowRequests &+= 1

        case "photo-detail":
            guard let value = value as? PhotoWindowValue else { return unroutable(id, value) }
            present(.photo(value))

        case "video-detail":
            guard let value = value as? VideoWindowValue else { return unroutable(id, value) }
            present(.video(value))

        case "shared-photo":
            guard let item = value as? SharedMediaItem else { return unroutable(id, value) }
            present(.sharedPhoto(item))

        case "remote-viewer":
            guard let value = value as? RemoteViewerWindowValue else { return unroutable(id, value) }
            present(.remoteViewer(value))

        case "remote-alert":
            guard let value = value as? RemoteAlertWindowValue else { return unroutable(id, value) }
            present(.remoteAlert(value))

        case "console":
            sheet = .console
        case "gpu-memory":
            sheet = .gpuMemory
        case "video-adjustments":
            sheet = .videoAdjustments
        case "film-player":
            sheet = .filmPlayer

        default:
            unroutable(id, value)
        }
    }

    /// Push `destination`, or pop back to it if the same window value is
    /// already on the stack (visionOS would summon that window).
    private func present(_ destination: IOSWindowDestination) {
        if let index = path.firstIndex(of: destination) {
            path.removeSubrange(path.index(after: index)...)
            return
        }
        path.append(destination)
    }

    private func unroutable(_ id: String, _ value: (any Codable & Hashable)?) {
        AppLogger.windowState.error(
            "iOS router has no destination for scene \(id, privacy: .public) with value \(String(describing: value))"
        )
    }

    // MARK: - Dismiss

    /// `dismissWindow()` from inside a presentation: pop that destination and
    /// everything above it. From the main window it is a no-op — the one
    /// window cannot close itself.
    func dismiss(token: String?) {
        guard let token else { return }
        if let index = path.firstIndex(where: { $0.id == token }) {
            path.removeSubrange(index...)
        }
    }

    /// `dismissWindow(id:)` — the singleton tool windows.
    func dismiss(id: String) {
        if let tool = IOSToolSheet(rawValue: id), sheet == tool {
            sheet = nil
        }
    }

    /// `dismissWindow(id:value:)` — a specific window value, wherever it is on
    /// the stack. Used by the remote viewer's `stopVideo`/`dismissText` frames
    /// and by saved-group restores.
    func dismiss(id: String, value: any Codable & Hashable) {
        path.removeAll { destination in
            guard destination.sceneID == id else { return false }
            switch (destination, value) {
            case (.photo(let a), let b as PhotoWindowValue): return a == b
            case (.video(let a), let b as VideoWindowValue): return a == b
            case (.sharedPhoto(let a), let b as SharedMediaItem): return a == b
            case (.remoteViewer(let a), let b as RemoteViewerWindowValue): return a == b
            case (.remoteAlert(let a), let b as RemoteAlertWindowValue): return a == b
            default: return false
            }
        }
    }

    func popToRoot() {
        path.removeAll()
    }
}

// MARK: - Environment

private struct IOSWindowTokenKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Identity of the router destination the view is presented in; nil in
    /// the main window. Read by `DismissWindowProxy`.
    var iosWindowToken: String? {
        get { self[IOSWindowTokenKey.self] }
        set { self[IOSWindowTokenKey.self] = newValue }
    }
}

#endif
