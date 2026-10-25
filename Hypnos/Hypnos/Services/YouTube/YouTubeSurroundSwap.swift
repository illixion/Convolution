/*
 Hypnos - YouTube surround for the Apple TV player and the Mac window
 (sideload builds only: `HYPNOS_YOUTUBE`)

 The video window starts YouTube's stereo master at once and, when YouTube
 lets the 5.1 track play, swaps in a copy of the master with it spliced in
 (`VideoWindowModel+YouTube`). `TVVideoPlayerView` and `MacVideoPlayerWindow`
 hand a URL to AVKit's own player instead, so they take the same spliced
 master from here and replace their player item with it at the playhead:
 the TV player through its coordinator, which already watches each item it
 plays, the Mac window through `YouTubeItemSwap`. If the new item fails,
 both go back to the stereo master where they were.
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

/// Moves an `AVPlayer` onto a new item at the playhead, playing on if it
/// was, and reports the item failing, before or after it starts. One swap
/// at a time: a new one, or `stop()`, drops the last one's observers.
@MainActor
final class YouTubeItemSwap {
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var onFailure: (@MainActor () -> Void)?
    /// Where the new item starts, and whether it plays, once it's ready.
    private var pending: (time: CMTime, plays: Bool)?

    func swap(_ player: AVPlayer, to item: AVPlayerItem, onFailure: @escaping @MainActor () -> Void) {
        stop()
        self.onFailure = onFailure
        // A swap whose item never got ready still holds the playhead.
        pending = pending ?? (player.currentTime(), player.timeControlStatus != .paused)
        // A seek before the item is ready is dropped, so it waits for that.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak player] observedItem, _ in
            let status = observedItem.status
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, player.currentItem === observedItem else { return }
                switch status {
                case .readyToPlay:
                    guard let pending = self.pending else { return }
                    self.pending = nil
                    player.seek(to: pending.time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        if pending.plays { player.play() }
                    }
                case .failed:
                    self.fail()
                default:
                    break
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail() }
        }
        player.replaceCurrentItem(with: item)
    }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        onFailure = nil
    }

    private func fail() {
        let handler = onFailure
        stop()
        handler?()
    }
}

#endif
