/*
 Hypnos - the picture of a 3D Blu-ray disc image, decoded on the device

 A Blu-ray's 3D is MVC (H.264 Multiview), which no Apple decoder handles.
 mvc3d (a local package, ../../mvc3d) reads the disc image in place over
 HTTP range requests (Jellyfin serves the raw ISO from
 `Videos/{id}/stream?static=true`), picks the feature playlist and decodes
 both views with edge264. Each frame is copied into pixel buffers: the left
 eye for the film player's own layer, and both eyes top and bottom for the
 stereo tap, which crops the eyes out the way it does for a frame-packed
 file.

 Film time is the transport stream's clock, which the Atmos plugin's audio
 scene also uses: the scene starts at the first PlayItem's IN time (its
 `startSeconds`), and mvc3d's frames are stamped in playlist time from that
 same IN time, so film time = playlist time + `originSeconds`. A feature
 made of several clips restarts the stream clock at each clip, which this
 mapping (and the plugin's) doesn't follow; the features seen so far are
 one clip.

 Decoding runs on its own serial queue, at most `queuedFrames` ahead of the
 player taking them; the player keeps under a second queued in its layer.

 The disc's own subtitles (PGS bitmaps) are read from the same bytes as the
 base view and collected in `subtitles` (`DiscSubtitles`).
 */

import CoreMedia
import CoreVideo
import Foundation
import MVC3D
import RAVEFilm
import DebugTrace

final class MVCPictureSource: FilmPictureSource, @unchecked Sendable {
    let durationSeconds: Double
    let frameRate = 24000.0 / 1001
    let summary: String
    /// Film time of playlist time 0.
    let originSeconds: Double
    let isStereo: Bool
    /// The disc's PGS subtitle tracks, collected as the picture is read.
    let subtitles: DiscSubtitles

    private let playlist: BlurayPlaylist
    private let disc: BlurayDisc
    private let url: URL
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "com.illixion.hypnos.mvc-decode", qos: .userInitiated)
    private let lock = NSLock()
    private var current: FrameChannel?
    // Decode queue only.
    private var decoder: PlaylistDecoder?
    private let leftMaker = StereoPixelBufferMaker(layout: .separate)
    private let packedMaker = StereoPixelBufferMaker(layout: .packed(.topAndBottom))
    private var formats: [CMVideoFormatDescription] = []

    /// What the decoding is doing, for the `film` debug query and the log.
    struct Diagnostics: Encodable, Sendable {
        var run = 0
        var phase = "idle"
        var phaseSeconds = 0.0
        var framesOut = 0
        var lastFrameSeconds: Double?
        var lastError: String?
        var runsQueued = 0
    }
    private var state = Diagnostics()
    private var phaseStarted = Date()
    var diagnostics: Diagnostics {
        lock.withLock {
            var d = state
            d.phaseSeconds = Date().timeIntervalSince(phaseStarted)
            return d
        }
    }
    private func enter(_ phase: String, run: Int) {
        lock.withLock {
            guard state.run == run else { return }
            state.phase = phase
            phaseStarted = Date()
        }
    }

    private static let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "MVCPicture")
    private static let queuedFrames = 4
    /// edge264 worker threads: decoding runs at 2-3x realtime per core on
    /// Apple silicon, and a seek decodes up to a second of pictures it drops.
    private static let decodeThreads = 3

    /// Opens the disc image at `url`. Reads its file system and playlists.
    static func open(url: URL, headers: [String: String]) async throws -> MVCPictureSource {
        try await Task.detached(priority: .userInitiated) {
            try MVCPictureSource(url: url, headers: headers)
        }.value
    }

    private init(url: URL, headers: [String: String]) throws {
        self.url = url
        self.headers = headers
        disc = try Self.openDisc(url: url, headers: headers)
        guard let (name, playlist) = try disc.mainPlaylist() else { throw FormatError("no playlist on the disc") }
        self.playlist = playlist
        isStereo = playlist.isStereo
        originSeconds = Double(playlist.items.first?.inPTS ?? 0) / 90_000
        durationSeconds = originSeconds + playlist.duration
        subtitles = DiscSubtitles(playlist: playlist, originSeconds: originSeconds)
        summary = "Blu-ray \(isStereo ? "MVC 3D" : "H.264"), playlist \(name), decoded on device"
    }

    /// A disc image over HTTP (Jellyfin's static stream), or on the device:
    /// an image file, or a folder holding BDMV. Each call reads the disc's
    /// file system afresh, so readers on other threads get their own.
    static func openDisc(url: URL, headers: [String: String] = [:]) throws -> BlurayDisc {
        guard url.isFileURL else {
            return BlurayDisc(fileSystem: try UDFFileSystem(image: HTTPByteSource(url: url, headers: headers)))
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return BlurayDisc(fileSystem: DirectoryFileSystem(root: url))
        }
        return BlurayDisc(fileSystem: try UDFFileSystem(image: FileByteSource(url: url)))
    }

    /// The feature playlist's audio, on its own reader of the same disc.
    func audioSource(itemID: String) throws -> DiscAudioSource {
        try DiscAudioSource(itemID: itemID, disc: Self.openDisc(url: url, headers: headers),
                            playlist: playlist, originSeconds: originSeconds)
    }

    func frames(from filmTime: Double, stereo: Bool) -> AsyncThrowingStream<FilmPictureFrame, Error> {
        let channel = FrameChannel(capacity: Self.queuedFrames)
        let previous = lock.withLock { () -> FrameChannel? in
            defer { current = channel }
            return current
        }
        // A seek replaces the run; the old one stops at its next frame.
        previous?.cancel()
        let stereo = stereo && isStereo
        let run = lock.withLock { () -> Int in
            state.runsQueued += 1
            return state.runsQueued
        }
        queue.async { [self] in
            guard !channel.isCancelled else { return }
            lock.withLock {
                state.run = run
                state.framesOut = 0
                state.lastError = nil
            }
            let began = Date()
            var frames = 0
            Self.logger.info("Run \(run): from \(filmTime, format: .fixed(precision: 2)) s\(stereo ? ", stereo" : "")")
            do {
                enter("opening decoder", run: run)
                let decoder = try self.decoder ?? PlaylistDecoder(disc: disc, playlist: playlist, threads: Self.decodeThreads)
                self.decoder = decoder
                enter("seeking", run: run)
                // Subtitles come out of the same reads as the picture.
                decoder.sidePIDs = subtitles.pids
                let subtitles = self.subtitles
                decoder.onSidePackets = { subtitles.feed($0) }
                subtitles.beginRun(at: Int64(((filmTime - originSeconds) * 90_000).rounded()))
                try decoder.seek(to: filmTime - originSeconds)
                enter("decoding", run: run)
                let origin = Int64((originSeconds * 90_000).rounded())
                try decoder.decode { frame in
                    guard !channel.isCancelled else { return false }
                    guard let pts = frame.pts else { return true }
                    let time = CMTime(value: pts + origin, timescale: 90_000)
                    let picture = try sampleBuffer(leftMaker.makeBuffers(frame).left, at: time)
                    let packed = stereo && frame.right != nil
                        ? try sampleBuffer(packedMaker.makeBuffers(frame).left, at: time) : nil
                    enter("waiting for the player", run: run)
                    let taken = channel.put(FilmPictureFrame(picture: picture, stereo: packed))
                    frames += 1
                    lock.withLock {
                        if state.run == run {
                            state.framesOut = frames
                            state.lastFrameSeconds = time.seconds
                        }
                    }
                    enter("decoding", run: run)
                    return taken
                }
                channel.finish(throwing: nil)
                enter(channel.isCancelled ? "stopped" : "finished", run: run)
            } catch {
                // The decoder's state is unknown after a failure.
                self.decoder = nil
                channel.finish(throwing: error)
                lock.withLock { if state.run == run { state.lastError = "\(error)" } }
                enter("failed", run: run)
                Self.logger.error("Run \(run) failed: \(error.localizedDescription, privacy: .public)")
            }
            Self.logger.info("Run \(run): \(frames) frames in \(Date().timeIntervalSince(began), format: .fixed(precision: 1)) s")
        }
        // Dropping the stream (the player's feed ended) stops the decoding.
        let stop = StopOnRelease(channel)
        return AsyncThrowingStream(unfolding: { try await stop.channel.next() })
    }

    private func sampleBuffer(_ pixels: CVPixelBuffer, at time: CMTime) throws -> CMSampleBuffer {
        let format: CMVideoFormatDescription
        if let match = formats.first(where: { CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixels) }) {
            format = match
        } else {
            format = try CMVideoFormatDescription(imageBuffer: pixels)
            formats.append(format)
        }
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1001, timescale: 24000), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        return try CMSampleBuffer(imageBuffer: pixels, formatDescription: format, sampleTiming: timing)
    }
}

/// Decoded frames handed from the decode queue to the player, with room for
/// `capacity` before the decoder waits.
private final class FrameChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let space: DispatchSemaphore
    private var frames: [FilmPictureFrame] = []
    private var waiter: CheckedContinuation<FilmPictureFrame?, Error>?
    private var ended = false
    private var failure: Error?
    private(set) var isCancelled: Bool {
        get { lock.withLock { cancelled } }
        set { lock.withLock { cancelled = newValue } }
    }
    private var cancelled = false

    init(capacity: Int) {
        // Raised from 0 rather than created at `capacity`: libdispatch traps
        // when a semaphore is released below its starting value, which a
        // channel dropped mid-stream (a seek) always is.
        space = DispatchSemaphore(value: 0)
        for _ in 0 ..< capacity { space.signal() }
    }

    /// Decode queue: waits for room. False once the reader is gone.
    func put(_ frame: FilmPictureFrame) -> Bool {
        space.wait()
        lock.lock()
        guard !cancelled else { lock.unlock(); return false }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            space.signal()
            waiter.resume(returning: frame)
        } else {
            frames.append(frame)
            lock.unlock()
        }
        return true
    }

    func finish(throwing error: Error?) {
        lock.lock()
        ended = true
        failure = error
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        frames.removeAll()
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        space.signal() // a decoder waiting for room sees the cancel
        waiter?.resume(returning: nil)
    }

    func next() async throws -> FilmPictureFrame? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !frames.isEmpty {
                    let frame = frames.removeFirst()
                    lock.unlock()
                    space.signal()
                    continuation.resume(returning: frame)
                } else if cancelled || ended {
                    let failure = cancelled ? nil : self.failure
                    lock.unlock()
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: nil) }
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }
}

/// Cancels its channel when the stream holding it is released.
private final class StopOnRelease: Sendable {
    let channel: FrameChannel
    init(_ channel: FrameChannel) { self.channel = channel }
    deinit { channel.cancel() }
}
