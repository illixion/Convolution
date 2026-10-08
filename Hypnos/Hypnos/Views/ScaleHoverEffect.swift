/*
 Hypnos - Scale Hover Effect

 Custom visionOS 2.0 hover effect that scales thumbnails on focus.

 `CustomHoverEffect` is visionOS-only. On iOS the type exists so call sites
 compile, and `hoverEffect(ScaleHoverEffect())` degrades to the system
 pointer highlight (iPad trackpad / mouse); touch has no hover to react to.
 */

import SwiftUI

#if os(visionOS)

struct ScaleHoverEffect: CustomHoverEffect {
    func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, proxy in
            effect.animation(.easeOut(duration: 0.2)) {
                $0.scaleEffect(
                    isActive ? CGSize(width: 1.08, height: 1.08) : CGSize(width: 1, height: 1),
                    anchor: .center
                )
            }
        }
    }
}

#elseif os(macOS)

// `.hoverEffect` doesn't exist on macOS — a real mouse cursor already shows
// hover with no help needed. No-op.
struct ScaleHoverEffect {}

extension View {
    func hoverEffect(_ effect: ScaleHoverEffect) -> some View {
        self
    }
}

#else

struct ScaleHoverEffect {}

extension View {
    func hoverEffect(_ effect: ScaleHoverEffect) -> some View {
        hoverEffect(.highlight)
    }
}

#endif

extension View {
    /// How a thumbnail reacts to the gaze: `ScaleHoverEffect`, or a plain
    /// highlight with Reduce Motion on.
    @ViewBuilder
    func thumbnailHoverEffect(reduceMotion: Bool = false) -> some View {
        #if os(macOS)
        hoverEffect(ScaleHoverEffect())
        #else
        if reduceMotion {
            hoverEffect(.highlight)
        } else {
            hoverEffect(ScaleHoverEffect())
        }
        #endif
    }

    /// Tap runs `action`, with a quick press-down dip.
    func thumbnailTap(reduceMotion: Bool, action: @escaping () -> Void) -> some View {
        modifier(ThumbnailTap(reduceMotion: reduceMotion, action: action))
    }

    /// A thumbnail's long-press. On visionOS a held gesture runs
    /// `quickLook` when there is one (its side menu carries the same items,
    /// `QuickLookActionRows`), else opens the items in a popover on the
    /// cell: visionOS never presents a `.contextMenu` on a view carrying a
    /// `CustomHoverEffect` (device, 2026-10-08: not on the cell, inside a
    /// button or on one), and its lifted preview of a 3D tile is an empty
    /// grey card. Elsewhere it is the system context menu.
    func thumbnailMenu<Items: View>(reduceMotion: Bool, quickLook: (() -> Void)? = nil,
                                    @ViewBuilder items: @escaping () -> Items) -> some View {
        modifier(ThumbnailMenu(reduceMotion: reduceMotion, quickLook: quickLook, items: items))
    }
}

private struct ThumbnailTap: ViewModifier {
    let reduceMotion: Bool
    let action: () -> Void
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.92 : 1)
            .onTapGesture {
                if !reduceMotion {
                    withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                    withAnimation(.easeOut(duration: 0.15).delay(0.08)) { pressed = false }
                }
                action()
            }
    }
}

private struct ThumbnailMenu<Items: View>: ViewModifier {
    let reduceMotion: Bool
    let quickLook: (() -> Void)?
    let items: () -> Items

    #if os(visionOS)
    @State private var isShown = false
    /// Press feedback: a dip on touch-down, then a slow grow that telegraphs
    /// the menu, as the Quick Look long-press did.
    @State private var scale: CGFloat = 1
    @State private var growth: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onLongPressGesture(minimumDuration: 0.5, perform: {
                growth?.cancel()
                withAnimation(.easeOut(duration: 0.15)) { scale = 1 }
                if let quickLook {
                    quickLook()
                } else {
                    isShown = true
                }
            }, onPressingChanged: { pressing in
                growth?.cancel()
                guard !reduceMotion else { return }
                if pressing {
                    withAnimation(.easeOut(duration: 0.08)) { scale = 0.92 }
                    growth = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.4)) { scale = 1.06 }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { scale = 1 }
                }
            })
            .popover(isPresented: $isShown) {
                VStack(alignment: .leading, spacing: 2) {
                    items()
                }
                .buttonStyle(ClosingRowStyle())
                .labelStyle(.titleAndIcon)
                .padding(10)
                .frame(minWidth: 260, alignment: .leading)
            }
    }
    #else
    func body(content: Content) -> some View {
        content.contextMenu { items() }
    }
    #endif
}

#if os(visionOS)
/// A popover menu row that closes the popover after its action, as a
/// context menu's items do. A tap gesture over the rows to close it kept
/// the buttons' own actions from running.
private struct ClosingRowStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Button(role: configuration.role) {
                dismiss()
                configuration.trigger()
            } label: {
                configuration.label
            }
            .buttonStyle(PlayerPopoverRowStyle())
        }
    }
}
#endif

