/*
 Hypnos - Library feature: Jellyfin implementation of `MediaServerLibrary`

 Owns every Jellyfin REST call the Library UI needs and the DTO→`LibraryItem`
 mapping (kept out of the shared model file on purpose — see
 `MediaServerLibrary.swift`'s header). Playback routing asks the Atmos
 Objects plugin (`JellyfinPlugin/`, `GET /AtmosObjects/{id}`) whether an item
 has object audio; movies/episodes without it fall back to Jellyfin's own
 streaming, direct-play when `NativeVideoDecodeProbe` says AVFoundation can
 decode the source natively, else the HLS transcode.
 */

import Foundation
import os

enum JellyfinLibraryError: Error, LocalizedError {
    case notConfigured
    case http(path: String, status: Int)
    case noSuchUser

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the Jellyfin server URL and sign in first."
        case .http(let path, let status): return "\(path): HTTP \(status)"
        case .noSuchUser: return "No Jellyfin user to report progress as."
        }
    }
}

// MARK: - DTOs (Jellyfin's own wire shape; never exposed outside this file)

private struct JFUserData: Decodable {
    let Played: Bool?
    let IsFavorite: Bool?
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
}

private struct JFImageTags: Decodable {
    let Primary: String?
    let Logo: String?
    let Thumb: String?
}

private struct JFItem: Decodable {
    let Id: String
    let Name: String?
    let SortName: String?
    let Overview: String?
    let ProductionYear: Int?
    let RunTimeTicks: Int64?
    let Genres: [String]?
    let CommunityRating: Double?
    let OfficialRating: String?
    let `Type`: String?
    let ImageTags: JFImageTags?
    let BackdropImageTags: [String]?
    let UserData: JFUserData?
    let SeriesId: String?
    let SeriesName: String?
    let SeasonId: String?
    let ParentIndexNumber: Int?  // season number, on an episode
    let IndexNumber: Int?        // episode/season number
    let ItemIds: [String]?       // BoxSet members, when queried with Fields=ItemIds

    var kind: LibraryItemKind {
        switch `Type` {
        case "Movie": return .movie
        case "Series": return .series
        case "Season": return .season
        case "Episode": return .episode
        case "BoxSet": return .collection
        default: return .unknown
        }
    }
}

private struct JFPage: Decodable {
    let Items: [JFItem]
}

private extension LibraryItem {
    init(_ dto: JFItem) {
        self.init(id: dto.Id, kind: dto.kind, title: dto.Name ?? "")
        sortTitle = dto.SortName
        overview = dto.Overview
        year = dto.ProductionYear
        runtimeSeconds = dto.RunTimeTicks.map { Double($0) / 10_000_000 }
        genres = dto.Genres ?? []
        communityRating = dto.CommunityRating
        officialRating = dto.OfficialRating
        seriesId = dto.SeriesId
        seriesName = dto.SeriesName
        seasonId = dto.kind == .episode ? dto.SeasonId : nil
        seasonNumber = dto.kind == .episode ? dto.ParentIndexNumber : (dto.kind == .season ? dto.IndexNumber : nil)
        episodeNumber = dto.kind == .episode ? dto.IndexNumber : nil
        childItemIds = dto.ItemIds ?? []

        var images: [LibraryImageRef] = []
        if let tag = dto.ImageTags?.Primary {
            images.append(LibraryImageRef(kind: .primary, blurhash: nil, tag: tag))
        }
        if let tag = dto.ImageTags?.Logo {
            images.append(LibraryImageRef(kind: .logo, blurhash: nil, tag: tag))
        }
        if let tag = dto.ImageTags?.Thumb {
            images.append(LibraryImageRef(kind: .thumb, blurhash: nil, tag: tag))
        }
        if let tag = dto.BackdropImageTags?.first {
            images.append(LibraryImageRef(kind: .backdrop, blurhash: nil, tag: tag))
        }
        self.images = images

        userData = LibraryUserData(
            isPlayed: dto.UserData?.Played ?? false,
            isFavorite: dto.UserData?.IsFavorite ?? false,
            playbackPositionTicks: dto.UserData?.PlaybackPositionTicks,
            playedPercentage: dto.UserData?.PlayedPercentage
        )
    }
}

/// Jellyfin's per-item Atmos Objects plugin state (`GET /AtmosObjects/{id}`).
/// See `JellyfinPlugin/README.md`.
private struct AtmosItemState: Decodable {
    let state: String  // none | partial | preparing | ready | unsupported | failed
}

/// Just enough of the Atmos Scene response to prove it decoded — used only
/// to force a real has-objects probe (see `hasAtmosObjects`), never read.
private struct AtmosSceneProbe: Decodable {
    let sampleRate: Int
}

/// `MediaServerLibrary` backed by a Jellyfin server. Holds no UI state of
/// its own — `server`/auth live in `FilmSession`/`JellyfinAuth`, which the
/// app constructs this from.
///
/// An actor: `home()`/`item(id:)`/progress reporting etc. all hit the
/// network and mutate `cachedUserId`/`playSessions`, so this needs the same
/// safe-mutable-state story every other network service in the app gets
/// from being an actor (`StashAPIClient`, `ImageLoader`). `imageURL` stays
/// synchronous (the protocol requires it — building a URL from data already
/// in hand shouldn't need an await), which is why `baseURL`/
/// `authHeaderToken`/`fixedUserId` are `nonisolated let`: immutable, so
/// they're safe to read from a nonisolated context with no hop.
actor JellyfinLibrary: MediaServerLibrary {
    nonisolated let baseURL: URL
    /// Either a signed-in user's access token, or a plain API key (in which
    /// case `resolveUserId` picks a user to report progress/state as).
    private nonisolated let authHeaderToken: String
    private var cachedUserId: String?
    private nonisolated let fixedUserId: String?

    /// - Parameters:
    ///   - baseURL: the Jellyfin server address.
    ///   - accessToken: a signed-in session's access token, or a plain API key.
    ///   - userId: the signed-in user's id, when known (username/password
    ///     sign-in already has one); nil for API-key mode, where the first
    ///     call resolves one via `/Users`.
    init(baseURL: URL, accessToken: String, userId: String?) {
        self.baseURL = baseURL
        self.authHeaderToken = accessToken
        self.fixedUserId = userId
        self.cachedUserId = userId
    }

    // MARK: - Home

    func home() async throws -> LibraryHome {
        let userId = try await resolveUserId()
        async let resume = fetchItems(path: "Users/\(userId)/Items/Resume", query: [
            .init(name: "MediaTypes", value: "Video"),
            .init(name: "Recursive", value: "true"),
            .init(name: "Limit", value: "12"),
        ])
        async let nextUp = fetchItems(path: "Shows/NextUp", query: [
            .init(name: "userId", value: userId),
            .init(name: "Limit", value: "12"),
        ])
        async let recentMovies = fetchLatestItems(userId: userId, query: [
            .init(name: "IncludeItemTypes", value: "Movie"),
            .init(name: "Limit", value: "16"),
        ])
        async let recentShows = fetchLatestItems(userId: userId, query: [
            .init(name: "IncludeItemTypes", value: "Series"),
            .init(name: "Limit", value: "16"),
        ])
        async let collections = fetchItems(path: "Users/\(userId)/Items", query: [
            .init(name: "IncludeItemTypes", value: "BoxSet"),
            .init(name: "Recursive", value: "true"),
            .init(name: "Limit", value: "16"),
        ])

        var shelves: [LibraryShelf] = []
        let resumeItems = try await resume
        if !resumeItems.isEmpty {
            shelves.append(LibraryShelf(id: "continue-watching", title: "Continue Watching", items: resumeItems, style: .landscape))
        }
        let nextUpItems = try await nextUp
        if !nextUpItems.isEmpty {
            shelves.append(LibraryShelf(id: "next-up", title: "Next Up", items: nextUpItems, style: .landscape))
        }
        let recentMovieItems = try await recentMovies
        if !recentMovieItems.isEmpty {
            shelves.append(LibraryShelf(id: "recent-movies", title: "Recently Added Movies", items: recentMovieItems))
        }
        let recentShowItems = try await recentShows
        if !recentShowItems.isEmpty {
            shelves.append(LibraryShelf(id: "recent-shows", title: "Recently Added Shows", items: recentShowItems))
        }
        let collectionItems = try await collections
        if !collectionItems.isEmpty {
            shelves.append(LibraryShelf(id: "collections", title: "Collections", items: collectionItems))
        }

        // A hero pick: the most recently added movie or show, so home always
        // has something to feature full-bleed even on a very small library.
        let hero = recentMovieItems.first ?? recentShowItems.first ?? nextUpItems.first

        return LibraryHome(hero: hero, shelves: shelves)
    }

    // MARK: - Detail

    func item(id: String) async throws -> LibraryItem {
        let userId = try await resolveUserId()
        let dto: JFItem = try await get("Users/\(userId)/Items/\(id)")
        return LibraryItem(dto)
    }

    func seasons(seriesId: String) async throws -> [LibraryItem] {
        let userId = try await resolveUserId()
        return try await fetchItems(path: "Shows/\(seriesId)/Seasons", query: [.init(name: "userId", value: userId)])
    }

    func episodes(seasonId: String) async throws -> [LibraryItem] {
        let season = try await item(id: seasonId)
        guard let seriesId = season.seriesId else { return [] }
        let userId = try await resolveUserId()
        return try await fetchItems(path: "Shows/\(seriesId)/Episodes", query: [
            .init(name: "userId", value: userId),
            .init(name: "seasonId", value: seasonId),
        ])
    }

    func similar(itemId: String) async throws -> [LibraryItem] {
        let userId = try await resolveUserId()
        return try await fetchItems(path: "Items/\(itemId)/Similar", query: [
            .init(name: "userId", value: userId),
            .init(name: "Limit", value: "12"),
        ])
    }

    func search(_ term: String) async throws -> [LibraryItem] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let userId = try await resolveUserId()
        return try await fetchItems(path: "Users/\(userId)/Items", query: [
            .init(name: "searchTerm", value: term),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Recursive", value: "true"),
            .init(name: "Limit", value: "25"),
        ])
    }

    // MARK: - Images

    nonisolated func imageURL(item: LibraryItem, kind: LibraryImageKind, size: LibraryImageSize) -> URL? {
        guard let ref = item.image(kind) else { return nil }
        let jellyfinType: String
        switch kind {
        case .primary: jellyfinType = "Primary"
        case .backdrop: jellyfinType = "Backdrop"
        case .logo: jellyfinType = "Logo"
        case .thumb: jellyfinType = "Thumb"
        }
        var url = baseURL.appending(path: "Items/\(item.id)/Images/\(jellyfinType)")
        var query: [URLQueryItem] = []
        if let maxWidth = size.maxWidth { query.append(.init(name: "maxWidth", value: String(maxWidth))) }
        if let maxHeight = size.maxHeight { query.append(.init(name: "fillHeight", value: String(maxHeight))) }
        if let quality = size.quality { query.append(.init(name: "quality", value: String(quality))) }
        if let tag = ref.tag { query.append(.init(name: "tag", value: tag)) }
        url.append(queryItems: query)
        return url
    }

    // MARK: - Playback routing

    /// Whether the Atmos Objects plugin can serve object audio for `itemId`.
    ///
    /// `GET /AtmosObjects/{id}`'s state stays `"none"` until something has
    /// actually asked the plugin to look — confirmed directly against the
    /// dev instance: an untouched item (Atmos or not) always reads back
    /// `"none"`, so trusting that passive state alone would route *every*
    /// unprobed item to the Atmos player, Atmos or not. `"none"` therefore
    /// forces one real probe (`GET .../Scene?startSeconds=0`, confirmed cheap
    /// — ~0.1s on the dev instance either way, since a real decode only
    /// starts once a video segment is actually requested): 422 means the
    /// track has no objects, 200 means it does, and either way the plugin
    /// remembers the result so this item never needs re-probing. A
    /// non-`"none"` state (`partial`/`preparing`/`ready`) is trusted as-is;
    /// `"unsupported"` and `"failed"` both fall back to the generic player —
    /// `"failed"` too, since handing playback to a path that already failed
    /// once is worse than a safe fallback.
    private func hasAtmosObjects(itemId: String) async -> Bool {
        guard let state = try? await get("AtmosObjects/\(itemId)", as: AtmosItemState.self) else {
            return false
        }
        switch state.state {
        case "none":
            do {
                _ = try await get("AtmosObjects/\(itemId)/Scene", query: [.init(name: "startSeconds", value: "0")]) as AtmosSceneProbe
                return true
            } catch {
                return false
            }
        case "unsupported", "failed":
            return false
        default:
            return true
        }
    }

    func playbackRoute(for item: LibraryItem) async throws -> PlaybackRoute {
        if await hasAtmosObjects(itemId: item.id) {
            return .atmosFilmPlayer
        }

        // Confirmed directly against the dev instance: `/Items/{id}/stream`
        // (as opposed to `/Videos/{id}/stream`) is a flat 404 — Jellyfin's
        // direct-play route lives under `Videos`, not `Items`.
        let directURL = baseURL.appending(path: "Videos/\(item.id)/stream")
            .appending(queryItems: [
                .init(name: "static", value: "true"),
                .init(name: "api_key", value: authHeaderToken),
            ])
        let resumeSeconds = item.userData.playbackPositionSeconds

        if await NativeVideoDecodeProbe.canPlayNatively(url: directURL, timeout: 5) {
            return .genericPlayer(GenericPlaybackPlan(method: .direct, streamURL: directURL, resumeSeconds: resumeSeconds))
        }

        var transcodeURL = baseURL.appending(path: "Videos/\(item.id)/master.m3u8")
        transcodeURL.append(queryItems: [
            .init(name: "api_key", value: authHeaderToken),
            .init(name: "VideoCodec", value: "h264"),
            .init(name: "AudioCodec", value: "aac"),
        ])
        return .genericPlayer(GenericPlaybackPlan(method: .transcode, streamURL: transcodeURL, resumeSeconds: resumeSeconds))
    }

    // MARK: - Progress reporting

    /// One play-session id per item currently being reported, so
    /// progress/stop calls after `reportPlaybackStarted` reference the same
    /// session Jellyfin opened.
    private var playSessions: [String: String] = [:]

    func reportPlaybackStarted(itemId: String, positionSeconds: Double) async {
        let sessionId = UUID().uuidString
        playSessions[itemId] = sessionId
        await post("Sessions/Playing", body: [
            "ItemId": itemId,
            "PlaySessionId": sessionId,
            "PositionTicks": Int64(positionSeconds * 10_000_000),
            "IsPaused": false,
            "CanSeek": true,
        ])
    }

    func reportPlaybackProgress(itemId: String, positionSeconds: Double, isPaused: Bool) async {
        await post("Sessions/Playing/Progress", body: [
            "ItemId": itemId,
            "PlaySessionId": playSessions[itemId] ?? UUID().uuidString,
            "PositionTicks": Int64(positionSeconds * 10_000_000),
            "IsPaused": isPaused,
            "CanSeek": true,
        ])
    }

    func reportPlaybackStopped(itemId: String, positionSeconds: Double) async {
        await post("Sessions/Playing/Stopped", body: [
            "ItemId": itemId,
            "PlaySessionId": playSessions[itemId] ?? UUID().uuidString,
            "PositionTicks": Int64(positionSeconds * 10_000_000),
        ])
        playSessions[itemId] = nil
    }

    func setPlayed(itemId: String, played: Bool) async throws {
        let userId = try await resolveUserId()
        try await sendState(path: "Users/\(userId)/PlayedItems/\(itemId)", set: played)
    }

    func setFavorite(itemId: String, favorite: Bool) async throws {
        let userId = try await resolveUserId()
        try await sendState(path: "Users/\(userId)/FavoriteItems/\(itemId)", set: favorite)
    }

    // MARK: - User resolution (API-key fallback)

    /// A signed-in session already knows its user id; API-key mode has to
    /// ask the server which users exist and pick one (the first — Jellyfin
    /// servers configured this way are typically single-user).
    private func resolveUserId() async throws -> String {
        if let fixedUserId { return fixedUserId }
        if let cachedUserId { return cachedUserId }
        struct JFUser: Decodable { let Id: String }
        let users: [JFUser] = try await get("Users")
        guard let first = users.first else { throw JellyfinLibraryError.noSuchUser }
        cachedUserId = first.Id
        return first.Id
    }

    // MARK: - Transport

    /// Every list endpoint (as opposed to the single-item
    /// `Users/{id}/Items/{id}`) omits `Overview` and `Genres` unless asked
    /// for — confirmed directly against the dev instance: a shelf/search
    /// item came back with `Genres: null` and no `Overview` key at all,
    /// which would otherwise leave every hero/shelf card's overview blank
    /// and its genre chips empty. Every `fetchItems`/`fetchLatestItems` call
    /// asks for both so home/search/similar don't need a follow-up
    /// `item(id:)` just to show a synopsis.
    private static let listFields = URLQueryItem(name: "Fields", value: "Overview,Genres")

    private func fetchItems(path: String, query: [URLQueryItem]) async throws -> [LibraryItem] {
        let page: JFPage = try await get(path, query: query + [Self.listFields])
        return page.Items.map(LibraryItem.init)
    }

    /// `Users/{id}/Items/Latest` is the one item-listing endpoint that
    /// doesn't share the `{"Items": [...]}` envelope every other one uses —
    /// confirmed directly against the dev instance, it's a bare JSON array.
    /// Decoding it as `JFPage` throws a "found an array, expected a
    /// dictionary" error, so it gets its own fetch.
    private func fetchLatestItems(userId: String, query: [URLQueryItem]) async throws -> [LibraryItem] {
        let items: [JFItem] = try await get("Users/\(userId)/Items/Latest", query: query + [Self.listFields])
        return items.map(LibraryItem.init)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.setValue(JellyfinClientIdentity.authorizationHeader(token: authHeaderToken), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw JellyfinLibraryError.http(path: path, status: status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await get(path, query: [])
    }

    private func post(_ path: String, body: [String: Any]) async {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue(JellyfinClientIdentity.authorizationHeader(token: authHeaderToken), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            AppLogger.library.error("Progress report to \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendState(path: String, set: Bool) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = set ? "POST" : "DELETE"
        request.setValue(JellyfinClientIdentity.authorizationHeader(token: authHeaderToken), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 204 else { throw JellyfinLibraryError.http(path: path, status: status) }
    }
}
