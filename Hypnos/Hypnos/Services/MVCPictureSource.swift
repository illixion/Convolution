/*
 Hypnos - the picture of a 3D Blu-ray, decoded on the device

 A Blu-ray's 3D is MVC (H.264 Multiview), which no Apple decoder handles.
 Vergence (a local package, ../../vergence) reads it in place over HTTP range
 requests (Jellyfin serves the raw file from `Videos/{id}/stream?static=true`)
 and decodes both views with edge264. Two kinds of file:

 - a disc image or folder: Vergence picks the feature playlist and joins
   its base and dependent clips;
 - a disc remuxed to Matroska (MakeMKV's 3D MVC MKV, and the remuxes made
   from it): one video track with both views in every Block, read by
   `MatroskaStereoReader`, seeking by the file's Cues.

 Each frame is copied into pixel buffers: the left eye for the film player's
 own layer, and both eyes top and bottom for the stereo tap, which crops the
 eyes out the way it does for a frame-packed file.

 Film time for a disc is the transport stream's clock, which the Atmos
 plugin's audio scene also uses: the scene starts at the first PlayItem's IN
 time (its `startSeconds`), and Vergence's frames are stamped in playlist time
 from that same IN time, so film time = playlist time + `originSeconds`. A
 feature made of several clips restarts the stream clock at each clip, which
 this mapping (and the plugin's) doesn't follow; the features seen so far are
 one clip. A Matroska file's time is its own, as the plugin's is for it, so
 its origin is 0.

 Decoding runs on its own serial queue, at most `queuedFrames` ahead of the
 player taking them; the player keeps under a second queued in its layer.

 A disc's own subtitles (PGS bitmaps) are read from the same bytes as the
 base view and collected in `subtitles` (`DiscSubtitles`). A Matroska file's
 come through Jellyfin like any file's.
 */

import CoreMedia
import CoreVideo
import Foundation
import VergenceApple
import RAVEFilm
import DebugTrace

final class MVCPictureSource: FilmPictureSource, @unchecked Sendable {
    let durationSeconds: Double
    let frameRate: Double
    let summary: String
    /// Film time of playlist time 0 (0 for a Matroska file).
    let originSeconds: Double
    let isStereo: Bool
    /// The disc's PGS subtitle tracks, collected as the picture is read; nil
    /// for a Matroska file.
    let subtitles: DiscSubtitles?
    /// A disc image or folder, rather than a Matroska remux of one.
    var isDisc: Bool { if case .disc = origin { true } else { false } }

    private enum Origin {
        case disc(BlurayDisc, BlurayPlaylist)
        case matroska(ByteSource, MatroskaFile)
    }
    private let origin: Origin
    private let url: URL
    private let headers: [String: String]
    /// Where the file is read from, for a reader of its sound
    /// (`MatroskaFilmAudioSource`).
    var sourceURL: URL { url }
    /// The file's base view is the right eye (Matroska StereoMode 14).
    private let swapsEyes: Bool
    private let frameDuration: CMTime
    private let queue = DispatchQueue(label: "com.illixion.hypnos.mvc-decode", qos: .userInitiated)
    private let lock = NSLock()
    private var current: FrameChannel?
    // Decode queue only.
    private var playlistDecoder: PlaylistDecoder?
    private var matroskaDecoder: StereoDecoder?
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
            try MVCPictureSource(discURL: url, headers: headers)
        }.value
    }

    /// Opens a Matroska file with an MVC track at `url` (over HTTP, or on
    /// the device). Reads its header and Cues.
    static func openMatroska(url: URL, headers: [String: String]) async throws -> MVCPictureSource {
        try await Task.detached(priority: .userInitiated) {
            try MVCPictureSource(matroskaURL: url, headers: headers)
        }.value
    }

    private init(discURL url: URL, headers: [String: String]) throws {
        self.url = url
        self.headers = headers
        let disc = try Self.openDisc(url: url, headers: headers)
        guard let (name, playlist) = try disc.mainPlaylist() else { throw FormatError("no playlist on the disc") }
        origin = .disc(disc, playlist)
        isStereo = playlist.isStereo
        swapsEyes = false
        frameRate = 24000.0 / 1001
        frameDuration = CMTime(value: 1001, timescale: 24000)
        originSeconds = Double(playlist.items.first?.inPTS ?? 0) / 90_000
        durationSeconds = originSeconds + playlist.duration
        subtitles = DiscSubtitles(playlist: playlist, originSeconds: originSeconds)
        summary = "Blu-ray \(isStereo ? "MVC 3D" : "H.264"), playlist \(name), decoded on device"
    }

    private init(matroskaURL url: URL, headers: [String: String]) throws {
        self.url = url
        self.headers = headers
        let source = try Self.byteSource(url: url, headers: headers)
        let file = try MatroskaFile(source: source)
        guard let track = file.video, track.avc != nil else { throw FormatError("no H.264 video track") }
        origin = .matroska(source, file)
        isStereo = track.isMVC
        swapsEyes = track.baseIsRightEye
        (frameRate, frameDuration) = Self.frameRate(nanosecondsPerFrame: track.defaultDuration)
        originSeconds = 0
        durationSeconds = file.durationSeconds ?? 0
        subtitles = nil
        summary = "Blu-ray remux \(isStereo ? "MVC 3D" : "H.264") in Matroska, \(file.cues.count) cues, decoded on device"
    }

    /// A track's frame rate, snapped to the broadcast rate it stands for.
    private static func frameRate(nanosecondsPerFrame: UInt64?) -> (Double, CMTime) {
        let standard: [(Int64, Int32)] = [(1001, 24000), (1, 24), (1, 25), (1001, 30000), (1, 30), (1, 50), (1001, 60000), (1, 60)]
        guard let ns = nanosecondsPerFrame, ns > 0 else { return (24000.0 / 1001, CMTime(value: 1001, timescale: 24000)) }
        let seconds = Double(ns) / 1e9
        if let match = standard.first(where: { abs(Double($0.0) / Double($0.1) - seconds) < 0.00005 }) {
            return (Double(match.1) / Double(match.0), CMTime(value: match.0, timescale: match.1))
        }
        return (1 / seconds, CMTime(seconds: seconds, preferredTimescale: 90_000))
    }

    /// Whether the Matroska file at `url` has an MVC track, from its header
    /// alone (a few small range requests over HTTP).
    static func hasMatroskaMVC(url: URL, headers: [String: String]) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let source = try Self.byteSource(url: url, headers: headers, probing: true)
            guard MatroskaFile.looksLikeMatroska(try source.read(at: 0, count: 4)) else { return false }
            return try MatroskaFile(source: source, readCues: false).video?.isMVC ?? false
        }.value
    }

    private static func byteSource(url: URL, headers: [String: String], probing: Bool = false) throws -> ByteSource {
        guard !url.isFileURL else { return try FileByteSource(url: url) }
        // A probe reads the header and nothing else: small blocks, none ahead.
        return probing
            ? try HTTPByteSource(url: url, headers: headers, blockSize: 64 << 10, cacheBlocks: 4, readAhead: 1, timeout: 10)
            : try HTTPByteSource(url: url, headers: headers)
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

    /// The feature playlist's audio, on its own reader of the same disc. Nil
    /// for a Matroska file, whose sound is read apart from its picture.
    func audioSource(itemID: String) throws -> DiscAudioSource? {
        guard case .disc(_, let playlist) = origin else { return nil }
        return try DiscAudioSource(itemID: itemID, disc: Self.openDisc(url: url, headers: headers),
                                   playlist: playlist, originSeconds: originSeconds)
    }

    /// Opens the decoder (decode queue only), set up for a run from
    /// `filmTime`, and returns how to seek and decode with it.
    private func prepareDecoder(from filmTime: Double) throws -> (seek: (Double) throws -> Void,
                                                                  decode: ((StereoFrame) throws -> Bool) throws -> Void) {
        switch origin {
        case .disc(let disc, let playlist):
            let decoder = try playlistDecoder ?? PlaylistDecoder(disc: disc, playlist: playlist, threads: Self.decodeThreads)
            playlistDecoder = decoder
            if let subtitles {
                // Subtitles come out of the same reads as the picture.
                decoder.sidePIDs = subtitles.pids
                decoder.onSidePackets = { subtitles.feed($0) }
                subtitles.beginRun(at: Int64(((filmTime - originSeconds) * 90_000).rounded()))
            }
            return (decoder.seek(to:), decoder.decode(output:))
        case .matroska(let source, let file):
            let decoder = try matroskaDecoder
                ?? StereoDecoder(reader: MatroskaStereoReader(source: source, file: file), threads: Self.decodeThreads)
            matroskaDecoder = decoder
            return (decoder.seek(to:), decoder.decode(output:))
        }
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
                let decoder = try prepareDecoder(from: filmTime)
                enter("seeking", run: run)
                try decoder.seek(filmTime - originSeconds)
                enter("decoding", run: run)
                let origin = Int64((originSeconds * 90_000).rounded())
                let swapsEyes = self.swapsEyes
                try decoder.decode { decoded in
                    guard !channel.isCancelled else { return false }
                    guard let pts = decoded.pts else { return true }
                    let frame = swapsEyes ? decoded.swappingEyes() : decoded
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
                playlistDecoder = nil
                matroskaDecoder = nil
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
        let timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: time,
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
