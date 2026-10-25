/*
 Hypnos - YouTube surround for the Apple TV player
 (sideload builds only: `HYPNOS_YOUTUBE`)

 The video window starts YouTube's stereo master at once and, when YouTube
 lets the 5.1 track play, swaps in a copy of the master with it spliced in
 (`VideoWindowModel+YouTube`). `TVVideoPlayerView` hands a URL to AVKit's own
 player instead, so it takes the same spliced master from here and its
 coordinator, which already watches each item it plays, replaces the player
 item with it at the playhead. If the new item fails, it goes back to the
 stereo master where it was.
 */

#if HYPNOS_YOUTUBE

import AVFoundation
import DebugTrace
import Foundation

@MainActor
enum YouTubeSurroundSwap {
    /// `master`, YouTube's own HLS master for `video`, with the video's 5.1
    /// track spliced in and served on loopback, once YouTube lets the track
    /// play (5-20 s). Nil with Surround Sound off, for a video without 5.1,
    /// and for a stream that isn't YouTube's master (the backend's, or one
    /// already spliced).
    static func surroundMaster(for video: GalleryVideo, playing master: URL) async -> URL? {
        guard YouTubeSurround.isEnabled, let id = YouTubeVideoID(videoIdentity: video.identity),
              master.host != "127.0.0.1",
              let text = await YouTubeRenditions.playlistText(at: master),
              text.contains("#EXT-X-STREAM-INF:"),
              let surround = await YouTubeSurround.audio(for: id), !Task.isCancelled,
              let composed = YouTubeManifestComposer.compose(master: text, surround: surround),
              let url = await LoopbackPlaylistServer.shared.publish(composed)
        else { return nil }
        AppLogger.youtube.info("Surround master ready: \(surround.channels, privacy: .public)-channel \(surround.codecs, privacy: .public)")
        return url
    }
}

#endif
