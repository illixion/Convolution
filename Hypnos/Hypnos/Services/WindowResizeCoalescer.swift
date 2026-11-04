//
//  WindowResizeCoalescer.swift
//  Hypnos
//
//  One window's geometry requests, deduplicated.
//
//  visionOS has no window-*position* API: `requestGeometryUpdate` carries a
//  size and the system decides where the resized window ends up. So every
//  granted resize is also a move the app cannot undo, and the cost is paid in
//  full by the photo viewer. (Under SwiftUI's `pushWindow` the viewer shared
//  the gallery's scene, so each request walked the grid window around the
//  room; RAVEUI's push gives the viewer its own scene and leaves the hidden
//  gallery where it was, but the viewer itself still moves with every grant.)
//
//  The viewer computes the same target size from several independent triggers
//  (branch appearance, aspect-ratio change, load completion, end of a swipe,
//  and a delayed verification pass) because any one of them can be the one
//  that first knows the final aspect ratio. They are not redundant as
//  *triggers* — they are redundant as *requests*. This forwards the first and
//  drops the restatements.
//
//  The test for "that one already landed" is deliberately **not** "the window
//  is now the size I asked for". A requested size and the scene geometry that
//  comes back are not in the same coordinate space — the scene is larger than
//  the SwiftUI content the sizes are computed from by the window's chrome
//  insets, which is the same mismatch documented in `WindowSizeNudge` as the
//  cause of a size ratchet. Comparing across the two would make every grant
//  look wrong and suppress nothing.
//
//  What is compared instead is the scene geometry against itself: the window's
//  size is sampled just before each request is sent, and a restatement is
//  dropped only when the window has moved since. If the window has *not*
//  changed since the last identical request, the request either did nothing or
//  was dropped by the system — the two are indistinguishable from here, so it
//  goes through. That is what keeps every existing retry path working
//  (scene-restoration stomps, dropped requests during window placement) while
//  still collapsing the burst of identical requests that one image open fires.
//

import SwiftUI

@MainActor
final class WindowResizeCoalescer {
    /// Sizes within this many points of each other are the same size. Loose
    /// enough to absorb the sub-point differences that fall out of
    /// aspect-ratio arithmetic, tight enough that a real resize is never eaten.
    private static let tolerance: CGFloat = 1.5

    /// The size of the last request actually sent — not the last one asked for.
    private var lastRequestedSize: CGSize?

    /// The window's own geometry as it was immediately before that request went
    /// out. The window having moved away from this is the evidence that the
    /// request landed.
    private var sceneSizeBeforeLastRequest: CGSize?

    /// The last resizing restriction actually sent. `setUniformResizing()` runs
    /// on every render-branch appearance — which includes each image switch and
    /// every flip in and out of the adjustments preview — and re-asserting a
    /// restriction the window already has is one more geometry update for the
    /// system to re-anchor around.
    private var lastRestriction: WindowGeometry.ResizingRestriction?

    /// Requests dropped since this window opened. Debug signal only: it is how
    /// you tell "the window stopped drifting" from "the window stopped being
    /// asked to move".
    private(set) var suppressedCount: Int = 0

    /// Forward a geometry request unless it restates one the window has already
    /// visibly answered. Returns whether anything was actually sent.
    ///
    /// - Parameter force: bypass the dedupe entirely. For callers that
    ///   deliberately re-request a size they know they already asked for,
    ///   because they have read back evidence that the grant was wrong.
    @discardableResult
    func request(
        _ scene: PlatformWindowScene?,
        size: CGSize? = nil,
        restriction: WindowGeometry.ResizingRestriction? = nil,
        animated: Bool = false,
        force: Bool = false
    ) -> Bool {
        guard size != nil || restriction != nil else { return false }

        let sceneSize = scene?.effectiveGeometrySize
        var sizeToSend = size
        var restrictionToSend = restriction

        if !force {
            if let size, let lastRequested = lastRequestedSize,
               Self.matches(size, lastRequested),
               let sceneSize, let sceneSizeBefore = sceneSizeBeforeLastRequest,
               !Self.matches(sceneSize, sceneSizeBefore) {
                sizeToSend = nil
            }
            if let restriction, restriction == lastRestriction {
                restrictionToSend = nil
            }
        }

        guard sizeToSend != nil || restrictionToSend != nil else {
            suppressedCount += 1
            return false
        }

        WindowGeometry.request(
            scene,
            size: sizeToSend,
            restriction: restrictionToSend,
            animated: animated
        )

        if let sizeToSend {
            lastRequestedSize = sizeToSend
            sceneSizeBeforeLastRequest = sceneSize
        }
        if let restrictionToSend { lastRestriction = restrictionToSend }
        return true
    }

    /// Forget what was last requested, so the next request is always sent. For
    /// the moments where the window is handed to something that sizes it by
    /// other means and the recorded request no longer describes anything.
    func invalidate() {
        lastRequestedSize = nil
        sceneSizeBeforeLastRequest = nil
        lastRestriction = nil
    }

    private static func matches(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}
