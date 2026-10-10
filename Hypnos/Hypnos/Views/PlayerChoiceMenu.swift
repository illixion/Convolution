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
///
/// With a `badge`, the bar shows the value in force ("1080p", "AI 3D") in
/// place of the icon, so it reads without opening the menu.
struct PlayerChoiceMenu<Items: View>: View {
    let title: String
    let systemImage: String
    var badge: String?
    var badgeIsActive = false
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
                Label(badge.map { "\(title): \($0)" } ?? title, systemImage: systemImage)
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
            if let badge {
                PlayerBadge(text: badge, isActive: badgeIsActive)
                    .accessibilityLabel("\(title): \(badge)")
            } else {
                Label(title, systemImage: systemImage).ravePlayerAccessoryLabel()
            }
        }
        .help(help ?? title)
    }
}

/// A control-bar button that reads as its value ("1080p", "AI 3D") rather
/// than as an icon. `isActive` fills it, for a mode that is on (3D).
struct PlayerBadge: View {
    let text: String
    var isActive = false

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? AnyShapeStyle(.tint.opacity(0.4)) : AnyShapeStyle(.quaternary), in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
            .ravePlayerControlLabel()
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
