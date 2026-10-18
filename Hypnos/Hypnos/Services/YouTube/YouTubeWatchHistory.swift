/*
 Hypnos - what was watched, and where each video was left

 Kept by the YouTube backend (web-yt-dlp's `/api/history`), not by YouTube:
 the person clears YouTube's own history often, and nothing here reports a
 watch to YouTube. Every device's player reports to the same server (as
 does the Firefox extension in web-yt-dlp), so a video started on the Apple
 TV resumes on the Vision Pro, and the tiles show how far each was watched.

 YouTube's history page is only ever read: once a day a signed-in device
 loads it in a hidden page and posts what it lists to `/import`, which adds
 what was watched in YouTube's own apps without disturbing what was
 reported here.

 Reports that can't be sent wait in an outbox (the newest per video, with
 the time it was seen) until the server answers again. Uses the backend's
 endpoint and token; with no backend configured all of this is off and the
 tab falls back to the on-device `YouTubeHistory`.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class YouTubeWatchHistory {
    static let shared = YouTubeWatchHistory()

    struct Entry: Decodable, Sendable, Equatable {
        var id: String
        var title: String?
        var channel: String?
        var duration: Double?
        var position: Double
        var completed: Bool
        var sortAt: Double
        var lastWatchedAt: Double?

        /// How far along the tile's bar is, 0–1.
        var fraction: Double? {
            if completed, let duration, position >= duration - 10 { return 1 }
            guard let duration, duration > 0, position > 0 else { return completed ? 1 : nil }
            return min(position / duration, 1)
        }

        var summary: YouTubeVideoSummary? {
            guard let videoID = YouTubeVideoID(id) else { return nil }
            return YouTubeVideoSummary(id: videoID, title: title ?? "YouTube video", author: channel,
                                       lengthSeconds: duration)
        }
    }

    enum Event: String, Codable { case start, progress, pause, end }

    struct Report: Codable, Sendable {
        var id: String
        var position: Double
        var duration: Double?
        var title: String?
        var channel: String?
        var device: String
        var event: Event
        /// When it was seen, ms since 1970: the server keeps the newest.
        var at: Double
    }

    /// What the server knows about each video a tile asked for; a video it
    /// doesn't know has no entry.
    private(set) var entries: [YouTubeVideoID: Entry] = [:]
    /// The Watched shelf, newest first.
    private(set) var recent: [Entry] = []
    private(set) var recentNext: Double?
    private(set) var recentError: String?
    private(set) var isLoadingRecent = false

    @ObservationIgnored private var asked: Set<YouTubeVideoID> = []
    @ObservationIgnored private var wanted: [YouTubeVideoID] = []
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var outbox: [String: Report]
    @ObservationIgnored private var flushing = false
    /// Title and channel of videos opened from a tile, for their reports.
    @ObservationIgnored private var metadata: [YouTubeVideoID: YouTubeVideoSummary] = [:]

    private static let outboxKey = "youtube.watchHistory.outbox"
    private static let importedKey = "youtube.watchHistory.importedAt"
    private static let importInterval: TimeInterval = 24 * 3600

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private init() {
        outbox = UserDefaults.standard.data(forKey: Self.outboxKey)
            .flatMap { try? JSONDecoder().decode([String: Report].self, from: $0) } ?? [:]
    }

    /// The backend is set up; without it nothing here does anything.
    var isAvailable: Bool {
        let backend = YouTubeBackend.shared
        return backend.isConfigured && backend.hasToken
    }

    static var deviceName: String {
        #if os(visionOS)
        "Vision Pro"
        #elseif os(tvOS)
        "Apple TV"
        #elseif os(macOS)
        "Mac"
        #else
        UIDevice.current.model
        #endif
    }

    // MARK: - Tiles

    /// A tile came on screen; its entry arrives with the next batch.
    func want(_ id: YouTubeVideoID) {
        guard isAvailable, !asked.contains(id), !wanted.contains(id) else { return }
        wanted.append(id)
        guard lookupTask == nil else { return }
        lookupTask = Task {
            // Tiles appear a screenful at a time; ask for them together.
            try? await Task.sleep(for: .milliseconds(300))
            while !wanted.isEmpty {
                let batch = Array(wanted.prefix(200))
                wanted.removeFirst(batch.count)
                asked.formUnion(batch)
                if let found = await lookup(batch) {
                    for (id, entry) in found { entries[id] = entry }
                } else {
                    asked.subtract(batch)
                }
            }
            lookupTask = nil
        }
    }

    /// Asks again for every tile, e.g. when the tab comes back, so progress
    /// made on another device shows.
    func refreshTiles() {
        asked.removeAll()
    }

    private func lookup(_ ids: [YouTubeVideoID]) async -> [YouTubeVideoID: Entry]? {
        struct Reply: Decodable { var videos: [String: Entry] }
        guard let reply: Reply = await call("POST", "api/history/lookup", body: ["ids": ids.map(\.rawValue)]) else {
            return nil
        }
        var found: [YouTubeVideoID: Entry] = [:]
        for (key, entry) in reply.videos { if let id = YouTubeVideoID(key) { found[id] = entry } }
        return found
    }

    /// Where to start `id`: the saved position, unless it was finished or
    /// barely begun. Asks the server (briefly) so another device's progress
    /// counts.
    func resumePosition(for id: YouTubeVideoID) async -> Double? {
        guard isAvailable else { return nil }
        let entry = await lookup([id])?[id] ?? entries[id]
        if let entry { entries[id] = entry }
        guard let entry, entry.position >= 15 else { return nil }
        if let duration = entry.duration, entry.position >= duration - 10 { return nil }
        return entry.position
    }

    // MARK: - Watched shelf

    func loadRecent(more: Bool = false) async {
        guard isAvailable, !isLoadingRecent, !more || recentNext != nil else { return }
        struct Reply: Decodable { var videos: [Entry]; var next: Double? }
        isLoadingRecent = true
        defer { isLoadingRecent = false }
        var path = "api/history?limit=60"
        if more, let recentNext { path += "&before=\(Int64(recentNext))" }
        guard let reply: Reply = await call("GET", path) else {
            if !more { recentError = "The YouTube backend didn't answer." }
            return
        }
        recentError = nil
        let fresh = more ? recent + reply.videos : reply.videos
        var seen = Set<String>()
        recent = fresh.filter { seen.insert($0.id).inserted }
        recentNext = reply.next
        for entry in reply.videos { if let id = YouTubeVideoID(entry.id) { entries[id] = entry } }
    }

    func remove(_ id: YouTubeVideoID) async {
        struct Reply: Decodable { var removed: Bool }
        recent.removeAll { $0.id == id.rawValue }
        entries[id] = nil
        outbox[id.rawValue] = nil
        saveOutbox()
        let _: Reply? = await call("DELETE", "api/history/\(id.rawValue)")
    }

    // MARK: - Reports

    /// Remembers what a tile said about a video about to play, so its
    /// reports carry a title and channel.
    func noteOpening(_ summary: YouTubeVideoSummary) {
        metadata[summary.id] = summary
    }

    func send(_ id: YouTubeVideoID, position: Double, duration: Double?, title: String?, event: Event) {
        guard isAvailable, position.isFinite, position >= 0 else { return }
        let known = metadata[id]
        let report = Report(
            id: id.rawValue, position: position,
            duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? known?.lengthSeconds,
            title: known?.title ?? title, channel: known?.author,
            device: Self.deviceName, event: event, at: Date().timeIntervalSince1970 * 1000)
        // The tile shows it straight away.
        if var entry = entries[id] {
            entry.position = position
            if let duration = report.duration { entry.duration = duration }
            entries[id] = entry
        } else {
            entries[id] = Entry(id: id.rawValue, title: report.title, channel: report.channel,
                                duration: report.duration, position: position, completed: false,
                                sortAt: report.at, lastWatchedAt: report.at)
        }
        // A start must reach the server even if a later report replaces it
        // in the outbox, or the viewing isn't counted; the server only takes
        // its position if nothing newer arrived.
        if let waiting = outbox[id.rawValue], waiting.event == .start, event != .start {
            var merged = report
            merged.event = .start
            outbox[id.rawValue] = merged
        } else {
            outbox[id.rawValue] = report
        }
        saveOutbox()
        flush()
    }

    /// Sends what waits in the outbox, oldest first, including what arrives
    /// meanwhile; stops at the first failure and tries again with the next
    /// report.
    func flush() {
        guard isAvailable, !flushing, !outbox.isEmpty else { return }
        flushing = true
        Task {
            defer { flushing = false }
            while let report = outbox.values.min(by: { $0.at < $1.at }) {
                struct Reply: Decodable { var video: Entry }
                guard let reply: Reply = await call("PUT", "api/history/\(report.id)", body: report) else {
                    return
                }
                if outbox[report.id]?.at == report.at {
                    outbox[report.id] = nil
                } else if report.event == .start, outbox[report.id]?.event == .start {
                    // Merged into a start while this one was on its way.
                    outbox[report.id]?.event = .progress
                }
                if let id = YouTubeVideoID(report.id), entries[id] != nil || recent.contains(where: { $0.id == report.id }) {
                    entries[id] = reply.video
                }
                saveOutbox()
            }
        }
    }

    private func saveOutbox() {
        UserDefaults.standard.set(try? JSONEncoder().encode(outbox), forKey: Self.outboxKey)
    }

    // MARK: - YouTube's history page

    /// Once a day is enough: imports add only what was watched elsewhere.
    var isImportDue: Bool {
        guard isAvailable else { return false }
        let last = UserDefaults.standard.double(forKey: Self.importedKey)
        return Date().timeIntervalSince1970 - last > Self.importInterval
    }

    /// Posts what YouTube's history page lists, newest first.
    func importFromYouTube(_ videos: [YouTubeVideoSummary]) async {
        guard isAvailable, !videos.isEmpty else { return }
        struct Item: Encodable { var id: String; var title: String; var channel: String?; var duration: Double?; var progress: Double? }
        struct Body: Encodable { var items: [Item]; var device: String }
        struct Reply: Decodable { var added: Int; var updated: Int; var skipped: Int }
        let body = Body(items: videos.map {
            Item(id: $0.id.rawValue, title: $0.title, channel: $0.author, duration: $0.lengthSeconds,
                 progress: $0.watchedFraction)
        }, device: "YouTube history via \(Self.deviceName)")
        guard let reply: Reply = await call("POST", "api/history/import", body: body) else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.importedKey)
        AppLogger.youtube.info("Imported YouTube's history: \(reply.added, privacy: .public) added, \(reply.updated, privacy: .public) updated")
        if reply.added + reply.updated > 0 { refreshTiles() }
    }

    // MARK: - Transport

    private func call<Reply: Decodable>(_ method: String, _ path: String) async -> Reply? {
        await call(method, path, body: Optional<[String: String]>.none)
    }

    private func call<Reply: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?) async -> Reply? {
        let backend = YouTubeBackend.shared
        guard let base = backend.baseURL, let url = URL(string: path, relativeTo: base.appendingPathComponent("")) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(backend.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.youtube.error("Watch history \(method, privacy: .public) answered \(code, privacy: .public)")
                return nil
            }
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            AppLogger.youtube.error("Watch history \(method, privacy: .public) failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }
}

/// Follows one YouTube video's playback and reports it: a start once it
/// plays, then every 10 s while it plays, at once on pause or resume, and
/// once more when the player closes. Players feed it their playhead
/// (`update`) as often as they like.
@MainActor
final class YouTubeWatchReporter {
    private let id: YouTubeVideoID
    private let title: String?
    private var started = false
    private var lastSent = Date.distantPast
    private var lastPaused: Bool?
    private var position: Double = 0
    private var duration: Double?

    init?(video: GalleryVideo) {
        guard let id = YouTubeVideoID(videoIdentity: video.identity), YouTubeWatchHistory.shared.isAvailable else {
            return nil
        }
        self.id = id
        title = video.title
        duration = video.duration
    }

    func update(position: Double, duration: Double?, isPaused: Bool) {
        guard position.isFinite else { return }
        self.position = position
        if let duration, duration.isFinite, duration > 0 { self.duration = duration }
        if !started {
            guard position > 0, !isPaused else { return }
            started = true
            send(.start, paused: false)
        } else if isPaused != lastPaused {
            send(isPaused ? .pause : .progress, paused: isPaused)
        } else if !isPaused, Date().timeIntervalSince(lastSent) >= 10 {
            send(.progress, paused: false)
        }
    }

    /// The player closed.
    func finish() {
        guard started else { return }
        let ended = duration.map { position >= $0 - 2 } ?? false
        send(ended ? .end : .pause, paused: true)
        started = false
    }

    private func send(_ event: YouTubeWatchHistory.Event, paused: Bool) {
        lastSent = Date()
        lastPaused = paused
        YouTubeWatchHistory.shared.send(id, position: position, duration: duration, title: title, event: event)
    }
}

#endif
