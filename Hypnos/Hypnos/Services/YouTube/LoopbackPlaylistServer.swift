/*
 Hypnos - serves composed HLS master playlists on 127.0.0.1

 A spliced master playlist (`YouTubeManifestComposer`) exists only in
 memory, and AVFoundation will not play an HLS master from a `file:` or
 `data:` URL, so it is served on loopback, where the native player, the
 stereo engine and the decode probe all open it unchanged.

 Only the master is served here; its variant and rendition URIs are
 absolute (YouTube's CDN, the backend), so the player fetches media from
 there directly.

 The server itself is the app's generic `LoopbackHTTPServer`, shared with
 the Matroska remuxer; this is YouTube's view of it. Playlists live for the
 process. A restored window's loopback URL is dead after a relaunch, which
 `YouTubeResolver.needsRefresh` treats like an expired YouTube URL: the
 window resolves the video again.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation

final class LoopbackPlaylistServer: Sendable {
    static let shared = LoopbackPlaylistServer()

    /// Publishes `playlist` and returns its URL, or nil when the listener
    /// can't start.
    func publish(_ playlist: String) async -> URL? {
        let url = await LoopbackHTTPServer.shared.publishPlaylist(playlist)
        if url == nil { AppLogger.youtube.error("Loopback playlist server failed to start") }
        return url
    }

    func isLive(_ url: URL) -> Bool {
        playlist(at: url) != nil
    }

    /// The playlist served at `url`, if this launch published it.
    func playlist(at url: URL) -> String? {
        LoopbackHTTPServer.shared.playlist(at: url)
    }
}

#endif
