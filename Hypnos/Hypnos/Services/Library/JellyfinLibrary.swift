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

import DebugTrace
import Foundation
import os

enum JellyfinLibraryError: Error, LocalizedError {
    case notConfigured
    case http(path: String, status: Int)
    case noSuchUser

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the Jellyfin server URL and sign in first."
        case .http(_, 401):
            return "Jellyfin didn't accept the saved sign-in. Sign out and back in under Settings → Jellyfin."
        case .http(let path, let status): return "\(path): HTTP \(status)"
        case .noSuchUser: return "No Jellyfin user to report progress as."
        }
    }
}

// MARK: - DTOs (Jellyfin's own wire shape; never exposed outside this file)

/// Jellyfin writes dates with seven fractional digits
/// ("2026-10-07T09:59:52.0404237Z"), more than `ISO8601DateFormatter`
/// accepts, so the fraction is dropped before parsing. Whole seconds are
/// plenty for ordering by when something was watched.
enum JellyfinDate {
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        var trimmed = string
        if let dot = trimmed.firstIndex(of: ".") {
            let zone = trimmed[dot...].firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" }
            trimmed = String(trimmed[..<dot]) + (zone.map { String(trimmed[$0...]) } ?? "Z")
        } else if !trimmed.hasSuffix("Z"), !trimmed.dropFirst(19).contains(where: { $0 == "+" || $0 == "-" }) {
            trimmed += "Z"
        }
        return formatter.date(from: trimmed)
    }
}

private struct JFUserData: Decodable {
    let Played: Bool?
    let IsFavorite: Bool?
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
    let LastPlayedDate: String?
}

private struct JFChapter: Decodable {
    let Name: String?
    let StartPositionTicks: Int64?
}

/// `GET /MediaSegments/{id}` (Jellyfin 10.10+).
private struct JFMediaSegments: Decodable {
    struct Segment: Decodable {
        let `Type`: String?
        let StartTicks: Int64?
        let EndTicks: Int64?
    }
    let Items: [Segment]?
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
    let Video3DFormat: String?   // HalfSideBySide etc.; returned without asking
    let VideoType: String?       // VideoFile, Iso, BluRay (a folder), Dvd; returned without asking
    let IsoType: String?         // BluRay or Dvd, for an Iso
    // Artwork an episode/season inherits from its series.
    let ParentBackdropItemId: String?
    let ParentBackdropImageTags: [String]?
    let ParentLogoItemId: String?
    let ParentLogoImageTag: String?
    let ParentThumbItemId: String?
    let ParentThumbImageTag: String?
    /// Only on the single-item endpoint (or with Fields=Chapters).
    let Chapters: [JFChapter]?

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
        stereoFormat = StereoscopicFormat(jellyfin: dto.Video3DFormat)
        isBlurayDisc = dto.VideoType == "BluRay" || (dto.VideoType == "Iso" && dto.IsoType == "BluRay")

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
        // Inherited art goes after the item's own, so `image(_:)` (first
        // match) prefers the item's.
        if let owner = dto.ParentBackdropItemId, let tag = dto.ParentBackdropImageTags?.first {
            images.append(LibraryImageRef(kind: .backdrop, blurhash: nil, tag: tag, ownerId: owner))
        }
        if let owner = dto.ParentLogoItemId, let tag = dto.ParentLogoImageTag {
            images.append(LibraryImageRef(kind: .logo, blurhash: nil, tag: tag, ownerId: owner))
        }
        if let owner = dto.ParentThumbItemId, let tag = dto.ParentThumbImageTag {
            images.append(LibraryImageRef(kind: .thumb, blurhash: nil, tag: tag, ownerId: owner))
        }
        self.images = images

        userData = LibraryUserData(
            isPlayed: dto.UserData?.Played ?? false,
            isFavorite: dto.UserData?.IsFavorite ?? false,
            playbackPositionTicks: dto.UserData?.PlaybackPositionTicks,
            playedPercentage: dto.UserData?.PlayedPercentage,
            lastPlayedDate: dto.UserData?.LastPlayedDate.flatMap(JellyfinDate.parse)
        )
    }
}

/// The parts of `GET /Items/{id}/PlaybackInfo` that shape a stream request.
private struct JFPlaybackInfo: Decodable {
    struct MediaSource: Decodable {
        struct Stream: Decodable {
            let `Type`: String?
            let Codec: String?
            let Index: Int?
            let Language: String?
            let Title: String?
            let IsDefault: Bool?
            let IsForced: Bool?
            let IsHearingImpaired: Bool?
            let IsTextSubtitleStream: Bool?
        }
        let Id: String?
        let MediaStreams: [Stream]?
        /// HalfSideBySide, FullSideBySide, HalfTopAndBottom, FullTopAndBottom
        /// or MVC, from the file name (`Movie.3D.HSBS.mkv`) or its metadata.
        let Video3DFormat: String?
    }
    let MediaSources: [MediaSource]?
    let PlaySessionId: String?
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
            .init(name: "Limit", value: "16"),
        ])
        async let nextUp = fetchItems(path: "Shows/NextUp", query: [
            .init(name: "userId", value: userId),
            .init(name: "Limit", value: "20"),
        ])
        // When each show was last watched, to order Up Next by it: NextUp's
        // own episodes are unwatched, so they carry no date of their own.
        async let watchedEpisodes = fetchItems(path: "Users/\(userId)/Items", query: [
            .init(name: "IncludeItemTypes", value: "Episode"),
            .init(name: "Recursive", value: "true"),
            .init(name: "Filters", value: "IsPlayed"),
            .init(name: "SortBy", value: "DatePlayed"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "Limit", value: "60"),
        ])
        async let latestEpisodes = fetchLatestItems(userId: userId, query: [
            .init(name: "IncludeItemTypes", value: "Episode"),
            .init(name: "GroupItems", value: "false"),
            .init(name: "Limit", value: "40"),
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
        let nextUpItems = try await nextUp
        let watched = (try? await watchedEpisodes) ?? []
        let upNext = Self.upNext(resume: resumeItems, nextUp: nextUpItems, watchedEpisodes: watched)
        if !upNext.isEmpty {
            shelves.append(LibraryShelf(id: "up-next", title: "Up Next", items: upNext, style: .landscape))
        }
        // New episodes of the shows this user watches, past where they are
        // in each (an unwatched episode before their place isn't news).
        let followed = Set((watched + resumeItems).compactMap(\.seriesId))
        var frontier: [String: (Int, Int)] = [:]
        for item in upNext {
            if let seriesId = item.seriesId, let season = item.seasonNumber, let number = item.episodeNumber {
                frontier[seriesId] = (season, number)
            }
        }
        let newEpisodes = ((try? await latestEpisodes) ?? []).filter { episode in
            guard let seriesId = episode.seriesId, followed.contains(seriesId), !episode.userData.isPlayed else { return false }
            guard let place = frontier[seriesId] else { return true }
            guard let season = episode.seasonNumber, let number = episode.episodeNumber else { return false }
            return (season, number) > place
        }
        if !newEpisodes.isEmpty {
            shelves.append(LibraryShelf(id: "new-episodes", title: "New Episodes", items: newEpisodes, style: .landscape))
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

        // Featured picks for the hero: recently added movies and shows,
        // alternating, keeping only those with backdrop art (the hero is
        // full-bleed, and a flat placeholder there looks broken). A library
        // with no backdrops at all still features its newest item.
        var interleaved: [LibraryItem] = []
        for index in 0..<max(recentMovieItems.count, recentShowItems.count) {
            if index < recentMovieItems.count { interleaved.append(recentMovieItems[index]) }
            if index < recentShowItems.count { interleaved.append(recentShowItems[index]) }
        }
        var featured = Array(interleaved.filter { $0.image(.backdrop) != nil }.prefix(6))
        if featured.isEmpty, let first = interleaved.first ?? nextUpItems.first {
            featured = [first]
        }

        return LibraryHome(featured: featured, shelves: shelves)
    }

    /// One "Up Next" row, as in the Apple TV app: films and episodes in
    /// progress plus each show's next episode, most recently watched first,
    /// one entry per show.
    ///
    /// Jellyfin's NextUp also returns an episode that is already in
    /// progress, so the two lists overlap by id. A show can also have both a
    /// half-watched episode and a different next one (the user moved on
    /// without finishing): whichever was watched later wins, the paused
    /// episode on a tie, since that is the one the user left.
    static func upNext(resume: [LibraryItem], nextUp: [LibraryItem], watchedEpisodes: [LibraryItem]) -> [LibraryItem] {
        var seriesLastWatched: [String: Date] = [:]
        for episode in watchedEpisodes + resume {
            guard let seriesId = episode.seriesId, let date = episode.userData.lastPlayedDate else { continue }
            seriesLastWatched[seriesId] = max(seriesLastWatched[seriesId] ?? .distantPast, date)
        }
        struct Candidate {
            let item: LibraryItem
            let date: Date?
            let isResume: Bool
            let order: Int
        }
        var candidates: [Candidate] = resume.enumerated().map { index, item in
            Candidate(item: item, date: item.userData.lastPlayedDate, isResume: true, order: index)
        }
        let resumeIds = Set(resume.map(\.id))
        for (index, item) in nextUp.enumerated() where !resumeIds.contains(item.id) {
            let date = item.seriesId.flatMap { seriesLastWatched[$0] } ?? item.userData.lastPlayedDate
            candidates.append(Candidate(item: item, date: date, isResume: false, order: resume.count + index))
        }
        candidates.sort { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.isResume != rhs.isResume { return lhs.isResume }
                return lhs.order < rhs.order
            }
        }
        var seenSeries = Set<String>()
        return candidates.compactMap { candidate in
            if let seriesId = candidate.item.seriesId {
                guard seenSeries.insert(seriesId).inserted else { return nil }
            }
            return candidate.item
        }
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

    func nextUp(seriesId: String) async throws -> LibraryItem? {
        let userId = try await resolveUserId()
        // Resume first: Shows/NextUp skips an episode that is only partly
        // watched once a later one has been started.
        let resumable = try await fetchItems(path: "Users/\(userId)/Items/Resume", query: [
            .init(name: "ParentId", value: seriesId),
            .init(name: "Recursive", value: "true"),
            .init(name: "Limit", value: "1"),
        ])
        if let episode = resumable.first { return episode }
        // Jellyfin's NextUp already falls back to the first episode for a
        // series nobody has started (disableFirstEpisode defaults to false).
        let next = try await fetchItems(path: "Shows/NextUp", query: [
            .init(name: "userId", value: userId),
            .init(name: "seriesId", value: seriesId),
            .init(name: "Limit", value: "1"),
        ])
        if let episode = next.first { return episode }
        // Every episode watched: start the series over.
        return try await fetchItems(path: "Shows/\(seriesId)/Episodes", query: [
            .init(name: "userId", value: userId),
            .init(name: "Limit", value: "1"),
        ]).first
    }

    func episode(after episode: LibraryItem) async throws -> LibraryItem? {
        guard episode.kind == .episode, let seriesId = episode.seriesId else { return nil }
        let userId = try await resolveUserId()
        // startItemId lists from this episode onward, across seasons.
        let run = try await fetchItems(path: "Shows/\(seriesId)/Episodes", query: [
            .init(name: "userId", value: userId),
            .init(name: "startItemId", value: episode.id),
            .init(name: "Limit", value: "2"),
        ])
        guard run.first?.id == episode.id, run.count > 1 else { return nil }
        return run[1]
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

    func browse(kind: LibraryItemKind?, startIndex: Int, limit: Int) async throws -> [LibraryItem] {
        let userId = try await resolveUserId()
        let includeItemTypes: String = switch kind {
        case .movie: "Movie"
        case .series: "Series"
        default: "Movie,Series"
        }
        return try await fetchItems(path: "Users/\(userId)/Items", query: [
            .init(name: "IncludeItemTypes", value: includeItemTypes),
            .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "StartIndex", value: String(startIndex)),
            .init(name: "Limit", value: String(limit)),
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
        var url = baseURL.appending(path: "Items/\(ref.ownerId ?? item.id)/Images/\(jellyfinType)")
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
        // A disc plays in the film player whether or not the plugin has object
        // audio for it: its picture is decoded on the device either way, and
        // without the plugin its sound is the disc's own 5.1 (`DiscAudioSource`).
        // Jellyfin's own route for a disc image is a slow 2D remux.
        if item.isBlurayDisc {
            return .atmosFilmPlayer
        }
        if await hasAtmosObjects(itemId: item.id) {
            return .atmosFilmPlayer
        }

        // Header-authenticated, so a token the server no longer accepts
        // fails here, under the Play button, rather than as a player window
        // that never shows a frame (every stream URL below authenticates by
        // query parameter and AVPlayer reports its 401 as nothing at all).
        let userId = try await resolveUserId()
        let info: JFPlaybackInfo = try await get("Items/\(item.id)/PlaybackInfo", query: [
            .init(name: "userId", value: userId),
        ])
        let source = info.MediaSources?.first
        let mediaSourceId = source?.Id ?? item.id
        // One id per play. Jellyfin names a transcode's output after the
        // media, device and play session, so without one every play of an
        // item on this device maps onto the same job, including a stale one
        // left behind by a player that vanished mid-stream (a headset
        // reboot). It also lets the stop report end this play's transcode.
        let playSessionId = info.PlaySessionId ?? UUID().uuidString
        Self.playSessions.withLock { $0[item.id] = playSessionId }

        // Confirmed directly against the dev instance: `/Items/{id}/stream`
        // (as opposed to `/Videos/{id}/stream`) is a flat 404 — Jellyfin's
        // direct-play route lives under `Videos`, not `Items`.
        let directURL = baseURL.appending(path: "Videos/\(item.id)/stream")
            .appending(queryItems: [
                .init(name: "static", value: "true"),
                .init(name: "MediaSourceId", value: mediaSourceId),
                .init(name: "api_key", value: authHeaderToken),
            ])
        let resumeSeconds = item.userData.resumeSeconds

        if await NativeVideoDecodeProbe.canPlayNatively(url: directURL, timeout: 5) {
            return .genericPlayer(GenericPlaybackPlan(method: .direct, streamURL: directURL, resumeSeconds: resumeSeconds))
        }

        let sourceVideoCodec = source?.MediaStreams?
            .first { $0.Type == "Video" }?.Codec?.lowercased()
        let transcodeURL = Self.hlsStreamURL(
            baseURL: baseURL, itemId: item.id, mediaSourceId: mediaSourceId,
            sourceVideoCodec: sourceVideoCodec, playSessionId: playSessionId,
            token: authHeaderToken)
        return .genericPlayer(GenericPlaybackPlan(method: .transcode, streamURL: transcodeURL, resumeSeconds: resumeSeconds))
    }

    // MARK: - Subtitles

    func subtitleTracks(itemId: String) async throws -> [LibrarySubtitleTrack] {
        let userId = try await resolveUserId()
        let info: JFPlaybackInfo = try await get("Items/\(itemId)/PlaybackInfo", query: [
            .init(name: "userId", value: userId),
        ])
        return Self.subtitleTracks(in: info.MediaSources?.first, itemId: itemId)
    }

    private static func subtitleTracks(in source: JFPlaybackInfo.MediaSource?, itemId: String) -> [LibrarySubtitleTrack] {
        let sourceId = source?.Id ?? itemId
        return (source?.MediaStreams ?? []).compactMap { stream in
            guard stream.Type == "Subtitle", let index = stream.Index else { return nil }
            return LibrarySubtitleTrack(
                id: index, sourceId: sourceId, language: stream.Language, name: stream.Title,
                isDefault: stream.IsDefault ?? false, isForced: stream.IsForced ?? false,
                isHearingImpaired: stream.IsHearingImpaired ?? false,
                isText: stream.IsTextSubtitleStream ?? false)
        }
    }

    /// `Subtitles/{index}/Stream.vtt` converts any text stream, external or
    /// embedded, to WebVTT. An embedded stream is extracted from the whole
    /// file on first request, so this can take a while on a large film.
    func subtitleData(itemId: String, track: LibrarySubtitleTrack) async throws -> Data {
        let path = "Videos/\(itemId)/\(track.sourceId)/Subtitles/\(track.id)/Stream.vtt"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue(JellyfinClientIdentity.authorizationHeader(token: authHeaderToken), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw JellyfinLibraryError.http(path: path, status: status) }
        return data
    }

    // MARK: - Media segments (Skip Intro / Skip Credits)

    /// The skippable stretches of `itemId`, in order. Media segments when
    /// the server has any (a provider plugin such as Intro Skipper fills
    /// them in; a bare server has none), else chapters named like an intro
    /// or the credits. Empty when neither says anything.
    func mediaSegments(itemId: String) async throws -> [LibraryMediaSegment] {
        let page: JFMediaSegments? = try? await get("MediaSegments/\(itemId)")
        let served = (page?.Items ?? []).compactMap { segment -> LibraryMediaSegment? in
            guard let kind = Self.segmentKind(segment.Type),
                  let start = segment.StartTicks, let end = segment.EndTicks, end > start
            else { return nil }
            return LibraryMediaSegment(kind: kind, startSeconds: Double(start) / 10_000_000,
                                       endSeconds: Double(end) / 10_000_000)
        }
        if !served.isEmpty { return served.sorted { $0.startSeconds < $1.startSeconds } }

        let userId = try await resolveUserId()
        let dto: JFItem = try await get("Users/\(userId)/Items/\(itemId)")
        return Self.chapterSegments(dto.Chapters ?? [], runtimeTicks: dto.RunTimeTicks)
    }

    private static func segmentKind(_ type: String?) -> LibraryMediaSegment.Kind? {
        switch type {
        case "Intro": .intro
        case "Recap": .recap
        case "Preview": .preview
        case "Outro": .outro
        case "Commercial": .commercial
        default: nil
        }
    }

    /// A chapter whose name says what it is runs to the next chapter (or
    /// the end). "Chapter 3" and the like say nothing and are skipped.
    private static func chapterSegments(_ chapters: [JFChapter], runtimeTicks: Int64?) -> [LibraryMediaSegment] {
        let ordered = chapters.compactMap { chapter -> (name: String, start: Int64)? in
            guard let name = chapter.Name, let start = chapter.StartPositionTicks else { return nil }
            return (name, start)
        }.sorted { $0.start < $1.start }
        var segments: [LibraryMediaSegment] = []
        for (index, chapter) in ordered.enumerated() {
            guard let kind = chapterKind(chapter.name) else { continue }
            let end = index + 1 < ordered.count ? ordered[index + 1].start : (runtimeTicks ?? 0)
            guard end > chapter.start else { continue }
            segments.append(LibraryMediaSegment(kind: kind, startSeconds: Double(chapter.start) / 10_000_000,
                                                endSeconds: Double(end) / 10_000_000))
        }
        return segments
    }

    static func chapterKind(_ name: String) -> LibraryMediaSegment.Kind? {
        let words = name.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
        let text = words.joined(separator: " ")
        func has(_ word: String) -> Bool { words.contains(word) }
        if has("recap") || text.hasPrefix("previously") { return .recap }
        if has("preview") || text.contains("next episode") || text.contains("next time") { return .preview }
        if has("intro") || has("introduction") || has("opening") || has("op")
            || text.contains("title sequence") || text.contains("main titles") { return .intro }
        if has("credits") || has("outro") || has("ending") || has("ed") || has("closing") { return .outro }
        return nil
    }

    /// Jellyfin's HLS stream for a source AVFoundation can't open directly
    /// (MKV, WebM). Each parameter is here for a measured reason, all against
    /// the dev instance (10.11) and AVPlayer:
    ///
    /// - `VideoBitrate`/`AudioBitrate`/`MaxStreamingBitrate`: without them
    ///   Jellyfin sizes a transcode for 640 kbps and scales the picture to
    ///   416 px wide, whatever the source.
    /// - `VideoCodec` names the source's own codec when Apple platforms decode
    ///   it (H.264, HEVC), so the video is stream-copied rather than
    ///   re-encoded; anything else (VP9, AV1) is encoded to H.264. Copying is
    ///   also what lets a 4K HEVC source start in about 2 s instead of
    ///   waiting on a software 4K encode the server may not keep up with.
    /// - `main.m3u8` rather than `master.m3u8`: for an HDR source whose video
    ///   is copied, the master playlist also offers an SDR H.264 variant, and
    ///   AVPlayer may pick that one. That is a full 4K re-encode (it ran the
    ///   dev container out of memory). The variant playlist is exactly the
    ///   copied stream.
    /// - `SegmentContainer=mp4`: HEVC in HLS has to be fragmented MP4, not TS.
    /// - `AudioCodec=aac`, up to 5.1: plays on every Apple platform. Jellyfin
    ///   re-encoded EAC3 even when offered it first.
    /// - `MediaSourceId` is required. Without it Jellyfin (10.11 confirmed)
    ///   answers 400 "The mediaSourceId field is required.", which AVPlayer
    ///   surfaces only as "resource unavailable".
    /// - `DeviceId` and `PlaySessionId` key the server's transcode job, which
    ///   `api_key` query auth otherwise leaves unset.
    static func hlsStreamURL(baseURL: URL, itemId: String, mediaSourceId: String,
                             sourceVideoCodec: String?, playSessionId: String,
                             token: String) -> URL {
        let videoCodec = switch sourceVideoCodec {
        case "hevc", "h265": "hevc"
        default: "h264"
        }
        let maxBitrate = 120_000_000
        let audioBitrate = 640_000
        return baseURL.appending(path: "Videos/\(itemId)/main.m3u8").appending(queryItems: [
            .init(name: "api_key", value: token),
            .init(name: "MediaSourceId", value: mediaSourceId),
            .init(name: "DeviceId", value: JellyfinClientIdentity.deviceId),
            .init(name: "PlaySessionId", value: playSessionId),
            .init(name: "VideoCodec", value: videoCodec),
            .init(name: "AudioCodec", value: "aac"),
            .init(name: "TranscodingMaxAudioChannels", value: "6"),
            .init(name: "MaxAudioChannels", value: "6"),
            .init(name: "SegmentContainer", value: "mp4"),
            .init(name: "MaxStreamingBitrate", value: String(maxBitrate)),
            .init(name: "VideoBitrate", value: String(maxBitrate - audioBitrate)),
            .init(name: "AudioBitrate", value: String(audioBitrate)),
        ])
    }

    /// Ends this play's transcode on the server. A stop report does the same
    /// thing, but only a play that got as far as a start report sends one; a
    /// stream that never produced a frame would otherwise keep its ffmpeg job
    /// running until Jellyfin's idle timer notices.
    func stopTranscoding(itemId: String) async {
        guard let playSessionId = Self.playSessions.withLock({ $0.removeValue(forKey: itemId) }) else { return }
        await stopEncoding(playSessionId: playSessionId)
    }

    private func stopEncoding(playSessionId: String) async {
        var request = URLRequest(url: baseURL.appending(path: "Videos/ActiveEncodings").appending(queryItems: [
            .init(name: "deviceId", value: JellyfinClientIdentity.deviceId),
            .init(name: "playSessionId", value: playSessionId),
        ]))
        request.httpMethod = "DELETE"
        request.setValue(JellyfinClientIdentity.authorizationHeader(token: authHeaderToken), forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The same HLS stream under a new play session, so Jellyfin starts a
    /// new remux at wherever the player next asks; nil for a stream with no
    /// session (direct play). The old session's job is ended.
    ///
    /// Needed after the player reloads a segment mid-stream (visionOS took
    /// its decoder away). A remux resumed mid-file cuts its segments at 6 s
    /// steps from the resume point, while the playlist steps from the start
    /// of the file, so later segments start up to a GOP away from where the
    /// playlist puts them (0-5 s on a real x265 episode, 2026-10-07). Played
    /// straight through, the media's own timestamps hide that; a reload
    /// places the segment at the playlist's time and the player's clock,
    /// subtitles with it, runs that far behind the sound and picture. A new
    /// job starts exactly at the first segment it is asked for.
    func renewedStreamURL(itemId: String, streamURL: URL) async -> URL? {
        guard var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.contains(where: { $0.name == "PlaySessionId" })
        else { return nil }
        let fresh = UUID().uuidString
        let old = Self.playSessions.withLock { sessions in
            let old = sessions[itemId]
            sessions[itemId] = fresh
            return old
        }
        components.queryItems = items.map { $0.name == "PlaySessionId" ? .init(name: "PlaySessionId", value: fresh) : $0 }
        if let old {
            // After the swap has had a moment, so the outgoing player isn't
            // left asking for deleted segments.
            Task {
                try? await Task.sleep(for: .seconds(5))
                await self.stopEncoding(playSessionId: old)
            }
        }
        return components.url
    }

    // MARK: - Progress reporting

    /// One play-session id per item currently playing, so the stream URL,
    /// the start/progress/stop reports and `stopTranscoding` all name the
    /// same session. Static because `LibraryService.current()` builds a
    /// fresh `JellyfinLibrary` per use: the one that routed playback is not
    /// the one that reports on it.
    private static let playSessions = OSAllocatedUnfairLock(initialState: [String: String]())

    private func playSessionId(for itemId: String) -> String {
        Self.playSessions.withLock { sessions in
            if let existing = sessions[itemId] { return existing }
            let fresh = UUID().uuidString
            sessions[itemId] = fresh
            return fresh
        }
    }

    func reportPlaybackStarted(itemId: String, positionSeconds: Double) async {
        let sessionId = playSessionId(for: itemId)
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
            "PlaySessionId": playSessionId(for: itemId),
            "PositionTicks": Int64(positionSeconds * 10_000_000),
            "IsPaused": isPaused,
            "CanSeek": true,
        ])
    }

    func reportPlaybackStopped(itemId: String, positionSeconds: Double) async {
        // Screens showing this item's progress reload once the server has
        // the new position, and a Play pressed meanwhile waits for it.
        await LibraryWatchState.shared.reportBegan(itemId: itemId)
        await post("Sessions/Playing/Stopped", body: [
            "ItemId": itemId,
            "PlaySessionId": playSessionId(for: itemId),
            "PositionTicks": Int64(positionSeconds * 10_000_000),
        ])
        Self.playSessions.withLock { _ = $0.removeValue(forKey: itemId) }
        await LibraryWatchState.shared.reportLanded(itemId: itemId)
    }

    func setPlayed(itemId: String, played: Bool) async throws {
        let userId = try await resolveUserId()
        try await sendState(path: "Users/\(userId)/PlayedItems/\(itemId)", set: played)
        await LibraryWatchState.shared.changed()
    }

    func setFavorite(itemId: String, favorite: Bool) async throws {
        let userId = try await resolveUserId()
        try await sendState(path: "Users/\(userId)/FavoriteItems/\(itemId)", set: favorite)
        await LibraryWatchState.shared.changed()
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
            AppLogger.library.error("Progress report to \(path, privacy: .public) failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
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
