/*
 Hypnos - what the video window does differently for a YouTube video
 (sideload builds only: `HYPNOS_YOUTUBE`)

 Four things, everything else is the ordinary stream path:

 - **Expired streams.** A restored window carries a YouTube HLS URL that
   expires after ~6 h, or a loopback master from an earlier launch. `start()`
   resolves the video again before the renderer probes it, so a stale URL
   never reaches the probe (which would route it to WebKit).
 - **Renditions.** The master is read for the sizes the video has
   (`YouTubeRenditions`), which the Quality menu lists. A chosen one plays a
   copy of the master holding only it, from the start when the saved
   preference names one (the renderer waits for the copy), or swapped in at
   the playhead when picked; Auto plays the whole master.
 - **Surround that doesn't play.** If the spliced surround master won't open
   (the probe says undecodable, or the native player fails), the window
   reopens the video with YouTube's own stereo at the playhead rather than
   falling back to WebKit.
 - **SponsorBlock auto-skip** (`MediaSegmentSkipper.autoSkip`), announced by
   the undo button under the window.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation

extension VideoWindowModel {
    var youTubeID: YouTubeVideoID? { YouTubeVideoID(videoIdentity: video.identity) }

    /// Called by `start()`; true when it has taken over resolving the
    /// renderer (a stream to resolve again, or a rendition to cut first).
    func prepareYouTubeStream() -> Bool {
        guard let id = youTubeID else { return false }
        if YouTubeResolver.needsRefresh(video.streamURL) {
            reopenYouTube(id, allowSurround: true, reason: "the stream URL expired")
            return true
        }
        // A copy cut earlier this launch (a popped-out window): its master.
        let master = YouTubeRenditions.source(of: video.streamURL) ?? video.streamURL
        let waits = youTubeChosenHeight != nil || master != video.streamURL
        readYouTubeRenditions(master: master, resolvesRenderer: waits)
        return waits
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
                self.youTubeMaster = nil
                self.readYouTubeRenditions(master: resolution.video.streamURL, resolvesRenderer: true)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.reportPlaybackFailure(error.localizedDescription)
            }
        }
    }

    /// Reads the renditions `master` offers, settles the choice on one the
    /// video has, and plays it. With `resolvesRenderer` the renderer was
    /// held for this and is resolved after; otherwise a change of stream is
    /// a swap at the playhead.
    private func readYouTubeRenditions(master: URL, resolvesRenderer: Bool) {
        youTubeRenditionTask?.cancel()
        youTubeRenditionTask = Task { [weak self] in
            let text = await Self.playlistText(at: master)
            guard let self, !Task.isCancelled else { return }
            let renditions = text.map(YouTubeRenditions.parse) ?? []
            if let text, !renditions.isEmpty {
                self.youTubeMaster = (master, text)
                self.youTubeRenditions = renditions
                if let chosen = self.youTubeChosenHeight {
                    // The highest the video has at or below the choice, else its lowest.
                    self.youTubeChosenHeight = renditions.first { $0.height <= chosen }?.height ?? renditions.last?.height
                }
                AppLogger.youtube.info("Renditions: \(renditions.map(\.title).joined(separator: ", "), privacy: .public); playing \(self.youTubeChosenHeight.map { "\($0)p" } ?? "Auto", privacy: .public)")
            } else {
                // Not a master (the backend's stream): nothing to choose.
                self.youTubeMaster = nil
                self.youTubeRenditions = []
                if self.video.streamURL != master { self.video.streamURL = master }
            }
            self.updatePictureResolutionCap()
            await self.playChosenYouTubeRendition(swapping: !resolvesRenderer)
            if resolvesRenderer, !Task.isCancelled { self.resolvePlaybackRenderer() }
        }
    }

    /// A playlist's text: from the loopback server when it's one of ours.
    private static func playlistText(at url: URL) async -> String? {
        if let served = LoopbackPlaylistServer.shared.playlist(at: url) { return served }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            AppLogger.youtube.error("Couldn't read the HLS master for its renditions: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    /// Points the window at the chosen rendition's copy of the master, or
    /// the whole master for Auto. `swapping` keeps the playhead, as a
    /// quality change does.
    private func playChosenYouTubeRendition(swapping: Bool) async {
        guard let master = youTubeMaster else { return }
        var target = master.url
        if let height = youTubeChosenHeight {
            if let copy = await YouTubeRenditions.publish(master.text, from: master.url, keepingHeight: height) {
                target = copy
            } else {
                AppLogger.youtube.error("Couldn't serve the \(height, privacy: .public)p rendition; playing the whole master")
            }
        }
        guard target != video.streamURL, youTubeMaster?.url == master.url else { return }
        if swapping, currentTime > 1 {
            carryPositionToNextRenderer(reason: "YouTube quality change")
            streamSwitchStart = currentTime
        }
        stallMonitor.noteStepped(at: .now)
        video.streamURL = target
    }

    // MARK: Quality

    /// The size playing under Auto, as the menu names it ("1080p").
    private var youTubePlayingHeight: Int? {
        if let size = pictureSize {
            return YouTubeRenditions.sizeClass(width: Int(size.width), height: Int(size.height))
        }
        return youTubeAutoHeight
    }

    /// What the quality control reads: the rendition chosen, or Auto and
    /// what it plays ("Auto · 1080p").
    var youTubeQualityLabel: String {
        if let height = youTubeChosenHeight { return YouTubeRendition.badge(height) }
        return "Auto" + (youTubePlayingHeight.map { " · \(YouTubeRendition.badge($0))" } ?? "")
    }

    /// The same, short, for the bar's badge: what is playing ("1080p", "4K").
    var youTubeQualityBadge: String {
        if let height = youTubeChosenHeight ?? youTubePlayingHeight { return YouTubeRendition.badge(height) }
        return "Auto"
    }

    /// The viewer picked a rendition (nil: Auto): remembered for every
    /// YouTube video (the nearest level at or below it), and played now,
    /// swapped in at the playhead.
    func setYouTubeQuality(height: Int?) {
        guard height != youTubeChosenHeight else { return }
        YouTubeQuality.preferred = height.map(YouTubeQuality.level(height:)) ?? .auto
        youTubeChosenHeight = height
        youTubeAutoHeight = nil
        dismissQualityNotice()
        AppLogger.youtube.info("Quality set to \(height.map { "\($0)p" } ?? "Auto", privacy: .public)")
        updatePictureResolutionCap()
        // Still reading the master: that applies the choice when it's done.
        guard youTubeMaster != nil else { return }
        youTubeSwapTask?.cancel()
        youTubeSwapTask = Task { [weak self] in
            await self?.playChosenYouTubeRendition(swapping: true)
        }
    }

    /// 3D can't keep up with a YouTube picture `pictureHeight` high: under
    /// Auto, cap it at 1080p (1440p still dropped frames on a Vision Pro).
    /// False when it didn't step, and the window gives its advice instead.
    func stepYouTubeDownFor3D(pictureHeight: Int) -> Bool {
        guard youTubeID != nil, youTubeChosenHeight == nil else { return false }
        let current = youTubeAutoHeight ?? (pictureHeight > 0 ? pictureHeight : 2160)
        guard current > 1080 else { return false }
        let next = 1080
        AppLogger.youtube.info("3D couldn't keep up at \(current, privacy: .public) lines; capping at \(next, privacy: .public)p")
        youTubeAutoHeight = next
        updatePictureResolutionCap()
        showQualityNotice("Quality lowered to \(next)p so 3D plays smoothly")
        return true
    }

    /// Skips an auto-skip SponsorBlock segment the playhead just entered;
    /// the undo button under the window says so.
    func autoSkipYouTubeSegmentIfNeeded() {
        guard youTubeID != nil, !isScrubbing,
              let hit = segmentSkipper.autoSkip(at: currentTime) else { return }
        skip(hit.segment, name: hit.label)
    }
}

#endif
