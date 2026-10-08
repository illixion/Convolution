/*
 Hypnos - Library downloads: the Library, served from the device

 What `JellyfinLibrary` answers when the server can't be reached: the same
 calls (home, item, seasons, episodes, Next Up, the next episode), built
 from the downloads alone, so the Library tab, detail pages and autoplay
 work offline unchanged, just with less in them.

 Online, `merge` lays the device's unsynced watch state over the server's
 copy of a downloaded item, so a film watched on a plane resumes where it
 was left before the sync has reached the server.
 */

import Foundation
import Observation

/// Whether the server answered lately. `JellyfinLibrary` sets it from every
/// request; screens show "Offline" and the store syncs on the way back.
enum LibraryConnectivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastUnreachable: Date?

    /// The last request couldn't reach the server, within the last minute.
    static var seemsOffline: Bool {
        lock.withLock { lastUnreachable.map { Date().timeIntervalSince($0) < 60 } ?? false }
    }

    static func unreachable() {
        lock.withLock { lastUnreachable = Date() }
        Task { @MainActor in LibraryDownloads.shared.connectivityChanged(offline: true) }
    }

    static func reachable() {
        let wasOffline = lock.withLock { () -> Bool in
            defer { lastUnreachable = nil }
            return lastUnreachable != nil
        }
        if wasOffline {
            Task { @MainActor in LibraryDownloads.shared.connectivityChanged(offline: false) }
        }
    }
}

enum LibraryOfflineCatalog {
    private static var store: LibraryOfflineStore { .shared }

    /// The server's copy of `item` with the device's unsynced watch state on
    /// top. Also refreshes the download's own copy of the server's state.
    static func merge(_ item: LibraryItem) -> LibraryItem {
        guard let record = store.record(for: item.id) else { return item }
        if record.needsSync { return record.displayItem.withServerFields(from: item) }
        if record.item.userData != item.userData {
            store.update(itemId: item.id) { $0.item.userData = item.userData; $0.localPosition = nil; $0.localPlayed = nil }
        }
        return item
    }

    static func item(id: String) -> LibraryItem? {
        if let record = store.record(for: id) { return record.displayItem }
        for record in store.records {
            if let series = record.series, series.id == id { return series }
        }
        return seasons(seriesId: nil).first { $0.id == id }
    }

    /// Seasons a show has downloaded episodes in, made from those episodes.
    static func seasons(seriesId: String?) -> [LibraryItem] {
        let episodes = store.records.filter { $0.item.kind == .episode && (seriesId == nil || $0.item.seriesId == seriesId) }
        var seasons: [String: LibraryItem] = [:]
        for record in episodes {
            let episode = record.item
            let id = seasonId(of: episode)
            guard seasons[id] == nil else { continue }
            var season = LibraryItem(id: id, kind: .season,
                                     title: episode.seasonNumber.map { "Season \($0)" } ?? "Episodes")
            season.seriesId = episode.seriesId
            season.seriesName = episode.seriesName
            season.seasonNumber = episode.seasonNumber
            season.images = record.series?.images ?? []
            seasons[id] = season
        }
        return seasons.values.sorted { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }
    }

    static func episodes(seasonId: String) -> [LibraryItem] {
        store.records
            .filter { $0.item.kind == .episode && Self.seasonId(of: $0.item) == seasonId }
            .sorted { ($0.item.episodeNumber ?? 0) < ($1.item.episodeNumber ?? 0) }
            .map(\.displayItem)
    }

    /// The episode in progress, else the first unwatched one after the last
    /// watched, else the first downloaded.
    static func nextUp(seriesId: String) -> LibraryItem? {
        let episodes = store.episodes(seriesId: seriesId).map(\.displayItem)
        if let resuming = episodes.first(where: { $0.userData.resumeSeconds != nil }) { return resuming }
        let lastWatched = episodes.lastIndex { $0.userData.isPlayed }
        let after = lastWatched.map { episodes.index(after: $0) } ?? episodes.startIndex
        return episodes[after...].first { !$0.userData.isPlayed } ?? episodes.first
    }

    static func episode(after episode: LibraryItem) -> LibraryItem? {
        guard let seriesId = episode.seriesId else { return nil }
        let episodes = store.episodes(seriesId: seriesId).map(\.displayItem)
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    /// The Library home with nothing but downloads, or nil when there are none.
    static func home() -> LibraryHome? {
        let records = store.records
        guard !records.isEmpty else { return nil }
        let items = records.sorted { $0.downloadedAt > $1.downloadedAt }.map(\.displayItem)
        var shelves: [LibraryShelf] = []
        let resuming = items.filter { $0.userData.resumeSeconds != nil }
        if !resuming.isEmpty {
            shelves.append(LibraryShelf(id: "up-next", title: "Up Next", items: resuming, style: .landscape))
        }
        let movies = items.filter { $0.kind == .movie }
        if !movies.isEmpty {
            shelves.append(LibraryShelf(id: "downloaded-movies", title: "Downloaded Movies", items: movies))
        }
        var shows: [LibraryItem] = []
        for record in records.sorted(by: { $0.downloadedAt > $1.downloadedAt }) {
            if let series = record.series, !shows.contains(where: { $0.id == series.id }) { shows.append(series) }
        }
        if !shows.isEmpty {
            shelves.append(LibraryShelf(id: "downloaded-shows", title: "Downloaded Shows", items: shows))
        }
        let featured = Array((movies + shows).filter { $0.image(.backdrop) != nil }.prefix(6))
        return LibraryHome(featured: featured.isEmpty ? Array((movies + shows).prefix(1)) : featured, shelves: shelves)
    }

    /// The online home's "Downloads" row: movies and episodes on the device.
    static func downloadsShelf() -> LibraryShelf? {
        let items = store.records.sorted { $0.downloadedAt > $1.downloadedAt }.map(\.displayItem)
        guard !items.isEmpty else { return nil }
        return LibraryShelf(id: "downloads", title: "Downloads", items: items, style: .landscape)
    }

    private static func seasonId(of episode: LibraryItem) -> String {
        episode.seasonId ?? "\(episode.seriesId ?? "")-season-\(episode.seasonNumber ?? 0)"
    }
}

private extension LibraryItem {
    /// The device's watch state with the server's latest metadata.
    func withServerFields(from server: LibraryItem) -> LibraryItem {
        var merged = server
        merged.userData = userData
        merged.userData.isFavorite = server.userData.isFavorite
        return merged
    }
}
