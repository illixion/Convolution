import RAVEUI
import SwiftUI

/// The streaming quality choice for a Library title: a menu on the bar, a
/// popover of rows inside the compact bar's More (see `PlayerChoiceMenu`).
struct StreamQualityMenu: View {
    let selected: LibraryStreamQuality
    /// What is in force, e.g. "Auto · 720p".
    let label: String
    var isChanging = false
    var onOpenChanged: (Bool) -> Void = { _ in }
    let onSelect: (LibraryStreamQuality) -> Void

    var body: some View {
        PlayerChoiceMenu(title: "Quality: \(label)", systemImage: "gauge.with.dots.needle.67percent",
                         help: isChanging ? "Changing quality…" : "Streaming quality",
                         onOpenChanged: onOpenChanged) { close in
            ForEach(LibraryStreamQuality.allCases, id: \.self) { quality in
                Button {
                    close()
                    onSelect(quality)
                } label: {
                    StreamQualityRow(quality: quality, isSelected: quality == selected)
                }
            }
        }
        .accessibilityIdentifier("player.quality")
    }
}

/// One level: its title, what it means for the two original-quality
/// choices, and a checkmark on the chosen one.
struct StreamQualityRow: View {
    let quality: LibraryStreamQuality
    let isSelected: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(quality.title)
                if let detail = quality.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "checkmark").opacity(isSelected ? 1 : 0)
        }
    }
}

/// A heading between groups of rows in the compact bar's More popover.
struct PlayerPopoverSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 8)
    }
}

/// A value nudged in place from the More popover — convergence, subtitle
/// timing — so a quick correction needs no trip to the Adjustments window.
struct PlayerStepRow: View {
    let title: String
    let value: String
    let decrease: () -> Void
    let increase: () -> Void
    var reset: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            step("minus", action: decrease, label: "Decrease \(title)")
            step("plus", action: increase, label: "Increase \(title)")
            if let reset {
                step("arrow.counterclockwise", action: reset, label: "Reset \(title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minWidth: 280)
    }

    private func step(_ symbol: String, action: @escaping () -> Void, label: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.borderless)
        #if os(visionOS) || os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(label)
    }
}

/// Shows `bar` on the control bar and `menu` inside its More popover, where
/// the same accessories can be grouped and labelled.
struct PlayerAccessoryLayout<Bar: View, MenuContent: View>: View {
    @ViewBuilder let bar: Bar
    @ViewBuilder let menu: MenuContent
    @Environment(\.ravePlayerControlsInMenu) private var inMenu

    var body: some View {
        if inMenu { menu } else { bar }
    }
}

/// Auto lowered the quality (or couldn't): said under the window, beside
/// the skip button, where it reads over any picture, stereo included.
struct StreamQualityNotice: View {
    let text: String
    var systemImage = "gauge.with.dots.needle.33percent"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #if os(visionOS)
            .glassBackgroundEffect(in: Capsule())
            #else
            .background(.regularMaterial, in: Capsule())
            #endif
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityIdentifier("player.qualityNotice")
    }
}
