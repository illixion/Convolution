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
    init(prefix: String = "a") { self.prefix = prefix }
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

    }
}
