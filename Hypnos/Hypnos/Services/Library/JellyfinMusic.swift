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
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var audioMode = JellyfinMusicAudioMode(rawValue: UserDefaults.standard.string(forKey: "jellyfinMusic.audioMode") ?? "") ?? .speaker
    private(set) var headLocked = UserDefaults.standard.bool(forKey: "jellyfinMusic.headLocked")
    var isShuffled = false
    var repeats = false
    var error: String?
    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playSessionId = UUID().uuidString
    private var progressTask: Task<Void, Never>?
    private var lastProgressReport = Date.distantPast

    private init() {}

    func play(_ track: JellyfinMusicItem, from tracks: [JellyfinMusicItem]? = nil) {
        guard let (base, token) = connection() else { error = "Configure Jellyfin in Settings first."; return }
        queue = tracks ?? [track]
        guard let index = queue.firstIndex(of: track) else { queue = [track]; start(track, base: base, token: token); return }
        start(queue[index], base: base, token: token)
    }

    func next() {
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }), let (base, token) = connection() else { return }
        let next = isShuffled && queue.count > 1 ? (i + Int.random(in: 1..<queue.count)) % queue.count : (i + 1 < queue.count ? i + 1 : (repeats ? 0 : -1))
        guard next >= 0 else {
            stop()
            return
        }
        start(queue[next], base: base, token: token)
    }
    func previous() {
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }), let (base, token) = connection() else { return }
        if currentTime > 3 { player?.seek(to: .zero); return }
        let previous = i > 0 ? i - 1 : (repeats ? queue.count - 1 : -1)
        guard previous >= 0 else { player?.seek(to: .zero); return }
        start(queue[previous], base: base, token: token)
    }
    func toggle() { guard let player else { return }; if isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }; publishNowPlaying() }
    func toggleMute() { isMuted.toggle(); player?.isMuted = isMuted }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); currentTime = seconds; publishNowPlaying() }
    func artworkURL(for item: JellyfinMusicItem) -> URL? {
        guard let (base, token) = connection() else { return nil }
        let imageID = item.ImageTags?["Primary"] != nil ? item.Id : item.AlbumId
        guard let imageID, let tag = item.ImageTags?["Primary"] ?? item.AlbumPrimaryImageTag else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("Items/\(imageID)/Images/Primary"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "maxWidth", value: "360"), URLQueryItem(name: "ApiKey", value: token)]
        return c?.url
    }
    func toggleShuffle() { isShuffled.toggle() }
    func toggleRepeat() { repeats.toggle() }

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

    private func start(_ item: JellyfinMusicItem, base: URL, token: String) {
        var c = URLComponents(url: base.appendingPathComponent("Audio/\(item.Id)/stream"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "UserId", value: JellyfinAuth.shared.session?.userId), URLQueryItem(name: "ApiKey", value: token)].compactMap { item in
            guard let value = item.value else { return nil }
            return URLQueryItem(name: item.name, value: value)
        }
        guard let url = c.url else { return }
        stopReporting()
        releasePlayer()
        playSessionId = UUID().uuidString
        current = item
        currentTime = 0; duration = Double(item.RunTimeTicks ?? 0) / 10_000_000
        if audioMode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
        else { AudioSessionConfig.configureMixedPlayback() }
        let nextPlayer = AVPlayer(url: url)
        #if os(visionOS)
        if let playerItem = nextPlayer.currentItem {
            playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        }
        #endif
        player = nextPlayer
        nextPlayer.isMuted = isMuted
        applySpatialAudioPreference()
        configureRemoteCommands()
        nextPlayer.play(); isPlaying = true
        observation = nextPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self, self.player === p else { return }
                self.isPlaying = p.timeControlStatus == .playing
                self.publishNowPlaying()
            }
        }
        timeObserver = nextPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.player === nextPlayer else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let d = nextPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.reportProgress()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nextPlayer.currentItem, queue: .main) { [weak self] _ in Task { @MainActor in self?.next() } }
        reportStarted()
        publishNowPlaying()
    }

    /// End playback before hiding its controls, including a manual Next on the last song.
    func stop() {
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
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
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
            center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.player?.pause(); self?.isPlaying = false; self?.publishNowPlaying() }; return .success }
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
