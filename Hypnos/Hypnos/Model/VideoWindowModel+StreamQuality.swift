/*
 Hypnos - Video Window: streaming quality for Library titles

 The window plays a Jellyfin title at the level `qualityPreference` asks
 for. Picking another level swaps the stream at the playhead, the same way a
 renewed play session does (`video.streamURL` changes, the position is
 carried). With `auto`, `StreamStallMonitor` watches the player's buffering
 and steps the stream down a level when it can't keep up, and the ornament
 says so (`qualityNotice`). `original` never steps.
 */

import CoreGraphics
import DebugTrace
import Foundation
import RAVEMedia

extension VideoWindowModel {
    /// The title is a server stream whose quality can change: a Library
    /// title, not a download playing from the device.
    var offersQualityChoice: Bool {
        libraryItemId != nil && !video.streamURL.isFileURL
    }

    /// The capped level now playing; nil is the original.
    var streamLevel: LibraryStreamQuality? {
        LibraryStreamQuality.level(ofStream: video.streamURL)
    }

    /// What the quality control reads: the choice, and under Auto the level
    /// it has stepped down to.
    var qualityLabel: String {
        if qualityPreference == .auto, let level = streamLevel {
            return "Auto · \(level.shortTitle)"
        }
        return qualityPreference.shortTitle
    }

    /// What is in force, short, for the bar's badge: the level playing
    /// ("720p"; "1080p" for either 1080p cap), or the choice when that is
    /// the original.
    var qualityBadge: String {
        let shown = streamLevel ?? qualityPreference
        return shown.maxHeight == 1080 ? "1080p" : shown.shortTitle
    }

    /// The viewer picked `quality`: remember it for every title, and swap
    /// this one's stream if it changes what plays.
    func setQuality(_ quality: LibraryStreamQuality) {
        guard quality != qualityPreference || isChangingQuality else { return }
        qualityPreference = quality
        ai3DAutoCappedLibrary = false
        LibraryStreamQuality.preferred = quality
        dismissQualityNotice()
        let target: LibraryStreamQuality? = quality.maxBitrate == nil ? nil : quality
        guard target != streamLevel else { return }
        switchStream(to: target, reason: "chosen")
    }

    // MARK: Buffering

    /// A playback report's waiting state. Reports only arrive on a change of
    /// state or while time advances, so a stall is polled once a second
    /// until it ends.
    func noteBuffering(_ waiting: Bool) {
        guard waiting != isBuffering else { return }
        isBuffering = waiting
        evaluateStall()
        stallPollTask?.cancel()
        guard waiting else { return }
        stallPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isBuffering else { return }
                self.evaluateStall()
            }
        }
    }

    private var adaptsQuality: Bool {
        qualityPreference == .auto && offersQualityChoice && !isChangingQuality
            && !usesImmersiveStereo && playbackFailure == nil
    }

    private func evaluateStall() {
        guard adaptsQuality else { return }
        if stallMonitor.update(waiting: isBuffering, at: .now) {
            stepDownQuality(reason: "kept stalling")
        }
    }

    /// A first frame should show within `StreamStallMonitor.startupTimeout`;
    /// under Auto a stream that hasn't started by then steps down.
    func armStartupQualityWatch() {
        startupQualityTask?.cancel()
        guard offersQualityChoice else { return }
        startupQualityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StreamStallMonitor.startupTimeout))
            guard !Task.isCancelled, let self, self.adaptsQuality, !self.hasPresentedVideo else { return }
            self.stepDownQuality(reason: "didn't start")
        }
    }

    private func stepDownQuality(reason: String) {
        guard let itemId = libraryItemId, let library = LibraryService.current() else { return }
        isChangingQuality = true
        qualitySwitchTask?.cancel()
        qualitySwitchTask = Task { [weak self] in
            guard let self else { return }
            let bitrate: Int?
            if let known = self.sourceBitrate, known.itemId == itemId {
                bitrate = known.bitrate
            } else {
                bitrate = await library.sourceBitrate(itemId: itemId)
                self.sourceBitrate = (itemId, bitrate)
            }
            guard !Task.isCancelled, self.libraryItemId == itemId else { return }
            guard let next = LibraryStreamQuality.stepDown(from: self.streamLevel, sourceBitrate: bitrate) else {
                self.isChangingQuality = false
                self.stallMonitor.noteStepped(at: .now)
                AppLogger.videoWindow.info("Stream \(reason, privacy: .public) at the lowest quality; nothing lower to try")
                self.showQualityNotice("Still buffering at the lowest quality")
                return
            }
            AppLogger.videoWindow.info("Auto quality: stream \(reason, privacy: .public) at \(self.streamLevel?.rawValue ?? "original", privacy: .public); stepping down to \(next.rawValue, privacy: .public)")
            self.isChangingQuality = false
            self.switchStream(to: next, reason: "auto")
            self.showQualityNotice("Quality lowered to \(next.title) to keep playing")
        }
    }

    /// Replaces the stream with one at `level` (nil: the original), at the
    /// playhead.
    func switchStream(to level: LibraryStreamQuality?, reason: String, forAI3D: Bool = false) {
        guard let itemId = libraryItemId, let library = LibraryService.current() else { return }
        isChangingQuality = true
        qualitySwitchTask?.cancel()
        qualitySwitchTask = Task { [weak self] in
            defer { self?.isChangingQuality = false }
            do {
                let plan = try await library.streamPlan(
                    itemId: itemId, quality: level ?? .original, forAI3D: forAI3D)
                guard !Task.isCancelled, let self, self.libraryItemId == itemId else { return }
                self.sourceBitrate = (itemId, plan.sourceBitrate)
                guard plan.streamURL != self.video.streamURL else {
                    self.resumePendingPseudo3DEngage()
                    return
                }
                AppLogger.videoWindow.info("Switching to \(plan.quality?.rawValue ?? "original", privacy: .public) quality (\(reason, privacy: .public)) at \(self.currentTime, format: .fixed(precision: 2))s")
                self.carryPositionToNextRenderer(reason: "quality change")
                self.streamSwitchStart = self.currentTime
                self.stallMonitor.noteStepped(at: .now)
                // Direct play and HLS can resolve to different renderers.
                let needsRenderer = plan.streamURL.pathExtension != self.video.streamURL.pathExtension
                    || self.usingTranscodedStream
                // The reserve transcode belongs to the stream it backs up.
                self.usingTranscodedStream = false
                self.video.transcodeStreamURL = plan.transcodeURL
                self.video.streamURL = plan.streamURL
                if needsRenderer {
                    self.resolvePlaybackRenderer()
                } else {
                    self.resumePendingPseudo3DEngage()
                }
                self.armStartupQualityWatchIfNoPicture()
            } catch {
                AppLogger.videoWindow.error("Quality change failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                self?.resumePendingPseudo3DEngage()
                self?.showQualityNotice("Couldn't change quality")
            }
        }
    }

    /// A switch made before the first frame gets its own startup window.
    private func armStartupQualityWatchIfNoPicture() {
        if !hasPresentedVideo { armStartupQualityWatch() }
    }

    // MARK: 3D load

    /// A stereo picture (AI 3D or live 3D) just appeared: its first seconds
    /// include model loading and the first decode, so they don't count.
    func stereoPictureStarted() {
        stereoLoadStrikes = 0
        stereoLoadGraceUntil = .now.addingTimeInterval(5)
    }

    /// The stereo pump's report every couple of seconds. Three overloaded
    /// reports in a row (about 6 s of visible stutter) are acted on: under
    /// Auto, a stream above 1080p steps to 1080p, since the conversion's
    /// cost follows the picture's size; otherwise the viewer is told once
    /// what would help.
    func noteStereoPerformance(_ sample: StereoPerformance) {
        // Faster than 1× the source passes more frames than the eyes can
        // show (a 60 fps video at 2× is 120 a second), which reads as an
        // overload that a lower quality wouldn't cure.
        guard showsStereoPicture, !isPaused, !isScrubbing, !isChangingQuality, playbackSpeed <= 1,
              Date.now >= stereoLoadGraceUntil, sample.isOverloaded,
              !isRealtimeAI3DSharingWithConversion else {
            stereoLoadStrikes = 0
            return
        }
        stereoLoadStrikes += 1
        AppLogger.videoWindow.info("Stereo picture dropping frames: \(Int(sample.deliveredFraction * 100), privacy: .public)% of \(sample.sourceFramesPerSecond, format: .fixed(precision: 1), privacy: .public) fps shown (\(self.stereoLoadStrikes, privacy: .public)/3)")
        guard stereoLoadStrikes >= 3 else { return }
        stereoLoadStrikes = 0
        stereoLoadGraceUntil = .now.addingTimeInterval(20)

        #if HYPNOS_YOUTUBE
        if stepYouTubeDownFor3D(pictureHeight: sample.sourceHeight) { return }
        #endif
        // Straight to 1080p, never below: on a Vision Pro 1440p still
        // dropped frames in 3D, and below 1080p 3D isn't worth the picture.
        if offersQualityChoice, qualityPreference == .auto, pictureHeight(sample) > 1080,
           let next = LibraryStreamQuality.smallerPicture(than: 1081, from: streamLevel) {
            AppLogger.videoWindow.info("3D couldn't keep up at \(self.streamLevel?.rawValue ?? "original", privacy: .public), \(sample.sourceHeight, privacy: .public) lines; stepping to \(next.rawValue, privacy: .public)")
            switchStream(to: next, reason: "3D couldn't keep up")
            showQualityNotice("Quality lowered to \(next.title) so 3D plays smoothly")
            return
        }
        guard stereoLoadAdvisedIdentity != video.identity else { return }
        stereoLoadAdvisedIdentity = video.identity
        let isAI3D = shouldUsePseudo3D
        var choosesQuality = offersQualityChoice
        #if HYPNOS_YOUTUBE
        if youTubeID != nil { choosesQuality = true }
        #endif
        let advice: String
        if choosesQuality {
            advice = "3D can't keep up with this video. Choose a lower quality for smooth playback."
        } else if isAI3D, case .realtime = pseudo3DDepthMode {
            advice = "AI 3D can't keep up with this video. Choose AI 3D (Pre-Processed) for smooth 3D."
        } else {
            advice = "3D can't keep up with this video's resolution."
        }
        showQualityNotice(advice)
    }

    /// Real-time AI 3D while this video's own conversion runs: the two share
    /// the Neural Engine until the converted depth takes over, so dropped
    /// frames are expected and short-lived, and a lower quality wouldn't
    /// cure them.
    private var isRealtimeAI3DSharingWithConversion: Bool {
        guard shouldUsePseudo3D, case .realtime = pseudo3DDepthMode else { return false }
        return DepthConversionManager.shared.isProcessing(videoIdentity: video.identity)
    }

    /// The picture's height: as the pump measured it, else what the level
    /// playing allows (the original counts as 4K).
    private func pictureHeight(_ sample: StereoPerformance) -> Int {
        if sample.sourceHeight > 0 { return sample.sourceHeight }
        return streamLevel?.maxHeight ?? 2160
    }

    // MARK: Notice

    func showQualityNotice(_ text: String) {
        qualityNotice = text
        qualityNoticeTask?.cancel()
        qualityNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.qualityNotice = nil
        }
    }

    func dismissQualityNotice() {
        qualityNoticeTask?.cancel()
        qualityNotice = nil
    }

    // MARK: Lifecycle

    /// A new title starts at the saved preference with a fresh watch.
    func resetStreamQualityState() {
        cancelStreamQualityTasks()
        qualityPreference = .preferred
        isChangingQuality = false
        isBuffering = false
        qualityNotice = nil
        stallMonitor = StreamStallMonitor()
        #if HYPNOS_YOUTUBE
        youTubeQuality = .preferred
        youTubeAutoHeight = nil
        #endif
        updatePictureResolutionCap()
    }

    /// The cap the players apply: YouTube's level, else none.
    func updatePictureResolutionCap() {
        var cap = CGSize.zero
        #if HYPNOS_YOUTUBE
        if youTubeID != nil {
            cap = YouTubeQuality.maximumResolution(height: youTubeQuality.height ?? youTubeAutoHeight)
        }
        #endif
        if cap != maximumPictureResolution { maximumPictureResolution = cap }
    }

    func cancelStreamQualityTasks() {
        stallPollTask?.cancel()
        qualityNoticeTask?.cancel()
        qualitySwitchTask?.cancel()
        startupQualityTask?.cancel()
    }
}
