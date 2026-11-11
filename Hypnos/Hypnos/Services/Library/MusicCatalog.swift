import Foundation
import Observation

enum MusicSection: String, CaseIterable, Identifiable, Sendable {
    case recent, albums, artists, songs, genres, playlists, favorites, recentlyPlayed, mostPlayed
    var id: Self { self }
    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        case .genres: "Genres"
        case .playlists: "Playlists"
        case .favorites: "Favorite Songs"
        case .recentlyPlayed: "Recently Played"
        case .mostPlayed: "Most Played"
        }
    }
    var symbol: String {
        switch self {
        case .recent: "clock"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.note"
        case .genres: "guitars"
        case .playlists: "music.note.list"
        case .favorites: "heart"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .mostPlayed: "chart.bar"
        }
    }
    /// The browsing sections, then the lists made from what the listener does.
    static let library: [MusicSection] = [.recent, .albums, .artists, .songs, .genres]
    static let collections: [MusicSection] = [.playlists, .favorites, .recentlyPlayed, .mostPlayed]
    /// Sections whose rows are songs rather than artwork tiles.
    var listsSongs: Bool { [.songs, .favorites, .recentlyPlayed, .mostPlayed].contains(self) }
    /// The orders the listener can pick. Every list can be sorted; Random is in each, to flick through a library.
    var sorts: [MusicSort] {
        switch self {
        case .recent: [.dateAdded, .title, .artist, .year, .random]
        case .albums: [.title, .artist, .year, .dateAdded, .random]
        case .artists, .playlists: [.title, .dateAdded, .random]
        case .genres: [.title, .random]
        case .songs: [.title, .artist, .album, .year, .time, .plays, .lastPlayed, .dateAdded, .random]
        case .favorites: [.title, .artist, .album, .year, .time, .plays, .lastPlayed, .dateAdded, .random]
        case .recentlyPlayed: [.lastPlayed, .plays, .title, .artist, .album, .year, .time, .dateAdded, .random]
        case .mostPlayed: [.plays, .lastPlayed, .title, .artist, .album, .year, .time, .dateAdded, .random]
        }
    }
    /// The order a section is in until the listener picks another (what its section headers follow).
    var defaultSort: MusicSort {
        switch self {
        case .recent: .dateAdded
        case .albums, .artists, .songs, .genres, .playlists, .favorites: .title
        case .recentlyPlayed: .lastPlayed
        case .mostPlayed: .plays
        }
    }
}

enum MusicSort: String, CaseIterable, Identifiable, Sendable {
    /// The list's own order: an album's tracks by disc and number, a playlist as it was arranged.
    case listOrder
    case title, artist, album, year, time, plays, lastPlayed, dateAdded
    /// A fresh shuffle each time it is picked or dealt again.
    case random
    var id: Self { self }
    var title: String {
        switch self {
        case .listOrder: "Original Order"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .time: "Time"
        case .plays: "Plays"
        case .lastPlayed: "Last Played"
        case .dateAdded: "Date Added"
        case .random: "Random"
        }
    }
    var symbol: String {
        switch self {
        case .listOrder: "list.number"
        case .title: "textformat"
        case .artist: "music.mic"
        case .album: "square.stack"
        case .year: "calendar"
        case .time: "clock"
        case .plays: "chart.bar"
        case .lastPlayed: "clock.arrow.circlepath"
        case .dateAdded: "plus.circle"
        case .random: "dice"
        }
    }
    /// What the menu calls this order where it is shown: an album's own order is its track numbers.
    func label(in request: MusicRequest) -> String {
        guard self == .listOrder else { return title }
        return request.playlistID != nil ? "Playlist Order" : request.albumID != nil ? "Track Number" : title
    }
    /// Jellyfin's `SortBy` for this order, ending in a name so paging never sees ties in a different order twice.
    /// A song's `SortName` starts with its track number, so songs break ties by `Name`.
    func server(songs: Bool) -> (keys: String, descending: Bool) {
        let tail = songs ? "Name" : "SortName"
        switch self {
        case .listOrder: return ("ParentIndexNumber,IndexNumber,\(tail)", false)
        case .title: return (tail, false)
        case .artist: return (songs ? "Artist,Album,ParentIndexNumber,IndexNumber" : "AlbumArtist,ProductionYear,SortName", false)
        case .album: return ("Album,ParentIndexNumber,IndexNumber,\(tail)", false)
        case .year: return ("ProductionYear,\(tail)", true)
        case .time: return ("Runtime,\(tail)", false)
        case .plays: return ("PlayCount,DatePlayed,\(tail)", true)
        case .lastPlayed: return ("DatePlayed", true)
        case .dateAdded: return ("DateCreated", true)
        case .random: return ("Random", false)
        }
    }
    /// The direction a first pick of this order goes (newest, most played and latest year first).
    var startsDescending: Bool { server(songs: false).descending }
    /// Whether flipping the direction means anything.
    var hasDirection: Bool { self != .random }
}

struct MusicRequest: Hashable, Sendable {
    var section: MusicSection = .recent
    var albumID: String?
    var artistID: String?
    var playlistID: String?
    var genreID: String?
    var sort: MusicSort?
    /// Nil is the direction the order starts in; set once the listener flips it.
    var descending: Bool?
    var search = ""
    var playbackSongs = false
    var randomOrder = false
    /// Dealing Random again changes this: a new request is a new listing, so a new shuffle (an old one stays
    /// cached while the listener is on it, so the grid doesn't reshuffle under their finger).
    var shuffleSeed = 0

    /// The orders this screen offers: a section's own, or the ones that mean something inside an album, a
    /// playlist, an artist or a genre.
    var sorts: [MusicSort] {
        if playbackSongs { return [] }
        if albumID != nil { return [.listOrder, .title, .artist, .time, .plays, .random] }
        if playlistID != nil { return [.listOrder, .title, .artist, .album, .year, .time, .plays, .dateAdded, .random] }
        if artistID != nil { return section == .songs ? [] : [.year, .title, .dateAdded, .random] }
        if genreID != nil { return section == .songs ? [] : [.title, .artist, .year, .dateAdded, .random] }
        return section.sorts
    }
    /// The order a screen is in until the listener picks another.
    var defaultSort: MusicSort? {
        if playbackSongs { return nil }
        if albumID != nil || playlistID != nil { return .listOrder }
        if artistID != nil { return section == .songs ? nil : .year }
        if genreID != nil { return section == .songs ? nil : .title }
        return section.defaultSort
    }
    /// The order in force, the screen's own when none was picked (or the one picked isn't offered here).
    var effectiveSort: MusicSort? {
        if let sort, sorts.contains(sort) { return sort }
        return defaultSort
    }
    var isDescending: Bool { effectiveSort?.hasDirection == false ? false : (descending ?? effectiveSort?.startsDescending ?? false) }
    /// Whether the screen is one of a section's lists, as opposed to the inside of an album, artist, playlist or genre.
    var isTopLevel: Bool { albumID == nil && artistID == nil && playlistID == nil && genreID == nil && !playbackSongs }
    /// What a saved order is filed under: a section's own, or the kind of item the screen is inside.
    var sortKey: String {
        if albumID != nil { return "album" }
        if playlistID != nil { return "playlist" }
        if artistID != nil { return "artist" }
        if genreID != nil { return "genre" }
        return section.rawValue
    }
}

extension MusicRequest {
    /// A playlist's songs are sorted here: the server hands a playlist back in its own order and nothing else.
    var sortsLocally: Bool {
        guard playlistID != nil, search.isEmpty, !playbackSongs, let sort = effectiveSort else { return false }
        return sort != .listOrder || isDescending
    }

    /// `items` in the order in force, stably (equal items keep their place). Random deals them afresh.
    func sorted(_ items: [JellyfinMusicItem]) -> [JellyfinMusicItem] {
        guard let sort = effectiveSort else { return items }
        let descending = isDescending
        switch sort {
        case .random: return items.shuffled()
        case .listOrder: return descending ? items.reversed() : items
        default: break
        }
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
        func text(_ a: String?, _ b: String?) -> ComparisonResult { (a ?? "").localizedStandardCompare(b ?? "") }
        func chain(_ results: ComparisonResult...) -> ComparisonResult { results.first { $0 != .orderedSame } ?? .orderedSame }
        func track(_ a: JellyfinMusicItem, _ b: JellyfinMusicItem) -> ComparisonResult {
            chain(compare(a.ParentIndexNumber ?? 1, b.ParentIndexNumber ?? 1), compare(a.IndexNumber ?? 0, b.IndexNumber ?? 0))
        }
        func order(_ a: JellyfinMusicItem, _ b: JellyfinMusicItem) -> ComparisonResult {
            switch sort {
            case .title: text(a.Name, b.Name)
            case .artist: chain(text(a.songArtist, b.songArtist), text(a.Album, b.Album), track(a, b))
            case .album: chain(text(a.Album, b.Album), track(a, b))
            case .year: compare(a.ProductionYear ?? 0, b.ProductionYear ?? 0)
            case .time: compare(a.RunTimeTicks ?? 0, b.RunTimeTicks ?? 0)
            case .plays: compare(a.UserData?.PlayCount ?? 0, b.UserData?.PlayCount ?? 0)
            case .dateAdded: compare(a.DateCreated ?? "", b.DateCreated ?? "")
            case .lastPlayed: compare(a.UserData?.LastPlayedDate ?? "", b.UserData?.LastPlayedDate ?? "")
            case .listOrder, .random: .orderedSame
            }
        }
        return items.enumerated().sorted { left, right in
            let result = order(left.element, right.element)
            if result == .orderedSame { return left.offset < right.offset }
            return descending ? result == .orderedDescending : result == .orderedAscending
        }.map(\.element)
    }
}

struct MusicAlbumGroup: Identifiable {
    let id: String
    let title: String
    let items: [JellyfinMusicItem]
    init(title: String, items: [JellyfinMusicItem], id: String? = nil) {
        self.title = title; self.items = items; self.id = id ?? title
    }
}

/// One run of songs under a header. `position` is where each song sits in the whole loaded list.
struct MusicSongGroup: Identifiable {
    let id: String
    let title: String?
    let rows: [(position: Int, song: JellyfinMusicItem)]
}

/// What a list's section headers say. They follow the order the list is in, as iTunes's do: sorted by title
/// there is a letter above each run, by year the year, by date added Today, Yesterday and the months.
enum MusicGrouping: Sendable {
    case none, letter, artist, album, year, dateAdded

    static func of(_ request: MusicRequest) -> MusicGrouping {
        guard request.search.isEmpty, request.isTopLevel else { return .none }
        switch request.effectiveSort {
        case .title: return .letter
        case .artist: return .artist
        case .album: return .album
        case .year: return .year
        case .dateAdded: return .dateAdded
        case .time, .plays, .lastPlayed, .listOrder, .random, nil: return .none
        }
    }

    /// The header an item sits under; nil when this grouping has none for it.
    func title(for item: JellyfinMusicItem, now: Date = Date()) -> String? {
        switch self {
        case .none: return nil
        case .letter: return Self.letter(of: item.Name)
        case .artist: return item.isSong || item.Type == "MusicAlbum" ? item.artist : Self.letter(of: item.Name)
        case .album: return item.isSong ? (item.Album ?? "Unknown Album") : Self.letter(of: item.Name)
        case .year: return item.ProductionYear.map(String.init) ?? "Unknown Year"
        case .dateAdded: return Self.dateBucket(item.DateCreated, now: now)
        }
    }

    /// The letter an A-Z index files a name under, skipping the articles Jellyfin leaves out of its sort
    /// names ("The Beatles" is under B); digits and symbols share "#".
    static func letter(of name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        for article in ["the ", "a ", "an "] where lower.hasPrefix(article) && lower.count > article.count {
            text = String(text.dropFirst(article.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let first = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first,
              first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    static func dateBucket(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let raw, let date = MusicDates.parse(raw) else { return "Earlier" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days >= 0, days < 7 { return "This Week" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "This Month" }
        let style = Date.FormatStyle(calendar: calendar).month(.wide).year()
        return date.formatted(style)
    }

    /// Cut `items` into runs of one header each, in the order they arrived: the server's order is the truth,
    /// so a header is never moved up to meet an earlier run of the same name.
    func runs<T>(_ items: [T], item: (T) -> JellyfinMusicItem) -> [(title: String?, range: Range<Int>)] {
        guard self != .none, !items.isEmpty else { return [(nil, 0..<items.count)] }
        let now = Date()
        var result: [(title: String?, range: Range<Int>)] = []
        var start = 0
        var current = title(for: item(items[0]), now: now)
        for index in 1..<max(1, items.count) where index < items.count {
            let next = title(for: item(items[index]), now: now)
            if next != current {
                result.append((current, start..<index))
                start = index; current = next
            }
        }
        result.append((current, start..<items.count))
        return result
    }
}

enum MusicDates {
    // ISO8601DateFormatter is documented thread-safe for formatting and parsing.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    /// Jellyfin writes dates with seven fractional digits, which `ISO8601DateFormatter` reads only as `.withFractionalSeconds`.
    static func parse(_ raw: String) -> Date? { fractional.date(from: raw) ?? plain.date(from: raw) }
}

/// Browsing owns no playback clock. Loading a page cannot invalidate the transport,
/// and clock updates cannot rebuild the artwork grid.
@MainActor @Observable
final class MusicListing {
    private(set) var items: [JellyfinMusicItem] = []
    private(set) var albums: [JellyfinMusicItem] = []
    private(set) var songs: [JellyfinMusicItem] = []
    private(set) var groups: [MusicAlbumGroup] = []
    /// The songs under their section headers; empty when the screen has none (an album lists its own discs).
    private(set) var songGroups: [MusicSongGroup] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?
    /// Bumped each time a page is published, so a screen can animate what arrived.
    private(set) var revision = 0
    @ObservationIgnored private var configuration: String?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var library: JellyfinLibrary?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    let request: MusicRequest

    init(request: MusicRequest) { self.request = request }

    func loadIfNeeded() async {
        let key = LibraryService.configurationKey
        if configuration != key {
            loadTask?.cancel()
            loadTask = nil
            generation = UUID()
            configuration = key
            library = LibraryService.current()
            items = []; albums = []; songs = []; groups = []; songGroups = []
            offset = 0; loaded = false; hasMore = true; isLoading = false; error = nil
        }
        guard !loaded else { return }
        await loadMore()
    }

    func loadMore() async {
        // A screen disappearing must not cancel a shared cached page and strand
        // another screen waiting for that same page. Configuration changes cancel it.
        if let loadTask { await loadTask.value; return }
        let ticket = generation
        let task = Task {
            await self.fetchNextPage()
            // Clear inside the task, before any coalesced waiter resumes and
            // requests the next page (e.g. Play while the album is opening).
            if ticket == self.generation { self.loadTask = nil }
        }
        loadTask = task
        await task.value
    }

    private func fetchNextPage() async {
        guard !isLoading, hasMore else { return }
        guard let library else { error = "Configure Jellyfin in Settings first."; return }
        let ticket = generation
        isLoading = true
        error = nil
        defer { if ticket == generation { isLoading = false } }
        do {
            // A random order is dealt a page at a time, so a page can repeat what is already here: ask again
            // (a few times) rather than leave a Load More that adds nothing.
            let random = request.effectiveSort == .random && request.search.isEmpty
            // The server can't sort a playlist (its own order is the point), so one that is sorted loads whole.
            let sortsLocally = request.sortsLocally
            // Gathered off to the side, so a sort that needs every page never shows the pages half sorted.
            var pool = items
            var known = Set(pool.map(\.id))
            var nextOffset = offset
            var more = true
            var attempts = 0
            while true {
                let page: JellyfinMusicPage
                if !request.search.isEmpty, let hits = await MusicSearchStore.shared.hits(for: request.search) {
                    // The fuzzy index ranks by name, artist and album and forgives typos; the server then
                    // gives those items as the screens show them.
                    let found = try await library.musicItems(ids: hits.map(\.id))
                    let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let ordered = hits.compactMap { byID[$0.id] }
                    page = JellyfinMusicPage(Items: ordered, TotalRecordCount: ordered.count)
                } else {
                    page = try await library.musicPage(request, start: nextOffset)
                }
                try Task.checkCancellation()
                guard ticket == generation, configuration == LibraryService.configurationKey else { return }
                let fresh = page.Items.filter { known.insert($0.id).inserted }
                pool.append(contentsOf: fresh)
                nextOffset += page.Items.count
                let total = page.TotalRecordCount ?? (page.Items.count == 60 ? nextOffset + 1 : nextOffset)
                more = !page.Items.isEmpty && (random ? pool.count < total : nextOffset < total)
                attempts += 1
                if sortsLocally, more { continue }
                if random, fresh.isEmpty, more, attempts < 4 { continue }
                break
            }
            if sortsLocally { pool = request.sorted(pool) }
            items = pool
            offset = nextOffset
            hasMore = more
            loaded = true
            revision += 1
            // Partition once per page, rather than conditionally expanding ForEach rows.
            songs = items.filter(\.isSong)
            albums = items.filter { !$0.isSong }
            let grouping = MusicGrouping.of(request)
            if !request.search.isEmpty {
                let artists = albums.filter { $0.Type == "MusicArtist" }
                let rest = albums.filter { $0.Type != "MusicArtist" }
                groups = [MusicAlbumGroup(title: "Artists", items: artists), MusicAlbumGroup(title: "Albums", items: rest)]
                    .filter { !$0.items.isEmpty }
            } else if grouping != .none {
                groups = grouping.runs(albums, item: { $0 }).enumerated().map { index, run in
                    MusicAlbumGroup(title: run.title ?? "", items: Array(albums[run.range]), id: "\(index)-\(run.title ?? "")")
                }
                let rows = songs.enumerated().map { (position: $0.offset, song: $0.element) }
                songGroups = grouping.runs(rows, item: { $0.song }).enumerated().map { index, run in
                    MusicSongGroup(id: "\(index)-\(run.title ?? "")", title: run.title, rows: Array(rows[run.range]))
                }
            } else { groups = [MusicAlbumGroup(title: request.section.title, items: albums)] }
        } catch is CancellationError {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch {
            if ticket == generation { self.error = error.localizedDescription }
        }
    }

    /// Forget what was loaded and load again (after the playlist behind it changed).
    func refresh() async {
        loadTask?.cancel()
        loadTask = nil
        configuration = nil
        await loadIfNeeded()
    }

    /// Full album/playlist queues are fetched only after an explicit Play action,
    /// in bounded requests, on JellyfinLibrary's actor.
    /// Every song of this screen, paged in bounded requests. Empty after a failure.
    func allSongs() async -> [JellyfinMusicItem] {
        await loadIfNeeded()
        while hasMore && error == nil && !Task.isCancelled {
            let previousOffset = offset
            await loadMore()
            guard offset > previousOffset else { break }
        }
        return Task.isCancelled || error != nil ? [] : songs
    }

    func playAll(using music: JellyfinMusicSession, shuffled: Bool = false) async {
        let queue = await allSongs()
        guard let first = queue.first else { return }
        if shuffled { music.playShuffled(queue) }
        else { music.play(first, from: queue) }
    }
    func shuffle(using music: JellyfinMusicSession) async {
        error = nil
        if request.albumID != nil || request.playlistID != nil {
            await playAll(using: music, shuffled: true)
            return
        }
        // Ask the server for a random song page; never enumerate every album
        // or limit shuffle to the browsing page that happens to be on screen.
        guard let library = LibraryService.current() else {
            error = "Configure Jellyfin in Settings first."
            return
        }
        let key = LibraryService.configurationKey
        var source = request
        source.playbackSongs = true
        source.randomOrder = true
        do {
            let page = try await library.musicPage(source, start: 0)
            try Task.checkCancellation()
            guard key == LibraryService.configurationKey else { return }
            music.playRandomPage(page.Items, source: source, library: library)
        } catch is CancellationError {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch { self.error = error.localizedDescription }
    }

}

@MainActor
final class MusicCatalog {
    static let shared = MusicCatalog()
    private var listings: [MusicRequest: MusicListing] = [:]
    func listing(for request: MusicRequest) -> MusicListing {
        if let listing = listings[request] { return listing }
        // Bound cached screens as well as individual network requests.
        if listings.count >= 24 { listings.removeAll() }
        let listing = MusicListing(request: request)
        listings[request] = listing
        return listing
    }
    /// Drop cached screens that a change made stale (a playlist created, renamed or edited).
    func invalidate(where stale: (MusicRequest) -> Bool) {
        listings = listings.filter { !stale($0.key) }
    }
}
