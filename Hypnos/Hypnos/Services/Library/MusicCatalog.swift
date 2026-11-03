import Foundation
import Observation

enum MusicSection: String, CaseIterable, Identifiable, Sendable {
    case recent, albums, artists, songs, playlists
    var id: Self { self }
    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        case .playlists: "Playlists"
        }
    }
    var symbol: String {
        switch self {
        case .recent: "clock"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        }
    }
}

struct MusicRequest: Hashable, Sendable {
    var section: MusicSection = .recent
    var albumID: String?
    var artistID: String?
    var playlistID: String?
    var search = ""
    var playbackSongs = false
    var randomOrder = false
}

struct MusicAlbumGroup: Identifiable {
    let title: String
    let items: [JellyfinMusicItem]
    var id: String { title }
}

/// Browsing owns no playback clock. Loading a page cannot invalidate the transport,
/// and clock updates cannot rebuild the artwork grid.
@MainActor @Observable
final class MusicListing {
    private(set) var items: [JellyfinMusicItem] = []
    private(set) var albums: [JellyfinMusicItem] = []
    private(set) var songs: [JellyfinMusicItem] = []
    private(set) var groups: [MusicAlbumGroup] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?
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
            items = []; albums = []; songs = []; groups = []
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
            let page = try await library.musicPage(request, start: offset)
            try Task.checkCancellation()
            guard ticket == generation, configuration == LibraryService.configurationKey else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.Items.filter { !existing.contains($0.id) })
            offset += page.Items.count
            hasMore = !page.Items.isEmpty && offset < (page.TotalRecordCount ?? (page.Items.count == 60 ? offset + 1 : offset))
            loaded = true
            // Partition once per page, rather than conditionally expanding ForEach rows.
            songs = items.filter(\.isSong)
            albums = items.filter { !$0.isSong }
            if request.section == .recent && request.search.isEmpty {
                let calendar = Calendar.current
                let now = Date()
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let plainFormatter = ISO8601DateFormatter()
                let buckets = Dictionary(grouping: albums) { item -> String in
                    guard let raw = item.DateCreated,
                          let date = formatter.date(from: raw) ?? plainFormatter.date(from: raw) else { return "Earlier" }
                    if calendar.isDateInToday(date) { return "Today" }
                    if calendar.isDateInYesterday(date) { return "Yesterday" }
                    if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
                    if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "This Month" }
                    return "Earlier"
                }
                groups = ["Today", "Yesterday", "This Week", "This Month", "Earlier"].compactMap { title in
                    guard let items = buckets[title] else { return nil }
                    return MusicAlbumGroup(title: title, items: items)
                }
            } else { groups = [MusicAlbumGroup(title: request.section.title, items: albums)] }
        } catch is CancellationError {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch {
            if ticket == generation { self.error = error.localizedDescription }
        }
    }

    /// Full album/playlist queues are fetched only after an explicit Play action,
    /// in bounded requests, on JellyfinLibrary's actor.
    func playAll(using music: JellyfinMusicSession, shuffled: Bool = false) async {
        await loadIfNeeded()
        while hasMore && error == nil && !Task.isCancelled {
            let previousOffset = offset
            await loadMore()
            guard offset > previousOffset else { return }
        }
        guard !Task.isCancelled, error == nil, let first = songs.first else { return }
        if shuffled { music.playShuffled(songs) }
        else { music.play(first, from: songs) }
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
}
