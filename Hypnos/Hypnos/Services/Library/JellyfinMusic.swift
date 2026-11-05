import AVFoundation
import Foundation
import MediaPlayer

struct JellyfinMusicNameID: Decodable, Hashable, Sendable {
    let Name: String
    let Id: String?
}

struct JellyfinMusicUserData: Decodable, Hashable, Sendable {
    let IsFavorite: Bool?
    /// 0-10; the Jellyfin web UI ignores it, so stars are Hypnos's own view of it.
    let Rating: Double?
    let PlayCount: Int?
    let Likes: Bool?
}

struct JellyfinMusicStream: Decodable, Hashable, Sendable {
    let `Type`: String?
    let Codec: String?
    let BitDepth: Int?
    let SampleRate: Int?
    let BitRate: Int?
    let Channels: Int?
}

struct JellyfinMusicItem: Decodable, Identifiable, Hashable, Sendable {
    let Id: String
    let Name: String
    let `Type`: String?
    let AlbumId: String?
    let DateCreated: String?
    let ChildCount: Int?
    let IndexNumber: Int?
    /// The disc number on a song.
    let ParentIndexNumber: Int?
    let ProductionYear: Int?
    let Genres: [String]?
    let Overview: String?
    let AlbumPrimaryImageTag: String?
    let NormalizationGain: Double?
    let AlbumNormalizationGain: Double?
    let Album: String?
    let AlbumArtist: String?
    let AlbumArtists: [JellyfinMusicNameID]?
    let Artists: [String]?
    let ArtistItems: [JellyfinMusicNameID]?
    let RunTimeTicks: Int64?
    let ImageTags: [String: String]?
    let HasLyrics: Bool?
    let UserData: JellyfinMusicUserData?
    let MediaStreams: [JellyfinMusicStream]?
    /// Set on a playlist's songs; the handle for removing and moving that entry.
    let PlaylistItemId: String?
    var isSong: Bool { self.Type == "Audio" }
    var id: String { Id }
    var artist: String { AlbumArtist ?? Artists?.joined(separator: ", ") ?? "Unknown Artist" }
    /// The first audio stream, which is what a lossless badge is read from.
    var audioStream: JellyfinMusicStream? { MediaStreams?.first { $0.Type == "Audio" } }
    var albumArtistID: String? { AlbumArtists?.first?.Id }
    var artistID: String? { ArtistItems?.first?.Id }
    var seconds: Double { Double(RunTimeTicks ?? 0) / 10_000_000 }

    /// A navigation target made from what a song already knows about its album or artist.
    static func reference(id: String, name: String, type: String, artist: String? = nil) -> JellyfinMusicItem? {
        var object: [String: Any] = ["Id": id, "Name": name, "Type": type]
        if let artist { object["AlbumArtist"] = artist }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(JellyfinMusicItem.self, from: data)
    }
}

struct JellyfinMusicPage: Decodable, Sendable {
    let Items: [JellyfinMusicItem]
    let TotalRecordCount: Int?
}

/// What Jellyfin holds about one song's plays for the listener.
struct MusicPlayState: Sendable {
    let playCount: Int
    let played: Bool
    let lastPlayed: String?
}

/// What happens when a song ends: stop at the end of the queue, wrap around it, or play the same song again.
enum MusicRepeatMode: String, Sendable {
    case off, all, one
    var next: MusicRepeatMode { self == .off ? .all : self == .all ? .one : .off }
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
    /// Where `current` sits in `queue`. A song can be queued twice, so a position (never the song's id) is what
    /// identifies "now playing", what Next advances from and what the Up Next list marks.
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var isMuted = false
    private(set) var volume = min(1, max(0, UserDefaults.standard.object(forKey: "jellyfinMusic.volume") as? Double ?? 1))
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var audioMode = JellyfinMusicAudioMode(rawValue: UserDefaults.standard.string(forKey: "jellyfinMusic.audioMode") ?? "") ?? .speaker
    private(set) var headLocked = UserDefaults.standard.bool(forKey: "jellyfinMusic.headLocked")
    /// Even out song loudness with the server's `NormalizationGain` (Jellyfin's LUFS scan).
    private(set) var soundCheck = UserDefaults.standard.bool(forKey: "jellyfinMusic.soundCheck")
    var isShuffled = false
    private(set) var repeatMode = MusicRepeatMode(rawValue: UserDefaults.standard.string(forKey: "jellyfinMusic.repeatMode") ?? "") ?? .off
    /// Whether the queue wraps around: Repeat All, and Repeat One once the listener moves on by hand.
    var repeats: Bool { repeatMode != .off }
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
    private var preloaded: (item: AVPlayerItem, music: JellyfinMusicItem, index: Int)?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playSessionId = UUID().uuidString
    private var progressTask: Task<Void, Never>?
    /// The playing song's play state as it was before Jellyfin counted this play (it counts at the start).
    private var startTask: Task<MusicPlayState?, Never>?
    private var lastProgressReport = Date.distantPast

    private init() {}

    // MARK: - Starting playback

    /// Play `track` as part of `tracks`. `index` names the entry when the same song is in the list twice.
    func play(_ track: JellyfinMusicItem, from tracks: [JellyfinMusicItem]? = nil, at index: Int? = nil) {
        guard let (base, token) = connection() else { error = "Configure Jellyfin in Settings first."; return }
        resetRandomSource()
        isShuffled = false
        queue = tracks ?? [track]
        orderedQueue = queue
        if let index, queue.indices.contains(index) {
            start(at: index, base: base, token: token)
        } else if let found = queue.firstIndex(of: track) {
            start(at: found, base: base, token: token)
        } else {
            queue = [track]; orderedQueue = queue
            start(at: 0, base: base, token: token)
        }
    }

    /// Shuffle a concrete album/playlist once, then walk it without repeating
    /// tracks until the queue has completed (or Repeat wraps it).
    func playShuffled(_ tracks: [JellyfinMusicItem]) {
        guard !tracks.isEmpty, let (base, token) = connection() else { return }
        resetRandomSource()
        orderedQueue = tracks
        queue = tracks.shuffled()
        isShuffled = true
        start(at: 0, base: base, token: token)
    }

    func playRandomPage(_ tracks: [JellyfinMusicItem], source: MusicRequest, library: JellyfinLibrary) {
        guard !tracks.isEmpty else { return }
        playShuffled(tracks)
        randomSource = source
        randomLibrary = library
        randomConfiguration = LibraryService.configurationKey
    }

    func next() {
        guard let currentIndex, let (base, token) = connection() else { return }
        if currentIndex + 1 < queue.count {
            start(at: currentIndex + 1, base: base, token: token)
        } else if let randomSource, let randomLibrary {
            refillRandomQueue(source: randomSource, library: randomLibrary)
        } else if repeats, !queue.isEmpty {
            start(at: 0, base: base, token: token)
        } else { stop() }
    }

    func previous() {
        guard let currentIndex, let (base, token) = connection() else { return }
        if currentTime > 3 { player?.seek(to: .zero); return }
        let previous = currentIndex > 0 ? currentIndex - 1 : (repeats ? queue.count - 1 : -1)
        guard previous >= 0 else { player?.seek(to: .zero); return }
        start(at: previous, base: base, token: token)
    }

    /// Jump to an entry of the queue (a tap in Up Next).
    func jump(to index: Int) {
        guard queue.indices.contains(index), let (base, token) = connection() else { return }
        start(at: index, base: base, token: token)
    }

    // MARK: - Editing the queue

    /// Put `item` right behind the playing song. With nothing playing it simply starts.
    func playNext(_ item: JellyfinMusicItem) { insert([item], at: (currentIndex ?? -1) + 1) }
    func playNext(_ items: [JellyfinMusicItem]) { insert(items, at: (currentIndex ?? -1) + 1) }
    /// Put `items` at the end of the queue.
    func addToQueue(_ items: [JellyfinMusicItem]) { insert(items, at: queue.count) }

    private func insert(_ items: [JellyfinMusicItem], at position: Int) {
        guard !items.isEmpty else { return }
        guard current != nil, currentIndex != nil else { play(items[0], from: items); return }
        let at = min(max(0, position), queue.count)
        queue.insert(contentsOf: items, at: at)
        if let currentIndex, at <= currentIndex { self.currentIndex = currentIndex + items.count }
        // A random-refill queue is finished once the listener adds to it by hand.
        syncOrderedQueueAfterEdit(adding: items)
        refreshPreload()
    }

    /// Remove an entry. The playing song can't be removed (Next skips past it).
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        queue.remove(at: index)
        if let currentIndex, index < currentIndex { self.currentIndex = currentIndex - 1 }
        if !isShuffled { orderedQueue = queue }
        refreshPreload()
    }

    /// Move an entry so it ends up at `destination` in the new order.
    func moveInQueue(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), queue.indices.contains(destination), source != destination else { return }
        let entry = queue.remove(at: source)
        queue.insert(entry, at: destination)
        if let currentIndex {
            if currentIndex == source { self.currentIndex = destination }
            else if source < currentIndex, destination >= currentIndex { self.currentIndex = currentIndex - 1 }
            else if source > currentIndex, destination <= currentIndex { self.currentIndex = currentIndex + 1 }
        }
        if !isShuffled { orderedQueue = queue }
        refreshPreload()
    }

    private func syncOrderedQueueAfterEdit(adding items: [JellyfinMusicItem]) {
        if isShuffled { orderedQueue.append(contentsOf: items) } else { orderedQueue = queue }
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

    /// Whether the queue refills itself from the server when it runs out (a library or artist shuffle).
    var hasRandomRefill: Bool { randomSource != nil }

    private func resetRandomSource() {
        queueGeneration = UUID()
        refillTask?.cancel()
        refillTask = nil
        randomSource = nil
        randomLibrary = nil
        randomConfiguration = nil
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
        applyVolume()
        UserDefaults.standard.set(volume, forKey: "jellyfinMusic.volume")
    }

    // MARK: - Sound Check

    func setSoundCheck(_ enabled: Bool) {
        soundCheck = enabled
        UserDefaults.standard.set(enabled, forKey: "jellyfinMusic.soundCheck")
        applyVolume()
    }

    /// The loudness correction the server measured for the playing song, in dB (negative: it is loud).
    var currentGainDB: Double? { current?.NormalizationGain ?? current?.AlbumNormalizationGain }

    /// What Sound Check multiplies the volume by. AVPlayer can't go above 1.0, so a quiet song stays as it is.
    nonisolated static func soundCheckFactor(gainDB: Double?) -> Double {
        guard let gainDB, gainDB.isFinite else { return 1 }
        return min(1, max(0.05, pow(10, gainDB / 20)))
    }

    private func applyVolume() {
        let factor = soundCheck ? Self.soundCheckFactor(gainDB: currentGainDB) : 1
        player?.volume = Float(volume * factor)
    }

    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); currentTime = seconds; publishNowPlaying() }
    func artworkURL(for item: JellyfinMusicItem, maxWidth: Int = 360) -> URL? {
        guard let (base, token) = connection() else { return nil }
        let imageID = item.ImageTags?["Primary"] != nil ? item.Id : item.AlbumId
        guard let imageID, let tag = item.ImageTags?["Primary"] ?? item.AlbumPrimaryImageTag else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("Items/\(imageID)/Images/Primary"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "maxWidth", value: String(maxWidth)), URLQueryItem(name: "ApiKey", value: token)]
        return c?.url
    }
    func toggleShuffle() {
        guard let current, let currentIndex else { isShuffled.toggle(); return }
        isShuffled.toggle()
        if isShuffled {
            orderedQueue = queue
            var rest = queue
            rest.remove(at: currentIndex)
            queue = [current] + rest.shuffled()
            self.currentIndex = 0
        } else {
            queue = orderedQueue
            self.currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
            resetRandomSource()
        }
        refreshPreload()
    }
    /// Off, then Repeat All, then Repeat One.
    func toggleRepeat() {
        repeatMode = repeatMode.next
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "jellyfinMusic.repeatMode")
        refreshPreload()
    }

    /// Everything after the playing song leaves the queue, and a random queue stops refilling: the song plays out
    /// and that is the end (iTunes's Clear Up Next).
    func clearUpNext() {
        guard let currentIndex else { return }
        resetRandomSource()
        queue.removeSubrange((currentIndex + 1)...)
        orderedQueue = queue
        refreshPreload()
    }

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

    /// Where playback goes after the current song, when that is already known (not a random refill).
    private func upcomingIndex() -> Int? {
        guard let currentIndex, repeatMode != .one else { return nil }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if randomSource == nil, repeats, !queue.isEmpty { return 0 }
        return nil
    }

    /// Queue the next song behind the playing one (or drop a stale one), for gapless playback.
    private func refreshPreload() {
        guard let queuePlayer = player as? AVQueuePlayer else { return }
        let wanted = upcomingIndex()
        if let preloaded, let wanted, preloaded.index == wanted, preloaded.music.id == queue[wanted].id { return }
        if let preloaded { queuePlayer.remove(preloaded.item); self.preloaded = nil }
        guard let wanted, let (base, token) = connection(),
              let item = makePlayerItem(for: queue[wanted], base: base, token: token) else { return }
        queuePlayer.insert(item, after: queuePlayer.currentItem)
        preloaded = (item, queue[wanted], wanted)
    }

    /// The queue player rolled into the preloaded song: move the session's state onto it.
    private func advanceToPreloaded() {
        guard let preloaded else { return }
        self.preloaded = nil
        finishReporting()
        playSessionId = UUID().uuidString
        current = preloaded.music
        currentIndex = preloaded.index
        currentTime = 0
        duration = Double(preloaded.music.RunTimeTicks ?? 0) / 10_000_000
        isPlaying = true
        applyVolume()
        reportStarted()
        publishNowPlaying()
        refreshPreload()
    }

    private func start(at index: Int, base: URL, token: String) {
        guard queue.indices.contains(index),
              let firstItem = makePlayerItem(for: queue[index], base: base, token: token) else { return }
        let item = queue[index]
        finishReporting()
        releasePlayer()
        playSessionId = UUID().uuidString
        current = item
        currentIndex = index
        currentTime = 0; duration = Double(item.RunTimeTicks ?? 0) / 10_000_000
        if audioMode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
        else { AudioSessionConfig.configureMixedPlayback() }
        let nextPlayer = AVQueuePlayer(items: [firstItem])
        nextPlayer.actionAtItemEnd = .advance
        player = nextPlayer
        nextPlayer.isMuted = isMuted
        applyVolume()
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
                // Repeat One starts the same song over; nothing is queued behind it, so the end lands here.
                if self.repeatMode == .one, let index = self.currentIndex, let (base, token) = self.connection() {
                    self.start(at: index, base: base, token: token)
                } else { self.next() }
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
        finishReporting()
        releasePlayer()
        current = nil
        currentIndex = nil
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

    // MARK: - Reporting to Jellyfin

    private func reportStarted() {
        guard let (base, token) = connection(), let item = current else { return }
        let userID = JellyfinAuth.shared.session?.userId
        nonisolated(unsafe) let payload: [String: Any] = ["ItemId": item.Id, "PlaySessionId": playSessionId, "PositionTicks": 0,
                                                            "IsPaused": false, "CanSeek": true]
        startTask = Task {
            // Jellyfin counts a play the moment it hears of the start, so the state worth keeping is read first.
            let before = await Self.readPlayState(base: base, token: token, userID: userID, itemID: item.Id)
            await Self.deliverReport(path: "Sessions/Playing", payload: payload, base: base, token: token, userID: userID,
                                     itemID: item.Id, restoring: nil)
            return before
        }
    }
    private func reportProgress() {
        guard Date().timeIntervalSince(lastProgressReport) >= 10 else { return }
        lastProgressReport = Date()
        sendReport("Sessions/Playing/Progress", includePaused: true)
    }

    /// Whether a listen counts as a play: half the song or four minutes, the rule scrobblers use.
    nonisolated static func isCountedListen(seconds: Double, duration: Double) -> Bool {
        guard duration > 0 else { return seconds >= 30 }
        return seconds >= min(duration * 0.5, 240)
    }

    /// Tell Jellyfin the song ended. Jellyfin counts a play when a song starts, so every skip would land in Most
    /// Played and Recently Played; a song left before a real listen has its play state put back as it was
    /// before it started.
    private func finishReporting() {
        progressTask?.cancel()
        let counted = Self.isCountedListen(seconds: currentTime, duration: duration)
        let started = startTask
        startTask = nil
        guard let (base, token) = connection(), let item = current else { isPlaying = false; return }
        let ticks = Int64(max(0, currentTime) * 10_000_000)
        nonisolated(unsafe) let payload: [String: Any] = ["ItemId": item.Id, "PlaySessionId": playSessionId, "PositionTicks": ticks]
        let userID = JellyfinAuth.shared.session?.userId
        Task {
            let before = counted ? nil : await started?.value
            await Self.deliverReport(path: "Sessions/Playing/Stopped", payload: payload, base: base, token: token, userID: userID,
                                     itemID: item.Id, restoring: before)
        }
        isPlaying = false
    }

    private func sendReport(_ path: String, includePaused: Bool) {
        guard let (base, token) = connection(), let item = current else { return }
        let ticks = Int64(max(0, currentTime) * 10_000_000)
        var payload: [String: Any] = ["ItemId": item.Id, "PlaySessionId": playSessionId, "PositionTicks": ticks]
        if includePaused { payload["IsPaused"] = !isPlaying; payload["CanSeek"] = true }
        let userID = JellyfinAuth.shared.session?.userId
        nonisolated(unsafe) let body = payload
        progressTask = Task {
            await Self.deliverReport(path: path, payload: body, base: base, token: token, userID: userID, itemID: item.Id, restoring: nil)
        }
    }

    /// A song's play state as Jellyfin holds it for the signed-in user. Nil on an API key (no user to count for).
    nonisolated static func readPlayState(base: URL, token: String, userID: String?, itemID: String) async -> MusicPlayState? {
        guard let userID else { return nil }
        var read = URLRequest(url: base.appendingPathComponent("Users/\(userID)/Items/\(itemID)"))
        read.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: read),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["UserData"] as? [String: Any] else { return nil }
        return MusicPlayState(playCount: state["PlayCount"] as? Int ?? 0, played: state["Played"] as? Bool ?? false,
                              lastPlayed: state["LastPlayedDate"] as? String)
    }

    /// Post a playback report, then, with `restoring`, write that play state back.
    nonisolated static func deliverReport(path: String, payload: [String: Any], base: URL, token: String, userID: String?,
                                          itemID: String, restoring: MusicPlayState?) async {
        let authorization = "MediaBrowser Token=\"\(token)\""
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: request)
        guard let restoring, let userID else { return }
        var restore: [String: Any] = ["PlayCount": restoring.playCount, "Played": restoring.played]
        if let last = restoring.lastPlayed { restore["LastPlayedDate"] = last }
        var write = URLRequest(url: base.appendingPathComponent("UserItems/\(itemID)/UserData").appending(queryItems: [URLQueryItem(name: "userId", value: userID)]))
        write.httpMethod = "POST"
        write.setValue(authorization, forHTTPHeaderField: "Authorization")
        write.setValue("application/json", forHTTPHeaderField: "Content-Type")
        write.httpBody = try? JSONSerialization.data(withJSONObject: restore)
        _ = try? await URLSession.shared.data(for: write)
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
            // Anchored to the user's front, not to whichever window is active: automatic
            // anchoring followed the active scene, so opening a window (a photo viewer)
            // moved the sound's anchor and cut the music.
            : .headTracked(.front, soundStageSize: .automatic)
        #endif
    }
    private func connection() -> (URL,String)? {
        let s = FilmSession.shared
        guard let base = URL(string: s.server), !s.apiKey.isEmpty || JellyfinAuth.shared.session != nil else { return nil }
        return (base, JellyfinAuth.shared.session?.accessToken ?? s.apiKey)
    }
}
