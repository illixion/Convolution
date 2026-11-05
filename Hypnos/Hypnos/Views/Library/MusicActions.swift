/*
 Hypnos - Music section: what a listener can do to a song, album or playlist.

 `MusicUserState` holds favorites and star ratings the listener just changed, so a row answers at once and
 reverts if the server refuses. `MusicActions` is the Music section's coordinator: the playlist picker and the
 Get Info sheet hang off it, and so does the notice that says what happened.
 */

import SwiftUI

@MainActor @Observable
final class MusicUserState {
    static let shared = MusicUserState()
    private var favorites: [String: Bool] = [:]
    private var ratings: [String: Int] = [:]
    @ObservationIgnored private var configuration = LibraryService.configurationKey

    /// Another account or server has other items under the same ids' names; start clean.
    func resetIfConfigurationChanged() {
        let key = LibraryService.configurationKey
        guard key != configuration else { return }
        configuration = key
        favorites = [:]; ratings = [:]
    }

    func isFavorite(_ item: JellyfinMusicItem) -> Bool { favorites[item.id] ?? item.UserData?.IsFavorite ?? false }

    /// 0...5 stars (Jellyfin keeps ten points).
    func stars(_ item: JellyfinMusicItem) -> Int {
        ratings[item.id] ?? min(5, max(0, Int(((item.UserData?.Rating ?? 0) / 2).rounded())))
    }

    func toggleFavorite(_ item: JellyfinMusicItem, actions: MusicActions? = nil) async {
        let wanted = !isFavorite(item)
        favorites[item.id] = wanted
        do {
            guard let library = LibraryService.current() else { throw MusicServerError.signInRequired }
            try await library.setFavorite(itemId: item.id, favorite: wanted)
        } catch {
            favorites[item.id] = !wanted
            actions?.post(error.localizedDescription)
        }
    }

    func setStars(_ item: JellyfinMusicItem, stars: Int, actions: MusicActions? = nil) async {
        let previous = self.stars(item)
        ratings[item.id] = stars
        do {
            guard let library = LibraryService.current() else { throw MusicServerError.signInRequired }
            try await library.setMusicRating(id: item.id, stars: stars)
        } catch {
            ratings[item.id] = previous
            actions?.post(error.localizedDescription)
        }
    }
}

@MainActor @Observable
final class MusicActions {
    struct PlaylistRequest: Identifiable {
        let id = UUID()
        let title: String
        let items: [JellyfinMusicItem]
    }

    var playlistRequest: PlaylistRequest?
    var infoItem: JellyfinMusicItem?
    private(set) var isAdministrator = false
    /// Bumped when something the lists show was changed on the server (an edit, a playlist change).
    private(set) var revision = 0
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    func prepare() async {
        MusicUserState.shared.resetIfConfigurationChanged()
        isAdministrator = false
        guard let library = LibraryService.current() else { return }
        isAdministrator = (try? await library.isAdministrator()) ?? false
    }

    func post(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Something about the library changed. `namesChanged` is true when an item's title, artist or album did
    /// (Get Info), which is what the fuzzy search index holds; playlist edits leave it alone.
    func libraryChanged(namesChanged: Bool = false) {
        MusicCatalog.shared.invalidate { _ in true }
        if namesChanged { MusicSearchStore.shared.invalidate(rebuild: true) }
        revision += 1
    }

    /// The songs a song, album, artist, playlist or genre stands for.
    func songs(of item: JellyfinMusicItem) async -> [JellyfinMusicItem] {
        if item.isSong { return [item] }
        guard let request = Self.songRequest(for: item) else { return [] }
        return await MusicCatalog.shared.listing(for: request).allSongs()
    }

    static func songRequest(for item: JellyfinMusicItem) -> MusicRequest? {
        switch item.Type {
        case "MusicAlbum": MusicRequest(section: .songs, albumID: item.id)
        case "MusicArtist": MusicRequest(section: .songs, artistID: item.id)
        case "Playlist": MusicRequest(section: .songs, playlistID: item.id)
        case "MusicGenre": MusicRequest(section: .songs, genreID: item.id)
        default: nil
        }
    }

    func playNext(_ item: JellyfinMusicItem) async {
        let songs = await songs(of: item)
        guard !songs.isEmpty else { return post("Nothing to play.") }
        JellyfinMusicSession.shared.playNext(songs)
        post(songs.count == 1 ? "Playing next: \(songs[0].Name)" : "\(songs.count) songs play next")
    }

    func addToQueue(_ item: JellyfinMusicItem) async {
        let songs = await songs(of: item)
        guard !songs.isEmpty else { return post("Nothing to add.") }
        JellyfinMusicSession.shared.addToQueue(songs)
        post(songs.count == 1 ? "Added to Up Next: \(songs[0].Name)" : "\(songs.count) songs added to Up Next")
    }

    func addToPlaylist(_ item: JellyfinMusicItem) async {
        let songs = await songs(of: item)
        guard !songs.isEmpty else { return post("Nothing to add.") }
        playlistRequest = PlaylistRequest(title: item.Name, items: songs)
    }

    func showInfo(_ item: JellyfinMusicItem) { infoItem = item }
}

extension EnvironmentValues {
    /// The Music section's coordinator; nil outside it (Now Playing is a sheet of its own).
    @Entry var musicActions: MusicActions? = nil
    /// Opens an album or artist from a row's menu. Set by each Music screen for what it contains.
    @Entry var musicOpen: ((JellyfinMusicItem) -> Void)? = nil
}

/// What a song's file is, for a badge and a detail line.
struct MusicQuality {
    let isLossless: Bool
    let isHiRes: Bool
    let detail: String

    var badge: String { isHiRes ? "Hi-Res Lossless" : "Lossless" }
}

extension JellyfinMusicItem {
    var quality: MusicQuality? {
        guard let stream = audioStream, let codec = stream.Codec?.lowercased() else { return nil }
        let lossless = ["alac", "flac", "ape", "wavpack", "wv", "tta", "dsd_lsbf", "dsd_msbf"].contains(codec)
            || codec.hasPrefix("pcm")
        let hiRes = lossless && ((stream.BitDepth ?? 16) > 16 || (stream.SampleRate ?? 44_100) > 48_000)
        var parts = [codec.hasPrefix("pcm") ? "PCM" : codec.uppercased()]
        if lossless, let depth = stream.BitDepth, let rate = stream.SampleRate {
            parts.append("\(depth)-bit/\(String(format: "%g", Double(rate) / 1000)) kHz")
        } else if let bitrate = stream.BitRate {
            parts.append("\(bitrate / 1000) kbps")
        }
        return MusicQuality(isLossless: lossless, isHiRes: hiRes, detail: parts.joined(separator: " · "))
    }

    /// "3:45" / "1:02:10".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
