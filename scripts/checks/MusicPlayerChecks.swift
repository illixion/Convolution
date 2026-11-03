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
    init(prefix: String = "a") { self.prefix = prefix }
    func requestCount() -> Int { calls }
    func musicPage(_ request: MusicRequest, start: Int, limit: Int = 60) async throws -> JellyfinMusicPage {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        let itemType = request.section == .songs ? "Audio" : "MusicAlbum"
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
