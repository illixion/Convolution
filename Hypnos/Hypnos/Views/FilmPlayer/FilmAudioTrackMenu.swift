import RAVEFilm
import RAVEUI
import SwiftUI

/// The film's object-audio tracks, in the transport beside Subtitles; shown
/// when there is more than one. The default the player opened with follows
/// the device's languages (the plugin's choice). Picking another swaps only
/// the sound, at the current position.
struct FilmAudioTrackMenu: View {
    let player: FilmPlayer
    var onOpenChanged: (Bool) -> Void = { _ in }

    var body: some View {
        PlayerChoiceMenu(title: "Audio", systemImage: "speaker.wave.2",
                         help: player.audioTracks.first { $0.index == player.audioStream }.map { "Audio: \($0.title)" },
                         onOpenChanged: onOpenChanged) { close in
            ForEach(player.audioTracks) { track in
                Button {
                    close()
                    Task { await player.selectAudioTrack(track.index) }
                } label: {
                    if track.index == player.audioStream {
                        Label(track.title, systemImage: "checkmark")
                    } else {
                        Text(track.title)
                    }
                }
            }
        }
        .accessibilityIdentifier("player.audio")
    }
}
