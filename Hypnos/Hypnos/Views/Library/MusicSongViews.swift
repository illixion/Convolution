/*
 Hypnos - Music section: song rows and the menu every song, album, artist and playlist shares.
 */

import SwiftUI

/// What the playlist screen hands a row while the listener is arranging it.
struct MusicPlaylistEditing {
    var remove: () -> Void
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
}

struct MusicSongRow: View {
    let song: JellyfinMusicItem
    /// Where the song sits in `list`; a song can be in a playlist twice.
    let position: Int
    let list: [JellyfinMusicItem]
    /// Show the track number where the artwork would be (inside an album).
    var showsTrackNumber = false
    var editing: MusicPlaylistEditing?
    @Environment(\.musicActions) private var actions
    private let music = JellyfinMusicSession.shared
    private let userState = MusicUserState.shared

    var body: some View {
        let isCurrent = music.current?.id == song.id
        HStack(spacing: 12) {
            if let editing {
                Button(role: .destructive, action: editing.remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    .buttonStyle(.plain).accessibilityLabel("Remove from Playlist")
            }
            Button {
                music.play(song, from: list, at: position)
            } label: {
                HStack(spacing: 14) {
                    leading(isCurrent: isCurrent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.Name).foregroundStyle(isCurrent ? Color.accentColor : .primary).lineLimit(1)
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if song.quality?.isLossless == true {
                Text(song.quality?.isHiRes == true ? "Hi-Res" : "Lossless")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().stroke(.secondary.opacity(0.5)))
                    .accessibilityLabel(song.quality?.isHiRes == true ? "Hi-Res Lossless" : "Lossless")
            }
            if userState.isFavorite(song) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink).accessibilityLabel("Favorite")
            }
            if song.RunTimeTicks != nil {
                Text(JellyfinMusicItem.clock(song.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let editing {
                VStack(spacing: 0) {
                    Button { editing.moveUp?() } label: { Image(systemName: "chevron.up") }
                        .disabled(editing.moveUp == nil).accessibilityLabel("Move Up")
                    Button { editing.moveDown?() } label: { Image(systemName: "chevron.down") }
                        .disabled(editing.moveDown == nil).accessibilityLabel("Move Down")
                }
                .buttonStyle(.plain).font(.caption)
            } else {
                #if !os(tvOS)
                Menu { MusicItemMenu(item: song) } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("More for \(song.Name)")
                #endif
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu { MusicItemMenu(item: song) }
    }

    private var subtitle: String {
        showsTrackNumber ? song.artist : [song.artist, song.Album].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func leading(isCurrent: Bool) -> some View {
        if showsTrackNumber {
            Group {
                if isCurrent { Image(systemName: music.isPlaying ? "waveform" : "pause.fill").foregroundStyle(Color.accentColor) }
                else { Text(song.IndexNumber.map(String.init) ?? "–").foregroundStyle(.secondary).monospacedDigit() }
            }
            .frame(width: 30)
        } else {
            MusicArtwork(item: song, music: music)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { if isCurrent { RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35)); Image(systemName: music.isPlaying ? "waveform" : "pause.fill").foregroundStyle(.white) } }
        }
    }
}

/// The actions of one song, album, artist, playlist or genre. Rows, tiles, headers and Now Playing all show it.
struct MusicItemMenu: View {
    let item: JellyfinMusicItem
    @Environment(\.musicActions) private var actions
    @Environment(\.musicOpen) private var open
    private let userState = MusicUserState.shared

    var body: some View {
        // A genre is a whole slice of the library; adding or favoriting it is never what a tap means.
        if item.Type == "MusicGenre" { EmptyView() } else { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if let actions {
            Section {
                Button("Play Next", systemImage: "text.insert") { Task { await actions.playNext(item) } }
                Button("Add to Up Next", systemImage: "text.append") { Task { await actions.addToQueue(item) } }
                if item.Type != "Playlist" {
                    Button("Add to Playlist…", systemImage: "text.badge.plus") { Task { await actions.addToPlaylist(item) } }
                }
            }
        }
        Section {
            let favorite = userState.isFavorite(item)
            Button(favorite ? "Remove from Favorites" : "Favorite", systemImage: favorite ? "heart.slash" : "heart") {
                Task { await userState.toggleFavorite(item, actions: actions) }
            }
            if item.isSong {
                MusicStarsMenu(item: item)
            }
        }
        if item.isSong, let open {
            Section {
                if let albumID = item.AlbumId, let album = JellyfinMusicItem.reference(id: albumID, name: item.Album ?? "Album", type: "MusicAlbum", artist: item.AlbumArtist) {
                    Button("Go to Album", systemImage: "square.stack") { open(album) }
                }
                if let artistID = item.albumArtistID ?? item.artistID,
                   let artist = JellyfinMusicItem.reference(id: artistID, name: item.AlbumArtists?.first?.Name ?? item.ArtistItems?.first?.Name ?? item.artist, type: "MusicArtist") {
                    Button("Go to Artist", systemImage: "music.mic") { open(artist) }
                }
            }
        }
        if let actions, actions.isAdministrator, item.Type != "Playlist" {
            Section { Button("Get Info…", systemImage: "info.circle") { actions.showInfo(item) } }
        }
    }
}

struct MusicStarsMenu: View {
    let item: JellyfinMusicItem
    @Environment(\.musicActions) private var actions
    private let userState = MusicUserState.shared

    var body: some View {
        let current = userState.stars(item)
        Menu("Rating", systemImage: current > 0 ? "star.fill" : "star") {
            ForEach((1...5).reversed(), id: \.self) { stars in
                Button {
                    Task { await userState.setStars(item, stars: current == stars ? 0 : stars, actions: actions) }
                } label: {
                    let text = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
                    if current == stars { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
            if current > 0 {
                Button("Clear Rating", systemImage: "xmark") { Task { await userState.setStars(item, stars: 0, actions: actions) } }
            }
        }
    }
}
