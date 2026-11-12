import AVFoundation
import Foundation
import MediaPlayer
import RAVEMedia

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
    let LastPlayedDate: String?
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
    /// The file's container ("flac", "mp3", "mov,mp4,m4a,3gp,3g2,mj2"): what the music engine fetches.
    let Container: String?
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
    /// Who performs a song: its own artists, which differ from the album's on a compilation or a feature.
    var songArtist: String { Artists.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") } ?? artist }
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
    private(set) var volume = min(1, max(0, HypnosDefaults.store.object(forKey: "jellyfinMusic.volume") as? Double ?? 1))
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var audioMode = JellyfinMusicAudioMode(rawValue: HypnosDefaults.store.string(forKey: "jellyfinMusic.audioMode") ?? "") ?? .speaker
    private(set) var headLocked = HypnosDefaults.store.bool(forKey: "jellyfinMusic.headLocked")
    /// Even out song loudness with the server's `NormalizationGain` (Jellyfin's LUFS scan).
    private(set) var soundCheck = HypnosDefaults.store.bool(forKey: "jellyfinMusic.soundCheck")
    var isShuffled = false
    /// Whether the equalizer shapes the music (it filters the engine's output, so every song). Nil before playback.
    private(set) var eqResult: EQAttachResult?
    private(set) var repeatMode = MusicRepeatMode(rawValue: HypnosDefaults.store.string(forKey: "jellyfinMusic.repeatMode") ?? "") ?? .off
    /// Whether the queue wraps around: Repeat All, and Repeat One once the listener moves on by hand.
    var repeats: Bool { repeatMode != .off }
    var error: String?
    /// Seconds two songs overlap when one gives way to the next; 0 is Off (every join gapless).
    private(set) var crossfadeSeconds = min(12, max(0, HypnosDefaults.store.object(forKey: "jellyfinMusic.crossfadeSeconds") as? Double ?? 0))
    /// What a crossfade does between an album's consecutive tracks.
    private(set) var albumCrossfade = MusicAlbumCrossfade(rawValue: HypnosDefaults.store.string(forKey: "jellyfinMusic.crossfadeAlbums") ?? "") ?? .unlessSeamless
    /// How the playing song will give way to the next one, once that is planned.
    private(set) var upcomingTransition: MusicTimeline.Transition?
    @ObservationIgnored private var orderedQueue: [JellyfinMusicItem] = []
    @ObservationIgnored private var randomSource: MusicRequest?
    @ObservationIgnored private var randomLibrary: JellyfinLibrary?
    @ObservationIgnored private var randomConfiguration: String?
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    @ObservationIgnored private var queueGeneration = UUID()
    /// Plays the queue (`Services/Library/MusicEngine/`): decoded on the device, every join sample-exact.
    @ObservationIgnored private var engine: MusicPlaybackEngine?
    /// The playing song's handle in the engine.
    @ObservationIgnored private var currentToken: UUID?
    /// The next song, already handed to the engine behind the playing one, and how the two will join.
    @ObservationIgnored private var preloaded: (token: UUID, music: JellyfinMusicItem, index: Int, transition: MusicTimeline.Transition)?
    /// Songs whose original file the device couldn't read: fetched as a server FLAC instead.
    @ObservationIgnored private var transcodeIDs: Set<String> = []
    @ObservationIgnored private var lastFailureSkip = Date.distantPast
    @ObservationIgnored private var resumesAfterInterruption = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    private var playSessionId = UUID().uuidString
    private var progressTask: Task<Void, Never>?
    /// The playing song's play state as it was before Jellyfin counted this play (it counts at the start).
    private var startTask: Task<MusicPlayState?, Never>?
    private var lastProgressReport = Date.distantPast

    private init() {
        SleepTimer.shared.register(self) { [weak self] in
            guard let self, self.isPlaying else { return false }
            self.pause()
            return true
        }
    }

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
        if currentTime > 3 { seek(to: 0); return }
        let previous = currentIndex > 0 ? currentIndex - 1 : (repeats ? queue.count - 1 : -1)
        guard previous >= 0 else { seek(to: 0); return }
        start(at: previous, base: base, token: token)
    }

    /// The song a Next would play, when it is already known: not at the end of a queue that stops there, and not a
    /// random queue's refill, which has yet to be fetched. What the title shows peeking in while it is flicked.
    var nextItem: JellyfinMusicItem? {
        guard let currentIndex else { return nil }
        if currentIndex + 1 < queue.count { return queue[currentIndex + 1] }
        if randomSource == nil, repeats, !queue.isEmpty { return queue[0] }
        return nil
    }

    /// The song before the playing one. Unlike the Previous button (which first restarts a song that has played
    /// for a few seconds) this is always the song before: a deliberate flick back means it.
    var previousItem: JellyfinMusicItem? {
        guard let currentIndex else { return nil }
        if currentIndex > 0 { return queue[currentIndex - 1] }
        return repeats && queue.count > 1 ? queue[queue.count - 1] : nil
    }

    /// Go to the song before this one, whatever the clock says. Does nothing at the start of a queue that stops there.
    func skipBack() {
        guard let currentIndex, previousItem != nil, let (base, token) = connection() else { return }
        start(at: currentIndex > 0 ? currentIndex - 1 : queue.count - 1, base: base, token: token)
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
        engine?.setPlaying(false)
        isPlaying = false
        publishNowPlaying()
    }
    func toggle() {
        guard currentToken != nil else { return }
        if isPlaying { pause() } else { resume() }
    }
    private func resume() {
        guard let engine, currentToken != nil else { return }
        if audioMode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
        else { AudioSessionConfig.configureMixedPlayback() }
        engine.setPlaying(true)
        isPlaying = true
        publishNowPlaying()
    }
    func toggleMute() { isMuted.toggle(); engine?.setMuted(isMuted) }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        applyVolume()
        HypnosDefaults.store.set(volume, forKey: "jellyfinMusic.volume")
    }

    // MARK: - Sound Check

    func setSoundCheck(_ enabled: Bool) {
        soundCheck = enabled
        HypnosDefaults.store.set(enabled, forKey: "jellyfinMusic.soundCheck")
        applyVolume()
    }

    /// The loudness correction the server measured for the playing song, in dB (negative: it is loud).
    var currentGainDB: Double? { current?.NormalizationGain ?? current?.AlbumNormalizationGain }

    /// What Sound Check multiplies the volume by. AVPlayer can't go above 1.0, so a quiet song stays as it is.
    nonisolated static func soundCheckFactor(gainDB: Double?) -> Double {
        guard let gainDB, gainDB.isFinite else { return 1 }
        return min(1, max(0.05, pow(10, gainDB / 20)))
    }

    /// The listener's volume on the output, and each song's Sound Check gain on its own samples (two songs
    /// crossfading each keep their own).
    private func applyVolume() {
        guard let engine else { return }
        engine.setVolume(Float(volume))
        if let currentToken, let current { engine.setGain(gain(for: current), for: currentToken) }
        if let preloaded { engine.setGain(gain(for: preloaded.music), for: preloaded.token) }
    }

    private func gain(for item: JellyfinMusicItem) -> Float {
        soundCheck ? Float(Self.soundCheckFactor(gainDB: item.NormalizationGain ?? item.AlbumNormalizationGain)) : 1
    }

    func seek(to seconds: Double) {
        guard let engine, let currentToken else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        engine.seek(currentToken, to: target)
        currentTime = target
        publishNowPlaying()
        // The engine drops what it had planned after the song; plan it again.
        preloaded = nil
        refreshPreload()
    }
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
        HypnosDefaults.store.set(repeatMode.rawValue, forKey: "jellyfinMusic.repeatMode")
        refreshPreload()
    }

    // MARK: - Crossfade

    func setCrossfadeSeconds(_ seconds: Double) {
        crossfadeSeconds = min(12, max(0, seconds))
        HypnosDefaults.store.set(crossfadeSeconds, forKey: "jellyfinMusic.crossfadeSeconds")
        refreshPreload()
    }

    func setAlbumCrossfade(_ value: MusicAlbumCrossfade) {
        albumCrossfade = value
        HypnosDefaults.store.set(value.rawValue, forKey: "jellyfinMusic.crossfadeAlbums")
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
        HypnosDefaults.store.set(mode.rawValue, forKey: "jellyfinMusic.audioMode")
        if current != nil {
            if mode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
            else { AudioSessionConfig.configureMixedPlayback() }
        }
        updateRemoteCommandsEnabled()
        publishNowPlaying()
    }

    func toggleHeadLocked() {
        headLocked.toggle()
        HypnosDefaults.store.set(headLocked, forKey: "jellyfinMusic.headLocked")
        applySpatialAudioPreference()
    }

    /// The engine, made on first playback with the app's equalizer on its output.
    private func makeEngine() -> MusicPlaybackEngine {
        if let engine { return engine }
        let engine = MusicPlaybackEngine(processor: MusicEngineHooks.makeProcessor())
        engine.onSongStarted = { [weak self] token in self?.engineStartedSong(token) }
        engine.onProgress = { [weak self] token, seconds, exact in self?.engineProgress(token, seconds: seconds, exact: exact) }
        engine.onFinished = { [weak self] token in self?.engineFinished(token) }
        engine.onFailure = { [weak self] token, message in self?.engineFailed(token, message: message) }
        self.engine = engine
        observeInterruptions()
        return engine
    }

    /// `item` as the engine's song: its file (fetched once, shared by every entry of it) and its gain.
    private func engineSong(_ item: JellyfinMusicItem, token: UUID, base: URL, apiToken: String) -> MusicTimeline.Song {
        let file = MusicSongFiles.shared.file(for: item, base: base, token: apiToken, fallback: transcodeIDs.contains(item.Id))
        return MusicTimeline.Song(token: token, file: file, gain: gain(for: item), estimatedSeconds: item.seconds)
    }

    /// Where playback goes after the current song, when that is already known (not a random refill).
    /// Repeat One plays the same entry again, joined without a gap.
    private func upcomingIndex() -> Int? {
        guard let currentIndex else { return nil }
        if repeatMode == .one { return currentIndex }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if randomSource == nil, repeats, !queue.isEmpty { return 0 }
        return nil
    }

    /// Hands the engine the song after this one and how to join them (or nothing), after any queue or setting change.
    private func refreshPreload() {
        guard let engine, let currentToken, let currentIndex, let current else { return }
        // Already joining or fading into it: too late to change.
        if let preloaded, engine.hasCommitted(preloaded.token) { return }
        guard let wanted = upcomingIndex(), queue.indices.contains(wanted), let (base, apiToken) = connection() else {
            if preloaded != nil { engine.setNext(nil, transition: .gapless, after: currentToken) }
            preloaded = nil
            upcomingTransition = nil
            keepFiles()
            return
        }
        let next = queue[wanted]
        let transition = transition(from: current, to: next, sameEntry: wanted == currentIndex)
        if let preloaded, preloaded.index == wanted, preloaded.music.id == next.id {
            if preloaded.transition != transition {
                self.preloaded?.transition = transition
                engine.setNext(engineSong(next, token: preloaded.token, base: base, apiToken: apiToken), transition: transition, after: currentToken)
            }
            upcomingTransition = transition
            return
        }
        let token = UUID()
        engine.setNext(engineSong(next, token: token, base: base, apiToken: apiToken), transition: transition, after: currentToken)
        preloaded = (token, next, wanted, transition)
        upcomingTransition = transition
        keepFiles()
        measureSeamIfNeeded(from: current, to: next, base: base, apiToken: apiToken)
    }

    private func transition(from a: JellyfinMusicItem, to b: JellyfinMusicItem, sameEntry: Bool) -> MusicTimeline.Transition {
        let seams = MusicSeams.shared
        let seam = MusicTransitionRules.seam(seams.known(a.Id), seams.known(b.Id))
        if seam == .continuous, MusicTransitionRules.isAlbumSequence(a, b) { seams.markSeamless(album: a.AlbumId) }
        return MusicTransitionRules.transition(from: a, to: b, crossfadeSeconds: crossfadeSeconds, albums: albumCrossfade, seam: seam,
                                               albumIsSeamless: a.AlbumId.map { seams.seamlessAlbums.contains($0) } ?? false,
                                               repeatingOne: sameEntry)
    }

    /// Listens to a seam inside an album when whether to crossfade it depends on it; plans again once it's heard.
    private func measureSeamIfNeeded(from a: JellyfinMusicItem, to b: JellyfinMusicItem, base: URL, apiToken: String) {
        guard crossfadeSeconds > 0, albumCrossfade == .unlessSeamless, MusicTransitionRules.isAlbumSequence(a, b),
              !(a.AlbumId.map { MusicSeams.shared.seamlessAlbums.contains($0) } ?? false) else { return }
        for item in [a, b] {
            let file = MusicSongFiles.shared.file(for: item, base: base, token: apiToken, fallback: transcodeIDs.contains(item.Id))
            MusicSeams.shared.measure(item, file: file) { [weak self] in self?.refreshPreload() }
        }
    }

    /// The device keeps the playing song's file, the next one's and the one before (a quick Previous).
    private func keepFiles() {
        var keep = Set<String>()
        if let current { keep.insert(current.Id) }
        if let preloaded { keep.insert(preloaded.music.Id) }
        if let currentIndex, currentIndex > 0, queue.indices.contains(currentIndex - 1) { keep.insert(queue[currentIndex - 1].Id) }
        MusicSongFiles.shared.keep(keep)
    }

    /// The engine has started playing the planned song (a gapless join, or the start of a crossfade).
    private func advanceToPreloaded() {
        guard let preloaded else { return }
        self.preloaded = nil
        finishReporting()
        playSessionId = UUID().uuidString
        current = preloaded.music
        currentIndex = preloaded.index
        currentToken = preloaded.token
        currentTime = 0
        duration = preloaded.music.seconds
        isPlaying = true
        reportStarted()
        publishNowPlaying()
        refreshPreload()
    }

    private func start(at index: Int, base: URL, token: String, from seconds: Double = 0) {
        guard queue.indices.contains(index) else { return }
        let item = queue[index]
        finishReporting()
        releasePlayer()
        playSessionId = UUID().uuidString
        current = item
        currentIndex = index
        currentTime = seconds; duration = item.seconds
        if audioMode == .music { AudioSessionConfig.configureExclusiveMusicPlayback() }
        else { AudioSessionConfig.configureMixedPlayback() }
        let engine = makeEngine()
        let songToken = UUID()
        currentToken = songToken
        engine.setVolume(Float(volume))
        engine.setMuted(isMuted)
        applySpatialAudioPreference()
        engine.start(engineSong(item, token: songToken, base: base, apiToken: token), at: seconds)
        eqResult = MusicEngineHooks.hasEqualizer ? .attached : nil
        isPlaying = true
        configureRemoteCommands()
        reportStarted()
        publishNowPlaying()
        refreshPreload()
    }

    // MARK: - What the engine reports

    private func engineStartedSong(_ token: UUID) {
        guard let preloaded, preloaded.token == token else { return }
        advanceToPreloaded()
    }

    private func engineProgress(_ token: UUID, seconds: Double, exact: Double?) {
        guard token == currentToken else { return }
        if let exact, exact > 0 { duration = exact }
        currentTime = max(0, duration > 0 ? min(seconds, duration) : seconds)
        reportProgress()
    }

    /// The last planned song has been heard to its end: what Next does from here (a random refill, or the end).
    private func engineFinished(_ token: UUID) {
        guard token == currentToken else { return }
        next()
    }

    /// A song couldn't be fetched or decoded. An original the device can't read is asked for again as a FLAC
    /// from the server; anything else skips the song (stopping if songs keep failing back to back).
    private func engineFailed(_ token: UUID, message: String) {
        let index = token == currentToken ? currentIndex : (token == preloaded?.token ? preloaded?.index : nil)
        guard let index, queue.indices.contains(index), let (base, apiToken) = connection() else { return }
        let item = queue[index]
        MusicEngineHooks.log(failure: message)
        let resumeAt = token == currentToken ? currentTime : 0
        if !transcodeIDs.contains(item.Id), MusicSongFiles.shared.downloadFailure(of: item.Id) == nil {
            transcodeIDs.insert(item.Id)
            start(at: index, base: base, token: apiToken, from: resumeAt)
            return
        }
        error = message
        if Date().timeIntervalSince(lastFailureSkip) > 5, index + 1 < queue.count {
            lastFailureSkip = Date()
            start(at: index + 1, base: base, token: apiToken)
        } else {
            stop()
        }
    }

    /// A phone call or another app's audio stops the music; it carries on afterwards when the system says so.
    private func observeInterruptions() {
        #if !os(macOS)
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self, let type else { return }
                if type == .began {
                    self.resumesAfterInterruption = self.isPlaying
                    if self.isPlaying { self.pause() }
                } else if options.contains(.shouldResume), self.resumesAfterInterruption {
                    self.resumesAfterInterruption = false
                    self.resume()
                }
            }
        }
        #endif
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
        keepFiles()
        AudioSessionConfig.configureMixedPlayback()
    }

    private func releasePlayer() {
        engine?.stop()
        currentToken = nil
        preloaded = nil
        upcomingTransition = nil
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
            center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
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
        engine?.setSpatialExperience(headLocked
            ? .fixed(soundStageSize: .automatic)
            // Anchored to the user's front, not to whichever window is active: automatic
            // anchoring followed the active scene, so opening a window (a photo viewer)
            // moved the sound's anchor and cut the music.
            : .headTracked(.front, soundStageSize: .automatic))
        #endif
    }
    private func connection() -> (URL,String)? {
        let s = FilmSession.shared
        guard let base = URL(string: s.server), !s.apiKey.isEmpty || JellyfinAuth.shared.session != nil else { return nil }
        return (base, JellyfinAuth.shared.session?.accessToken ?? s.apiKey)
    }
}

