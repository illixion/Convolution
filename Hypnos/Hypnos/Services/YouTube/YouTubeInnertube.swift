/*
 Hypnos - YouTube's own API, called from the device

 Four calls, all unauthenticated:

 - **player**, asked as YouTube's visionOS app (the values yt-dlp 2026.08.19
   sends for its `visionos` client). It answers with an HLS master playlist up
   to 2160p60, VP9 Profile 2 PQ included, with no PO token and no player
   JavaScript, which is what lets the video play in our own `AVPlayer` and
   reach the depth pipeline (spike: `TVLab/FilmLabTV/YouTubeLab.swift`,
   measured 4K60 HDR10 on an Apple TV). The one extra step is a visitor id
   from a watch page; without it the API answers "Sign in to confirm you're
   not a bot". Its audio is stereo AAC only. Made-for-kids videos and live
   streams come back unplayable from this client and fall through to the
   backend.
 - **player** again, as a Samsung TV's YouTube app (TVHTML5, yt-dlp's
   `tv_samsung`), for **surround**: of the clients measured signed out on
   2026-10-25, the TV one lists the 5.1 EC-3 and AC-3 tracks (itags 328, 380)
   as plain stream URLs with no SABR; the visionOS, iOS and Android VR
   clients list stereo only. Those URLs need the player script's challenge
   solved and the pre-roll ad's time to pass (`YouTubeSurround`), and the
   call itself needs the script's `signatureTimestamp`.
 - **search**, as the web client. Only `videoRenderer`s are kept (Shorts and
   channel cards are dropped); a continuation token pages further.
 - **player** again, as the web client, for the day a video was published
   (`publishDate`). Without a PO token that client won't play anything, but
   its answer still carries the video's `microformat` (~3 KB), which the
   visionOS client's lacks. The feeds and search only say "3 days ago".

 These shapes are YouTube's private API and change without notice; every
 parse is defensive and a missing field degrades to nil rather than failing
 the whole response.
 */

#if HYPNOS_YOUTUBE

import Foundation

/// What the player API said about one video.
struct YouTubePlayerInfo: Sendable {
    var id: YouTubeVideoID
    var hlsURL: URL?
    var title: String?
    var author: String?
    var lengthSeconds: Double?
    var isLive: Bool
    /// `OK`, `UNPLAYABLE`, `LOGIN_REQUIRED`, `ERROR`, …
    var status: String
    var reason: String?

    var isPlayable: Bool { status == "OK" && hlsURL != nil && !isLive }
}

/// The TV client's audio formats for one video (`YouTubeInnertube.tvAudioFormats`).
struct YouTubeTVAudio: Sendable {
    struct Format: Sendable {
        var itag: Int
        /// "ec-3", "ac-3", "mp4a.40.2", "opus", …
        var codecs: String
        var channels: Int
        var bitrate: Int?
        /// A plain stream URL, or nil when the format comes as a cipher.
        var url: String?
        var signatureCipher: String?
        var initRange: ClosedRange<Int>?
        var indexRange: ClosedRange<Int>?
        var language: String?
        /// The video's own track among dubbed ones (absent: the only one).
        var isDefaultTrack: Bool
        /// A loudness-compressed (DRC) copy of another format.
        var isDRC: Bool

        init?(_ json: [String: Any]) {
            guard let itag = json["itag"] as? Int, let mime = json["mimeType"] as? String,
                  mime.hasPrefix("audio/"),
                  let codecs = mime.firstMatch(of: #/codecs="([^"]+)"/#).map({ String($0.1) }) else { return nil }
            func range(_ key: String) -> ClosedRange<Int>? {
                guard let object = json[key] as? [String: Any],
                      let start = (object["start"] as? String).flatMap(Int.init),
                      let end = (object["end"] as? String).flatMap(Int.init), start <= end else { return nil }
                return start...end
            }
            let track = json["audioTrack"] as? [String: Any]
            self.itag = itag
            self.codecs = codecs
            channels = json["audioChannels"] as? Int ?? 2
            bitrate = json["bitrate"] as? Int
            url = json["url"] as? String
            signatureCipher = json["signatureCipher"] as? String
            initRange = range("initRange")
            indexRange = range("indexRange")
            language = (track?["id"] as? String)?.split(separator: ".").first.map(String.init)
            isDefaultTrack = track.map { $0["audioIsDefault"] as? Bool ?? false } ?? true
            isDRC = json["isDrc"] as? Bool ?? false
        }
    }

    /// `OK`, `UNPLAYABLE`, `LOGIN_REQUIRED`, …
    var status: String
    var formats: [Format]
    /// When the pre-roll has run out and the URLs work.
    var availableAt: Date
}

/// One search result.
struct YouTubeVideoSummary: Identifiable, Hashable, Codable, Sendable {
    var id: YouTubeVideoID
    var title: String
    var author: String?
    var lengthText: String?
    var lengthSeconds: Double?
    var viewCountText: String?
    var publishedText: String?
    /// How far YouTube's own history says it was watched, 0–1, from a
    /// signed-in page's red bar.
    var watchedFraction: Double?

    var thumbnailURL: URL { YouTubeInnertube.thumbnailURL(for: id) }
}

struct YouTubeSearchPage: Sendable {
    var results: [YouTubeVideoSummary]
    var continuation: String?
}

enum YouTubeInnertubeError: LocalizedError {
    case badResponse(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "YouTube answered with HTTP \(code)."
        case .unreadable: "YouTube's answer couldn't be read."
        }
    }
}

actor YouTubeInnertube {
    static let shared = YouTubeInnertube()

    private static let base = URL(string: "https://www.youtube.com/youtubei/v1/")!

    // The visionOS app, as yt-dlp 2026.08.19 presents it.
    private static let visionAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let visionClient: [String: String] = [
        "clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple",
        "deviceModel": "RealityDevice17,1", "userAgent": visionAgent,
        "osName": "visionOS", "osVersion": "26.5.23O471", "hl": "en", "gl": "US",
    ]
    private static let webClientVersion = "2.20260708.00.00"
    // A Samsung TV's app, as yt-dlp 2026.10.21 presents its `tv_samsung` client.
    private static let tvAgent = "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1"
    private static let tvClientVersion = "5.20260707"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// A visitor id lasts for months; one per launch keeps watch-page
    /// fetches (~1 MB each) to the first video.
    private var visitorData: (value: String, fetched: Date)?

    static func thumbnailURL(for id: YouTubeVideoID) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(id.rawValue)/mqdefault.jpg")!
    }

    // MARK: - Player

    func player(_ id: YouTubeVideoID) async throws -> YouTubePlayerInfo {
        let visitor = try? await visitorID(for: id)
        var context = Self.visionClient
        if let visitor { context["visitorData"] = visitor }
        var headers = [
            "User-Agent": Self.visionAgent,
            "X-YouTube-Client-Name": "101",
            "X-YouTube-Client-Version": "1.02",
        ]
        if let visitor { headers["X-Goog-Visitor-Id"] = visitor }
        let json = try await post("player", body: [
            "context": ["client": context],
            "videoId": id.rawValue,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ], headers: headers)

        let playability = json["playabilityStatus"] as? [String: Any]
        let streaming = json["streamingData"] as? [String: Any]
        let details = json["videoDetails"] as? [String: Any]
        return YouTubePlayerInfo(
            id: id,
            hlsURL: (streaming?["hlsManifestUrl"] as? String).flatMap(URL.init(string:)),
            title: details?["title"] as? String,
            author: details?["author"] as? String,
            lengthSeconds: (details?["lengthSeconds"] as? String).flatMap(Double.init),
            isLive: (details?["isLive"] as? Bool) ?? false,
            status: playability?["status"] as? String ?? "ERROR",
            reason: playability?["reason"] as? String
        )
    }

    /// The video's audio-only formats as the TV client lists them, and how
    /// long its pre-roll keeps their URLs locked.
    func tvAudioFormats(_ id: YouTubeVideoID, signatureTimestamp: Int) async throws -> YouTubeTVAudio {
        let visitor = try? await visitorID(for: id)
        var context: [String: Any] = [
            "clientName": "TVHTML5", "clientVersion": Self.tvClientVersion, "deviceMake": "Samsung",
            "deviceModel": "SmartTV", "clientScreen": "WATCH", "hl": "en", "gl": "US",
        ]
        if let visitor { context["visitorData"] = visitor }
        var headers = [
            "User-Agent": Self.tvAgent,
            "X-YouTube-Client-Name": "7",
            "X-YouTube-Client-Version": Self.tvClientVersion,
        ]
        if let visitor { headers["X-Goog-Visitor-Id"] = visitor }
        let json = try await post("player", body: [
            "context": ["client": context],
            "videoId": id.rawValue,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": [
                "html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": signatureTimestamp,
            ]],
        ], headers: headers)
        let answeredAt = Date()
        let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "ERROR"
        let adaptive = ((json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]) ?? []
        let formats = adaptive.compactMap(YouTubeTVAudio.Format.init)
        return YouTubeTVAudio(status: status, formats: formats,
                              availableAt: answeredAt.addingTimeInterval(Self.preRollSeconds(json)))
    }

    /// How long the pre-roll ads hold the stream URLs back: each ad shown
    /// before the video, for its skip offset when it has one, else its
    /// length. googlevideo answers 403 until then (yt-dlp's
    /// `_get_available_at_timestamp`).
    private static func preRollSeconds(_ json: [String: Any]) -> TimeInterval {
        var renderers: [[String: Any]] = []
        for placement in (json["adPlacements"] as? [[String: Any]]) ?? [] {
            guard let renderer = placement["adPlacementRenderer"] as? [String: Any],
                  let config = (renderer["config"] as? [String: Any])?["adPlacementConfig"] as? [String: Any],
                  config["kind"] as? String == "AD_PLACEMENT_KIND_START",
                  let ad = (renderer["renderer"] as? [String: Any])?["instreamVideoAdRenderer"] as? [String: Any]
            else { continue }
            renderers.append(ad)
        }
        for slot in (json["adSlots"] as? [[String: Any]]) ?? [] {
            guard let renderer = slot["adSlotRenderer"] as? [String: Any],
                  (renderer["adSlotMetadata"] as? [String: Any])?["triggerEvent"] as? String == "SLOT_TRIGGER_EVENT_BEFORE_CONTENT",
                  let content = (((renderer["fulfillmentContent"] as? [String: Any])?["fulfilledLayout"] as? [String: Any])?[
                      "playerBytesAdLayoutRenderer"] as? [String: Any])?["renderingContent"] as? [String: Any]
            else { continue }
            if let ad = content["instreamVideoAdRenderer"] as? [String: Any] { renderers.append(ad) }
            let layouts = (content["playerBytesSequentialLayoutRenderer"] as? [String: Any])?["sequentialLayouts"] as? [[String: Any]] ?? []
            for layout in layouts {
                if let ad = (((layout["playerBytesAdLayoutRenderer"] as? [String: Any])?["renderingContent"] as? [String: Any])?[
                    "instreamVideoAdRenderer"] as? [String: Any]) {
                    renderers.append(ad)
                }
            }
        }
        return renderers.reduce(0) { total, ad in
            if let skip = ad["skipOffsetMilliseconds"] as? Double { return total + skip / 1000 }
            if let vars = ad["playerVars"] as? String,
               let length = vars.firstMatch(of: #/(?:^|&)length_seconds=(\d+)/#).flatMap({ Double($0.1) }) {
                return total + length
            }
            return total
        }
    }

    private func visitorID(for id: YouTubeVideoID) async throws -> String? {
        if let visitorData, Date().timeIntervalSince(visitorData.fetched) < 6 * 3600 {
            return visitorData.value
        }
        try YouTubeConsent.require()
        var request = URLRequest(url: id.watchURL)
        request.setValue(Self.visionAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        guard let match = html.firstMatch(of: #/"VISITOR_DATA":"([^"]+)"/#) else { return nil }
        let value = String(match.1)
        visitorData = (value, Date())
        return value
    }

    // MARK: - Publish date

    /// When a video was published; a live stream on air counts from its
    /// start. Same request and fields as the "yyyy-mm-dd upload dates"
    /// userscript (greasyfork 493024) makes from youtube.com.
    func publishDate(_ id: YouTubeVideoID) async throws -> Date? {
        let json = try await post("player", body: [
            "context": ["client": ["clientName": "WEB", "clientVersion": Self.webClientVersion,
                                   "hl": "en", "gl": "US"]],
            "videoId": id.rawValue,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ], headers: [
            "User-Agent": Self.visionAgent,
            "X-YouTube-Client-Name": "1",
            "X-YouTube-Client-Version": Self.webClientVersion,
        ])
        guard let microformat = (json["microformat"] as? [String: Any])?["playerMicroformatRenderer"]
            as? [String: Any] else { return nil }
        let live = microformat["liveBroadcastDetails"] as? [String: Any]
        let stamp = (live?["isLiveNow"] as? Bool == true ? live?["startTimestamp"] as? String : nil)
            ?? microformat["publishDate"] as? String
            ?? microformat["uploadDate"] as? String
        return stamp.flatMap(Self.date(fromStamp:))
    }

    /// "2026-10-08T07:00:19-07:00", or a bare "2026-10-08" as older answers
    /// gave, read as noon UTC so it stays that day almost everywhere.
    static func date(fromStamp stamp: String) -> Date? {
        if let date = try? Date(stamp, strategy: .iso8601) { return date }
        return try? Date(stamp + "T12:00:00Z", strategy: .iso8601)
    }

    // MARK: - Search

    func search(_ query: String, continuation: String? = nil) async throws -> YouTubeSearchPage {
        var body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": Self.webClientVersion,
                                   "hl": "en", "gl": "US"]],
        ]
        if let continuation { body["continuation"] = continuation } else { body["query"] = query }
        let json = try await post("search", body: body, headers: [
            "User-Agent": Self.visionAgent,
            "X-YouTube-Client-Name": "1",
            "X-YouTube-Client-Version": Self.webClientVersion,
        ])
        var results: [YouTubeVideoSummary] = []
        var seen = Set<YouTubeVideoID>()
        var token: String?
        Self.walk(json) { key, value in
            if key == "videoRenderer", let renderer = value as? [String: Any],
               let summary = Self.summary(renderer), seen.insert(summary.id).inserted {
                results.append(summary)
            } else if key == "continuationCommand", token == nil,
                      let command = value as? [String: Any] {
                token = command["token"] as? String
            }
        }
        return YouTubeSearchPage(results: results, continuation: token)
    }

    private static func summary(_ r: [String: Any]) -> YouTubeVideoSummary? {
        guard let raw = r["videoId"] as? String, let id = YouTubeVideoID(raw),
              let title = text(r["title"]) else { return nil }
        let length = text(r["lengthText"])
        return YouTubeVideoSummary(
            id: id,
            title: title,
            author: text(r["ownerText"]) ?? text(r["longBylineText"]),
            lengthText: length,
            lengthSeconds: length.flatMap(seconds(fromClock:)),
            viewCountText: text(r["shortViewCountText"]) ?? text(r["viewCountText"]),
            publishedText: text(r["publishedTimeText"])
        )
    }

    /// `simpleText` or the joined `runs` of a YouTube text object.
    private static func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String { return simple }
        if let runs = object["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// "1:02:03" → 3723.
    static func seconds(fromClock clock: String) -> Double? {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func walk(_ value: Any, _ visit: (String, Any) -> Void) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                visit(key, child)
                walk(child, visit)
            }
        } else if let array = value as? [Any] {
            for child in array { walk(child, visit) }
        }
    }

    // MARK: - Transport

    private func post(_ endpoint: String, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        try YouTubeConsent.require()
        var components = URLComponents(url: Self.base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YouTubeInnertubeError.badResponse(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeInnertubeError.unreadable
        }
        return json
    }
}

#endif
