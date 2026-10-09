/*
 Hypnos - the optional YouTube backend (web-yt-dlp)

 Nothing here is needed to watch YouTube: the device resolves videos itself
 (`YouTubeInnertube`). A configured web-yt-dlp server adds two things the
 device can't get on its own:

 - **Surround audio.** YouTube lists its 5.1 EC-3/AC-3 tracks only to a
   signed-in web client, which the server is (it holds the cookies). It
   serves that track as an audio-only HLS playlist, and `YouTubeResolver`
   splices it into YouTube's own master playlist as another audio rendition,
   so the picture still comes straight from YouTube at full quality.
 - **A fallback stream** for what the visionOS client refuses (made-for-kids
   videos, some age-gated ones): `/stream` remuxes a ≤1080p rendition the
   device decodes as-is (`transcode=never`), so it starts in seconds.

 The token travels in the query string because `AVPlayer` can't add headers
 to the requests it makes on its own. A stream URL is therefore a
 credential: log the host, never the URL.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation

/// The surround track a backend offers for one video.
struct YouTubeSurroundAudio: Sendable, Equatable {
    var channels: Int
    /// RFC 6381 codec string for the HLS `CODECS` attribute (`ec-3`, `ac-3`).
    var codecs: String
    var bandwidth: Int
    var language: String?
    var playlistURL: URL
}

@MainActor
@Observable
final class YouTubeBackend {
    static let shared = YouTubeBackend()

    private static let endpointKey = "youtube.backend.endpoint"
    private static let surroundKey = "youtube.backend.surround"

    /// e.g. `https://servo.example.ts.net/yt`. Empty: no backend.
    var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Self.endpointKey) }
    }

    /// Ask the backend for surround audio on every video.
    var prefersSurround: Bool {
        didSet { UserDefaults.standard.set(prefersSurround, forKey: Self.surroundKey) }
    }

    /// Held in the keychain, read through on each request.
    var token: String {
        get { KeychainStore.string(for: .youtubeBackendToken) ?? "" }
        set {
            _ = KeychainStore.set(newValue.isEmpty ? nil : newValue, for: .youtubeBackendToken)
            tokenRevision += 1
        }
    }
    /// Bumped on every token change so views reading `hasToken` refresh.
    private(set) var tokenRevision = 0

    var hasToken: Bool {
        _ = tokenRevision
        return !token.isEmpty
    }

    private init() {
        endpoint = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        prefersSurround = UserDefaults.standard.object(forKey: Self.surroundKey) as? Bool ?? true
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

    /// The video's surround track, or nil when it has none, the backend
    /// isn't configured, or it didn't answer within `timeout`.
    func surroundAudio(for id: YouTubeVideoID, timeout: Duration = .seconds(6)) async -> YouTubeSurroundAudio? {
        guard prefersSurround,
              let requestURL = url("api/youtube/audio", query: [URLQueryItem(name: "id", value: id.rawValue)]) else {
            return nil
        }
        let host = baseURL?.host ?? "?"
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout / .seconds(1)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                AppLogger.youtube.error("Backend \(host, privacy: .private(mask: .hash)) answered \(http.statusCode, privacy: .public) for surround audio")
                return nil
            }
            let reply = try JSONDecoder().decode(SurroundReply.self, from: data)
            guard reply.available, let channels = reply.channels, channels > 2,
                  let codecs = reply.codecs ?? reply.codec,
                  let playlist = reply.playlist.flatMap(URL.init(string:)) else { return nil }
            return YouTubeSurroundAudio(channels: channels, codecs: codecs,
                                        bandwidth: reply.bandwidth ?? 384_000,
                                        language: reply.language, playlistURL: playlist)
        } catch {
            AppLogger.youtube.error("Surround audio lookup failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    private struct SurroundReply: Decodable {
        var available: Bool
        var channels: Int?
        var codec: String?
        var codecs: String?
        var bandwidth: Int?
        var language: String?
        var playlist: String?
    }
}

#endif
