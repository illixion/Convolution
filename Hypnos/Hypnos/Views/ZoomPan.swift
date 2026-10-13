/*
 Hypnos

 Pinch-to-zoom and pan for flat pictures: photos in the viewer, and videos
 on the flat renderers when Settings → Display → Pinch to Zoom Videos is on.
*/

import SwiftUI

/// How far a picture is zoomed in and where it is panned to. Held by the
/// view that owns the picture, so it can turn swipe navigation off while
/// zoomed and reset when the picture changes.
struct ZoomPanState: Equatable {
    static let maxScale: CGFloat = 6

    var scale: CGFloat = 1
    /// Translation of the scaled picture's center, in the unscaled frame's points.
    var offset: CGSize = .zero

    var isZoomed: Bool { scale > 1.01 }

    mutating func reset() { self = ZoomPanState() }

    /// Keeps the picture covering its frame: an edge never comes inside it.
    func clamped(in size: CGSize) -> ZoomPanState {
        let limitX = max(0, (scale - 1) * size.width / 2)
        let limitY = max(0, (scale - 1) * size.height / 2)
        var result = self
        result.offset = CGSize(
            width: min(max(offset.width, -limitX), limitX),
            height: min(max(offset.height, -limitY), limitY)
        )
        return result
    }
}

extension View {
    /// Draws the picture at `state`'s zoom, clipped to its own frame where
    /// the frame is the window (everywhere but iOS, whose full-screen viewer
    /// lets a zoomed photo fill the screen).
    func zoomPanTransform(_ state: ZoomPanState) -> some View {
        modifier(ZoomPanTransformModifier(state: state))
    }

    /// Pinch to zoom (two hands on visionOS, a trackpad on macOS), drag to pan
    /// while zoomed. Pinching back to 1× snaps the picture home. Added as
    /// simultaneous gestures so taps and swipes on the content still work;
    /// callers turn their swipe off while `state.isZoomed`.
    func zoomPanGestures(_ state: Binding<ZoomPanState>, enabled: Bool = true) -> some View {
        modifier(ZoomPanGestureModifier(state: state, enabled: enabled))
    }
}

private struct ZoomPanTransformModifier: ViewModifier {
    let state: ZoomPanState

    func body(content: Content) -> some View {
        let transformed = content
            .scaleEffect(state.scale)
            .offset(state.offset)
        #if os(iOS)
        transformed
        #else
        transformed.clipped()
        #endif
    }
}

private struct ZoomPanGestureModifier: ViewModifier {
    @Binding var state: ZoomPanState
    let enabled: Bool

    /// State when the current pinch began, and when the current drag began.
    @State private var pinchStart: ZoomPanState?
    @State private var panStart: ZoomPanState?
    @State private var frameSize: CGSize = .zero

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { frameSize = $0 }
            .simultaneousGesture(magnify, including: enabled ? .all : .subviews)
            .simultaneousGesture(pan, including: enabled && state.isZoomed ? .all : .subviews)
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { state.reset() }
            }
        #endif
    }

    #if !os(tvOS)
    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? state
                if pinchStart == nil { pinchStart = start }
                let scale = min(max(start.scale * value.magnification, 1), ZoomPanState.maxScale)
                // Zoom about the pinch point: keep the content under it in place.
                let anchor = CGPoint(
                    x: (value.startAnchor.x - 0.5) * frameSize.width,
                    y: (value.startAnchor.y - 0.5) * frameSize.height
                )
                let ratio = scale / start.scale
                var next = start
                next.scale = scale
                next.offset = CGSize(
                    width: anchor.x - (anchor.x - start.offset.width) * ratio,
                    height: anchor.y - (anchor.y - start.offset.height) * ratio
                )
                state = next.clamped(in: frameSize)
            }
            .onEnded { _ in
                pinchStart = nil
                if !state.isZoomed {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.reset() }
                }
            }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // A pinch moves the picture itself; a hand drifting during it
                // must not pan on top.
                guard pinchStart == nil else { panStart = nil; return }
                let start = panStart ?? state
                if panStart == nil { panStart = start }
                var next = start
                next.offset = CGSize(
                    width: start.offset.width + value.translation.width,
                    height: start.offset.height + value.translation.height
                )
                state = next.clamped(in: frameSize)
            }
            .onEnded { _ in
                panStart = nil
            }
    }
    #endif
}
