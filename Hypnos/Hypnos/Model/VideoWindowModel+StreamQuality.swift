/*
 Hypnos - Video Window: streaming quality for Library titles

 The window plays a Jellyfin title at the level `qualityPreference` asks
 for. Picking another level swaps the stream at the playhead, the same way a
 renewed play session does (`video.streamURL` changes, the position is
 carried). With `auto`, `StreamStallMonitor` watches the player's buffering
 and steps the stream down a level when it can't keep up, and the ornament
 says so (`qualityNotice`). `original` never steps.
 */

import DebugTrace
import Foundation

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

    /// The viewer picked `quality`: remember it for every title, and swap
    /// this one's stream if it changes what plays.
    func setQuality(_ quality: LibraryStreamQuality) {
        guard quality != qualityPreference || isChangingQuality else { return }
        qualityPreference = quality
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
    private func switchStream(to level: LibraryStreamQuality?, reason: String) {
        guard let itemId = libraryItemId, let library = LibraryService.current() else { return }
        isChangingQuality = true
        qualitySwitchTask?.cancel()
        qualitySwitchTask = Task { [weak self] in
            defer { self?.isChangingQuality = false }
            do {
                let plan = try await library.streamPlan(itemId: itemId, quality: level ?? .original)
                guard !Task.isCancelled, let self, self.libraryItemId == itemId else { return }
                self.sourceBitrate = (itemId, plan.sourceBitrate)
                guard plan.streamURL != self.video.streamURL else { return }
                AppLogger.videoWindow.info("Switching to \(plan.quality?.rawValue ?? "original", privacy: .public) quality (\(reason, privacy: .public)) at \(self.currentTime, format: .fixed(precision: 2))s")
                self.carryPositionToNextRenderer(reason: "quality change")
                self.streamSwitchStart = self.currentTime
                self.stallMonitor.noteStepped(at: .now)
                // Direct play and HLS can resolve to different renderers.
                let needsRenderer = plan.streamURL.pathExtension != self.video.streamURL.pathExtension
                self.video.streamURL = plan.streamURL
                if needsRenderer { self.resolvePlaybackRenderer() }
                self.armStartupQualityWatchIfNoPicture()
            } catch {
                AppLogger.videoWindow.error("Quality change failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                self?.showQualityNotice("Couldn't change quality")
            }
        }
    }

    /// A switch made before the first frame gets its own startup window.
    private func armStartupQualityWatchIfNoPicture() {
        if !hasPresentedVideo { armStartupQualityWatch() }
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
    }

    func cancelStreamQualityTasks() {
        stallPollTask?.cancel()
        qualityNoticeTask?.cancel()
        qualitySwitchTask?.cancel()
        startupQualityTask?.cancel()
    }
}
