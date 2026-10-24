import RAVEUI
import SwiftUI

/// A choice in a player's control bar (subtitles, audio track, quality,
/// speed, view mode): a button that opens a popover of rows, on the bar and
/// inside the control strip's More popover alike. tvOS has no popovers, so
/// there it is a Menu.
///
/// It is a popover, not a Menu, because a Menu's content doesn't reliably
/// report closing: tapping its button a second time to dismiss it never
/// reported, which held the chrome open and left a stereo picture dimmed
/// (device, 2026-10-23; the same bug that made More a popover). A popover is
/// reported exactly, from its binding, through `onOpenChanged`, and closed
/// when `dismissal` (or the host's `playerChoiceDismissal`) changes, so a tap
/// on the picture can close it.
///
/// Inside More the nested popover doesn't report itself: More, open
/// underneath it, already holds the chrome, and a reported "menu" would take
/// the stereo picture's input away (see `VideoWindowModel.pictureTakesInputWithChrome`).
///
/// With a `badge`, the bar shows the value in force ("1080p", "AI 3D") in
/// place of the icon, so it reads without opening the menu.
///
/// A choice in a tvOS Menu reports it closed itself, in case its content's
/// disappear never comes.
struct PlayerChoiceMenu<Items: View>: View {
    let title: String
    let systemImage: String
    var badge: String?
    var badgeIsActive = false
    var help: String?
    /// Bumped by the host to close the popover.
    var dismissal = 0
    var onOpenChanged: (Bool) -> Void = { _ in }
    /// The rows; each calls the passed closure first, which closes the
    /// popover, or reports the menu closed.
    @ViewBuilder let items: (_ close: @escaping () -> Void) -> Items

    @Environment(\.ravePlayerControlsInMenu) private var inMenu
    @Environment(\.playerChoiceDismissal) private var hostDismissal
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
            .popover(isPresented: $showsPopover, arrowEdge: .trailing) { popoverRows }
            .onDisappear { showsPopover = false }
            .help(help ?? title)
        } else {
            Button { showsPopover.toggle() } label: { barLabel }
                .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                    popoverRows
                        // Taps reach the window, so one on the picture closes it.
                        .presentationBackgroundInteraction(.enabled)
                }
                .onChange(of: showsPopover) { _, shown in onOpenChanged(shown) }
                .onChange(of: dismissal + hostDismissal) { showsPopover = false }
                .onDisappear {
                    if showsPopover { onOpenChanged(false) }
                    showsPopover = false
                }
                .help(help ?? title)
        }
        #endif
    }

    #if !os(tvOS)
    /// Past this a popover scrolls: it opens above the bar, so a taller one
    /// put its first rows out of view (View Mode with its depth models).
    private static var maxPopoverHeight: CGFloat { 460 }

    private var popoverRows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                items { showsPopover = false }
            }
            .padding(12)
            .frame(minWidth: 220, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.maxPopoverHeight)
        // Rows read as in More's popover (checkmarks aligned).
        .environment(\.ravePlayerControlsInMenu, true)
        .buttonStyle(PlayerPopoverRowStyle())
        .presentationCompactAdaptation(.popover)
    }
    #endif

    @ViewBuilder private var barLabel: some View {
        if let badge {
            PlayerBadge(text: badge, isActive: badgeIsActive)
                .accessibilityLabel("\(title): \(badge)")
        } else {
            Label(title, systemImage: systemImage).ravePlayerAccessoryLabel()
        }
    }

    private var menu: some View {
        Menu {
            Group { items { onOpenChanged(false) } }
                // Silent inside the bar's More menu (tvOS), which reports for it.
                .ravePlayerMenuReporting(onOpenChanged)
        } label: {
            barLabel
        }
        .help(help ?? title)
    }
}

extension EnvironmentValues {
    /// Bumped by the player hosting the bar to close an open choice popover
    /// (a tap on the picture); see `PlayerChoiceMenu`.
    @Entry var playerChoiceDismissal = 0
}

/// A choice with a checkmark when it is the one in force. A system menu
/// draws whatever icon a label has, a hidden one included, so in a menu the
/// row has an icon only when checked (the menu aligns the titles itself); in
/// a popover the checkmark is hidden instead, keeping the titles aligned.
/// Every choice row goes through this, so none draws a checkmark of its own.
struct PlayerChoiceRow<Content: View>: View {
    let isChecked: Bool
    @ViewBuilder let content: Content

    init(isChecked: Bool, @ViewBuilder content: () -> Content) {
        self.isChecked = isChecked
        self.content = content()
    }

    @Environment(\.ravePlayerControlsInMenu) private var inMenu

    var body: some View {
        #if os(tvOS)
        // tvOS has no popovers: always a system menu.
        let inPopover = false
        #else
        let inPopover = inMenu
        #endif
        if inPopover {
            // `hidden` keeps the icon's room and drops it from the accessibility tree.
            Label { content } icon: { Image(systemName: "checkmark").hidden(!isChecked) }
        } else if isChecked {
            Label { content } icon: { Image(systemName: "checkmark") }
        } else {
            content
        }
    }
}

extension PlayerChoiceRow where Content == Text {
    init(_ title: String, isChecked: Bool) {
        self.init(isChecked: isChecked) { Text(title) }
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

private extension View {
    /// Hidden but laid out, or as is.
    @ViewBuilder func hidden(_ hidden: Bool) -> some View {
        if hidden { self.hidden() } else { self }
    }
}
