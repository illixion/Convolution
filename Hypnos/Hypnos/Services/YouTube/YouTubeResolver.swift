/*
 Hypnos - turn a YouTube video id into something the players open

 The chain, first match wins:

 1. **On the device**: YouTube's player API as the visionOS client
    (`YouTubeInnertube`) gives an HLS master up to 4K60 VP9 HDR that our own
    `AVPlayer` decodes once the supplemental VP9/AV1 decoders are registered
    (`HypnosApp.init`). Because the app owns the player, frames reach the
    depth pipeline (fake 3D), and there are no ads: those are separate
    entries in the player response, which nothing here plays. Its audio is
    stereo; the video window adds the 5.1 track once YouTube lets it play
    (`YouTubeSurround`), so nothing here waits for it.
 2. **The backend's `/stream`** for what the visionOS client refuses
    (made-for-kids, live, some age-gated videos).
 3. Otherwise the player API's own reason, shown to the viewer.

 YouTube's HLS URLs expire after about six hours, and loopback URLs die with
 the process, so a restored window resolves again (`needsRefresh`).
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation

struct YouTubeResolution: Sendable {
    enum Source: String, Sendable {
        case device
        case backend
    }

    var video: GalleryVideo
    var source: Source
}

enum YouTubeResolveError: LocalizedError {
    case unplayable(String)

    var errorDescription: String? {
        switch self {
        case .unplayable(let reason): reason
        }
    }
}

@MainActor
enum YouTubeResolver {
    /// Resolves `id` down the chain.
    static func resolve(_ id: YouTubeVideoID) async throws -> YouTubeResolution {
        // Before the backend fallback too, so a refused device call doesn't
        // turn into a request elsewhere.
        try YouTubeConsent.require()
        let backend = YouTubeBackend.shared

        let info: YouTubePlayerInfo?
        do {
            info = try await YouTubeInnertube.shared.player(id)
        } catch {
            AppLogger.youtube.error("Player API failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            info = nil
        }

        if let info, info.isPlayable, let hls = info.hlsURL {
            AppLogger.youtube.info("Resolved on device")
            return YouTubeResolution(video: makeVideo(id: id, info: info, streamURL: hls), source: .device)
        }

        let status = info.map { "\($0.status)\($0.isLive ? " live" : "")" } ?? "no answer"
        if let fallback = backend.fallbackStreamURL(for: id) {
            AppLogger.youtube.info("Device client refused (\(status, privacy: .public)); using the backend stream")
            return YouTubeResolution(video: makeVideo(id: id, info: info, streamURL: fallback), source: .backend)
        }
        AppLogger.youtube.info("Unplayable on device (\(status, privacy: .public)) and no backend configured")
        if info?.isLive == true {
            throw YouTubeResolveError.unplayable("Live streams can't be played on this device yet. Set up a YouTube backend in Settings to play them.")
        }
        throw YouTubeResolveError.unplayable(
            info?.reason ?? "YouTube didn't offer a stream this device can play. Set up a YouTube backend in Settings to play more videos."
        )
    }

    static func makeVideo(id: YouTubeVideoID, info: YouTubePlayerInfo?, streamURL: URL) -> GalleryVideo {
        GalleryVideo(
            identity: id.videoIdentity,
            thumbnailURL: YouTubeInnertube.thumbnailURL(for: id),
            streamURL: streamURL,
            title: info?.title,
            duration: info?.lengthSeconds,
            fileName: info?.title
        )
    }

    /// Whether a YouTube window's stream URL has to be resolved again before
    /// it plays: a loopback master from an earlier launch, or a YouTube URL
    /// within 15 minutes of its `expire` stamp. Backend URLs don't expire.
    static func needsRefresh(_ url: URL) -> Bool {
        // A copy cut to one rendition is as stale as the master it came from.
        if url.host == "127.0.0.1" {
            guard LoopbackPlaylistServer.shared.isLive(url) else { return true }
            return YouTubeRenditions.source(of: url).map(needsRefresh) ?? false
        }
        guard url.host?.hasSuffix("googlevideo.com") == true else { return false }
        // `…/expire/1791556239/…` in the path, or `expire=` in the query.
        let components = url.pathComponents
        let pathExpiry = components.firstIndex(of: "expire").flatMap { i in
            i + 1 < components.count ? TimeInterval(components[i + 1]) : nil
        }
        let queryExpiry = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "expire" }?.value.flatMap(TimeInterval.init)
        guard let expiry = pathExpiry ?? queryExpiry else { return true }
        return Date(timeIntervalSince1970: expiry).timeIntervalSinceNow < 15 * 60
    }

    /// The surround master, or a copy of it cut to one rendition; a copy of
    /// YouTube's own master is served on loopback too, and isn't.
    static func isSurroundStream(_ url: URL) -> Bool {
        (YouTubeRenditions.source(of: url) ?? url).host == "127.0.0.1"
    }
}

#endif
