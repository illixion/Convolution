/*
 On-screen text: reading a playing video ahead of its playhead.

 The words have to be known before they appear, so a narrator can start on
 time and pace a line to the time it has. The picture the viewer sees can't
 be read ahead: holding decoded frames for seconds runs out of memory (ten
 seconds of 1080p frames once pushed a headset into critical memory pressure,
 `hypnos-video-window.md`, Smooth Motion), and AVPlayer decodes only a few
 frames ahead of what it shows.

 So a second, muted player (the scout) plays the same asset at a low
 resolution (an HLS stream's 480p variant; 360p and 480p read every subtitle
 the 720p picture did) and runs about eight seconds ahead: twice the speed
 until it is there, then the main player's speed, paused if it gets too far
 ahead or the reader falls behind. Five frames a second of it are read
 (`OnScreenTextRecognizer`) and become cues (`OnScreenCueBuilder`).

 Like AI Captions (`RAVEGeneratedCaptions`), the host's transport is held
 while too little is read ahead (after a seek: until two seconds are), and a
 seek starts reading again from the new playhead.

 A progressive file is decoded at its own size, there being only one;
 a device remux (one variant) reads the source a second time near the
 scout's position.
 */

import AVFoundation
import CoreVideo
import Foundation
import Observation
import Vision

@MainActor @Observable
public final class OnScreenTextReader {
    public private(set) var cues: [OnScreenTextCue] = []
    public private(set) var status = ""
    public private(set) var error: String?
    public private(set) var enabled = false
    public private(set) var isBuffering = false
    /// Seconds of picture read ahead of the playhead.
    public private(set) var readAheadSeconds = 0.0
    /// Readiness relative to the resume target, for a progress bar.
    public private(set) var lookaheadProgress = 0.0
    /// Where subtitles are looked for. Changing it while reading starts again.
    public var region: OnScreenTextRegion = .bottom {
        didSet { if region != oldValue, enabled { start() } }
    }
    /// How far ahead the scout aims to be, in media seconds at 1x.
    public var leadSeconds = 8.0
    public var onChange: (() -> Void)?
    /// The recognizer is loaded (or gave up loading). Heavy model loads that
    /// compete with it for the Neural Engine wait for this.
    public var onRecognizerReady: (() -> Void)?
    /// The host holds sound and picture together while true.
    public var onBuffering: ((Bool) -> Void)?
    /// Code-defined diagnostics; never URLs or the text read.
    public var onDiagnostic: ((String) -> Void)?
    /// Every pass of the reading loop (~20 Hz): the player's playhead,
    /// whether it is playing and its speed. A narrator is driven from here.
    public var onTick: ((Double, Bool, Double) -> Void)?

    private weak var player: AVPlayer?
    private var scout: AVPlayer?
    private var scoutOutput: AVPlayerItemVideoOutput?
    private var task: Task<Void, Never>?
    private var analysis: OnScreenTextAnalysis?
    private var generation = UUID()
    private static let sampleInterval = 0.2

    public init() {}

    public var isBound: Bool { player != nil }

    /// The scout's state, for a debug readout: its time, rate, what it waits
    /// for, and whether a read or a seek is outstanding.
    public var scoutState: [String: String] {
        guard let scout, let item = scout.currentItem else { return ["scout": "none"] }
        return [
            "time": String(format: "%.2f", item.currentTime().seconds),
            "rate": String(format: "%.2f", scout.rate),
            "status": "\(item.status.rawValue)",
            "control": "\(scout.timeControlStatus.rawValue)",
            "waiting": scout.reasonForWaitingToPlay?.rawValue ?? "",
            "inFlight": "\(inFlight)",
            "seeking": "\(scoutSeeking)",
            "buffered": item.loadedTimeRanges.map { String(format: "%.1f-%.1f", $0.timeRangeValue.start.seconds, $0.timeRangeValue.end.seconds) }.joined(separator: ","),
        ]
    }

    public func bind(player: AVPlayer?) {
        guard self.player !== player else { return }
        let restart = enabled
        stop()
        self.player = player
        if restart, player != nil { start() }
    }

    public func start() {
        guard let player, let item = player.currentItem else { return }
        stop()
        enabled = true
        status = "Preparing text recognition…"
        let token = UUID(); generation = token
        let region = region
        let languages = Self.recognitionLanguages()
        let analysis = OnScreenTextAnalysis(region: region, sampleInterval: Self.sampleInterval, languages: languages)
        self.analysis = analysis
        task = Task { [weak self] in
            // The first recognition in a process loads Vision's model: 40 s
            // once on a Mac in a fresh process, and requests made meanwhile
            // can come back empty.
            let began = Date.now
            // Bounded: a warm-up that never returns (seen on a headset while
            // Kokoro's models were compiling) must not hold the reader on
            // "Preparing" for ever. Reading then starts anyway; a frame
            // that comes back empty is retried at `.fast`.
            let recognizer = analysis.recognizer
            // The accurate model loads on the side (minutes the first time on
            // a Vision Pro); frames are read at `.fast` until it has.
            Task.detached(priority: .utility) { recognizer.warmUpAccurate() }
            let finished = await Self.warmUp(recognizer, timeout: 20)
            guard let self, self.generation == token else { return }
            self.onDiagnostic?(String(format: "On-screen text: recognizer %@ after %.1f s", finished ? "ready" : "still loading, reading anyway", Date.now.timeIntervalSince(began)))
            self.onRecognizerReady?()
            self.status = "Reading on-screen text…"
            await self.run(main: player, item: item, analysis: analysis, token: token)
        }
    }

    private nonisolated static func warmUp(_ recognizer: OnScreenTextRecognizer, timeout: Double) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            Task.detached {
                recognizer.warmUpFast()
                if once.take() { continuation.resume(returning: true) }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                if once.take() { continuation.resume(returning: false) }
            }
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        tearDownScout()
        scoutSeeking = false
        scoutAudioOff = false
        stuckSince = nil
        analysis = nil
        enabled = false
        cues = []; status = ""; error = nil
        readAheadSeconds = 0; lookaheadProgress = 0
        setBuffering(false)
        onChange?()
    }

    // MARK: The loop

    private func run(main: AVPlayer, item: AVPlayerItem, analysis: OnScreenTextAnalysis, token: UUID) async {
        var playhead = main.currentTime().seconds.finiteOrZero
        var lastWall = Date.now
        var nextSample = playhead
        var samplesSinceForced = 0
        inFlight = false
        var holdingSince: Date?
        reportedFrames = false
        stallRecoveries = 0
        startScout(asset: item.asset, at: playhead)
        await analysis.restart(at: playhead)

        while !Task.isCancelled, generation == token, main.currentItem === item {
            let now = main.currentTime().seconds.finiteOrZero
            let playing = main.rate > 0
            let speed = Double(main.defaultRate > 0 ? main.defaultRate : 1)
            let elapsed = Date.now.timeIntervalSince(lastWall)
            let expected = playhead + elapsed * (playing ? speed : 0)
            // A seek, not drift: the same test AI Captions uses.
            if now < playhead - 0.25 || abs(now - expected) > max(0.75, elapsed * 0.5) {
                onDiagnostic?("On-screen text: playhead moved, reading again from there")
                nextSample = now
                inFlight = false
                await analysis.restart(at: now)
                seekScout(to: now)
            }
            playhead = now; lastWall = .now
            onTick?(now, playing, speed)

            guard let scout, let output = scoutOutput, let scoutItem = scout.currentItem else { break }
            if scoutItem.status == .failed {
                fail("The video couldn't be read for on-screen text.", code: (scoutItem.error as NSError?)?.code ?? 0)
                return
            }
            let scoutTime = scoutItem.currentTime().seconds.finiteOrZero
            if scoutItem.status == .readyToPlay, !scoutAudioOff { await silenceScout(scoutItem) }
            // A clock that stops while the scout says it plays (seen on a Mac
            // once the narration's audio engine started): seek it on.
            if scout.rate > 0, !scoutSeeking, scout.timeControlStatus == .playing {
                if abs(scoutTime - lastScoutTime) < 0.001 {
                    if stuckSince == nil { stuckSince = .now }
                    if Date.now.timeIntervalSince(stuckSince!) > 1 {
                        onDiagnostic?("On-screen text: scout clock stopped, seeking it on")
                        stuckSince = nil
                        seekScout(to: scoutTime + 0.1, keepingReadThrough: true)
                    }
                } else { stuckSince = nil }
            } else { stuckSince = nil }
            lastScoutTime = scoutTime
            // Fell behind the playhead (a stall, or the reader too slow):
            // jump a second past it. Once: the scout's clock reads the old
            // time until the seek lands.
            if scoutItem.status == .readyToPlay, !scoutSeeking, scoutTime < now - 0.5, !inFlight {
                onDiagnostic?(String(format: "On-screen text: scout %.1f s behind, jumping ahead", now - scoutTime))
                nextSample = now + 1
                await analysis.restart(at: now + 1)
                seekScout(to: now + 1)
            }

            // Read the frame due, one at a time.
            if !inFlight, !scoutSeeking, scoutTime >= nextSample,
               output.hasNewPixelBuffer(forItemTime: scoutItem.currentTime()),
               let buffer = output.copyPixelBuffer(forItemTime: scoutItem.currentTime(), itemTimeForDisplay: nil) {
                inFlight = true
                samplesSinceForced += 1
                let force = samplesSinceForced >= 5
                if force { samplesSinceForced = 0 }
                let frame = OnScreenPixelBuffer(buffer: buffer)
                let time = scoutTime
                // Behind schedule (a slow read): skip ahead rather than queue.
                nextSample = max(nextSample + Self.sampleInterval, scoutTime + Self.sampleInterval * 0.5)
                Task { [weak self] in
                    let result = await analysis.read(frame, at: time, force: force)
                    guard let self, self.generation == token else { return }
                    self.inFlight = false
                    if !self.reportedFrames { self.reportedFrames = true; self.onDiagnostic?("On-screen text: reading frames") }
                    if let failure = result.failure { self.onDiagnostic?("On-screen text: a frame failed (\(failure))") }
                    if result.cues != self.cues {
                        self.cues = result.cues
                        self.onChange?()
                    }
                    self.readThrough = result.readThrough
                }
            }

            // Pace the scout: catch up at 2x, keep pace, pause when far
            // enough ahead or while the reader is behind it.
            let ahead = scoutTime - now
            let target = leadSeconds * max(1, speed)
            // Half a second behind already costs samples (a cue's start
            // lands later): wait for the reader.
            let readerBehind = inFlight && scoutTime - nextSample > 0.5
            let desired: Float
            if scoutItem.status != .readyToPlay || scoutSeeking || readerBehind || ahead > target + 1 { desired = 0 }
            else if ahead < target { desired = 2 }
            else { desired = playing ? Float(speed) : 0 }
            if scout.rate != desired { scout.rate = desired }

            // Hold the viewer's playback while too little is read ahead.
            readAheadSeconds = max(0, readThrough - now)
            let policy = OnScreenTextBufferPolicy()
            lookaheadProgress = min(1, readAheadSeconds / (policy.resumeSeconds * max(0.25, speed)))
            let duration = item.duration.seconds
            let needsHold = policy.needsHold(playhead: now, readThrough: readThrough, duration: duration,
                                             rate: speed, alreadyHolding: isBuffering)
            if needsHold {
                holdingSince = holdingSince ?? .now
                if Date.now.timeIntervalSince(holdingSince!) > Self.holdLimit {
                    // The reader stalled (a frame that never came back, a scout
                    // that stopped). Say what state it was in, then start it
                    // again at the playhead; only a second stall in a row fails.
                    onDiagnostic?(String(format: "On-screen text: stalled %.0f s: scout %.1f, playhead %.1f, read through %.1f, in flight %d, seeking %d, rate %.1f, item %d",
                                         Self.holdLimit, scoutTime, now, readThrough, inFlight ? 1 : 0,
                                         scoutSeeking ? 1 : 0, scout.rate, scoutItem.status.rawValue))
                    stallRecoveries += 1
                    if stallRecoveries > 2 {
                        fail("On-screen text couldn't be read quickly enough to keep up with the video.", code: 0)
                        return
                    }
                    holdingSince = nil
                    inFlight = false
                    nextSample = now + 1
                    await analysis.restart(at: now + 1)
                    seekScout(to: now + 1)
                    continue
                }
            } else { holdingSince = nil; stallRecoveries = 0 }
            setBuffering(needsHold)
            status = needsHold ? "Reading ahead…" : "On-Screen Text"
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// How long the viewer's video may be held for reading before the reader is restarted.
    private static let holdLimit = 15.0
    private var stallRecoveries = 0
    private var readThrough = 0.0
    private var inFlight = false
    private var scoutSeeking = false
    private var scoutAudioOff = false
    private var lastScoutTime = -1.0
    private var stuckSince: Date?
    private var reportedFrames = false

    private func fail(_ message: String, code: Int) {
        onDiagnostic?("On-screen text: failed (code \(code)); read ahead \(readAheadSeconds)")
        stop()
        error = message
        status = "On-screen text failed"
    }

    private func setBuffering(_ value: Bool) {
        guard isBuffering != value else { return }
        isBuffering = value
        onBuffering?(value)
    }

    // MARK: The scout

    private func startScout(asset: AVAsset, at time: Double) {
        tearDownScout()
        scoutAudioOff = false
        let item = AVPlayerItem(asset: asset)
        // An HLS stream's smallest legible variant; a file plays at its size.
        item.preferredMaximumResolution = CGSize(width: 854, height: 480)
        item.preferredForwardBufferDuration = 10
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let scout = AVPlayer(playerItem: item)
        scout.isMuted = true
        scout.volume = 0
        #if !os(visionOS)
        scout.allowsExternalPlayback = false
        scout.preventsDisplaySleepDuringVideoPlayback = false
        #endif
        scout.automaticallyWaitsToMinimizeStalling = true
        #if os(iOS) || os(visionOS) || os(tvOS)
        scout.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        #endif
        self.scout = scout
        scoutOutput = output
        readThrough = time
        seekScout(to: time)
    }

    /// The scout needs no sound: its audio tracks (a file) or audible
    /// option (HLS, where the group allows none) are switched off, so its
    /// clock doesn't hang on an audio output.
    private func silenceScout(_ item: AVPlayerItem) async {
        scoutAudioOff = true
        for track in item.tracks where track.assetTrack?.mediaType == .audio { track.isEnabled = false }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), group.allowsEmptySelection {
            item.select(nil, in: group)
        }
    }

    private func seekScout(to time: Double, keepingReadThrough: Bool = false) {
        if !keepingReadThrough { readThrough = time }
        guard let scout else { return }
        scout.rate = 0
        scoutSeeking = true
        let token = generation
        scout.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                   toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.scoutSeeking = false
            }
        }
    }

    private func tearDownScout() {
        scout?.pause()
        scout?.replaceCurrentItem(with: nil)
        scout = nil
        scoutOutput = nil
    }

    /// The viewer's languages that Vision reads (in Vision's spelling,
    /// "en-US"), else nil for Vision's default.
    private static func recognitionLanguages() -> [String]? {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        var chosen: [String] = []
        for language in Locale.preferredLanguages {
            let base = String(language.lowercased().prefix(2))
            let exact = supported.first { $0.caseInsensitiveCompare(language) == .orderedSame }
            let near = supported.first { $0.lowercased().hasPrefix(base + "-") || $0.lowercased() == base }
            if let match = exact ?? near, !chosen.contains(match) { chosen.append(match) }
        }
        return chosen.isEmpty ? nil : chosen
    }
}

/// Media seconds read ahead the viewer's playback needs. Lighter than AI
/// Captions' policy (2.5 s to resume): after a seek the scout has to load
/// before it can catch up, and every second of hold is a second of waiting.
struct OnScreenTextBufferPolicy {
    var resumeSeconds = 2.0
    var lowWaterSeconds = 0.3
    func needsHold(playhead: Double, readThrough: Double, duration: Double, rate: Double, alreadyHolding: Bool) -> Bool {
        guard playhead.isFinite else { return false }
        let speed = max(0.25, rate.isFinite ? rate : 1)
        let remaining = duration.isFinite && duration > 0 ? max(0, duration - playhead) : .infinity
        let reserve = (alreadyHolding ? resumeSeconds : lowWaterSeconds) * speed
        return readThrough - playhead + 0.001 < min(reserve, remaining)
    }
}

/// A decoded frame handed to the reader; never shared after that.
struct OnScreenPixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Vision and the cue builder, off the main actor.
actor OnScreenTextAnalysis {
    struct Result: Sendable {
        var cues: [OnScreenTextCue]
        var readThrough: Double
        var failure: Int?
    }

    nonisolated let recognizer: OnScreenTextRecognizer
    private var builder: OnScreenCueBuilder
    private let region: OnScreenTextRegion

    init(region: OnScreenTextRegion, sampleInterval: Double, languages: [String]?) {
        self.region = region
        recognizer = OnScreenTextRecognizer(languages: languages)
        builder = OnScreenCueBuilder(configuration: .init(region: region, sampleInterval: sampleInterval))
    }

    func restart(at time: Double) {
        recognizer.reset()
        builder.restart(at: time)
    }

    func read(_ frame: OnScreenPixelBuffer, at time: Double, force: Bool) -> Result {
        var failure: Int?
        do {
            let lines = try recognizer.read(frame.buffer, region: region, force: force)
            builder.add(OnScreenTextFrame(time: time, lines: lines))
        } catch {
            failure = (error as NSError).code
            builder.add(OnScreenTextFrame(time: time, lines: []))
        }
        return Result(cues: builder.cues, readThrough: builder.readThrough, failure: failure)
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
}
