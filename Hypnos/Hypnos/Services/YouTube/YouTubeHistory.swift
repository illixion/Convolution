/*
 Hypnos - recently watched YouTube videos

 Kept on the device only (UserDefaults), newest first, so the YouTube tab
 has something to show before the first search. Nothing is reported to
 YouTube: the app never signs in.
 */

#if HYPNOS_YOUTUBE

import Foundation
import Observation

@MainActor
@Observable
final class YouTubeHistory {
    static let shared = YouTubeHistory()

    private static let key = "youtube.history"
    private static let limit = 60

    private(set) var videos: [YouTubeVideoSummary]

    private init() {
        videos = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([YouTubeVideoSummary].self, from: $0) } ?? []
    }

    func record(_ summary: YouTubeVideoSummary) {
        videos.removeAll { $0.id == summary.id }
        videos.insert(summary, at: 0)
        if videos.count > Self.limit { videos.removeLast(videos.count - Self.limit) }
        save()
    }

    func remove(_ id: YouTubeVideoID) {
        videos.removeAll { $0.id == id }
        save()
    }

    func clear() {
        videos = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(videos), forKey: Self.key)
    }
}

#endif
