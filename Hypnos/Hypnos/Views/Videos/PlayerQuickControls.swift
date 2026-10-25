import RAVEUI
import SwiftUI

/// The streaming quality choice for a Library title: a menu on the bar, a
/// popover of rows inside the control strip's More (see `PlayerChoiceMenu`).
/// It lists what this title can actually be streamed at
/// (`LibraryStreamQuality.offered`), not every level there is.
struct StreamQualityMenu: View {
    let selected: LibraryStreamQuality
    /// The levels this title offers.
    let offered: [LibraryStreamQuality]
    /// The title's own picture ("1080p"), for the Auto and Original rows.
    var sourceLabel: String?
    /// What is in force, e.g. "Auto · 720p".
    let label: String
    /// The same, short, for the bar's badge ("720p").
    let badge: String
    var isChanging = false
    var onOpenChanged: (Bool) -> Void = { _ in }
    let onSelect: (LibraryStreamQuality) -> Void

    var body: some View {
        PlayerChoiceMenu(title: "Quality", systemImage: "gauge.with.dots.needle.67percent",
                         badge: isChanging ? "…" : badge,
                         help: isChanging ? "Changing quality…" : "Streaming quality: \(label)",
                         onOpenChanged: onOpenChanged) { close in
            ForEach(offered, id: \.self) { quality in
                Button {
                    close()
                    onSelect(quality)
                } label: {
                    StreamQualityRow(quality: quality, isSelected: quality == selected, sourceLabel: sourceLabel)
                }
            }
        }
        .accessibilityIdentifier("player.quality")
    }
}

/// The playback speeds every player offers, and how they read.
enum PlaybackSpeed {
    static let choices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// "1×", "1.25×", "0.5×".
    static func label(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0 ... 2))) + "×"
    }
}

/// Playback speed: the bar shows the speed in force as its badge, filled
/// when it isn't 1×, so a sped-up film never goes unnoticed.
struct PlaybackSpeedMenu: View {
    let speed: Double
    var onOpenChanged: (Bool) -> Void = { _ in }
    let onSelect: (Double) -> Void

    var body: some View {
        PlayerChoiceMenu(title: "Speed", systemImage: "gauge.open.with.lines.needle.33percent.and.arrowtriangle",
                         badge: PlaybackSpeed.label(speed), badgeIsActive: speed != 1,
                         help: "Playback speed: \(PlaybackSpeed.label(speed))",
                         onOpenChanged: onOpenChanged) { close in
            ForEach(PlaybackSpeed.choices, id: \.self) { choice in
                Button {
                    close()
                    onSelect(choice)
                } label: {
                    PlayerChoiceRow(choice == 1 ? "Normal (1×)" : PlaybackSpeed.label(choice), isChecked: choice == speed)
                }
            }
        }
        .accessibilityIdentifier("player.speed")
    }
}

/// The video's audio tracks, when it has more than one
/// (`VideoWindowModel+AudioTracks`).
struct VideoAudioTrackMenu: View {
    let tracks: [VideoAudioTrack]
    let selected: VideoAudioTrack.ID?
    var onOpenChanged: (Bool) -> Void = { _ in }
    let onSelect: (VideoAudioTrack) -> Void

    var body: some View {
        PlayerChoiceMenu(title: "Audio", systemImage: "speaker.wave.2",
                         help: tracks.first { $0.id == selected }.map { "Audio: \($0.title)" } ?? "Audio",
                         onOpenChanged: onOpenChanged) { close in
            ForEach(tracks) { track in
                Button {
                    close()
                    onSelect(track)
                } label: {
                    PlayerChoiceRow(track.title, isChecked: track.id == selected)
                }
            }
        }
        .accessibilityIdentifier("player.audio")
    }
}

/// One level: its title, what it means for the two original-quality
/// choices (naming the title's own picture when known), and a checkmark on
/// the chosen one.
struct StreamQualityRow: View {
    let quality: LibraryStreamQuality
    let isSelected: Bool
    /// The title's own picture ("1080p").
    var sourceLabel: String?

    private var detail: String? {
        guard let sourceLabel else { return quality.detail }
        switch quality {
        case .auto: return "Original \(sourceLabel), lowered if the stream can't keep up"
        case .original: return "Original \(sourceLabel), never lowered"
        default: return quality.detail
        }
    }

    var body: some View {
        PlayerChoiceRow(isChecked: isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                Text(quality.title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A heading between groups of rows in the control strip's More popover.
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

/// Shows `bar` on the control strip and `menu` inside its More popover,
/// where the same accessories can be grouped and labelled. Each is given the
/// highest priority the strip has room for (`ravePlayerAccessoryRoom`): the
/// bar shows its accessories up to it, the menu the ones above it. A bar
/// with no More (the stacked bar, a plain HStack) is given `Int.max`.
struct PlayerAccessoryLayout<Bar: View, MenuContent: View>: View {
    @ViewBuilder let bar: (_ room: Int) -> Bar
    @ViewBuilder let menu: (_ room: Int) -> MenuContent
    @Environment(\.ravePlayerControlsInMenu) private var inMenu
    @Environment(\.ravePlayerAccessoryRoom) private var room

    var body: some View {
        if inMenu { menu(room) } else { bar(room) }
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
