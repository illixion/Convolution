/*
 Hypnos - Library feature: server-agnostic media model

 Everything in this file describes what the Library UI renders and what a
 `MediaServerLibrary` (see `MediaServerLibrary.swift`) hands back. It knows
 nothing about Jellyfin's wire format — `JellyfinLibrary.swift` owns that
 translation — so a second server implementation only needs its own mapper
 into these same types, not a UI change.
 */

import Foundation

/// What kind of thing a `LibraryItem` is. Mirrors Jellyfin's `BaseItemKind`
/// loosely, but only the cases the Library feature actually renders — v1 is
/// scoped to movies and TV shows (decision #1 in the feature plan).
enum LibraryItemKind: String, Codable, Hashable, Sendable {
    case movie
    case series
    case season
    case episode
    case collection
    case unknown
}

/// Which artwork slot an image request is for. Jellyfin serves each as a
/// separate `/Items/{id}/Images/{type}` endpoint; other servers may have
/// fewer slots, in which case they fall back to whichever they have.
enum LibraryImageKind: String, Codable, Hashable, Sendable {
    case primary   // poster (movies/episodes) or portrait key art
    case backdrop  // full-bleed background art
    case logo      // transparent title treatment
    case thumb     // landscape thumbnail (episodes, Continue Watching rows)
}

/// A requested pixel size for an image URL, so the caller doesn't have to
/// know the server's own query-parameter names (`maxWidth`/`fillHeight`/…).
struct LibraryImageSize: Hashable, Sendable {
    var maxWidth: Int?
    var maxHeight: Int?
    /// 0...1; nil lets the server pick its own default.
    var quality: Int?

    static let thumbnail = LibraryImageSize(maxWidth: 400, maxHeight: nil, quality: 90)
    static let poster = LibraryImageSize(maxWidth: 600, maxHeight: nil, quality: 96)
    static let backdropFull = LibraryImageSize(maxWidth: 1920, maxHeight: nil, quality: 90)
}

/// A reference to one piece of artwork: enough to build an image URL lazily
/// (so the caller controls size/quality per use site) plus an optional
/// blurhash for an immediate placeholder while the real image loads.
struct LibraryImageRef: Hashable, Sendable {
    var kind: LibraryImageKind
    var blurhash: String?
    /// Opaque cache-busting tag from the server (Jellyfin's `ImageTags`);
    /// folded into the cache key so a replaced poster doesn't serve stale.
    var tag: String?
    /// The item the artwork actually belongs to, when inherited: an episode
    /// has no backdrop or logo of its own and shows its series'. Nil means
    /// the item itself.
    var ownerId: String? = nil
}

/// Per-user state for an item: resume position, played/unplayed, favorite.
/// Comes back from the server alongside the item itself (Jellyfin embeds it
/// as `UserData`) and is what the progress-sync path both reads and writes.
struct LibraryUserData: Hashable, Sendable {
    var isPlayed: Bool = false
    var isFavorite: Bool = false
    /// Resume position, if partially watched. Nil (not zero) means "no
    /// resume point" — distinct from "resume at the very start".
    var playbackPositionTicks: Int64?
    /// Jellyfin ticks are 100ns units; convenience in seconds for player code.
    var playbackPositionSeconds: Double? {
        playbackPositionTicks.map { Double($0) / 10_000_000 }
    }
    /// 0...100, Jellyfin's own resume-percentage convention.
    var playedPercentage: Double?

    /// Where Resume starts, or nil when there is nothing to resume. Jellyfin
    /// reports a position of 0 (not null) for an untouched item, and keeps
    /// the last position on an item it has since marked played, so the raw
    /// ticks alone would offer "Resume" on everything.
    var resumeSeconds: Double? {
        guard !isPlayed, let seconds = playbackPositionSeconds, seconds >= 1 else { return nil }
        return seconds
    }

    static let empty = LibraryUserData()
}

/// One movie, series, season, episode or collection, as the Library UI
/// renders it. Assembled by a `MediaServerLibrary` implementation from that
/// server's own item representation.
struct LibraryItem: Identifiable, Hashable, Sendable {
    var id: String
    var kind: LibraryItemKind
    var title: String
    var sortTitle: String?
    var overview: String?
    var year: Int?
    /// Whole-item runtime; for an episode, the episode's own runtime.
    var runtimeSeconds: Double?
    var genres: [String] = []
    var communityRating: Double?   // e.g. Jellyfin's average user rating, 0...10
    var officialRating: String?    // e.g. "PG-13"

    var images: [LibraryImageRef] = []
    var userData: LibraryUserData = .empty

    // Series/season/episode hierarchy. A season's `seriesId`/`seriesName`
    // point at its show; an episode carries both its season and series.
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    /// For a `.collection` (Jellyfin BoxSet), the member item ids.
    var childItemIds: [String] = []

    func image(_ kind: LibraryImageKind) -> LibraryImageRef? {
        images.first { $0.kind == kind }
    }

    /// Display label for a season/episode lockup, e.g. "S2 E4".
    var episodeLabel: String? {
        guard kind == .episode, let seasonNumber, let episodeNumber else { return nil }
        return "S\(seasonNumber) E\(episodeNumber)"
    }

    /// Whether this can be handed to a player directly (a series or season
    /// plays through one of its episodes instead).
    var isPlayable: Bool { kind == .movie || kind == .episode }

    /// Seconds left to watch from the resume point, when resumable.
    var remainingSeconds: Double? {
        guard let resume = userData.resumeSeconds, let runtimeSeconds, runtimeSeconds > resume else { return nil }
        return runtimeSeconds - resume
    }
}

/// A horizontally-scrolling row of items on the Library home screen —
/// Continue Watching, Next Up, Recently Added, a genre, a collection.
struct LibraryShelf: Identifiable, Hashable, Sendable {
    /// Stable across refreshes for `ForEach`/focus-restoration purposes;
    /// not shown to the user.
    var id: String
    var title: String
    var items: [LibraryItem]

    /// Continue Watching / Next Up rows show a progress bar and landscape
    /// thumbnails instead of poster lockups.
    var style: Style = .poster

    enum Style: Sendable {
        case poster
        case landscape
    }
}

/// What the Library home screen renders: the featured picks the hero cycles
/// through (movies/shows with backdrop art) plus the shelves below it.
struct LibraryHome: Sendable {
    var featured: [LibraryItem]
    var shelves: [LibraryShelf]
}
