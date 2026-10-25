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
   the playhead when picked; Auto plays the whole master, or a copy of it
   without the SDR variants when the video is HDR and the device shows it.
 - **Surround.** The video starts at once in YouTube's stereo. Meanwhile
   `YouTubeSurround` finds its 5.1 track, which YouTube holds back until its
   pre-roll ad's time has passed (5-20 s); then the track is spliced into the
   master (`YouTubeManifestComposer`) and swapped in at the playhead, the
   way a quality change is. If the spliced master won't open (the probe says
   undecodable, or the native player fails), the window reopens the video
   with stereo at the playhead rather than falling back to WebKit.
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
            reopenYouTube(id, reason: "the stream URL expired")
            return true
        }
        // A copy cut earlier this launch (a popped-out window): its master.
        let master = YouTubeRenditions.source(of: video.streamURL) ?? video.streamURL
        // Auto waits too where HDR may need cutting: the master isn't read yet.
        let waits = youTubeChosenHeight != nil || master != video.streamURL || YouTubeRenditions.prefersHDR
        readYouTubeRenditions(master: master, resolvesRenderer: waits)
        return waits
    }

    /// True when the window is replaying its rendition without HDR: the
    /// native player failed on the HDR cut, which then stays off on this OS.
    /// Never falls through to WebKit for that, which plays the same cut in
    /// SDR and reports its picture late.
    func dropYouTubeHDR(reason: String) -> Bool {
        guard youTubeID != nil, let master = youTubeMaster,
              YouTubeRenditions.offersHDR(master.text) else { return false }
        AppLogger.youtube.info("Playing SDR instead: \(reason, privacy: .public)")
        YouTubeRenditions.noteHDRRefused()
        youTubeRenditions = YouTubeRenditions.parse(master: master.text, preferringHDR: false)
        youTubeSwapTask?.cancel()
        youTubeSwapTask = Task { [weak self] in
            await self?.playChosenYouTubeRendition(swapping: true)
            self?.resolvePlaybackRenderer()
        }
        return true
    }

    /// True when the window is reopening the video without surround.
    func dropYouTubeSurround(reason: String) -> Bool {
        guard let id = youTubeID, YouTubeResolver.isSurroundStream(video.streamURL) else { return false }
        youTubeSurroundRefused = true
        reopenYouTube(id, reason: reason)
        return true
    }

    private func reopenYouTube(_ id: YouTubeVideoID, reason: String) {
        AppLogger.youtube.info("Resolving the video again: \(reason, privacy: .public)")
        playbackRenderer = .resolving
        youTubeRefreshTask?.cancel()
        youTubeRefreshTask = Task { [weak self] in
            do {
                let resolution = try await YouTubeResolver.resolve(id)
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
            let text = await YouTubeRenditions.playlistText(at: master)
            guard let self, !Task.isCancelled else { return }
            let renditions = text.map { YouTubeRenditions.parse(master: $0) } ?? []
            if let text, !renditions.isEmpty {
                self.youTubeMaster = (master, text)
                self.youTubeRenditions = renditions
                if let chosen = self.youTubeChosenHeight {
                    // The highest the video has at or below the choice, else its lowest.
                    self.youTubeChosenHeight = renditions.first { $0.height <= chosen }?.height ?? renditions.last?.height
                }
                AppLogger.youtube.info("Renditions: \(renditions.map(\.title).joined(separator: ", "), privacy: .public); playing \(self.youTubeChosenHeight.map { "\($0)p" } ?? "Auto", privacy: .public)\(YouTubeRenditions.offersHDR(text) ? " in HDR" : "", privacy: .public)")
            } else {
                // Not a master (the backend's stream): nothing to choose.
                self.youTubeMaster = nil
                self.youTubeRenditions = []
                if self.video.streamURL != master { self.video.streamURL = master }
            }
            self.updatePictureResolutionCap()
            await self.playChosenYouTubeRendition(swapping: !resolvesRenderer)
            if resolvesRenderer, !Task.isCancelled { self.resolvePlaybackRenderer() }
            if !Task.isCancelled { self.startYouTubeSurround() }
        }
    }

    /// Finds the video's 5.1 track and, once YouTube lets it play, swaps the
    /// master with it spliced in at the playhead. Only from YouTube's own
    /// master, not one already spliced or the backend's stream.
    private func startYouTubeSurround() {
        guard YouTubeSurround.isEnabled, !youTubeSurroundRefused, let id = youTubeID,
              let master = youTubeMaster, master.url.host != "127.0.0.1" else { return }
        youTubeSurroundTask?.cancel()
        youTubeSurroundTask = Task { [weak self] in
            defer { if !Task.isCancelled { self?.youTubeSurroundTask = nil } }
            guard let surround = await YouTubeSurround.audio(for: id),
                  let composed = YouTubeManifestComposer.compose(master: master.text, surround: surround),
                  let url = await LoopbackPlaylistServer.shared.publish(composed) else { return }
            guard let self, !Task.isCancelled, self.youTubeID == id, self.youTubeMaster?.url == master.url,
                  !self.youTubeSurroundRefused else { return }
            AppLogger.youtube.info("Switching to \(surround.channels, privacy: .public)-channel \(surround.codecs, privacy: .public) at \(self.currentTime, format: .fixed(precision: 1), privacy: .public) s")
            self.youTubeMaster = (url, composed)
            await self.playChosenYouTubeRendition(swapping: true)
        }
    }

    /// Points the window at the chosen rendition's copy of the master, or
    /// the whole master for Auto (a copy without its SDR variants for an
    /// HDR video on a device that shows HDR). `swapping` keeps the playhead,
    /// as a quality change does.
    private func playChosenYouTubeRendition(swapping: Bool) async {
        guard let master = youTubeMaster else { return }
        var target = master.url
        let height = youTubeChosenHeight
        let hdr = YouTubeRenditions.prefersHDR
        if height != nil || YouTubeRenditions.offersHDR(master.text, preferringHDR: hdr) {
            if let copy = await YouTubeRenditions.publish(master.text, from: master.url, keepingHeight: height,
                                                          preferringHDR: hdr) {
                target = copy
            } else {
                AppLogger.youtube.error("Couldn't serve the \(height.map { "\($0)p" } ?? "HDR", privacy: .public) rendition; playing the whole master")
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
