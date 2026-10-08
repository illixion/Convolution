import RAVEUI
import SwiftUI

/// A choice in a player's control bar (subtitles, audio track): a Menu on
/// the bar itself, and inside the compact bar's More popover a button that
/// opens its own popover of rows.
///
/// A Menu opened from inside the More popover is a second-level dropdown,
/// which a tap on the picture can't close (device, 2026-10-08); a popover
/// nested in More closes with it when the tap closes More. The nested
/// popover doesn't report itself through `onOpenChanged`: More, open
/// underneath it, already holds the chrome, and a reported "menu" would take
/// the stereo picture's input away (see `VideoWindowModel.pictureTakesInputWithChrome`).
struct PlayerChoiceMenu<Items: View>: View {
    let title: String
    let systemImage: String
    var help: String?
    var onOpenChanged: (Bool) -> Void = { _ in }
    /// The rows; each calls the passed closure to close the popover first.
    @ViewBuilder let items: (_ close: @escaping () -> Void) -> Items

    @Environment(\.ravePlayerControlsInMenu) private var inMenu
    @State private var showsPopover = false

    var body: some View {
        #if os(tvOS)
        // tvOS has no popovers.
        menu
        #else
        if inMenu {
            Button { showsPopover.toggle() } label: {
                Label(title, systemImage: systemImage)
            }
            .popover(isPresented: $showsPopover, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 4) {
                    items { showsPopover = false }
                }
                .buttonStyle(PlayerPopoverRowStyle())
                .padding(12)
                .frame(minWidth: 220)
            }
            .onDisappear { showsPopover = false }
            .help(help ?? title)
        } else {
            menu
        }
        #endif
    }

    private var menu: some View {
        Menu {
            Group { items {} }
                // Silent inside the bar's More menu (tvOS), which reports for it.
                .ravePlayerMenuReporting(onOpenChanged)
        } label: {
            Label(title, systemImage: systemImage).ravePlayerAccessoryLabel()
        }
        .help(help ?? title)
    }
}

/// A full-width row in a player popover, highlighted under the gaze or
/// pointer like a menu item; a disabled row is dimmed and not highlighted,
/// as a menu would show it (a custom style draws neither on its own).
struct PlayerPopoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(.rect(cornerRadius: 10))
                #if os(visionOS) || os(iOS)
                .contentShape(.hoverEffect, .rect(cornerRadius: 10))
                .hoverEffect(.highlight, isEnabled: isEnabled)
                #endif
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}
