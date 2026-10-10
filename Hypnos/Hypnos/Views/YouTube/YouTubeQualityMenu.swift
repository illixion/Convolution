/*
 Hypnos - the YouTube quality choice in the video window (sideload builds
 only: `HYPNOS_YOUTUBE`). The same control as a Library title's
 `StreamQualityMenu`, over YouTube's levels.
 */

#if HYPNOS_YOUTUBE

import RAVEUI
import SwiftUI

struct YouTubeQualityMenu: View {
    let selected: YouTubeQuality
    /// What is in force, e.g. "Auto · 1440p".
    let label: String
    /// The same, short, for the bar's badge ("1440p").
    let badge: String
    var onOpenChanged: (Bool) -> Void = { _ in }
    let onSelect: (YouTubeQuality) -> Void

    var body: some View {
        PlayerChoiceMenu(title: "Quality", systemImage: "gauge.with.dots.needle.67percent", badge: badge,
                         help: "Picture quality: \(label)", onOpenChanged: onOpenChanged) { close in
            ForEach(YouTubeQuality.allCases) { quality in
                Button {
                    close()
                    onSelect(quality)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.title)
                            if let detail = quality.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "checkmark").opacity(quality == selected ? 1 : 0)
                    }
                }
            }
        }
        .accessibilityIdentifier("player.youtubeQuality")
    }
}

#endif
