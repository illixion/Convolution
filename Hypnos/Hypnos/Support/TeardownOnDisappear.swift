/*
 Hypnos - teardown that waits to see whether a disappearance is real

 SwiftUI can report `onDisappear` for a view that is still on screen and
 `onAppear` right after it. A photo window hosted by RAVEUI's viewer-HUD
 wrapper got such a pair about 0.2 s after its first frame, and again at
 each change of its scene's phase (device, 2026-11-14), all inside SwiftUI's
 own update with the hosting view never leaving its window. Its `cleanup()`
 can't be undone (`start()` runs once), so the window was left on its
 loading spinner, and a picture in 3D lost its state.

 `onTeardown` runs its action only if the view stays gone for `delay`; an
 appearance in between cancels it. The pending teardown is held by `key`, not
 in view state: the pair re-creates the subtree, so state inside it starts
 over and an appearance there would find nothing to cancel (the first version
 kept it in `@State` and the window still emptied a second after opening).
 Key it by something that outlives the subtree: the window's model, or its
 window value. A window the system really closes is also torn down at once
 through `SceneDelegate.onDisconnect`.
 */

import SwiftUI

@MainActor
private enum PendingTeardowns {
    static var tasks: [AnyHashable: Task<Void, Never>] = [:]
}

private struct TeardownOnDisappear: ViewModifier {
    let key: AnyHashable
    let delay: Duration
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                PendingTeardowns.tasks.removeValue(forKey: key)?.cancel()
            }
            .onDisappear {
                let key = key
                let delay = delay
                let action = action
                PendingTeardowns.tasks[key]?.cancel()
                PendingTeardowns.tasks[key] = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    PendingTeardowns.tasks[key] = nil
                    action()
                }
            }
    }
}

extension View {
    /// `onDisappear` for teardown that can't be undone: runs `action` once
    /// the view has stayed gone for `delay`. `key` must outlive the view's
    /// subtree (the window's model, or its window value).
    func onTeardown(
        key: AnyHashable,
        after delay: Duration = .seconds(1),
        perform action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(TeardownOnDisappear(key: key, delay: delay, action: action))
    }
}
