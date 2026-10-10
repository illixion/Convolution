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

    /// What the picker shows as chosen: Auto where it isn't offered is the original.
    private var selected: FilmPictureQuality {
        let quality = FilmPictureQuality(rawValue: stored) ?? .auto
        return choices.contains(quality) ? quality : .original
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
