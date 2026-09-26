/*
 Hypnos - Library feature: server-agnostic protocol

 The Library UI (home/detail/season/episode screens, shared across all four
 platforms) is written entirely against this protocol, never against
 Jellyfin's REST shape directly. `JellyfinLibrary` is the only conformer
 today; a second media server plugs in by writing another one and nothing
 under Views/Library needs to change.
 */

import Foundation

/// How to reach and authenticate with a media server, independent of the
/// Library protocol itself — a `MediaServerLibrary` is handed one of these
/// (or holds its own) rather than baking in `FilmSession`'s UserDefaults
/// reads directly, so it stays testable without touching real storage.
protocol MediaServerConnection: Sendable {
    var baseURL: URL { get }
}

/// Where playback should route an item to. Decided by asking the server
/// (Jellyfin: the Atmos Objects plugin's per-item state) rather than by
/// file extension, since the same title can exist with or without an Atmos
/// mux depending on the source the owner ripped.
enum PlaybackRoute: Sendable {
    /// RAVEFilm's `FilmPlayer`, via the Atmos Objects plugin (video segments
    /// + object audio). Used when the plugin reports object audio for this
    /// item.
    case atmosFilmPlayer
    /// The app's generic video player. `direct` streams the source
    /// natively-playable codec as-is; `transcode` asks the server for an
    /// HLS transcode (Jellyfin's `master.m3u8`) because
    /// `NativeVideoDecodeProbe` can't decode it directly.
    case genericPlayer(GenericPlaybackPlan)
}

struct GenericPlaybackPlan: Sendable {
    enum Method: Sendable { case direct, transcode }
    var method: Method
    var streamURL: URL
    /// Seconds to resume from, if the item has a saved position.
    var resumeSeconds: Double?
}

/// start/progress/stop calls a player makes as it plays an item, so the
/// server's watch-progress state (and, in turn, Continue Watching / Next
/// Up) stays in sync. Both FilmPlayer and the generic player report through
/// the same seam (see the feature plan's "Progress sync").
protocol PlaybackProgressReporting: Sendable {
    func reportPlaybackStarted(itemId: String, positionSeconds: Double) async
    func reportPlaybackProgress(itemId: String, positionSeconds: Double, isPaused: Bool) async
    func reportPlaybackStopped(itemId: String, positionSeconds: Double) async
}

/// Everything the Library UI needs from a media server: browsing, detail,
/// artwork, search, playback routing, and progress/favorite/played state.
protocol MediaServerLibrary: PlaybackProgressReporting {
    /// Home screen: hero pick + shelves (Continue Watching, Next Up,
    /// Recently Added Movies/Shows, per-genre, collections).
    func home() async throws -> LibraryHome

    /// Full detail for one item (movie, series, season or episode).
    func item(id: String) async throws -> LibraryItem

    /// A series' seasons, in order.
    func seasons(seriesId: String) async throws -> [LibraryItem]

    /// A season's episodes, in order.
    func episodes(seasonId: String) async throws -> [LibraryItem]

    /// "More Like This" for a given item.
    func similar(itemId: String) async throws -> [LibraryItem]

    /// Free-text search across movies and series.
    func search(_ term: String) async throws -> [LibraryItem]

    /// A URL for one item's artwork at the requested kind/size. Nil if the
    /// item has no image of that kind.
    func imageURL(item: LibraryItem, kind: LibraryImageKind, size: LibraryImageSize) -> URL?

    /// Decides how `item` should be played (see `PlaybackRoute`).
    func playbackRoute(for item: LibraryItem) async throws -> PlaybackRoute

    func setPlayed(itemId: String, played: Bool) async throws
    func setFavorite(itemId: String, favorite: Bool) async throws
}
