/*
 Hypnos - the day each YouTube video was published

 The feeds and search say only "3 days ago", so a video tile asks for the
 real date once it comes on screen (`YouTubeInnertube.publishDate`). Each
 lookup is a signed-out web-client player call from the app's own ephemeral
 session, never the signed-in page. Only tiles on screen are asked for, two
 at a time, and if YouTube turns one away, lookups stop for five minutes so
 a burst of them can't get this device bot-checked, which would stall
 playback too. A publish date never changes, so the answers are kept in
 Caches (the newest 3000).
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation
import Observation

@MainActor
@Observable
final class YouTubeUploadDates {
    static let shared = YouTubeUploadDates()

    private static let limit = 3000
    private static let concurrency = 2
    private static let pause: Duration = .seconds(300)
    private static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("youtube-upload-dates.json")

    private struct Entry: Codable {
        var id: String
        var date: Date
    }

    private(set) var dates: [YouTubeVideoID: Date] = [:]

    /// Oldest answer first, for trimming to `limit`.
    @ObservationIgnored private var order: [YouTubeVideoID] = []
    /// Tiles on screen waiting for their turn, in the order they appeared.
    @ObservationIgnored private var waiting: [YouTubeVideoID] = []
    /// Asked this launch, so a video YouTube gives no date for isn't asked again.
    @ObservationIgnored private var asked: Set<YouTubeVideoID> = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for entry in entries {
            guard let id = YouTubeVideoID(entry.id) else { continue }
            if dates.updateValue(entry.date, forKey: id) == nil { order.append(id) }
        }
    }

    /// A tile came on screen.
    func want(_ id: YouTubeVideoID) {
        guard dates[id] == nil, !asked.contains(id), !waiting.contains(id) else { return }
        waiting.append(id)
        drain()
    }

    /// A tile went off screen before its turn.
    func drop(_ id: YouTubeVideoID) {
        waiting.removeAll { $0 == id }
    }

    private func drain() {
        while !paused, running < Self.concurrency, !waiting.isEmpty {
            let id = waiting.removeFirst()
            asked.insert(id)
            running += 1
            Task {
                do {
                    if let date = try await YouTubeInnertube.shared.publishDate(id) { store(date, for: id) }
                } catch {
                    lookupFailed(id, error)
                }
                running -= 1
                drain()
            }
        }
    }

    private func lookupFailed(_ id: YouTubeVideoID, _ error: Error) {
        // Asked again the next time its tile appears.
        asked.remove(id)
        guard case YouTubeInnertubeError.badResponse(let code) = error, !paused else { return }
        AppLogger.youtube.notice("YouTube turned away a publish-date lookup (HTTP \(code, privacy: .public)); pausing them")
        paused = true
        Task {
            try? await Task.sleep(for: Self.pause)
            paused = false
            drain()
        }
    }

    private func store(_ date: Date, for id: YouTubeVideoID) {
        if dates.updateValue(date, forKey: id) == nil { order.append(id) }
        if order.count > Self.limit {
            let stale = order.prefix(order.count - Self.limit)
            for old in stale { dates[old] = nil }
            order.removeFirst(stale.count)
        }
        scheduleSave()
    }

    /// Answers arrive a few a second while a feed loads; write once they settle.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let entries = order.compactMap { id in dates[id].map { Entry(id: id.rawValue, date: $0) } }
            try? JSONEncoder().encode(entries).write(to: Self.fileURL, options: .atomic)
        }
    }
}

#endif
