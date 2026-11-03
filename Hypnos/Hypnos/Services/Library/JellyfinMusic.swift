import AVFoundation
import Foundation
import MediaPlayer

struct JellyfinMusicItem: Decodable, Identifiable, Hashable {
    let Id: String
    let Name: String
    let Album: String?
    let AlbumArtist: String?
    let Artists: [String]?
    let RunTimeTicks: Int64?
    let ImageTags: [String: String]?
    var id: String { Id }
    var artist: String { AlbumArtist ?? Artists?.joined(separator: ", ") ?? "Unknown Artist" }
}

struct JellyfinMusicPage: Decodable { let Items: [JellyfinMusicItem] }
private struct JellyfinUsers: Decodable { struct User: Decodable { let Id: String }; let Items: [User] }

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
    private(set) var albums: [JellyfinMusicItem] = []
    private(set) var tracks: [JellyfinMusicItem] = []
    private(set) var searchResults: [JellyfinMusicItem] = []
    private(set) var queue: [JellyfinMusicItem] = []
    private(set) var current: JellyfinMusicItem?
    private(set) var isLoading = false
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
    private var userIdentifier: String?
    private var lastProgressReport = Date.distantPast

    private init() {}

    func load() async {
        guard let (base, token) = connection() else { error = "Configure Jellyfin in Settings first."; return }
        isLoading = true; defer { isLoading = false }
        do {
            let users = try await getUsers(base: base, token: token)
            userIdentifier = JellyfinAuth.shared.session?.userId ?? users.first?.Id
            albums = try await get("Items", query: [("IncludeItemTypes", "MusicAlbum"), ("Recursive", "true"), ("SortBy", "DateCreated"), ("SortOrder", "Descending")], base: base, token: token).Items
            tracks = try await get("Items", query: [("IncludeItemTypes", "Audio"), ("Recursive", "true"), ("SortBy", "Album,ParentIndexNumber,IndexNumber"), ("SortOrder", "Ascending")], base: base, token: token).Items
            error = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { self.error = error.localizedDescription }
    }

    func search(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let (base, token) = connection() else { searchResults = []; return }
        do {
            searchResults = try await get("Items", query: [("IncludeItemTypes", "Audio,MusicAlbum"), ("Recursive", "true"), ("SearchTerm", term), ("Limit", "100"), ("SortBy", "SortName"), ("SortOrder", "Ascending")], base: base, token: token).Items
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { self.error = error.localizedDescription }
    }
    func clearSearch() { searchResults = [] }

    func play(_ track: JellyfinMusicItem, from tracks: [JellyfinMusicItem]? = nil) {
        guard let (base, token) = connection() else { error = "Configure Jellyfin in Settings first."; return }
        queue = tracks ?? self.tracks
        guard let index = queue.firstIndex(of: track) else { queue = [track]; start(track, base: base, token: token); return }
        start(queue[index], base: base, token: token)
    }

    func next() {
        guard let current, let i = queue.firstIndex(of: current), let (base, token) = connection() else { return }
        let next = isShuffled && queue.count > 1 ? Int.random(in: 0..<queue.count) : (i + 1 < queue.count ? i + 1 : (repeats ? 0 : -1))
        guard next >= 0 else {
            stopReporting(); self.current = nil
            updateRemoteCommandsEnabled()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            AudioSessionConfig.configureMixedPlayback()
            return
        }
        start(queue[next], base: base, token: token)
    }
    func previous() {
        guard let current, let i = queue.firstIndex(of: current), let (base, token) = connection() else { return }
        if currentTime > 3 { player?.seek(to: .zero); return }
        let previous = i > 0 ? i - 1 : (repeats ? queue.count - 1 : -1)
        guard previous >= 0 else { player?.seek(to: .zero); return }
        start(queue[previous], base: base, token: token)
    }
    func toggle() { guard let player else { return }; if isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }; publishNowPlaying() }
    func toggleMute() { isMuted.toggle(); player?.isMuted = isMuted }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); currentTime = seconds; publishNowPlaying() }
    func artworkURL(for item: JellyfinMusicItem) -> URL? {
        guard let (base, token) = connection(), let tag = item.ImageTags?["Primary"] else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("Items/\(item.Id)/Images/Primary"), resolvingAgainstBaseURL: false)
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
        c.queryItems = [URLQueryItem(name: "UserId", value: userIdentifier ?? JellyfinAuth.shared.session?.userId), URLQueryItem(name: "ApiKey", value: token)].compactMap { item in
            guard let value = item.value else { return nil }
            return URLQueryItem(name: item.name, value: value)
        }
        guard let url = c.url else { return }
        stopReporting()
        observation = nil; player?.pause()
        if let observer = timeObserver { player?.removeTimeObserver(observer); timeObserver = nil }
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer); endObserver = nil }
        playSessionId = UUID().uuidString
        current = item
        currentTime = 0; duration = Double(item.RunTimeTicks ?? 0) / 10_000_000
        if audioMode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
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
            Task { @MainActor in self?.isPlaying = p.timeControlStatus == .playing }
        }
        timeObserver = nextPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let d = nextPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.reportProgress()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nextPlayer.currentItem, queue: .main) { [weak self] _ in Task { @MainActor in self?.next() } }
        reportStarted()
        publishNowPlaying()
    }

    private func get(_ path: String, query: [(String,String)], base: URL, token: String) async throws -> JellyfinMusicPage {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } + [URLQueryItem(name: "ApiKey", value: token)]
        var request = URLRequest(url: c.url!); request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(JellyfinMusicPage.self, from: data)
    }
    private func getUsers(base: URL, token: String) async throws -> [JellyfinUsers.User] {
        var request = URLRequest(url: base.appendingPathComponent("Users")); request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([JellyfinUsers.User].self, from: data)
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
        progressTask?.cancel()
        let ticks = Int64(max(0, currentTime) * 10_000_000)
        var payload: [String: Any] = ["ItemId": item.Id, "PlaySessionId": playSessionId, "PositionTicks": ticks]
        if includePaused { payload["IsPaused"] = !isPlaying; payload["CanSeek"] = true }
        progressTask = Task {
            var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = "POST"
            request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: request)
        }
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
