import AVFoundation
import Foundation
import MediaPlayer

struct JellyfinMusicItem: Decodable, Identifiable, Hashable, Sendable {
    let Id: String
    let Name: String
    let `Type`: String?
    let AlbumId: String?
    let DateCreated: String?
    let ChildCount: Int?
    let IndexNumber: Int?
    let AlbumPrimaryImageTag: String?
    let NormalizationGain: Double?
    let AlbumNormalizationGain: Double?
    let Album: String?
    let AlbumArtist: String?
    let Artists: [String]?
    let RunTimeTicks: Int64?
    let ImageTags: [String: String]?
    var isSong: Bool { self.Type == "Audio" }
    var id: String { Id }
    var artist: String { AlbumArtist ?? Artists?.joined(separator: ", ") ?? "Unknown Artist" }
}

struct JellyfinMusicPage: Decodable, Sendable {
    let Items: [JellyfinMusicItem]
    let TotalRecordCount: Int?
}

enum JellyfinMusicAudioMode: String, CaseIterable, Identifiable {
    case speaker
    case music
    var id: String { rawValue }
    var title: String { self == .music ? "Music Mode" : "Speaker Mode" }
    var symbol: String { self == .music ? "music.note" : "hifispeaker" }
}

@MainActor
@Observable
final class JellyfinMusicSession {
    static let shared = JellyfinMusicSession()
    private(set) var queue: [JellyfinMusicItem] = []
    private(set) var current: JellyfinMusicItem?
    private(set) var isPlaying = false
    private(set) var isMuted = false
    private(set) var volume = min(1, max(0, UserDefaults.standard.object(forKey: "jellyfinMusic.volume") as? Double ?? 1))
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var audioMode = JellyfinMusicAudioMode(rawValue: UserDefaults.standard.string(forKey: "jellyfinMusic.audioMode") ?? "") ?? .speaker
    private(set) var headLocked = UserDefaults.standard.bool(forKey: "jellyfinMusic.headLocked")
    var isShuffled = false
    var repeats = false
    var error: String?
    @ObservationIgnored private var orderedQueue: [JellyfinMusicItem] = []
    @ObservationIgnored private var randomSource: MusicRequest?
    @ObservationIgnored private var randomLibrary: JellyfinLibrary?
    @ObservationIgnored private var randomConfiguration: String?
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    @ObservationIgnored private var queueGeneration = UUID()
    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    /// The next song, already queued behind the playing one so the player rolls into it with no gap.
    private var preloaded: (item: AVPlayerItem, music: JellyfinMusicItem)?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playSessionId = UUID().uuidString
    private var progressTask: Task<Void, Never>?
    private var lastProgressReport = Date.distantPast

    private init() {}

    func play(_ track: JellyfinMusicItem, from tracks: [JellyfinMusicItem]? = nil) {
        guard let (base, token) = connection() else { error = "Configure Jellyfin in Settings first."; return }
        resetRandomSource()
        isShuffled = false
        queue = tracks ?? [track]
        orderedQueue = queue
        guard let index = queue.firstIndex(of: track) else { queue = [track]; start(track, base: base, token: token); return }
        start(queue[index], base: base, token: token)
    }

    /// Shuffle a concrete album/playlist once, then walk it without repeating
    /// tracks until the queue has completed (or Repeat wraps it).
    func playShuffled(_ tracks: [JellyfinMusicItem]) {
        guard !tracks.isEmpty, let (base, token) = connection() else { return }
        resetRandomSource()
        orderedQueue = tracks
        queue = tracks.shuffled()
        isShuffled = true
        start(queue[0], base: base, token: token)
    }

    func playRandomPage(_ tracks: [JellyfinMusicItem], source: MusicRequest, library: JellyfinLibrary) {
        guard !tracks.isEmpty else { return }
        playShuffled(tracks)
        randomSource = source
        randomLibrary = library
        randomConfiguration = LibraryService.configurationKey
    }

    func next() {
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }), let (base, token) = connection() else { return }
        if i + 1 < queue.count {
            start(queue[i + 1], base: base, token: token)
        } else if let randomSource, let randomLibrary {
            refillRandomQueue(source: randomSource, library: randomLibrary)
        } else if repeats, let first = queue.first {
            start(first, base: base, token: token)
        } else { stop() }
    }

    private func refillRandomQueue(source: MusicRequest, library: JellyfinLibrary) {
        guard refillTask == nil else { return }
        let ticket = queueGeneration
        let lastID = current?.id
        refillTask = Task {
            defer { if ticket == queueGeneration { refillTask = nil } }
            do {
                let page = try await library.musicPage(source, start: 0)
                try Task.checkCancellation()
                guard ticket == queueGeneration, randomConfiguration == LibraryService.configurationKey else { return }
                // Avoid an immediate repeat across random pages when possible.
                let candidates = page.Items.filter { $0.id != lastID }
                let tracks = candidates.isEmpty ? page.Items : candidates
                guard !tracks.isEmpty else { stop(); return }
                playRandomPage(tracks, source: source, library: library)
            } catch is CancellationError {
            } catch {
                guard ticket == queueGeneration else { return }
                self.error = error.localizedDescription
                stop()
            }
        }
    }

    private func resetRandomSource() {
        queueGeneration = UUID()
        refillTask?.cancel()
        refillTask = nil
        randomSource = nil
        randomLibrary = nil
        randomConfiguration = nil
    }

    func previous() {
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }), let (base, token) = connection() else { return }
        if currentTime > 3 { player?.seek(to: .zero); return }
        let previous = i > 0 ? i - 1 : (repeats ? queue.count - 1 : -1)
        guard previous >= 0 else { player?.seek(to: .zero); return }
        start(queue[previous], base: base, token: token)
    }
    func pause() {
        // A queued network result must not restart music after an explicit pause.
        queueGeneration = UUID()
        refillTask?.cancel()
        refillTask = nil
        player?.pause()
        isPlaying = false
        publishNowPlaying()
    }
    func toggle() {
        guard let player else { return }
        if isPlaying { pause() }
        else { player.play(); isPlaying = true; publishNowPlaying() }
    }
    func toggleMute() { isMuted.toggle(); player?.isMuted = isMuted }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        player?.volume = Float(volume)
        UserDefaults.standard.set(volume, forKey: "jellyfinMusic.volume")
    }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); currentTime = seconds; publishNowPlaying() }
    func artworkURL(for item: JellyfinMusicItem) -> URL? {
        guard let (base, token) = connection() else { return nil }
        let imageID = item.ImageTags?["Primary"] != nil ? item.Id : item.AlbumId
        guard let imageID, let tag = item.ImageTags?["Primary"] ?? item.AlbumPrimaryImageTag else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("Items/\(imageID)/Images/Primary"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "maxWidth", value: "360"), URLQueryItem(name: "ApiKey", value: token)]
        return c?.url
    }
    func toggleShuffle() {
        guard let current else { isShuffled.toggle(); return }
        isShuffled.toggle()
        if isShuffled {
            orderedQueue = queue
            queue = [current] + queue.filter { $0.id != current.id }.shuffled()
        } else {
            queue = orderedQueue
            resetRandomSource()
        }
        refreshPreload()
    }
    func toggleRepeat() { repeats.toggle(); refreshPreload() }

    func setAudioMode(_ mode: JellyfinMusicAudioMode) {
        guard audioMode != mode else { return }
        audioMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "jellyfinMusic.audioMode")
        if current != nil {
            if mode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
            else { AudioSessionConfig.configureMixedPlayback() }
        }
        updateRemoteCommandsEnabled()
        publishNowPlaying()
    }

    func toggleHeadLocked() {
        headLocked.toggle()
        UserDefaults.standard.set(headLocked, forKey: "jellyfinMusic.headLocked")
        applySpatialAudioPreference()
    }

    private func streamURL(for item: JellyfinMusicItem, base: URL, token: String) -> URL? {
        var c = URLComponents(url: base.appendingPathComponent("Audio/\(item.Id)/universal"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "UserId", value: JellyfinAuth.shared.session?.userId), URLQueryItem(name: "ApiKey", value: token),
            // Direct play what AVFoundation opens; otherwise HLS. A bare `/stream` transcode is an endless,
            // unseekable pipe: seeking after a long pause left the clock running past the track's length.
            URLQueryItem(name: "Container", value: "mp3,aac,m4a,m4b,flac,wav,alac"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac")].compactMap { item in
            guard let value = item.value else { return nil }
            return URLQueryItem(name: item.name, value: value)
        }
        return c.url
    }

    private func makePlayerItem(for item: JellyfinMusicItem, base: URL, token: String) -> AVPlayerItem? {
        guard let url = streamURL(for: item, base: base, token: token) else { return nil }
        let playerItem = AVPlayerItem(url: url)
        #if os(visionOS)
        playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        #endif
        return playerItem
    }

    /// What follows the current song, when that is already known (not a random refill).
    private func upcoming() -> JellyfinMusicItem? {
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }) else { return nil }
        if i + 1 < queue.count { return queue[i + 1] }
        if randomSource == nil, repeats, let first = queue.first { return first }
        return nil
    }

    /// Queue the next song behind the playing one (or drop a stale one), for gapless playback.
    private func refreshPreload() {
        guard let queuePlayer = player as? AVQueuePlayer else { return }
        let wanted = upcoming()
        if let preloaded, preloaded.music.id == wanted?.id { return }
        if let preloaded { queuePlayer.remove(preloaded.item); self.preloaded = nil }
        guard let wanted, let (base, token) = connection(),
              let item = makePlayerItem(for: wanted, base: base, token: token) else { return }
        queuePlayer.insert(item, after: queuePlayer.currentItem)
        preloaded = (item, wanted)
    }

    /// The queue player rolled into the preloaded song: move the session's state onto it.
    private func advanceToPreloaded() {
        guard let preloaded else { return }
        self.preloaded = nil
        stopReporting()
        playSessionId = UUID().uuidString
        current = preloaded.music
        currentTime = 0
        duration = Double(preloaded.music.RunTimeTicks ?? 0) / 10_000_000
        isPlaying = true
        reportStarted()
        publishNowPlaying()
        refreshPreload()
    }

    private func start(_ item: JellyfinMusicItem, base: URL, token: String) {
        guard let firstItem = makePlayerItem(for: item, base: base, token: token) else { return }
        stopReporting()
        releasePlayer()
        playSessionId = UUID().uuidString
        current = item
        currentTime = 0; duration = Double(item.RunTimeTicks ?? 0) / 10_000_000
        if audioMode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
        else { AudioSessionConfig.configureMixedPlayback() }
        let nextPlayer = AVQueuePlayer(items: [firstItem])
        nextPlayer.actionAtItemEnd = .advance
        player = nextPlayer
        nextPlayer.isMuted = isMuted
        nextPlayer.volume = Float(volume)
        applySpatialAudioPreference()
        configureRemoteCommands()
        nextPlayer.play(); isPlaying = true
        itemObservation = nextPlayer.observe(\.currentItem, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self, self.player === p, let queued = self.preloaded, p.currentItem === queued.item else { return }
                self.advanceToPreloaded()
            }
        }
        observation = nextPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self, self.player === p else { return }
                // Something else paused us (opening an AI 3D photo takes audio focus) while
                // the listener never asked to: take focus back and carry on.
                if p.timeControlStatus == .paused, self.isPlaying, self.current != nil,
                   self.duration <= 0 || self.currentTime < self.duration - 1 {
                    if self.audioMode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
                    else { AudioSessionConfig.configureMixedPlayback() }
                    p.play()
                    return
                }
                self.isPlaying = p.timeControlStatus == .playing
                self.publishNowPlaying()
            }
        }
        timeObserver = nextPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.player === nextPlayer else { return }
                self.currentTime = time.seconds.isFinite ? max(0, min(time.seconds, self.duration > 0 ? self.duration : time.seconds)) : 0
                if let d = nextPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.reportProgress()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let ended = note.object as? AVPlayerItem
            Task { @MainActor in
                // With a song queued behind it the player rolls on by itself (advanceToPreloaded).
                guard let self, self.preloaded == nil, let ended,
                      ended === self.player?.currentItem else { return }
                self.next()
            }
        }
        reportStarted()
        publishNowPlaying()
        refreshPreload()
    }

    /// End playback before hiding its controls, including a manual Next on the last song.
    func stop() {
        resetRandomSource()
        orderedQueue = []
        stopReporting()
        releasePlayer()
        current = nil
        queue = []
        currentTime = 0
        duration = 0
        updateRemoteCommandsEnabled()
        publishNowPlaying()
        AudioSessionConfig.configureMixedPlayback()
    }

    private func releasePlayer() {
        observation = nil
        itemObservation = nil
        preloaded = nil
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        (player as? AVQueuePlayer)?.removeAllItems()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func reportStarted() { sendReport("Sessions/Playing", includePaused: true) }
    private func reportProgress() {
        guard Date().timeIntervalSince(lastProgressReport) >= 10 else { return }
        lastProgressReport = Date()
        sendReport("Sessions/Playing/Progress", includePaused: true)
    }
    private func stopReporting() { progressTask?.cancel(); sendReport("Sessions/Playing/Stopped", includePaused: false); isPlaying = false }
    private func sendReport(_ path: String, includePaused: Bool) {
        guard let (base, token) = connection(), let item = current else { return }
        let ticks = Int64(max(0, currentTime) * 10_000_000)
        var payload: [String: Any] = ["ItemId": item.Id, "PlaySessionId": playSessionId, "PositionTicks": ticks]
        if includePaused { payload["IsPaused"] = !isPlaying; payload["CanSeek"] = true }
        let task = Task {
            var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = "POST"
            request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: request)
        }
        if path != "Sessions/Playing/Stopped" { progressTask = task }
    }
    private func publishNowPlaying() {
        guard audioMode == .music else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            updateRemoteCommandsEnabled()
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.Name,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.Album ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        if !remoteCommandsConfigured {
            remoteCommandsConfigured = true
            center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.player?.play(); self?.isPlaying = true; self?.publishNowPlaying() }; return .success }
            center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
            center.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
            center.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
            center.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
                return .success
            }
        }
        updateRemoteCommandsEnabled()
    }

    private var remoteCommandsConfigured = false

    private func updateRemoteCommandsEnabled() {
        let center = MPRemoteCommandCenter.shared()
        let enabled = audioMode == .music && current != nil
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = enabled
        }
    }

    private func applySpatialAudioPreference() {
        #if os(visionOS)
        player?.intendedSpatialAudioExperience = headLocked
            ? .fixed(soundStageSize: .automatic)
            : AutomaticSpatialAudio.automatic
        #endif
    }
    private func connection() -> (URL,String)? {
        let s = FilmSession.shared
        guard let base = URL(string: s.server), !s.apiKey.isEmpty || JellyfinAuth.shared.session != nil else { return nil }
        return (base, JellyfinAuth.shared.session?.accessToken ?? s.apiKey)
    }
}
