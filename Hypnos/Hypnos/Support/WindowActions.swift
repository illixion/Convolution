/*
 Hypnos - Cross-platform window actions

 Every viewer in this app was written against visionOS's multi-window model:
 `openWindow` for a pop-out, `pushWindow` for an in-place viewer that returns to
 the gallery on dismiss, `dismissWindow` to close either. iPhone has exactly one
 window, and iPad's multi-scene support has neither `pushWindow` nor a way to
 present a scene *over* the caller. So the call sites keep their shape — the
 same `openWindow(id:value:)` / `pushWindow(id:value:)` / `dismissWindow()`
 spelling — but read the action through these proxies instead of SwiftUI's
 environment keys directly:

 - on visionOS **and macOS** each proxy wraps the real SwiftUI action — macOS
   gets real multiple windows too (see `Hypnos/CLAUDE.md` "macOS"), not the
   iOS/tvOS single-scene router. `pushWindow` has no macOS equivalent (it's a
   visionOS-only API: "replace this window's content in place"), so a push on
   macOS just opens a new window instead — the ordinary Mac convention is
   separate windows, not one window that swaps its content;
 - a push on visionOS is RAVEUI's `ravePushWindow`, not SwiftUI's
   `pushWindow`, which visionOS 27 stopped honouring (the viewer opened beside
   the gallery instead of in its place). The gallery retains its live content
   in memory and retires its shell; return reattaches it to a fresh window at
   the user. Every scene a push starts from or lands in
   carries `.raveWindowPushHost(sceneID:value:)` in `HypnosApp`;
 - on iOS and tvOS each proxy talks to `IOSWindowRouter`, which turns a window
   value into a full-screen cover (viewers) or a sheet (tool panels) inside the
   one window.

 The proxies are `DynamicProperty` wrappers so a view declares them exactly as
 it declared the environment action: `@OpenWindowProxy private var openWindow`.
 */

import SwiftUI
#if os(visionOS)
import RAVEUI
#endif

// MARK: - Actions

/// Stand-in for SwiftUI's `OpenWindowAction` with the same call shapes.
@MainActor
struct WindowOpenAction {
    #if os(visionOS) || os(macOS)
    let action: OpenWindowAction

    func callAsFunction(id: String) {
        action(id: id)
    }

    func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        action(id: id, value: value)
    }
    #else
    let router: IOSWindowRouter?

    func callAsFunction(id: String) {
        router?.open(id: id, value: nil as (any Codable & Hashable)?, pushed: false)
    }

    func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        router?.open(id: id, value: value, pushed: false)
    }
    #endif
}

/// Stand-in for SwiftUI's `PushWindowAction`. On iOS a push and an open land on
/// the same cover stack; the distinction survives only as the viewer's
/// `wasPushed` chrome (back button vs. gallery button). On macOS, which has no
/// `pushWindow` API at all, a push just opens a new window (see file header).
@MainActor
struct WindowPushAction {
    #if os(visionOS)
    let action: RAVEPushWindowAction

    func callAsFunction(id: String) {
        action(id: id)
    }

    func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        action(id: id, value: value)
    }
    #elseif os(macOS)
    let openAction: OpenWindowAction

    func callAsFunction(id: String) {
        openAction(id: id)
    }

    func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        openAction(id: id, value: value)
    }
    #else
    let router: IOSWindowRouter?

    func callAsFunction(id: String) {
        router?.open(id: id, value: nil as (any Codable & Hashable)?, pushed: true)
    }

    func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        router?.open(id: id, value: value, pushed: true)
    }
    #endif
}

/// Stand-in for SwiftUI's `DismissWindowAction`.
@MainActor
struct WindowDismissAction {
    #if os(visionOS)
    var stackedAction: RAVEDismissWindowAction? = nil
    #endif
    #if os(visionOS) || os(macOS)
    let action: DismissWindowAction

    func callAsFunction() {
        #if os(visionOS)
        if let stackedAction { return stackedAction() }
        #endif
        action()
    }

    func callAsFunction(id: String) {
        action(id: id)
    }

    func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        action(id: id, value: value)
    }
    #else
    let router: IOSWindowRouter?
    /// The presentation the calling view lives in; nil in the main window.
    let token: String?

    func callAsFunction() {
        router?.dismiss(token: token)
    }

    func callAsFunction(id: String) {
        router?.dismiss(id: id)
    }

    func callAsFunction<V: Codable & Hashable>(id: String, value: V) {
        router?.dismiss(id: id, value: value)
    }
    #endif
}

// MARK: - Property wrappers

@propertyWrapper
struct OpenWindowProxy: DynamicProperty {
    #if os(visionOS)
    @Environment(\.raveWindowShell) private var shell
    #endif
    #if os(visionOS) || os(macOS)
    @Environment(\.openWindow) private var action

    @MainActor var wrappedValue: WindowOpenAction {
        #if os(visionOS)
        WindowOpenAction(action: shell?.openWindow ?? action)
        #else
        WindowOpenAction(action: action)
        #endif
    }
    #else
    @Environment(IOSWindowRouter.self) private var router: IOSWindowRouter?

    var wrappedValue: WindowOpenAction { WindowOpenAction(router: router) }
    #endif

    init() {}
}

@propertyWrapper
struct PushWindowProxy: DynamicProperty {
    #if os(visionOS)
    @Environment(\.ravePushWindow) private var action

    var wrappedValue: WindowPushAction { WindowPushAction(action: action) }
    #elseif os(macOS)
    @Environment(\.openWindow) private var action

    var wrappedValue: WindowPushAction { WindowPushAction(openAction: action) }
    #else
    @Environment(IOSWindowRouter.self) private var router: IOSWindowRouter?

    var wrappedValue: WindowPushAction { WindowPushAction(router: router) }
    #endif

    init() {}
}

@propertyWrapper
struct DismissWindowProxy: DynamicProperty {
    #if os(visionOS)
    @Environment(\.raveWindowShell) private var shell
    @Environment(\.raveDismissWindow) private var stackedAction
    #endif
    #if os(visionOS) || os(macOS)
    @Environment(\.dismissWindow) private var action

    @MainActor var wrappedValue: WindowDismissAction {
        #if os(visionOS)
        WindowDismissAction(stackedAction: stackedAction, action: shell?.dismissWindow ?? action)
        #else
        WindowDismissAction(action: action)
        #endif
    }
    #else
    @Environment(IOSWindowRouter.self) private var router: IOSWindowRouter?
    @Environment(\.iosWindowToken) private var token

    var wrappedValue: WindowDismissAction { WindowDismissAction(router: router, token: token) }
    #endif

    init() {}
}
