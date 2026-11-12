/*
 Hypnos - the music engine: `MusicTimeline`'s samples through an `AVSampleBufferAudioRenderer`.

 Every song of a run goes into one renderer as one continuous stream of sample buffers (the
 synchronizer's clock never stops between songs), so a gapless join is gapless at the speaker and a
 crossfade is mixed sample by sample before it gets there. The equalizer filters the mixed stream
 (one `EQProcessor`, like the HLS path's `EQStreamEngine`, whose renderer handling this follows).

 The clock: `lead` (0.4 s) of audio is kept with the renderer ahead of what is heard, topped up every
 20 ms from a serial queue. The synchronizer runs only while that much is there: it starts once the
 first `lead` is decoded, and stops (buffering) if the decoders fall behind, rather than letting the
 clock run past audio that isn't there yet. The timeline's markers turn the clock into a song and a
 position; when the heard song changes, the session hears `onSongStarted`.

 A route change that flushes the renderer (`wasFlushedAutomatically`) is answered by enqueueing again
 what was in flight from the flush time; a renderer that fails (media services reset) is replaced and
 the song carries on from where it was heard.
 */

import AVFoundation
import CoreMedia
import Foundation
import os

/// What filters the mixed output (the app's equalizer). The engine calls it on its own queue.
nonisolated protocol MusicSampleProcessor: AnyObject, Sendable {
    func configure(sampleRate: Double, channelCount: Int)
    func process(channel: Int, samples: UnsafeMutablePointer<Float>, count: Int, stride: Int)
}

nonisolated final class MusicPlaybackEngine: @unchecked Sendable {
    typealias Song = MusicTimeline.Song
    typealias Transition = MusicTimeline.Transition

    /// Seconds of audio kept with the renderer ahead of the clock.
    static let lead = 0.4
    static let chunkFrames = 2048

    // Main-actor callbacks.
    var onSongStarted: (@MainActor (UUID) -> Void)?
    /// The heard song, how far in it is, and its exact length once known.
    var onProgress: (@MainActor (UUID, Double, Double?) -> Void)?
    /// The last song has been heard to its end.
    var onFinished: (@MainActor (UUID) -> Void)?
    var onFailure: (@MainActor (UUID, String) -> Void)?
    /// The clock stopped to wait for audio (true) or started again (false).
    var onBuffering: (@MainActor (Bool) -> Void)?

    private var renderer = AVSampleBufferAudioRenderer()
    private var synchronizer = AVSampleBufferRenderSynchronizer()
    private let processor: MusicSampleProcessor?
    private let queue = DispatchQueue(label: "Hypnos.MusicEngine", qos: .userInteractive)
    private var flushObserver: NSObjectProtocol?

    // Queue state.
    private var timeline: MusicTimeline?
    private var timer: DispatchSourceTimer?
    private var playing = false
    private var clockRunning = false
    private var enqueuedFrames: Int64 = 0
    private var timelineDone = false
    private var finishedReported = false
    private var inFlight: [(start: Int64, frames: Int, buffer: CMSampleBuffer)] = []
    private var description: CMAudioFormatDescription?
    private var describedRate: Double = 0
    private var heardToken: UUID?
    private var lastProgress = Date.distantPast
    private var durations: [UUID: Double] = [:]
    private var buffering = false
    private var failedTokens: Set<UUID> = []
    /// Tokens the timeline has started, readable from the main actor.
    private let committed = OSAllocatedUnfairLock(initialState: [UUID]())

    // Mirrors of the main actor's settings, re-applied to a replacement renderer.
    private var volume: Float = 1
    private var muted = false
    #if os(visionOS)
    private var spatial: (any SpatialAudioExperience)?
    #endif

    init(processor: MusicSampleProcessor?) {
        self.processor = processor
        synchronizer.addRenderer(renderer)
        #if os(visionOS)
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        #endif
        observeFlushes()
    }

    deinit {
        timer?.cancel()
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
    }

    // MARK: - Controls (any thread)

    /// Plays `song` from `seconds`, dropping whatever was playing.
    func start(_ song: Song, at seconds: Double = 0, playing: Bool = true) {
        queue.async { [self] in
            reset()
            timeline = MusicTimeline(song: song, at: seconds)
            committed.withLock { $0 = [song.token] }
            heardToken = song.token
            self.playing = playing
            startTimer()
        }
    }

    /// What follows the song that `after` names. Ignored once the timeline is past it.
    func setNext(_ song: Song?, transition: Transition, after: UUID) {
        queue.async { [self] in
            guard let timeline else { return }
            // A song planned after the timeline ran out (the last one is still being heard) carries on from it.
            if timeline.setNext(song, transition: transition, after: after), song != nil, timelineDone, !finishedReported {
                timelineDone = false
            }
        }
    }

    /// Whether the output has already begun `token` (a join or a fade the session hasn't heard yet).
    func hasCommitted(_ token: UUID) -> Bool { committed.withLock { $0.contains(token) } }

    func setPlaying(_ value: Bool) {
        queue.async { [self] in
            playing = value
            if !value, clockRunning { stopClock() }
            tick()
        }
    }

    func seek(_ token: UUID, to seconds: Double) {
        queue.async { [self] in
            guard let timeline else { return }
            timeline.seek(token, to: max(0, seconds))
            committed.withLock { $0 = [token] }
            restartOutput()
            heardToken = token
            durations[token] = nil
        }
    }

    func setGain(_ gain: Float, for token: UUID) {
        queue.async { [self] in timeline?.setGain(gain, for: token) }
    }

    func setVolume(_ value: Float) {
        queue.async { [self] in volume = value; renderer.volume = value }
    }

    func setMuted(_ value: Bool) {
        queue.async { [self] in muted = value; renderer.isMuted = value }
    }

    #if os(visionOS)
    func setSpatialExperience(_ experience: any SpatialAudioExperience) {
        queue.async { [self] in
            spatial = experience
            synchronizer.intendedSpatialAudioExperience = experience
        }
    }
    #endif

    func stop() {
        queue.async { [self] in
            reset()
            committed.withLock { $0 = [] }
        }
    }

    // MARK: - Queue

    private func reset() {
        timer?.cancel()
        timer = nil
        timeline = nil
        restartOutput()
        durations = [:]
        failedTokens = []
        heardToken = nil
        playing = false
    }

    /// Empties the renderer and starts the clock over at zero (a new run, a seek).
    private func restartOutput() {
        renderer.flush()
        synchronizer.setRate(0, time: .zero)
        clockRunning = false
        enqueuedFrames = 0
        inFlight = []
        timelineDone = false
        finishedReported = false
        lastProgress = .distantPast
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private var rate: Double { timeline?.format?.sampleRate ?? 44_100 }

    /// The clock in output frames.
    private var heardFrame: Int64 {
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite ? Int64(max(0, seconds) * rate) : 0
    }

    private func tick() {
        guard let timeline else { return }
        if renderer.status == .failed {
            replaceRenderer()
            return
        }
        let heard = heardFrame
        let leadFrames = Int64(Self.lead * rate)

        // Top up the renderer.
        while !timelineDone, enqueuedFrames < heard + leadFrames, renderer.isReadyForMoreMediaData {
            let (samples, status) = timeline.render(maxFrames: Self.chunkFrames)
            if !samples.isEmpty { enqueue(samples) }
            let tokens = timeline.tokens
            committed.withLock { $0 = tokens }
            switch status {
            case .audio: continue
            case .starving: break
            case .finished: timelineDone = true
            case .failed(let token, let message):
                if !failedTokens.contains(token) {
                    failedTokens.insert(token)
                    let callback = onFailure
                    DispatchQueue.main.async { MainActor.assumeIsolated { callback?(token, message) } }
                }
            }
            if status != .audio { break }
        }
        inFlight.removeAll { $0.start + Int64($0.frames) <= heard }

        // The clock runs while there is audio ahead of it.
        let ahead = enqueuedFrames - heard
        if playing {
            if !clockRunning, ahead >= Int64(Double(leadFrames) * 0.75) || (timelineDone && ahead > 0) {
                startClock(at: heard)
            } else if clockRunning, !timelineDone, ahead < Int64(0.02 * rate) {
                stopClock()
                setBuffering(true)
            }
        }

        // Which song is heard, and how far in.
        if let marker = timeline.markers.last(where: { $0.outputFrame <= heard }) {
            if marker.token != heardToken {
                heardToken = marker.token
                let callback = onSongStarted
                let token = marker.token
                DispatchQueue.main.async { MainActor.assumeIsolated { callback?(token) } }
                lastProgress = .distantPast
            }
            if let duration = timeline.duration(of: marker.token) { durations[marker.token] = duration }
            if Date().timeIntervalSince(lastProgress) >= 0.25 {
                lastProgress = Date()
                let seconds = Double(marker.songFrame + heard - marker.outputFrame) / rate
                let token = marker.token, duration = durations[token], callback = onProgress
                DispatchQueue.main.async { MainActor.assumeIsolated { callback?(token, seconds, duration) } }
            }
        }

        if timelineDone, heard >= enqueuedFrames, !finishedReported {
            finishedReported = true
            stopClock()
            let token = heardToken ?? UUID(), callback = onFinished
            DispatchQueue.main.async { MainActor.assumeIsolated { callback?(token) } }
        }
    }

    private func startClock(at frame: Int64) {
        synchronizer.setRate(1, time: CMTime(value: frame, timescale: CMTimeScale(rate)))
        clockRunning = true
        setBuffering(false)
    }

    private func stopClock() {
        let now = synchronizer.currentTime()
        synchronizer.setRate(0, time: now)
        clockRunning = false
    }

    private func setBuffering(_ value: Bool) {
        guard buffering != value else { return }
        buffering = value
        let callback = onBuffering
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(value) } }
    }

    private func enqueue(_ samples: [Float]) {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        if description == nil || describedRate != rate {
            description = Self.formatDescription(rate: rate)
            describedRate = rate
            processor?.configure(sampleRate: rate, channelCount: 2)
        }
        guard let description,
              let buffer = Self.sampleBuffer(samples, at: enqueuedFrames, rate: rate, description: description, processor: processor) else { return }
        renderer.enqueue(buffer)
        inFlight.append((enqueuedFrames, frames, buffer))
        enqueuedFrames += Int64(frames)
    }

    // MARK: - Recovering the output

    private func observeFlushes() {
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, (note.object as? AVSampleBufferAudioRenderer) === self.renderer else { return }
            let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self.queue.async { self.refill(from: time) }
        }
    }

    /// The output changed under the renderer (a route change): enqueue again what was still to be heard.
    private func refill(from time: CMTime?) {
        let from = time.map { Int64($0.seconds * rate) } ?? heardFrame
        for entry in inFlight where entry.start + Int64(entry.frames) > from { renderer.enqueue(entry.buffer) }
    }

    /// Media services reset: a new renderer, and the heard song from where it was.
    private func replaceRenderer() {
        let heard = heardFrame
        let marker = timeline?.markers.last { $0.outputFrame <= heard }
        synchronizer.removeRenderer(renderer, at: .zero)
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        renderer.volume = volume
        renderer.isMuted = muted
        #if os(visionOS)
        if let spatial { synchronizer.intendedSpatialAudioExperience = spatial }
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        #endif
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
        observeFlushes()
        description = nil
        if let marker, let timeline {
            let seconds = Double(marker.songFrame + heard - marker.outputFrame) / rate
            timeline.seek(marker.token, to: seconds)
            committed.withLock { $0 = [marker.token] }
        }
        restartOutput()
    }

    // MARK: - Sample buffers

    static func formatDescription(rate: Double) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var layout = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_Stereo, mChannelBitmap: [],
                                        mNumberChannelDescriptions: 0, mChannelDescriptions: AudioChannelDescription())
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                                    layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    /// Interleaved stereo samples through the equalizer, as a sample buffer at output frame `frame`.
    static func sampleBuffer(_ samples: [Float], at frame: Int64, rate: Double, description: CMAudioFormatDescription,
                             processor: MusicSampleProcessor?) -> CMSampleBuffer? {
        let frames = samples.count / 2
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let out = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Float.self)
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
        if let processor {
            for c in 0 ..< 2 { processor.process(channel: c, samples: out + c, count: frames, stride: 2) }
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: CMTime(value: frame, timescale: CMTimeScale(rate)), packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
