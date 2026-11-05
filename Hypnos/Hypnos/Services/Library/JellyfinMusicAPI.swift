/*
 Hypnos - Jellyfin music: the server operations behind the Music section's
 user features (ratings, playlists, lyrics) and the admin-only Edit sheet.

 Measured against Jellyfin 12.2 (see `jellyfin-music-api-findings` in the
 Hypnos memory): playlists, ratings and favorites belong to a *user*, so they
 fail with HTTP 400 on a bare API key; editing metadata, refreshing and
 uploading art need an administrator.
 */

import Foundation

struct MusicLyricCue: Sendable, Hashable {
    /// Seconds into the song.
    let start: Double
    let end: Double
    /// The characters of the line this cue covers.
    let range: Range<Int>
}

struct MusicLyricLine: Sendable, Hashable, Identifiable {
    let id: Int
    /// Nil on unsynchronised lyrics.
    let start: Double?
    let text: String
    let cues: [MusicLyricCue]
}

struct MusicLyrics: Sendable, Hashable {
    let lines: [MusicLyricLine]
    var isSynced: Bool { lines.contains { $0.start != nil } }
}

enum MusicServerError: LocalizedError {
    case signInRequired
    case notAdministrator

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in to Jellyfin with your account in Settings. An API key can't change playlists or ratings."
        case .notAdministrator:
            "Only a Jellyfin administrator can edit music details."
        }
    }
}

extension JellyfinLibrary {
    private func requireUser() throws {
        guard hasUserSession else { throw MusicServerError.signInRequired }
    }

    private func musicJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Items

    /// One item with the fields a header needs (the bio of an artist, the year of an album).
    func musicItem(id: String) async throws -> JellyfinMusicItem {
        let userID = try await resolveUserId()
        let data = try await http.data("Users/\(userID)/Items/\(id)")
        return try JSONDecoder().decode(JellyfinMusicItem.self, from: data)
    }

    /// These items, with what the lists show, in the order the server answers (callers keep their own order).
    func musicItems(ids: [String]) async throws -> [JellyfinMusicItem] {
        guard !ids.isEmpty else { return [] }
        let userID = try await resolveUserId()
        var found: [JellyfinMusicItem] = []
        // The ids ride in the URL, so a long list goes in pieces.
        for chunk in stride(from: 0, to: ids.count, by: 60).map({ Array(ids[$0..<min($0 + 60, ids.count)]) }) {
            let data = try await http.data("Users/\(userID)/Items", query: [
                .init(name: "Ids", value: chunk.joined(separator: ",")),
                .init(name: "Fields", value: "DateCreated,ChildCount,Genres,MediaStreams"),
            ])
            found += try JSONDecoder().decode(JellyfinMusicPage.self, from: data).Items
        }
        return found
    }

    /// One bounded page of the names the fuzzy search indexes, and how many there are of this kind in all.
    /// No artwork, user data or other fields: only what a word of the query can match.
    func musicSearchPage(kind: MusicSearchKind, start: Int, limit: Int) async throws -> (docs: [MusicSearchDoc], total: Int) {
        let userID = try await resolveUserId()
        var path = "Users/\(userID)/Items"
        var query: [URLQueryItem] = [
            .init(name: "UserId", value: userID), .init(name: "StartIndex", value: String(start)),
            .init(name: "Limit", value: String(limit)), .init(name: "EnableTotalRecordCount", value: "true"),
            .init(name: "Recursive", value: "true"), .init(name: "EnableImages", value: "false"),
            .init(name: "EnableUserData", value: "false"), .init(name: "SortBy", value: "SortName"),
            .init(name: "SortOrder", value: "Ascending"),
        ]
        if kind == .artist { path = "Artists/AlbumArtists" } else { query.append(.init(name: "IncludeItemTypes", value: kind.itemType)) }
        let page = try JSONDecoder().decode(JellyfinMusicPage.self, from: try await http.data(path, query: query))
        let docs = page.Items.map { item -> MusicSearchDoc in
            var artists: [String] = []
            for name in [item.AlbumArtist].compactMap({ $0 }) + (item.Artists ?? []) where !artists.contains(name) { artists.append(name) }
            return MusicSearchDoc(id: item.id, kind: kind, name: item.Name,
                                  artist: kind == .artist ? nil : artists.joined(separator: " "),
                                  album: kind == .song ? item.Album : nil)
        }
        return (docs, page.TotalRecordCount ?? start + docs.count)
    }

    // MARK: Ratings

    /// Stars are Hypnos's own view of Jellyfin's 0-10 `UserData.Rating` (two points a star). Jellyfin's web UI
    /// ignores it, which is why a rating never touches likes or favorites.
    func setMusicRating(id: String, stars: Int?) async throws {
        try requireUser()
        let userID = try await resolveUserId()
        let query = [URLQueryItem(name: "userId", value: userID)]
        if let stars, stars > 0 {
            _ = try await http.data("UserItems/\(id)/UserData", query: query, method: "POST",
                                    body: try musicJSON(["Rating": Double(min(5, stars) * 2)]))
        } else {
            _ = try await http.data("UserItems/\(id)/Rating", query: query, method: "DELETE")
        }
    }

    // MARK: Lyrics

    /// The song's lyrics, nil when it has none (Jellyfin answers 404).
    func musicLyrics(id: String) async throws -> MusicLyrics? {
        let data: Data
        do { data = try await http.data("Audio/\(id)/Lyrics") }
        catch JellyfinHTTP.Failure.http(404) { return nil }
        struct Cue: Decodable { let Start: Int64?; let End: Int64?; let Position: Int?; let EndPosition: Int? }
        struct Line: Decodable { let Text: String?; let Start: Int64?; let Cues: [Cue]? }
        struct Response: Decodable { let Lyrics: [Line]? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let tick = 10_000_000.0
        let lines = (response.Lyrics ?? []).enumerated().map { index, line in
            MusicLyricLine(
                id: index,
                start: line.Start.map { Double($0) / tick },
                text: line.Text ?? "",
                cues: (line.Cues ?? []).compactMap { cue in
                    guard let start = cue.Start, let end = cue.End, let from = cue.Position, let to = cue.EndPosition, to >= from
                    else { return nil }
                    return MusicLyricCue(start: Double(start) / tick, end: Double(end) / tick, range: from..<to)
                })
        }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty || $0.start != nil }
        return lines.isEmpty ? nil : MusicLyrics(lines: lines)
    }

    // MARK: Playlists

    /// The user's audio playlists, for the "Add to Playlist" picker.
    func musicPlaylists() async throws -> [JellyfinMusicItem] {
        let userID = try await resolveUserId()
        let data = try await http.data("Users/\(userID)/Items", query: [
            .init(name: "IncludeItemTypes", value: "Playlist"), .init(name: "MediaTypes", value: "Audio"),
            .init(name: "Recursive", value: "true"), .init(name: "SortBy", value: "SortName"),
            .init(name: "Fields", value: "ChildCount"),
        ])
        return try JSONDecoder().decode(JellyfinMusicPage.self, from: data).Items
    }

    @discardableResult
    func createMusicPlaylist(name: String, itemIDs: [String]) async throws -> String {
        try requireUser()
        let data = try await http.data("Playlists", method: "POST", body: try musicJSON([
            "Name": name, "Ids": itemIDs, "MediaType": "Audio", "IsPublic": false,
        ]))
        struct Created: Decodable { let Id: String }
        return try JSONDecoder().decode(Created.self, from: data).Id
    }

    func addToMusicPlaylist(id: String, itemIDs: [String]) async throws {
        try requireUser()
        let userID = try await resolveUserId()
        // Long lists would overrun a URL; Jellyfin takes the ids as a comma-separated query value.
        for chunk in stride(from: 0, to: itemIDs.count, by: 100).map({ Array(itemIDs[$0..<min($0 + 100, itemIDs.count)]) }) {
            _ = try await http.data("Playlists/\(id)/Items", query: [
                .init(name: "ids", value: chunk.joined(separator: ",")), .init(name: "userId", value: userID),
            ], method: "POST")
        }
    }

    func removeFromMusicPlaylist(id: String, entryIDs: [String]) async throws {
        try requireUser()
        _ = try await http.data("Playlists/\(id)/Items", query: [
            .init(name: "entryIds", value: entryIDs.joined(separator: ",")),
        ], method: "DELETE")
    }

    func moveMusicPlaylistItem(playlistID: String, entryID: String, to index: Int) async throws {
        try requireUser()
        _ = try await http.data("Playlists/\(playlistID)/Items/\(entryID)/Move/\(max(0, index))", method: "POST")
    }

    func renameMusicPlaylist(id: String, name: String) async throws {
        try requireUser()
        _ = try await http.data("Playlists/\(id)", method: "POST", body: try musicJSON(["Name": name]))
    }

    /// Deletes a playlist (never a song: Jellyfin's `DELETE Items/{id}` removes the file from disk).
    func deleteMusicPlaylist(id: String) async throws {
        try requireUser()
        _ = try await http.data("Items/\(id)", method: "DELETE")
    }

    // MARK: Administration

    func isAdministrator() async throws -> Bool {
        let userID = try await resolveUserId()
        struct User: Decodable {
            struct Policy: Decodable { let IsAdministrator: Bool? }
            let Policy: Policy?
        }
        let data = try await http.data("Users/\(userID)")
        return try JSONDecoder().decode(User.self, from: data).Policy?.IsAdministrator ?? false
    }

    /// The whole item as the server holds it. An edit sends all of it back, changing only the fields the
    /// sheet owns, so nothing the sheet doesn't know about is lost.
    func musicEditableItem(id: String) async throws -> Data {
        let userID = try await resolveUserId()
        return try await http.data("Items/\(id)", query: [.init(name: "userId", value: userID)])
    }

    func saveMusicItem(id: String, json: Data) async throws {
        _ = try await http.data("Items/\(id)", method: "POST", body: json)
    }

    /// Re-read the item's files. Fields locked by an earlier edit keep their edited value.
    func refreshMusicMetadata(id: String, replaceAll: Bool) async throws {
        _ = try await http.data("Items/\(id)/Refresh", query: [
            .init(name: "metadataRefreshMode", value: "FullRefresh"),
            .init(name: "imageRefreshMode", value: "None"),
            .init(name: "replaceAllMetadata", value: replaceAll ? "true" : "false"),
            .init(name: "replaceAllImages", value: "false"),
        ], method: "POST")
    }
}
