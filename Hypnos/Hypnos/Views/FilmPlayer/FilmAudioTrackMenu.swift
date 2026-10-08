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

/// Lossless or compressed object audio (`ObjectAudioQuality`): Auto follows
/// the connection, segment by segment, and the menu says where it is now.
/// A choice is remembered and applies at once, the sound reloading at the
/// current position like a track change.
struct ObjectAudioQualityMenu: View {
    let player: FilmPlayer
    var onOpenChanged: (Bool) -> Void = { _ in }
    @AppStorage(ObjectAudioQuality.defaultsKey) private var stored = ObjectAudioQuality.auto.rawValue

    private var selected: ObjectAudioQuality { ObjectAudioQuality(rawValue: stored) ?? .auto }

    var body: some View {
        PlayerChoiceMenu(title: "Audio Quality", systemImage: "waveform.badge.magnifyingglass",
                         help: "Object audio: \(player.audioQuality.isEmpty ? selected.title : player.audioQuality)",
                         onOpenChanged: onOpenChanged) { close in
            ForEach(ObjectAudioQuality.allCases, id: \.self) { quality in
                Button {
                    close()
                    stored = quality.rawValue
                    Task { await player.setAudioEncoding(quality.encoding, governor: quality.governor) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.title)
                            if let detail = detail(of: quality) {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "checkmark").opacity(quality == selected ? 1 : 0)
                    }
                }
            }
        }
        .accessibilityIdentifier("player.audioQuality")
    }

    /// Under Auto, where it is now ("Now AAC 64 kbps").
    private func detail(of quality: ObjectAudioQuality) -> String? {
        guard quality == .auto, selected == .auto, let now = player.audioQuality.split(separator: "·").last else { return quality.detail }
        return "\(quality.detail ?? "") · Now \(now.trimmingCharacters(in: .whitespaces))"
    }
}
