/*
 Hypnos - a thumbnail's quick actions inside Quick Look

 On visionOS a long-press on a thumbnail pops Quick Look straight away (the
 gesture it always had), so the thumbnail's quick actions (Open, Info,
 Rating, Share, Select, Delete…) live in Quick Look's side menu rather than
 in a context menu. A system context menu isn't an option there anyway:
 visionOS never presents one on a cell carrying the grid's custom scale
 hover effect. Elsewhere the same items are the cell's context menu.

 Each row closes Quick Look before its action runs, so whatever the action
 presents (a sheet, a confirmation, a window) isn't covered by the preview.
 */

import SwiftUI

/// Quick Look's side-menu rows for `actions`, styled like its own buttons.
struct QuickLookActionRows: View {
    let actions: AnyView
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            actions
        }
        .buttonStyle(QuickLookActionStyle(dismiss: dismiss))
        .labelStyle(QuickLookActionLabelStyle())
    }
}

/// Closes Quick Look, then runs the row's action.
private struct QuickLookActionStyle: PrimitiveButtonStyle {
    let dismiss: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            dismiss()
            configuration.trigger()
        } label: {
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        .hoverEffect()
        #endif
    }
}

/// Icon in a fixed column, then the title, like Quick Look's own rows.
private struct QuickLookActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.frame(width: 22)
            configuration.title.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
