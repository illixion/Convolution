/*
 Hypnos - the YouTube quality choice in the video window (sideload builds
 only: `HYPNOS_YOUTUBE`). The same control as a Library title's
 `StreamQualityMenu`: Auto, then the renditions this video actually has,
 as YouTube's own player lists them ("1080p60", "720p").
 */

#if HYPNOS_YOUTUBE

import RAVEUI
import SwiftUI

struct YouTubeQualityMenu: View {
    /// The chosen rendition's size class; nil is Auto.
    let selected: Int?
    let renditions: [YouTubeRendition]
    /// What is in force, e.g. "Auto · 1440p".
    let label: String
    /// The same, short, for the bar's badge ("1440p").
    let badge: String
    var onOpenChanged: (Bool) -> Void = { _ in }
    let onSelect: (Int?) -> Void

    var body: some View {
        PlayerChoiceMenu(title: "Quality", systemImage: "gauge.with.dots.needle.67percent", badge: badge,
                         help: "Picture quality: \(label)", onOpenChanged: onOpenChanged) { close in
            Button {
                close()
                onSelect(nil)
            } label: {
                row("Auto", detail: "The best the connection allows, lowered if 3D can't keep up",
                    isSelected: selected == nil)
            }
            ForEach(renditions, id: \.height) { rendition in
                Button {
                    close()
                    onSelect(rendition.height)
                } label: {
                    row(rendition.title, detail: nil, isSelected: selected == rendition.height)
                }
            }
        }
        .accessibilityIdentifier("player.youtubeQuality")
    }

    private func row(_ title: String, detail: String?, isSelected: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "checkmark").opacity(isSelected ? 1 : 0)
        }
    }
}

#endif
