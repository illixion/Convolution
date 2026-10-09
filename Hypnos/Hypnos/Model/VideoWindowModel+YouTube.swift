/*
 Hypnos - what the video window does differently for a YouTube video
 (sideload builds only: `HYPNOS_YOUTUBE`)

 Three things, everything else is the ordinary stream path:

 - **Expired streams.** A restored window carries a YouTube HLS URL that
   expires after ~6 h, or a loopback master from an earlier launch. `start()`
   resolves the video again before the renderer probes it, so a stale URL
   never reaches the probe (which would route it to WebKit).
 - **Surround that doesn't play.** If the spliced surround master won't open
   (the probe says undecodable, or the native player fails), the window
   reopens the video with YouTube's own stereo at the playhead rather than
   falling back to WebKit.
 - **SponsorBlock auto-skip** (`MediaSegmentSkipper.autoSkip`), announced in
   the window's notice slot.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation

extension VideoWindowModel {
    var youTubeID: YouTubeVideoID? { YouTubeVideoID(videoIdentity: video.identity) }

    /// Called by `start()`; true when it has taken over resolving the
    /// renderer.
    func refreshYouTubeStreamIfNeeded() -> Bool {
        guard let id = youTubeID, YouTubeResolver.needsRefresh(video.streamURL) else { return false }
        reopenYouTube(id, allowSurround: true, reason: "the stream URL expired")
        return true
    }

    /// True when the window is reopening the video without surround.
    func dropYouTubeSurround(reason: String) -> Bool {
        guard let id = youTubeID, YouTubeResolver.isSurroundStream(video.streamURL) else { return false }
        reopenYouTube(id, allowSurround: false, reason: reason)
        return true
    }

    private func reopenYouTube(_ id: YouTubeVideoID, allowSurround: Bool, reason: String) {
        AppLogger.youtube.info("Resolving the video again: \(reason, privacy: .public)")
        playbackRenderer = .resolving
        youTubeRefreshTask?.cancel()
        youTubeRefreshTask = Task { [weak self] in
            do {
                let resolution = try await YouTubeResolver.resolve(id, allowSurround: allowSurround)
                guard let self, !Task.isCancelled, self.youTubeID == id else { return }
                if self.currentTime > 1 {
                    self.carryPositionToNextRenderer(reason: "YouTube stream reopened")
                    self.streamSwitchStart = self.currentTime
                }
                self.video.streamURL = resolution.video.streamURL
                self.resolvePlaybackRenderer()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.reportPlaybackFailure(error.localizedDescription)
            }
        }
    }

    /// Skips an auto-skip SponsorBlock segment the playhead just entered.
    func autoSkipYouTubeSegmentIfNeeded() {
        guard youTubeID != nil, !isScrubbing,
              let hit = segmentSkipper.autoSkip(at: currentTime) else { return }
        skip(hit.segment)
        showQualityNotice("Skipped \(hit.label)")
    }
}

#endif
