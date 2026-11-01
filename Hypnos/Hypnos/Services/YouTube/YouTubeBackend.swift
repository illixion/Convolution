/*
 Hypnos - the optional YouTube backend (web-yt-dlp)

 Nothing here is needed to watch YouTube: the device resolves videos itself
 (`YouTubeInnertube`), surround included (`YouTubeSurround`; the backend's
 `/api/youtube/audio` is no longer asked). A configured web-yt-dlp server
 adds what the device can't get on its own:

 - **A fallback stream** for what the visionOS client refuses (made-for-kids
   videos, age-restricted ones, which need the server's signed-in cookies):
   `/stream` remuxes a ≤1080p rendition the device decodes as-is
   (`transcode=never`), so it starts in seconds.
 - **Watch history** across devices (`YouTubeWatchHistory`).

 The token travels in the query string because `AVPlayer` can't add headers
 to the requests it makes on its own. A stream URL is therefore a
 credential: log the host, never the URL.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation

@MainActor
@Observable
final class YouTubeBackend {
    static let shared = YouTubeBackend()

    private static let endpointKey = "youtube.backend.endpoint"

    /// e.g. `https://servo.example.ts.net/yt`. Empty: no backend.
    var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Self.endpointKey) }
    }

    /// Held in the keychain and read from it once: a keychain read is an IPC
    /// round trip, and `isAvailable`/`token` are asked on the main actor several
    /// times per watch-history report (every 10 s while a video plays), which
    /// stalled the HUD's follow for a moment each time. This type is the only
    /// writer of the item, so the copy can't go stale.
    var token: String {
        get {
            if let cachedToken { return cachedToken }
            let loaded = KeychainStore.string(for: .youtubeBackendToken) ?? ""
            cachedToken = loaded
            return loaded
        }
        set {
            _ = KeychainStore.set(newValue.isEmpty ? nil : newValue, for: .youtubeBackendToken)
            cachedToken = newValue
            tokenRevision += 1
        }
    }
    @ObservationIgnored private var cachedToken: String?
    /// Bumped on every token change so views reading `hasToken` refresh.
    private(set) var tokenRevision = 0

    var hasToken: Bool {
        _ = tokenRevision
        return !token.isEmpty
    }

    private init() {
        endpoint = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
    }

    var baseURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var isConfigured: Bool { baseURL != nil }

    // MARK: - Requests

    /// `{endpoint}/<path>?…&token=…`, keeping any path prefix the server
    /// sits under.
    private func url(_ path: String, query: [URLQueryItem]) -> URL? {
        guard let baseURL else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        var items = query
        let token = self.token
        if !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        components?.queryItems = items
        return components?.url
    }

    /// A progressive MP4 the device plays as-is, for videos the device
    /// can't resolve itself. Not fetched here: `AVPlayer` opens it.
    func fallbackStreamURL(for id: YouTubeVideoID) -> URL? {
        url("stream", query: [
            URLQueryItem(name: "url", value: id.watchURL.absoluteString),
            URLQueryItem(name: "id", value: id.rawValue),
            URLQueryItem(name: "height", value: "1080"),
            URLQueryItem(name: "transcode", value: "never"),
        ])
    }
}

#endif
