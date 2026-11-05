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
    /// Lay the row out as a table row: artist, album, plays and time each in a column under `MusicSongColumnHeader`.
    var columns = false
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
                    if columns {
                        HStack(spacing: 8) {
                            Text(song.Name).foregroundStyle(isCurrent ? Color.accentColor : .primary).lineLimit(1)
                            qualityBadge
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(song.artist)
                        cell(song.Album ?? "")
                        Text(song.UserData?.PlayCount.flatMap { $0 > 0 ? String($0) : nil } ?? "")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: MusicColumns.plays, alignment: .trailing)
                        Text(song.RunTimeTicks != nil ? JellyfinMusicItem.clock(song.seconds) : "")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: MusicColumns.time, alignment: .trailing)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.Name).foregroundStyle(isCurrent ? Color.accentColor : .primary).lineLimit(1)
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !columns { qualityBadge }
            if userState.isFavorite(song) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink).accessibilityLabel("Favorite")
                    .frame(width: columns ? MusicColumns.heart : nil)
            } else if columns {
                Color.clear.frame(width: MusicColumns.heart, height: 1)
            }
            if !columns, song.RunTimeTicks != nil {
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
                Menu { MusicItemMenu(item: song) } label: { Image(systemName: "ellipsis").frame(width: MusicColumns.menu, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("More for \(song.Name)")
                #endif
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu { MusicItemMenu(item: song) }
    }

    @ViewBuilder
    private var qualityBadge: some View {
        if song.quality?.isLossless == true {
            Text(song.quality?.isHiRes == true ? "Hi-Res" : "Lossless")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Capsule().stroke(.secondary.opacity(0.5)))
                .accessibilityLabel(song.quality?.isHiRes == true ? "Hi-Res Lossless" : "Lossless")
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
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

/// Widths the songs table keeps in step between its header and its rows.
enum MusicColumns {
    static let artwork: CGFloat = 44
    static let plays: CGFloat = 56
    static let time: CGFloat = 56
    static let heart: CGFloat = 20
    static let menu: CGFloat = 28
}

/// The header of the songs table. A column that can sort shows the direction when it is the one in force.
struct MusicSongColumnHeader: View {
    let sort: MusicSort?
    let descending: Bool
    let onSort: ((MusicSort) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 14) {
                Color.clear.frame(width: MusicColumns.artwork, height: 1)
                column("Name", .title).frame(maxWidth: .infinity, alignment: .leading)
                column("Artist", .artist).frame(maxWidth: .infinity, alignment: .leading)
                column("Album", .album).frame(maxWidth: .infinity, alignment: .leading)
                column("Plays", .plays).frame(width: MusicColumns.plays, alignment: .trailing)
                column("Time", .time).frame(width: MusicColumns.time, alignment: .trailing)
            }
            Color.clear.frame(width: MusicColumns.heart, height: 1)
            Color.clear.frame(width: MusicColumns.menu, height: 1)
        }
        .font(.caption.weight(.semibold))
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func column(_ title: String, _ key: MusicSort) -> some View {
        let active = sort == key
        let label = HStack(spacing: 3) {
            Text(title)
            if active { Image(systemName: descending ? "chevron.down" : "chevron.up").font(.caption2) }
        }
        .foregroundStyle(active ? Color.primary : .secondary)
        if let onSort {
            Button { onSort(key) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(title)")
                .accessibilityValue(active ? (descending ? "Descending" : "Ascending") : "")
        } else {
            label
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
                Button("Start Station", systemImage: "dot.radiowaves.left.and.right") { Task { await actions.startStation(item) } }
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
