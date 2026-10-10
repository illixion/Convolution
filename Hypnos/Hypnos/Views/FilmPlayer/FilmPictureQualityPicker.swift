import DebugTrace
import RAVEFilm
import SwiftUI

/// The film's picture: Auto (visionOS: the original, lowered for this film
/// when 3D can't keep up), the original, or a lower tier the plugin offers
/// (`FilmPictureQuality`). Shown only for a film with tiers on offer. A
/// choice is remembered and applies at once, at the playhead.
struct FilmPictureQualityPicker: View {
    let player: FilmVideoPlayer
    @AppStorage(FilmPictureQuality.defaultsKey) private var stored = FilmPictureQuality.auto.rawValue

    private var choices: [FilmPictureQuality] { FilmPictureQuality.choices(offering: player.offeredPictureHeights) }

    private var selected: FilmPictureQuality {
        FilmPictureQuality.selected(stored: stored, offering: player.offeredPictureHeights)
    }

    var body: some View {
        Picker("Picture Quality", selection: Binding {
            selected
        } set: { quality in
            stored = quality.rawValue
            AppLogger.filmPlayer.info("Picture quality → \(quality.rawValue, privacy: .public)")
            Task { await player.setPictureHeight(quality.height) }
        }) {
            ForEach(choices, id: \.self) { quality in
                Text(quality.title).tag(quality)
            }
        }
        Text(caption).font(.caption).foregroundStyle(.secondary)
    }

    private var caption: String {
        let now = FilmPictureQuality.name(of: player.pictureHeight)
        let changing = player.isChangingPictureTier ? " (changing…)" : ""
        if selected == .auto {
            return "Auto plays the original and lowers it for this film if 3D can't keep up. Now \(now)\(changing)."
        }
        return "Lower tiers are made by the server as they play and use less of the connection. Now \(now)\(changing)."
    }
}

/// The same choice in the transport, beside Audio Quality, so a tier is one
/// tap away mid-film; shown only for a film with tiers on offer.
struct FilmPictureQualityMenu: View {
    let player: FilmVideoPlayer
    var onOpenChanged: (Bool) -> Void = { _ in }
    @AppStorage(FilmPictureQuality.defaultsKey) private var stored = FilmPictureQuality.auto.rawValue

    private var selected: FilmPictureQuality {
        FilmPictureQuality.selected(stored: stored, offering: player.offeredPictureHeights)
    }

    var body: some View {
        PlayerChoiceMenu(title: "Picture Quality", systemImage: "gauge.with.dots.needle.67percent",
                         help: "Picture: \(FilmPictureQuality.name(of: player.pictureHeight))",
                         onOpenChanged: onOpenChanged) { close in
            ForEach(FilmPictureQuality.choices(offering: player.offeredPictureHeights), id: \.self) { quality in
                Button {
                    close()
                    stored = quality.rawValue
                    AppLogger.filmPlayer.info("Picture quality → \(quality.rawValue, privacy: .public)")
                    Task { await player.setPictureHeight(quality.height) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.title)
                            if quality == .auto, selected == .auto {
                                Text("Now \(FilmPictureQuality.name(of: player.pictureHeight))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "checkmark").opacity(quality == selected ? 1 : 0)
                    }
                }
            }
        }
        .accessibilityIdentifier("player.pictureQuality")
    }
}
