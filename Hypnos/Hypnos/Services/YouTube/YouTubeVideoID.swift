/*
 Hypnos - YouTube (sideload builds only: `HYPNOS_YOUTUBE`)

 A YouTube video id, parsed out of anything a person might paste or share:
 watch pages (desktop, mobile, music), youtu.be links, Shorts, embeds and
 live URLs, or a bare 11-character id.

 The whole YouTube feature compiles only with `HYPNOS_YOUTUBE` (set through
 `YOUTUBE_CONDITION`, see `Configuration/Hypnos.xcconfig`): unofficial
 YouTube playback is what got other visionOS players pulled from the store,
 so it stays out of every build until that is settled.
 */

#if HYPNOS_YOUTUBE

import Foundation

struct YouTubeVideoID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    var description: String { rawValue }

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(trimmed) else { return nil }
        rawValue = trimmed
    }

    /// The id in a pasted URL or a bare id; nil for anything else.
    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bare = YouTubeVideoID(trimmed) {
            self = bare
            return
        }
        var candidate = trimmed
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate) else { return nil }
        self.init(url: url)
    }

    init?(url: URL) {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            guard let first = path.first, let id = YouTubeVideoID(first) else { return nil }
            self = id
            return
        }
        guard Self.youtubeHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value,
           let id = YouTubeVideoID(v) {
            self = id
            return
        }
        // /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>
        if path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]),
           let id = YouTubeVideoID(path[1]) {
            self = id
            return
        }
        return nil
    }

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(rawValue)")! }

    /// The video-window identity: stable per video, so the depth cache and
    /// window restoration key on the video rather than an expiring URL.
    var videoIdentity: String { Self.identityPrefix + rawValue }

    static let identityPrefix = "youtube:"

    init?(videoIdentity: String) {
        guard videoIdentity.hasPrefix(Self.identityPrefix) else { return nil }
        self.init(String(videoIdentity.dropFirst(Self.identityPrefix.count)))
    }

    private static let youtubeHosts = ["youtube.com", "youtube-nocookie.com"]

    private static func isValid(_ s: String) -> Bool {
        s.count == 11 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }
}

#endif
