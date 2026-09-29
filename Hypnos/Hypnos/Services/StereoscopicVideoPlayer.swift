/*
 Hypnos - Stereoscopic Video Player

 Coordinates downloading, converting, and playing stereoscopic 3D video.
 Downloads full video, converts to MV-HEVC, then plays the converted file.
 */

// MV-HEVC (tagged pixel buffer group writing) is only used by the visionOS
// immersive stereoscopic-video pipeline (StereoscopicVideoView is already
// `#if os(visionOS)`-gated) and its APIs are unavailable on tvOS.
#if !os(tvOS)

import AVFoundation
import Combine
import DebugTrace
import RAVEMedia
import RealityKit

/// Player state for stereoscopic video
enum StereoscopicPlayerState: Equatable {
    case idle
    case downloading(progress: Double)
    case converting(progress: Double)
    case playing
    case paused
    case error(String)

    var isActive: Bool {
        switch self {
        case .downloading, .converting, .playing, .paused:
            return true
        case .idle, .error:
            return false
        }
    }
}

/// Reason for falling back to 2D playback
enum FallbackReason {
    case conversionFailed(Error)
    case downloadFailed(Error)
    case insufficientResources
    case unsupportedFormat
    case userRequested
}

/// Notification names for stereoscopic player events
extension Notification.Name {
    static let stereoscopicFallbackTo2D = Notification.Name("stereoscopicFallbackTo2D")
    static let stereoscopicPlaybackReady = Notification.Name("stereoscopicPlaybackReady")
}

/// Main coordinator for stereoscopic video playback
@MainActor
class StereoscopicVideoPlayer: ObservableObject {
    // Published state
    @Published private(set) var state: StereoscopicPlayerState = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var bufferProgress: Double = 0
    @Published private(set) var currentChunkInfo: String = ""

    // AVPlayer for playback
    private(set) var avPlayer: AVPlayer?

    // Components
    private let converter = MVHEVCConverter()
    private let videoCache = DiskVideoCache.shared

    // State
    private var currentVideo: GalleryVideo?
    @Published private(set) var convertedFileURL: URL?
    private var isUsingCachedVideo: Bool = false

    /// Current 3D settings being used (nil if using tag-detected defaults)
    @Published private(set) var currentSettings: Video3DSettings?

    // Tasks
    private var processingTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadObservation: NSKeyValueObservation?
    private var endOfPlayObserver: NSObjectProtocol?

    init() {}

    deinit {
        // Note: stop() must be called from MainActor context before deinit
    }

    // MARK: - Public API

    /// Start playing a stereoscopic video using tag-detected format
    /// - Parameter video: The video to play. Its server's credential is
    ///   resolved from `MediaAuthorization`, so there's nothing to pass.
    func play(video: GalleryVideo) async {
        guard video.isStereoscopic,
              let format = video.stereoscopicFormat else {
            state = .error("Video is not stereoscopic")
            return
        }

        // Create settings from tag-detected format
        let settings = Video3DSettings(
            format: format,
            eyesReversed: video.eyesReversed,
            horizontalFieldOfView: 90.0,
            horizontalDisparityAdjustment: 200.0
        )

        await play(video: video, customSettings: settings)
    }

    /// Start playing a video with custom 3D settings
    /// - Parameters:
    ///   - video: The video to play
    ///   - customSettings: Custom 3D conversion settings
    func play(video: GalleryVideo, customSettings: Video3DSettings) async {
        // Stop any existing playback
        stop()

        currentVideo = video
        currentSettings = customSettings
        isUsingCachedVideo = false

        // Use full settings cache key (includes format, eyesReversed, FOV, disparity)
        let settingsCacheKey = customSettings.cacheKey

        processingTask = Task {
            do {
                // Check cache first
                if let cachedURL = await videoCache.getCachedVideoURL(videoId: video.identity, format: settingsCacheKey) {
                    // Cache hit! Use cached converted video
                    AppLogger.stereoscopicPlayer.info("Cache hit for video: \(video.identity, privacy: .private(mask: .hash)) with settings: \(settingsCacheKey, privacy: .public)")

                    await MainActor.run {
                        self.currentChunkInfo = "Loading from cache..."
                        self.isUsingCachedVideo = true
                    }

                    // Get duration from cached file
                    let asset = AVURLAsset(url: cachedURL)
                    let durationCM = try await asset.load(.duration)
                    await MainActor.run {
                        self.duration = durationCM.seconds
                        self.convertedFileURL = cachedURL
                        self.startPlayback(url: cachedURL)
                    }
                    return
                }

                // Cache miss - need to download and convert
                AppLogger.stereoscopicPlayer.info("Cache miss for video: \(video.identity, privacy: .private(mask: .hash)) with settings: \(settingsCacheKey, privacy: .public), downloading...")

                await MainActor.run {
                    self.state = .downloading(progress: 0)
                    self.currentChunkInfo = "Downloading video..."
                }

                // Step 1: Download the complete video
                let localVideoURL = try await downloadVideo(video: video)

                AppLogger.stereoscopicPlayer.info("Download completed: \(localVideoURL.lastPathComponent)")

                // Reserve cache capacity for the upcoming MV-HEVC output (the
                // source size is the best estimate) so eviction makes room
                // during the conversion instead of blowing past the cap.
                let sourceSize = (try? FileManager.default.attributesOfItem(atPath: localVideoURL.path))?[.size] as? Int64 ?? 0
                await videoCache.reserveCapacity(token: video.identity, expectedBytes: sourceSize)
                defer { Task { await self.videoCache.releaseReservation(token: video.identity) } }

                if Task.isCancelled {
                    AppLogger.stereoscopicPlayer.info("Task cancelled after download")
                    return
                }

                // Step 2: Validate video format and get duration
                let asset = AVURLAsset(url: localVideoURL)
                var videoDuration: TimeInterval = 0

                // Check if AVFoundation can read this video format
                // This may throw for unsupported formats like WebM
                do {
                    let isReadable = try await asset.load(.isReadable)
                    if !isReadable {
                        throw StereoscopicPlayerError.conversionFailed("Video format cannot be read")
                    }

                    // Also check that we have video tracks
                    let tracks = try await asset.load(.tracks)
                    let videoTracks = tracks.filter { $0.mediaType == .video }
                    if videoTracks.isEmpty {
                        throw StereoscopicPlayerError.conversionFailed("No video tracks found in file")
                    }

                    // Try to get duration
                    let durationCM = try await asset.load(.duration)
                    videoDuration = durationCM.seconds
                    await MainActor.run {
                        self.duration = videoDuration
                    }
                    AppLogger.stereoscopicPlayer.info("Video validated: \(videoTracks.count) video track(s), duration: \(videoDuration) seconds")

                } catch let playerError as StereoscopicPlayerError {
                    // Re-throw our custom errors
                    throw playerError
                } catch {
                    // AVFoundation couldn't read the file. Downloads prefer the
                    // server transcode, rewritten to `/stream.mp4` (see
                    // GalleryVideo.transcodedDownloadURL), so reaching here with a
                    // raw container extension means there was no transcode to
                    // download — the setting is off, or the server can't provide one.
                    let urlExtension = video.transcodedDownloadURL.pathExtension.lowercased()
                    let unsupportedFormats = ["webm", "mkv", "flv", "avi", "wmv"]

                    AppLogger.stereoscopicPlayer.error("AVFoundation cannot read video: \(error.localizedDescription)")

                    if unsupportedFormats.contains(urlExtension) {
                        throw StereoscopicPlayerError.conversionFailed(
                            "\(urlExtension.uppercased()) can't be converted to 3D because this Stash server didn't provide an MP4 transcode. Enable transcoding in Settings (or on the server) and try again."
                        )
                    } else {
                        throw StereoscopicPlayerError.conversionFailed(
                            "This video format is not supported for 3D conversion. Only MP4/MOV videos can be converted. (Error: \(error.localizedDescription))"
                        )
                    }
                }

                // Step 3: Convert to MV-HEVC using custom settings
                await MainActor.run {
                    self.state = .converting(progress: 0)
                    self.currentChunkInfo = "Converting to 3D..."
                }

                let config = MVHEVCConversionConfig.from(video: video, settings: customSettings)
                let convertedURL = try await converter.convertFullVideo(
                    sourceURL: localVideoURL,
                    config: config,
                    videoId: video.identity,
                    progressHandler: { progress in
                        Task { @MainActor in
                            self.state = .converting(progress: progress)
                            self.currentChunkInfo = "Converting: \(Int(progress * 100))%"
                        }
                    }
                )

                AppLogger.stereoscopicPlayer.info("Conversion completed: \(convertedURL.lastPathComponent)")

                if Task.isCancelled {
                    AppLogger.stereoscopicPlayer.info("Task cancelled after conversion")
                    return
                }

                // Clean up downloaded source file
                try? FileManager.default.removeItem(at: localVideoURL)

                // Step 4: Cache the converted video
                let fileAttributes = try? FileManager.default.attributesOfItem(atPath: convertedURL.path)
                let fileSize = (fileAttributes?[.size] as? Int64) ?? 0

                let metadata = CachedVideoMetadata(
                    videoId: video.identity,
                    originalURL: video.streamURL.absoluteString,
                    stereoscopicFormat: settingsCacheKey,
                    sourceWidth: video.sourceWidth ?? 0,
                    sourceHeight: video.sourceHeight ?? 0,
                    duration: videoDuration,
                    fileSize: fileSize,
                    cachedDate: Date()
                )

                // Move converted file to cache (more efficient than copy)
                let cachedURL = try await videoCache.moveVideoToCache(
                    from: convertedURL,
                    videoId: video.identity,
                    format: settingsCacheKey,
                    metadata: metadata
                )

                if Task.isCancelled { return }

                // Step 5: Start playback from cached location
                await MainActor.run {
                    self.convertedFileURL = cachedURL
                    self.isUsingCachedVideo = true
                    self.startPlayback(url: cachedURL)
                }

            } catch {
                // Ignore cancellation errors (happen when settings change mid-download)
                if Task.isCancelled {
                    AppLogger.stereoscopicPlayer.info("Playback task cancelled (Task.isCancelled), ignoring error")
                    return
                }

                // Check for Swift CancellationError
                if error is CancellationError {
                    AppLogger.stereoscopicPlayer.info("Playback task cancelled (CancellationError), ignoring error")
                    return
                }

                // Also check for URLSession cancellation
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    AppLogger.stereoscopicPlayer.info("Download cancelled (NSURLErrorCancelled), ignoring error")
                    return
                }

                // Log detailed error info for debugging
                AppLogger.stereoscopicPlayer.error("Playback error: \(error.localizedDescription)")
                AppLogger.stereoscopicPlayer.error("Error type: \(String(describing: type(of: error)), privacy: .public)")
                AppLogger.stereoscopicPlayer.error("NSError domain: \(nsError.domain, privacy: .public), code: \(nsError.code)")

                // Set error state - don't immediately fall back to 2D
                // The error overlay will show with options to retry or play as 2D
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                    // Note: Don't call postFallbackNotification here - let user see the error first
                    // The error overlay has a "Play as 2D" button that will trigger the fallback
                }
            }
        }
    }

    /// Pause playback
    func pause() {
        avPlayer?.pause()
        state = .paused
    }

    /// Resume playback
    func resume() {
        avPlayer?.play()
        state = .playing
    }

    /// Toggle play/pause
    func togglePlayPause() {
        if state == .playing {
            pause()
        } else if state == .paused {
            resume()
        }
    }

    /// Seek to a time in seconds
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
    }

    /// Seek to a percentage of the video
    func seek(toPercentage percentage: Double) {
        let targetTime = duration * percentage
        seek(to: targetTime)
    }

    /// Stop playback and cleanup
    func stop() {
        processingTask?.cancel()
        processingTask = nil

        downloadTask?.cancel()
        downloadTask = nil
        downloadObservation?.invalidate()
        downloadObservation = nil

        if let observer = timeObserver, let player = avPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil

        if let observer = endOfPlayObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        endOfPlayObserver = nil

        avPlayer?.pause()
        avPlayer = nil

        // Only clean up converted file if it's NOT from cache
        // Cached files should persist for future playback
        if !isUsingCachedVideo, let url = convertedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        convertedFileURL = nil

        // Clean up any temp files from converter (not the cache)
        if let video = currentVideo {
            Task {
                await converter.cleanup(videoId: video.identity)
            }
        }

        currentVideo = nil
        currentSettings = nil
        isUsingCachedVideo = false
        state = .idle
        currentTime = 0
        duration = 0
        bufferProgress = 0
        currentChunkInfo = ""
    }

    /// Request fallback to 2D playback
    func requestFallback(reason: FallbackReason = .userRequested) {
        guard let video = currentVideo else { return }
        stop()
        postFallbackNotification(reason: reason, video: video)
    }

    // MARK: - Private Methods

    private func downloadVideo(video: GalleryVideo) async throws -> URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let downloadDir = cachesDir.appendingPathComponent("StereoscopicDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let destinationURL = downloadDir.appendingPathComponent("\(video.identity)_source.mp4")

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationURL)

        // WebM sources stream via Stash's HLS live transcode; downloading the
        // `.m3u8` playlist yields a text file, not video. `transcodedDownloadURL`
        // rewrites that to the server's `/stream.mp4` transcode, which downloads
        // to a normal MP4 that AVAssetReader (and hence MV-HEVC conversion) reads.
        let request = MediaAuthorization.shared.request(for: video.transcodedDownloadURL)

        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession.shared
            let task = session.downloadTask(with: request) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let tempURL = tempURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(throwing: URLError(.badServerResponse, userInfo: [
                        NSLocalizedDescriptionKey: "Server returned status \(statusCode)"
                    ]))
                    return
                }

                do {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            // Observe download progress
            self.downloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.state = .downloading(progress: progress.fractionCompleted)
                    self?.currentChunkInfo = "Downloading: \(Int(progress.fractionCompleted * 100))%"
                }
            }

            self.downloadTask = task
            task.resume()
        }
    }

    private func startPlayback(url: URL) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.applySpatialAudioPolicy()
        let player = AVPlayer(playerItem: playerItem)
        player.applySpatialAudioPolicy(for: asset)

        // Enable looping
        endOfPlayObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        self.avPlayer = player

        // Setup time observer
        setupTimeObserver()

        // Start playback
        player.play()
        state = .playing
        currentChunkInfo = "Playing"

        NotificationCenter.default.post(
            name: .stereoscopicPlaybackReady,
            object: self,
            userInfo: ["player": player]
        )
    }

    private func setupTimeObserver() {
        guard let player = avPlayer else { return }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // The observer is registered with `queue: .main`, so this fires on
            // the main thread — i.e. the main actor's executor. assumeIsolated
            // lets us touch the @MainActor `currentTime` synchronously without a
            // Task hop (which would lag the time readout by a runloop turn).
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
    }

    private func postFallbackNotification(reason: FallbackReason, video: GalleryVideo? = nil) {
        let videoToUse = video ?? currentVideo
        guard let video = videoToUse else { return }

        NotificationCenter.default.post(
            name: .stereoscopicFallbackTo2D,
            object: self,
            userInfo: ["reason": reason, "video": video]
        )
    }
}

// MARK: - Errors

enum StereoscopicPlayerError: Error, LocalizedError {
    case notStereoscopic
    case downloadFailed(String)
    case conversionFailed(String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notStereoscopic:
            return "Video is not stereoscopic"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .conversionFailed(let msg):
            return "Conversion failed: \(msg)"
        case .playbackFailed(let msg):
            return "Playback failed: \(msg)"
        }
    }
}
#endif
