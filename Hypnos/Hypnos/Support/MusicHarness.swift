/*
 Hypnos - Music section: throwaway verification harness (macOS, DEBUG only)

 Like `LibraryHarness`: launch the macOS build with `-MusicHarness` and the dev Jellyfin's address and a user in
 the environment, and it drives the Music section's server calls (every browsing section, ratings, favorites,
 playlists, lyrics, the administrator's edit and the play-state restore) through the real `JellyfinLibrary`,
 prints one `HARNESS:` line per check, and exits.

 Never point this at anything but the disposable dev Jellyfin (`scripts/dev-jellyfin.sh up`,
 http://127.0.0.1:8097). It signs in itself, because an unsigned macOS build can't use the keychain.
 Environment: HYPNOS_HARNESS_JELLYFIN_URL, HYPNOS_HARNESS_JELLYFIN_USER, HYPNOS_HARNESS_JELLYFIN_PASS;
 HYPNOS_HARNESS_EXPECT_LYRICS=1 when a .lrc sits beside the first song.
 */

#if DEBUG && os(macOS)

import Foundation

enum MusicHarness {
    private static let launchFlag = "-MusicHarness"
    nonisolated(unsafe) private static var failures = 0

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchFlag) else { return }
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["HYPNOS_HARNESS_JELLYFIN_URL"], let server = URL(string: urlString),
              let user = env["HYPNOS_HARNESS_JELLYFIN_USER"], let pass = env["HYPNOS_HARNESS_JELLYFIN_PASS"]
        else {
            print("HARNESS: FAIL missing HYPNOS_HARNESS_JELLYFIN_URL / _USER / _PASS")
            exit(1)
        }
        Task {
            await run(server: server, user: user, pass: pass, expectLyrics: env["HYPNOS_HARNESS_EXPECT_LYRICS"] == "1")
            print("HARNESS: \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let extra = detail()
        print("HARNESS: \(ok ? "PASS" : "FAIL") \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        fflush(stdout)
    }

    private static func signIn(server: URL, user: String, pass: String) async throws -> (token: String, userID: String) {
        var request = URLRequest(url: server.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MediaBrowser Client=\"Hypnos Harness\", Device=\"Mac\", DeviceId=\"hypnos-music-harness\", Version=\"1\"", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": user, "Pw": pass])
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Reply: Decodable { struct User: Decodable { let Id: String }; let AccessToken: String; let User: User }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return (reply.AccessToken, reply.User.Id)
    }

    private static func songs(_ library: JellyfinLibrary, _ request: MusicRequest, limit: Int = 60) async throws -> [JellyfinMusicItem] {
        try await library.musicPage(request, start: 0, limit: limit).Items
    }

    private static func run(server: URL, user: String, pass: String, expectLyrics: Bool) async {
        let auth: (token: String, userID: String)
        do { auth = try await signIn(server: server, user: user, pass: pass) } catch {
            check("sign in", false, "\(error)"); return
        }
        let library = JellyfinLibrary(baseURL: server, accessToken: auth.token, userId: auth.userID)
        let keyOnly = JellyfinLibrary(baseURL: server, accessToken: auth.token, userId: nil)
        check("user session is recognised, a key-only one is not", library.hasUserSession && !keyOnly.hasUserSession)

        do {
            // Every browsing section decodes, and carries what the screens now show.
            var all: [JellyfinMusicItem] = []
            for section in MusicSection.allCases {
                let items = try await songs(library, MusicRequest(section: section))
                check("section \(section.rawValue) loads", true, "\(items.count) items")
                if section == .songs { all = items }
            }
            guard let song = all.first, let albumID = song.AlbumId else { check("library has songs", false); return }
            check("songs sort by title, not track number", all.map(\.Name) == all.map(\.Name).sorted { $0.localizedStandardCompare($1) == .orderedAscending } || all.count < 2, all.prefix(3).map(\.Name).joined(separator: " | "))
            check("a song carries genre, year, disc and an audio stream", song.Genres?.isEmpty == false && song.ProductionYear != nil && song.ParentIndexNumber != nil && song.audioStream != nil,
                  "\(song.Genres ?? []) \(song.ProductionYear ?? 0) disc \(song.ParentIndexNumber ?? 0) \(song.quality?.detail ?? "no stream")")
            check("ALAC reads as lossless", song.quality?.isLossless == true, song.quality?.badge ?? "")
            let albumSongs = try await songs(library, MusicRequest(section: .songs, albumID: albumID))
            check("album songs come in track order", albumSongs.map { $0.IndexNumber ?? 0 } == albumSongs.map { $0.IndexNumber ?? 0 }.sorted() && !albumSongs.isEmpty, "\(albumSongs.count) songs")
            let artists = try await songs(library, MusicRequest(section: .artists))
            check("artists list", !artists.isEmpty, artists.first?.Name ?? "")
            if let artist = artists.first {
                let found = try await songs(library, MusicRequest(section: .albums, search: String(artist.Name.prefix(4))))
                check("search finds the artist as well as albums", found.contains { $0.Type == "MusicArtist" } && found.contains { $0.Type == "MusicAlbum" }, found.map { $0.Type ?? "?" }.joined(separator: ","))
                let artistSongs = try await songs(library, MusicRequest(section: .songs, artistID: artist.id))
                check("an artist's songs are songs", !artistSongs.isEmpty && artistSongs.allSatisfy(\.isSong), "\(artistSongs.count)")
                let bio = try await library.musicItem(id: artist.id)
                check("artist detail decodes", bio.Id == artist.id, "overview \(bio.Overview == nil ? "none" : "present")")
            }
            let genres = try await songs(library, MusicRequest(section: .genres))
            if let genre = genres.first {
                let genreAlbums = try await songs(library, MusicRequest(section: .albums, genreID: genre.id))
                check("genre \(genre.Name) lists its albums", !genreAlbums.isEmpty && genreAlbums.allSatisfy { $0.Type == "MusicAlbum" })
                let genreSongs = try await songs(library, MusicRequest(section: .songs, genreID: genre.id))
                check("genre songs are songs", !genreSongs.isEmpty && genreSongs.allSatisfy(\.isSong))
            } else { check("genres list", false, "none") }
            for sort in MusicSort.allCases {
                let items = try await songs(library, MusicRequest(section: .songs, sort: sort))
                check("songs sort by \(sort.rawValue) is accepted", !items.isEmpty)
            }
            for sort in MusicSection.albums.sorts {
                let items = try await songs(library, MusicRequest(section: .albums, sort: sort))
                check("albums sort by \(sort.rawValue) is accepted", !items.isEmpty)
            }
            let random = try await songs(library, MusicRequest(section: .songs, playbackSongs: true, randomOrder: true))
            check("random playback page is songs", !random.isEmpty && random.allSatisfy(\.isSong))

            // Loudness, from the dev server's LUFS scan.
            let gains = all.compactMap(\.NormalizationGain)
            check("songs carry NormalizationGain after the LUFS scan", !gains.isEmpty, "\(gains.count)/\(all.count) \(gains.first.map { String(format: "%.1f dB", $0) } ?? "")")
            if let gain = gains.first {
                let factor = JellyfinMusicSession.soundCheckFactor(gainDB: gain)
                check("Sound Check turns that song down", gain < 0 ? factor < 1 : factor == 1, String(format: "factor %.2f", factor))
            }

            // Ratings and favorites.
            try await library.setMusicRating(id: song.id, stars: 4)
            var reread = try await songs(library, MusicRequest(section: .songs, albumID: albumID)).first { $0.id == song.id }
            check("4 stars is stored as Rating 8", reread?.UserData?.Rating == 8, "\(reread?.UserData?.Rating ?? -1)")
            try await library.setMusicRating(id: song.id, stars: nil)
            reread = try await songs(library, MusicRequest(section: .songs, albumID: albumID)).first { $0.id == song.id }
            check("clearing the rating removes it", (reread?.UserData?.Rating ?? 0) == 0, "\(reread?.UserData?.Rating ?? 0)")
            try await library.setFavorite(itemId: song.id, favorite: true)
            var favorites = try await songs(library, MusicRequest(section: .favorites))
            check("a favorite appears in Favorite Songs", favorites.contains { $0.id == song.id })
            try await library.setFavorite(itemId: song.id, favorite: false)
            favorites = try await songs(library, MusicRequest(section: .favorites))
            check("and leaves it when removed", !favorites.contains { $0.id == song.id })
            do {
                try await keyOnly.setMusicRating(id: song.id, stars: 3)
                check("a key-only session is refused a rating up front", false)
            } catch MusicServerError.signInRequired { check("a key-only session is refused a rating up front", true) }

            // Playlists, end to end.
            let three = Array(all.prefix(3)).map(\.id)
            let playlistID = try await library.createMusicPlaylist(name: "Harness Playlist", itemIDs: three)
            let listed = try await library.musicPlaylists()
            check("created playlist is listed", listed.contains { $0.id == playlistID })
            var entries = try await songs(library, MusicRequest(section: .songs, playlistID: playlistID))
            check("playlist keeps the order it was made in and has entry ids", entries.map(\.id) == three && entries.allSatisfy { $0.PlaylistItemId != nil })
            if let last = entries.last?.PlaylistItemId {
                try await library.moveMusicPlaylistItem(playlistID: playlistID, entryID: last, to: 0)
                entries = try await songs(library, MusicRequest(section: .songs, playlistID: playlistID))
                check("moving an entry reorders the playlist", entries.first?.id == three.last, entries.map(\.Name).joined(separator: ", "))
            }
            try await library.addToMusicPlaylist(id: playlistID, itemIDs: Array(all.dropFirst(3).prefix(2)).map(\.id))
            entries = try await songs(library, MusicRequest(section: .songs, playlistID: playlistID))
            check("adding songs extends it", entries.count == min(5, 3 + max(0, all.count - 3)), "\(entries.count)")
            if let first = entries.first?.PlaylistItemId {
                try await library.removeFromMusicPlaylist(id: playlistID, entryIDs: [first])
                let after = try await songs(library, MusicRequest(section: .songs, playlistID: playlistID))
                check("removing an entry shortens it", after.count == entries.count - 1)
            }
            try await library.renameMusicPlaylist(id: playlistID, name: "Harness Renamed")
            let renamed = try await library.musicPlaylists()
            check("renaming a playlist", renamed.contains { $0.id == playlistID && $0.Name == "Harness Renamed" })
            let inSection = try await songs(library, MusicRequest(section: .playlists))
            check("Playlists section lists it", inSection.contains { $0.id == playlistID })
            try await library.deleteMusicPlaylist(id: playlistID)
            let gone = try await library.musicPlaylists()
            let remaining = try await songs(library, MusicRequest(section: .songs))
            check("deleting a playlist keeps the songs", !gone.contains { $0.id == playlistID } && remaining.count == all.count)

            // Lyrics.
            let withLyrics = all.first { $0.HasLyrics == true }
            let lyrics = try await library.musicLyrics(id: (withLyrics ?? song).id)
            if expectLyrics {
                check("synced lyrics load with word cues", lyrics?.isSynced == true && lyrics?.lines.contains { !$0.cues.isEmpty } == true, "\(lyrics?.lines.count ?? 0) lines")
            } else {
                check("a song without lyrics answers nil", lyrics == nil)
            }

            // Administrator edit.
            let isAdmin = try await library.isAdministrator()
            check("dev user is an administrator", isAdmin)
            let original = try await library.musicEditableItem(id: song.id)
            guard var edited = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { check("editable item parses", false); return }
            edited["Name"] = "Harness Edited"; edited["ProductionYear"] = 1999; edited["LockData"] = true
            edited["ArtistItems"] = [["Name": "Harness Artist", "Id": "00000000-0000-0000-0000-000000000000"]]
            try await library.saveMusicItem(id: song.id, json: JSONSerialization.data(withJSONObject: edited))
            try await library.refreshMusicMetadata(id: song.id, replaceAll: true)
            try await Task.sleep(for: .seconds(6))
            var item = try await library.musicItem(id: song.id)
            check("an edit survives a replace-refresh while locked", item.Name == "Harness Edited" && item.ProductionYear == 1999 && item.Artists == ["Harness Artist"], "\(item.Name) \(item.ProductionYear ?? 0) \(item.Artists ?? [])")
            // Revert, as the sheet does.
            edited["LockData"] = false; edited["LockedFields"] = []; edited["Overview"] = ""; edited["ForcedSortName"] = ""; edited["Tags"] = [String]()
            try await library.saveMusicItem(id: song.id, json: JSONSerialization.data(withJSONObject: edited))
            try await library.refreshMusicMetadata(id: song.id, replaceAll: true)
            try await Task.sleep(for: .seconds(6))
            item = try await library.musicItem(id: song.id)
            check("re-reading from the file restores the original", item.Name == song.Name && item.ProductionYear == song.ProductionYear && item.Artists == song.Artists, "\(item.Name) \(item.ProductionYear ?? 0) \(item.Artists ?? [])")

            // Play state: a skip must not count, a listen must.
            func playCount() async throws -> Int {
                try await songs(library, MusicRequest(section: .songs, albumID: albumID)).first { $0.id == song.id }?.UserData?.PlayCount ?? -1
            }
            let before = try await playCount()
            await JellyfinMusicSession.reportListenForHarness(base: server, token: auth.token, userID: auth.userID, itemID: song.id, positionTicks: Int64(song.seconds * 0.2 * 10_000_000), counted: false)
            let afterSkip = try await playCount()
            check("a 20% skip leaves the play count alone", afterSkip == before, "\(before) -> \(afterSkip)")
            await JellyfinMusicSession.reportListenForHarness(base: server, token: auth.token, userID: auth.userID, itemID: song.id, positionTicks: Int64(song.seconds * 0.9 * 10_000_000), counted: true)
            let afterListen = try await playCount()
            check("a real listen counts", afterListen == before + 1, "\(before) -> \(afterListen)")
            // Put the dev account back as found.
            var body = URLRequest(url: server.appending(path: "UserItems/\(song.id)/UserData").appending(queryItems: [URLQueryItem(name: "userId", value: auth.userID)]))
            body.httpMethod = "POST"
            body.setValue("application/json", forHTTPHeaderField: "Content-Type")
            body.setValue("MediaBrowser Token=\"\(auth.token)\"", forHTTPHeaderField: "Authorization")
            body.httpBody = try JSONSerialization.data(withJSONObject: ["PlayCount": before, "Played": before > 0])
            _ = try await URLSession.shared.data(for: body)
        } catch {
            check("harness ran to the end", false, "\(error)")
        }
    }
}

extension JellyfinMusicSession {
    /// A song starts and stops the way the session reports it (state read before the start, restored after a
    /// short listen), so the play-count handling can be checked against a server.
    static func reportListenForHarness(base: URL, token: String, userID: String, itemID: String, positionTicks: Int64, counted: Bool) async {
        let play = UUID().uuidString
        let before = await readPlayState(base: base, token: token, userID: userID, itemID: itemID)
        nonisolated(unsafe) let started: [String: Any] = ["ItemId": itemID, "PlaySessionId": play, "PositionTicks": 0, "CanSeek": true, "IsPaused": false]
        await deliverReport(path: "Sessions/Playing", payload: started, base: base, token: token, userID: userID, itemID: itemID, restoring: nil)
        nonisolated(unsafe) let stopped: [String: Any] = ["ItemId": itemID, "PlaySessionId": play, "PositionTicks": positionTicks]
        await deliverReport(path: "Sessions/Playing/Stopped", payload: stopped, base: base, token: token, userID: userID, itemID: itemID, restoring: counted ? nil : before)
    }
}

#endif
