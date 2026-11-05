import AVFoundation
import Foundation
import MediaPlayer
import Observation

// Isolate the actual player implementation from app configuration and audio focus.
@MainActor @Observable final class FilmSession {
    static let shared = FilmSession()
    var server = "http://127.0.0.1:9"
    var apiKey = "test-placeholder"
}
@MainActor final class JellyfinAuth {
    struct Session { let userId: String; let accessToken: String }
    static let shared = JellyfinAuth()
    var session: Session?
}
enum AudioSessionConfig {
    static func configureMixedPlayback() {}
    static func configureExclusiveMusicPlayback() {}
}

// Page delays expose cancellation and coalescing bugs without a network dependency.
actor JellyfinLibrary {
    private let prefix: String
    private var calls = 0
    private var lastRequest: MusicRequest?
    private var bigSearchPages = 0
    init(prefix: String = "a") { self.prefix = prefix }
    /// How many full pages of names the search index asked for (the totals check asks for one name).
    func fullSearchPageCount() -> Int { bigSearchPages }
    static let corpus: [MusicSearchDoc] = [
        MusicSearchDoc(id: "ar1", kind: .artist, name: "The Beatles", artist: nil, album: nil),
        MusicSearchDoc(id: "ar2", kind: .artist, name: "Motörhead", artist: nil, album: nil),
        MusicSearchDoc(id: "ar3", kind: .artist, name: "AC/DC", artist: nil, album: nil),
        MusicSearchDoc(id: "ar4", kind: .artist, name: "Beyoncé", artist: nil, album: nil),
        MusicSearchDoc(id: "al1", kind: .album, name: "Abbey Road", artist: "The Beatles", album: nil),
        MusicSearchDoc(id: "al2", kind: .album, name: "Ace of Spades", artist: "Motörhead", album: nil),
        MusicSearchDoc(id: "al3", kind: .album, name: "Back in Black", artist: "AC/DC", album: nil),
        MusicSearchDoc(id: "al4", kind: .album, name: "Lemonade", artist: "Beyoncé", album: nil),
        MusicSearchDoc(id: "s1", kind: .song, name: "Come Together", artist: "The Beatles", album: "Abbey Road"),
        MusicSearchDoc(id: "s2", kind: .song, name: "Ace of Spades", artist: "Motörhead", album: "Ace of Spades"),
        MusicSearchDoc(id: "s3", kind: .song, name: "Hells Bells", artist: "AC/DC", album: "Back in Black"),
        MusicSearchDoc(id: "s4", kind: .song, name: "Formation", artist: "Beyoncé", album: "Lemonade"),
        MusicSearchDoc(id: "s5", kind: .song, name: "Sgt. Pepper's Lonely Hearts Club Band", artist: "The Beatles", album: "Sgt. Pepper's Lonely Hearts Club Band"),
    ]
    func musicSearchPage(kind: MusicSearchKind, start: Int, limit: Int) async throws -> (docs: [MusicSearchDoc], total: Int) {
        if limit > 1 { bigSearchPages += 1 }
        let all = Self.corpus.filter { $0.kind == kind }
        return (Array(all.dropFirst(start).prefix(limit)), all.count)
    }
    func musicItems(ids: [String]) async throws -> [JellyfinMusicItem] {
        try ids.reversed().compactMap { id in
            guard let doc = Self.corpus.first(where: { $0.id == id }) else { return nil }
            return try JSONDecoder().decode(JellyfinMusicItem.self, from: Data(
                "{\"Id\":\"\(id)\",\"Name\":\"\(doc.name)\",\"Type\":\"\(doc.kind.itemType)\"}".utf8))
        }
    }
    func requestCount() -> Int { calls }
    func latestRequest() -> MusicRequest? { lastRequest }
    func musicPage(_ request: MusicRequest, start: Int, limit: Int = 60) async throws -> JellyfinMusicPage {
        calls += 1
        lastRequest = request
        try await Task.sleep(for: .milliseconds(30))
        let itemType = request.section == .songs || request.playbackSongs ? "Audio" : "MusicAlbum"
        let items = try (start..<min(start + limit, 125)).map { index in
            try JSONDecoder().decode(JellyfinMusicItem.self, from: Data(
                "{\"Id\":\"\(prefix)-\(index)\",\"Name\":\"Album \(index)\",\"Type\":\"\(itemType)\",\"ChildCount\":12}".utf8))
        }
        return JellyfinMusicPage(Items: items, TotalRecordCount: 125)
    }
}
@MainActor enum LibraryService {
    static var configurationKey = "a"
    static var backend = JellyfinLibrary()
    static func current() -> JellyfinLibrary? { backend }
}

@main struct MusicPlayerChecks {
    @MainActor static func main() async throws {
        let data = Data(#"{"Id":"song-a","Name":"Song A","Type":"Audio","AlbumId":"album-a","Album":"Greatest Hits","RunTimeTicks":100000000}"#.utf8)
        let song = try JSONDecoder().decode(JellyfinMusicItem.self, from: data)
        let music = JellyfinMusicSession.shared
        music.play(song, from: [song])
        precondition(music.current?.id == song.id)
        music.next()
        precondition(music.current == nil && music.queue.isEmpty && !music.isPlaying)
        var releasedFields = 0
        for name in ["_player", "_timeObserver", "_endObserver", "_observation", "player", "timeObserver", "endObserver", "observation"] {
            if let value = Mirror(reflecting: music).children.first(where: { $0.label == name })?.value {
                releasedFields += 1
                precondition(Mirror(reflecting: value).children.isEmpty, "Transport retained \(name) after terminal Next")
            }
        }
        precondition(releasedFields == 4, "Cleanup checks must inspect all four player/observer fields")
        print("Terminal Next releases playback and observers: PASS")
        music.play(song)
        music.stop()
        precondition(music.current == nil && !music.isPlaying && music.currentTime == 0)
        print("Explicit Stop clears playback: PASS")
        let savedVolume = music.volume
        music.setVolume(0.35)
        precondition(abs(music.volume - 0.35) < 0.0001)
        music.setVolume(2)
        precondition(music.volume == 1)
        music.setVolume(-1)
        precondition(music.volume == 0)
        music.setVolume(.nan)
        precondition(music.volume == 0)
        music.setVolume(savedVolume)
        print("Player volume is adjustable, clamped, and rejects invalid values: PASS")

        let untitled = try JSONDecoder().decode(JellyfinMusicItem.self, from: Data(#"{"Id":"song-b","Name":"Song B","Type":"Audio"}"#.utf8))
        precondition(untitled.isSong)
        print("Songs without Album metadata remain songs: PASS")

        let listing = MusicListing(request: MusicRequest())
        let initialLoad = Task { await listing.loadIfNeeded() }
        try await Task.sleep(for: .milliseconds(5))
        initialLoad.cancel()
        // A second appearance shares the load even if the first view vanished.
        await listing.loadIfNeeded()
        await initialLoad.value
        precondition(listing.items.count == 60 && listing.hasMore && !listing.isLoading)
        await listing.loadIfNeeded()
        let initialCalls = await LibraryService.backend.requestCount()
        precondition(initialCalls == 1)
        print("First page bounded, cached, coalesced and survives screen cancellation: PASS")
        await listing.loadMore()
        precondition(listing.items.count == 120 && listing.hasMore)
        await listing.loadMore()
        precondition(listing.items.count == 125 && !listing.hasMore)
        print("Paging appends unique items and stops at server total: PASS")
        let albumQueue = MusicListing(request: MusicRequest(section: .songs, albumID: "album-a"))
        let openingAlbum = Task { await albumQueue.loadIfNeeded() }
        try await Task.sleep(for: .milliseconds(5))
        await albumQueue.playAll(using: music)
        await openingAlbum.value
        precondition(music.queue.count == 125 && music.current?.id == "a-0")
        music.stop()
        print("Explicit Play fetches the complete paged album queue: PASS")

        let shortAlbum = Array(albumQueue.songs.prefix(3))
        music.playShuffled(shortAlbum)
        var visited: [String] = []
        for _ in shortAlbum {
            visited.append(music.current!.id)
            music.next()
        }
        precondition(Set(visited) == Set(shortAlbum.map(\.id)) && music.current == nil)
        print("Album shuffle visits each song exactly once and stops: PASS")

        let beforeShuffle = await LibraryService.backend.requestCount()
        await listing.shuffle(using: music)
        let randomRequest = await LibraryService.backend.latestRequest()
        let afterShuffle = await LibraryService.backend.requestCount()
        precondition(afterShuffle == beforeShuffle + 1 && music.queue.count == 60 && music.isShuffled)
        precondition(randomRequest?.playbackSongs == true && randomRequest?.randomOrder == true)
        print("Library shuffle requests one bounded random song page: PASS")

        let source = MusicRequest(playbackSongs: true, randomOrder: true)
        music.playRandomPage([shortAlbum[0]], source: source, library: LibraryService.backend)
        music.next()
        try await Task.sleep(for: .milliseconds(80))
        precondition(music.current != nil && music.queue.count == 59)
        print("Library shuffle refills after its random page ends: PASS")
        music.playRandomPage([shortAlbum[0]], source: source, library: LibraryService.backend)
        music.next()
        music.pause()
        try await Task.sleep(for: .milliseconds(80))
        precondition(music.queue.count == 1 && !music.isPlaying)
        print("Pausing during a random refill prevents delayed autoplay: PASS")

        music.playRandomPage([shortAlbum[0]], source: source, library: LibraryService.backend)
        music.next()
        music.stop()
        try await Task.sleep(for: .milliseconds(80))
        precondition(music.current == nil && music.queue.isEmpty)
        print("Stopping during a random refill prevents delayed autoplay: PASS")



        func track(_ id: String) throws -> JellyfinMusicItem {
            try JSONDecoder().decode(JellyfinMusicItem.self, from: Data("{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Audio\",\"RunTimeTicks\":2000000000}".utf8))
        }
        // The same song twice: position, not the song's id, says where playback is.
        let twin = try track("twin"), other = try track("other")
        music.play(twin, from: [twin, other, twin], at: 2)
        precondition(music.currentIndex == 2)
        music.previous()
        precondition(music.currentIndex == 1 && music.current?.id == "other")
        music.next()
        precondition(music.currentIndex == 2 && music.current?.id == "twin")
        music.next()
        precondition(music.current == nil && music.currentIndex == nil)
        print("A song queued twice advances by position, not by id: PASS")

        let queued = try (0..<4).map { try track("q-\($0)") }
        let extra = try track("x"), tail = try track("y")
        music.play(queued[1], from: queued)
        music.playNext(extra)
        precondition(music.queue.map(\.id) == ["q-0", "q-1", "x", "q-2", "q-3"] && music.currentIndex == 1)
        music.addToQueue([tail])
        precondition(music.queue.last?.id == "y")
        music.removeFromQueue(at: 0)
        precondition(music.currentIndex == 0 && music.current?.id == "q-1")
        music.removeFromQueue(at: 0)
        precondition(music.queue.count == 5, "The playing song can't be removed")
        music.moveInQueue(from: 3, to: 0)
        precondition(music.queue.map(\.id) == ["q-3", "q-1", "x", "q-2", "y"] && music.currentIndex == 1)
        music.moveInQueue(from: 0, to: 4)
        precondition(music.currentIndex == 0 && music.queue[0].id == "q-1" && music.current?.id == "q-1")
        music.moveInQueue(from: 0, to: 3)
        precondition(music.currentIndex == 3 && music.current?.id == "q-1")
        music.jump(to: 0)
        precondition(music.current?.id == music.queue[0].id)
        music.stop()
        music.playNext(extra)
        precondition(music.current?.id == "x" && music.queue.count == 1)
        music.stop()
        print("Play Next, Add to Queue, remove and move keep the playing song's position: PASS")

        precondition(JellyfinMusicSession.soundCheckFactor(gainDB: nil) == 1)
        precondition(abs(JellyfinMusicSession.soundCheckFactor(gainDB: -6) - 0.501) < 0.01)
        precondition(JellyfinMusicSession.soundCheckFactor(gainDB: 4) == 1, "A quiet song can't be boosted past full volume")
        precondition(JellyfinMusicSession.soundCheckFactor(gainDB: -200) >= 0.05)
        print("Sound Check turns loud songs down and never boosts: PASS")

        precondition(!JellyfinMusicSession.isCountedListen(seconds: 10, duration: 200))
        precondition(JellyfinMusicSession.isCountedListen(seconds: 100, duration: 200))
        precondition(JellyfinMusicSession.isCountedListen(seconds: 240, duration: 1000))
        precondition(!JellyfinMusicSession.isCountedListen(seconds: 200, duration: 1000))
        precondition(!JellyfinMusicSession.isCountedListen(seconds: 29, duration: 0))
        print("A listen counts after half the song or four minutes: PASS")

        let stale = MusicListing(request: MusicRequest(section: .albums))
        let oldLoad = Task { await stale.loadIfNeeded() }
        try await Task.sleep(for: .milliseconds(5))
        LibraryService.configurationKey = "b"
        LibraryService.backend = JellyfinLibrary(prefix: "b")
        await stale.loadIfNeeded()
        await oldLoad.value
        precondition(stale.items.count == 60 && stale.items.allSatisfy { $0.id.hasPrefix("b-") })
        print("Configuration changes discard old results and load the new account: PASS")

        // Sorting and section headers follow the order in force.
        precondition(MusicRequest(section: .songs).effectiveSort == .title && !MusicRequest(section: .songs).isDescending)
        precondition(MusicRequest(section: .recent).isDescending, "Recently Added starts newest first")
        precondition(MusicRequest(section: .songs, sort: .plays).isDescending, "Most played first")
        precondition(!MusicRequest(section: .songs, sort: .plays, descending: false).isDescending)
        precondition(MusicRequest(section: .albums, descending: true).effectiveSort == .title, "Flipping the default order keeps it")
        precondition(MusicRequest(section: .songs, albumID: "x").isTopLevel == false)
        precondition(MusicGrouping.of(MusicRequest(section: .songs)) == .letter)
        precondition(MusicGrouping.of(MusicRequest(section: .songs, sort: .time)) == .none)
        precondition(MusicGrouping.of(MusicRequest(section: .albums, search: "abba")) == .none)
        precondition(MusicGrouping.of(MusicRequest(section: .songs, albumID: "x")) == .none)
        precondition(MusicGrouping.of(MusicRequest(section: .mostPlayed)) == .none)
        precondition(MusicGrouping.letter(of: "The Beatles") == "B" && MusicGrouping.letter(of: "Écoute") == "E")
        precondition(MusicGrouping.letter(of: "99 Luftballons") == "#" && MusicGrouping.letter(of: "A") == "A")
        let calendar = Calendar(identifier: .gregorian)
        let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
        func bucket(_ raw: String) -> String { MusicGrouping.dateBucket(raw, now: now, calendar: calendar) }
        precondition(bucket("2026-11-05T01:00:00.0000000Z") == "Today")
        precondition(bucket("2026-11-04T20:00:00.0000000Z") == "Yesterday")
        precondition(bucket("2026-11-01T20:00:00.0000000Z") == "This Week")
        precondition(bucket("2026-11-01T01:00:00.0000000Z") == "This Week" || bucket("2026-11-01T01:00:00.0000000Z") == "This Month")
        precondition(bucket("2026-10-12T10:00:00Z").contains("October") && bucket("2025-03-12T10:00:00Z").contains("2025"))
        precondition(MusicGrouping.dateBucket(nil) == "Earlier")
        func named(_ name: String) throws -> JellyfinMusicItem {
            try JSONDecoder().decode(JellyfinMusicItem.self, from: Data("{\"Id\":\"\(name)\",\"Name\":\"\(name)\",\"Type\":\"Audio\"}".utf8))
        }
        let names = try ["Apple", "Avocado", "Banana", "The Cherry", "Cranberry", "Apricot"].map(named)
        let runs = MusicGrouping.letter.runs(names, item: { $0 })
        precondition(runs.map { $0.title } == ["A", "B", "C", "A"], "Runs keep the server's order")
        precondition(runs.map { $0.range.count } == [2, 1, 2, 1])
        precondition(MusicGrouping.letter.runs([JellyfinMusicItem](), item: { $0 }).count == 1)
        print("Sort direction and section headers follow the order in force: PASS")

        // Repeat cycles off, all, one; Clear Up Next keeps the queue through the playing song only.
        do {
            func item(_ id: String) throws -> JellyfinMusicItem {
                try JSONDecoder().decode(JellyfinMusicItem.self, from: Data("{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Audio\"}".utf8))
            }
            let session = JellyfinMusicSession.shared
            let songs = try ["q1", "q2", "q3", "q4"].map(item)
            precondition(session.repeatMode == .off)
            session.toggleRepeat(); precondition(session.repeatMode == .all && session.repeats)
            session.toggleRepeat(); precondition(session.repeatMode == .one && session.repeats)
            session.toggleRepeat(); precondition(session.repeatMode == .off && !session.repeats)
            session.play(songs[1], from: songs, at: 1)
            session.clearUpNext()
            precondition(session.queue.map(\.id) == ["q1", "q2"] && session.currentIndex == 1 && session.current?.id == "q2")
            session.clearUpNext()
            precondition(session.queue.count == 2, "Clearing twice changes nothing")
            session.stop()
            session.clearUpNext()
            precondition(session.queue.isEmpty, "Nothing playing, nothing to clear")
            UserDefaults.standard.removeObject(forKey: "jellyfinMusic.repeatMode")
        }
        print("Repeat cycles off, all, one and Clear Up Next keeps the playing song: PASS")

        // Fuzzy search: typos, diacritics, punctuation closed up, every word required.
        let index = MusicSearchIndex(docs: JellyfinLibrary.corpus)
        func top(_ query: String) -> [String] { index.search(query).map(\.id) }
        precondition(top("beatels").first == "ar1", "A typo finds the artist: \(top("beatels"))")
        precondition(top("motorhed").first == "ar2", "Diacritics and a typo: \(top("motorhed"))")
        precondition(top("MOTORHEAD").first == "ar2" && top("beyonce").first == "ar4")
        precondition(top("acdc").first == "ar3", "AC/DC typed without the slash: \(top("acdc"))")
        precondition(top("ac dc").first == "ar3")
        precondition(top("abbey road").first == "al1", "The album outranks its songs: \(top("abbey road"))")
        precondition(top("come tog").first == "s1", "Half a title: \(top("come tog"))")
        precondition(top("peper lonely").first == "s5", "A typo in a multi-word query: \(top("peper lonely"))")
        precondition(top("beatles lemonade").isEmpty, "Every word must match")
        precondition(top("zzzzzz").isEmpty && top("").isEmpty && top("  ").isEmpty)
        precondition(Set(top("beatles").prefix(1)) == ["ar1"] && top("beatles").contains("s1"), "Songs match on their artist too")
        precondition(top("ace of spades").prefix(2).sorted() == ["al2", "s2"], "Album and song of the same name tie ahead of the rest")
        precondition(MusicSearchIndex(docs: []).search("a").isEmpty)
        print("Fuzzy search forgives typos, folds diacritics and requires every word: PASS")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hypnos-music-search-\(UUID().uuidString)")
        let backend = JellyfinLibrary(prefix: "s")
        LibraryService.configurationKey = "search-config"
        LibraryService.backend = backend
        let store = MusicSearchStore(directory: directory, pageSize: 2)
        precondition(store.state == .idle && !store.isReady)
        store.prepare(onlyIfCached: true)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!store.isReady && store.state == .idle, "Nothing is built for someone who has not searched")
        store.prepare()
        for _ in 0..<100 where store.state != .ready { try await Task.sleep(for: .milliseconds(50)) }
        precondition(store.state == .ready && store.isReady)
        let beatels = await store.hits(for: "beatels")
        precondition(beatels?.first?.id == "ar1")
        let builtPages = await backend.fullSearchPageCount()
        precondition(builtPages >= 5, "Built from bounded pages")
        try await Task.sleep(for: .milliseconds(300))

        // A second launch reads the saved index and downloads no names.
        let again = JellyfinLibrary(prefix: "s2")
        LibraryService.backend = again
        let reopened = MusicSearchStore(directory: directory, pageSize: 2)
        reopened.prepare(onlyIfCached: true)
        for _ in 0..<100 where reopened.state != .ready { try await Task.sleep(for: .milliseconds(50)) }
        precondition(reopened.isReady, "A saved index loads without a search")
        let motorhed = await reopened.hits(for: "motorhed")
        precondition(motorhed?.first?.id == "ar2")
        try await Task.sleep(for: .milliseconds(200))
        let downloaded = await again.fullSearchPageCount()
        precondition(downloaded == 0, "Unchanged totals mean no download")

        // A change of account starts from nothing.
        LibraryService.configurationKey = "another-account"
        reopened.prepare(onlyIfCached: true)
        precondition(!reopened.isReady && reopened.state == .idle)
        print("The search index is built in pages, saved, reused without a download and dropped with the account: PASS")

        // A search in a listing goes through the index and keeps its ranking.
        LibraryService.configurationKey = "search-config"
        LibraryService.backend = JellyfinLibrary(prefix: "s3")
        MusicSearchStore.shared = MusicSearchStore(directory: directory, pageSize: 2)
        MusicSearchStore.shared.prepare()
        for _ in 0..<100 where !MusicSearchStore.shared.isReady { try await Task.sleep(for: .milliseconds(50)) }
        let searching = MusicListing(request: MusicRequest(section: .albums, search: "beatels"))
        await searching.loadIfNeeded()
        precondition(searching.items.first?.id == "ar1", "Ranked order survives the server's own order: \(searching.items.map(\.id))")
        precondition(searching.groups.first?.title == "Artists" && !searching.hasMore)
        try? FileManager.default.removeItem(at: directory)
        print("A search listing shows the index's ranking, artists first: PASS")

    }
}
