/*
 Hypnos - the players' chrome coming and going

 The control strip and the title corner rise into place as they appear and
 sink away as they hide, rather than blinking on and off. On visionOS they
 are ornaments, and an ornament whose visibility turns hidden vanishes at
 once, with no animation: `playerChromeOrnament` keeps it mounted until the
 hide has played, and mounts it hidden before animating it in. iOS's
 ornament shim slides its edge overlays the same way.
 */

import SwiftUI

enum PlayerChromeAnimation {
    static let reveal = Animation.spring(response: 0.36, dampingFraction: 0.86)
    static let hide = Animation.easeIn(duration: 0.2)
    /// How long the hide plays before the ornament is taken down.
    static let hideDuration: Duration = .milliseconds(240)
    /// How far (points, about a millimetre each) the title corner comes
    /// forward over a stereo picture. Its ornament hangs on the glass and
    /// overlaps the picture, whose plane sits ~12 mm in front of the glass,
    /// so the plane covered it: the title showed only while an open menu
    /// dimmed the picture (device, 2026-10-27).
    static let stereoTitleLift: CGFloat = 30
}

/// Chrome shown or hidden: faded and nudged towards the window it hangs
/// from (`edge`), a little smaller, and taking no input while hidden.
struct PlayerChromeReveal: ViewModifier {
    let shown: Bool
    /// The side the window is on: the chrome hides towards it.
    var edge: VerticalEdge = .top

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.96, anchor: edge == .top ? .top : .bottom)
            .offset(y: shown ? 0 : (edge == .top ? -16 : 16))
            .allowsHitTesting(shown)
    }
}

#if os(visionOS)
/// An ornament whose content animates in and out (see the file comment).
private struct PlayerChromeOrnament<OrnamentContent: View>: ViewModifier {
    let isPresented: Bool
    let keepsMounted: Bool
    let attachmentAnchor: OrnamentAttachmentAnchor
    let contentAlignment: Alignment3D
    let makeOrnament: (_ shown: Bool) -> OrnamentContent

    @State private var mounted = false
    @State private var shown = false
    @State private var transition: Task<Void, Never>?
    /// `keepsMounted`, let go of only after what it held (a prompt) has
    /// played its way out: acting on `keepsMounted` itself would take the
    /// ornament down in the same pass that removes the prompt.
    @State private var heldMounted = false
    @State private var lingerTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        let visibility: Visibility = mounted || keepsMounted || heldMounted ? .visible : .hidden
        let shown = shown
        return content
            .ornament(visibility: visibility, attachmentAnchor: attachmentAnchor,
                      contentAlignment: contentAlignment, ornament: { makeOrnament(shown) })
            .onChange(of: isPresented, initial: true) { _, presented in update(presented) }
            .onChange(of: keepsMounted, initial: true) { _, kept in lingerIfLetGo(kept) }
            .onDisappear { transition?.cancel(); lingerTask?.cancel() }
    }

    private func lingerIfLetGo(_ kept: Bool) {
        lingerTask?.cancel()
        if kept {
            heldMounted = true
            return
        }
        lingerTask = Task { @MainActor in
            try? await Task.sleep(for: PlayerChromeAnimation.hideDuration)
            guard !Task.isCancelled else { return }
            heldMounted = false
        }
    }

    private func update(_ presented: Bool) {
        transition?.cancel()
        if presented {
            let wasMounted = mounted || keepsMounted
            mounted = true
            guard !wasMounted else {
                withAnimation(PlayerChromeAnimation.reveal) { shown = true }
                return
            }
            // Mounted hidden first, so the reveal has somewhere to start.
            transition = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
                withAnimation(PlayerChromeAnimation.reveal) { shown = true }
            }
        } else {
            withAnimation(PlayerChromeAnimation.hide) { shown = false }
            transition = Task { @MainActor in
                try? await Task.sleep(for: PlayerChromeAnimation.hideDuration)
                guard !Task.isCancelled else { return }
                mounted = false
            }
        }
    }
}

extension View {
    /// An ornament for a player's chrome, animated in and out with
    /// `isPresented`. `keepsMounted` holds the ornament up for something else
    /// in it while the chrome is hidden (subtitles, a skip button); the
    /// content gets `shown` to animate its chrome by (`PlayerChromeReveal`).
    func playerChromeOrnament<Content: View>(
        isPresented: Bool,
        keepsMounted: Bool = false,
        attachmentAnchor: OrnamentAttachmentAnchor,
        contentAlignment: Alignment3D = .center,
        @ViewBuilder ornament: @escaping (_ shown: Bool) -> Content
    ) -> some View {
        modifier(PlayerChromeOrnament(isPresented: isPresented, keepsMounted: keepsMounted,
                                      attachmentAnchor: attachmentAnchor, contentAlignment: contentAlignment,
                                      makeOrnament: ornament))
    }
}
#endif
