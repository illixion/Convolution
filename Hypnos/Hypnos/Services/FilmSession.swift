/*
 Hypnos - film player session (Settings → Developer → Film Player)

 App glue around RAVEFilm's `FilmPlayer`: the Jellyfin server and API
 key, library search, which item is loaded, and whether the player is
 showing. The player itself (picture, Atmos object audio, one clock) lives
 in RAVESDK's `RAVEFilm` target. The server needs the Atmos
 Objects plugin (`JellyfinPlugin/`), which serves both the video segments
 and the object audio.
 */

import DebugTrace
import RAVEFilm
import RAVEMedia
import Foundation
import Observation

@MainActor
@Observable
final class FilmSession {
    static let shared = FilmSession()

    let player: FilmPlayer = {
        let player = FilmPlayer()
        player.volume = Float(PlayerVolume.saved)
        // Every film's objects and room follow the listener's equalizer.
        player.audioEQ = AudioEQ.shared
        return player
    }()
    /// The loaded item's subtitle tracks, drawn over the picture by the player view.
    let subtitles = SubtitleController()
    #if os(iOS) || os(macOS) || os(tvOS)
    /// The system's Picture in Picture for the film's picture, offered while
    /// the player view is up (`FilmPlayerView`).
    @ObservationIgnored private(set) lazy var pictureInPicture = FilmPictureInPicture(player: player)
    #endif
    /// How the loaded film packs its eyes, when it is a 3D film (Jellyfin's
    /// `Video3DFormat`). The player view plays it as real 3D, cropped per
    /// eye, instead of the fake-3D warp. Arrives just after the picture.
    private(set) var stereoFormat: StereoscopicFormat?
    @ObservationIgnored private var stereoFormatTask: Task<Void, Never>?

    var server: String = FilmSession.storedServer {
        didSet {
            HypnosDefaults.store.set(server, forKey: "filmPlayer.jellyfinServer")
            Self.excludeFromOtherCredentials(server)
        }
    }

    private nonisolated static var storedServer: String {
        HypnosDefaults.store.string(forKey: "filmPlayer.jellyfinServer")
            ?? HypnosDefaults.store.string(forKey: "atmosSpike.jellyfinServer") ?? ""
    }

    /// Registers the exclusion below for the saved server without building
    /// the session. `AppModel.init` calls this, because a restored video
    /// window can open a Jellyfin stream before anything touches `shared`.
    nonisolated static func excludeStoredServerFromOtherCredentials() {
        excludeFromOtherCredentials(storedServer)
    }

    /// Keeps a credential registered for the same host (Stash behind the
    /// same reverse proxy) off Jellyfin URLs. See
    /// `MediaAuthorization.excludeCredentials(under:owner:)`.
    private nonisolated static func excludeFromOtherCredentials(_ server: String) {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        let url = URL(string: trimmed).flatMap { $0.host == nil ? nil : $0 }
        MediaAuthorization.shared.excludeCredentials(under: url, owner: "jellyfin")
    }
    var apiKey: String = {
        // Same UserDefaults→Keychain migration shape as the Stash API key
        // (see `scripts/dev-stash.sh auth`'s use of `stashAPIKey`): a plain
        // Keychain secret has no `-UITestDefault key=value` route in from a
        // launch argument, so DEBUG-only test/harness runs seed it through
        // this legacy UserDefaults key instead, migrated in on first read.
        KeychainStore.migrateFromUserDefaults(legacyKey: "filmPlayer.jellyfinAPIKeyLegacy", to: .jellyfinAPIKey)
        return KeychainStore.string(for: .jellyfinAPIKey) ?? ""
    }() {
        didSet { KeychainStore.set(apiKey, for: .jellyfinAPIKey) }
    }

    private(set) var searchResults: [FilmLibraryItem] = []
    /// How the loaded film's picture and sound get to the player, for the
    /// playback info panel (the video window's, `PlaybackInfoPanel`). Nil for
    /// a download or before a film is loaded.
    private(set) var playbackInfo: PlaybackInfo?
    /// The loaded film's chapters; empty until the server answers, or without any.
    private(set) var chapters: [FilmChapter] = []
    @ObservationIgnored private var chaptersTask: Task<Void, Never>?
    private(set) var loadedItem: FilmLibraryItem? {
        didSet {
            guard loadedItem?.id != oldValue?.id else { return }
            loadSharedFields()
        }
    }
    /// Smooth Motion's fields for the loaded film's 3D picture, from an
    /// analysis track (`SmoothMotionTracks`); nil without one, and then a
    /// packed 3D picture plays without in-between frames.
    private(set) var sharedFields: AnalysisTrackFieldProvider?
    /// A 2D film's fields from an analysis coordinator (`smooth-motion-2d`),
    /// for Smooth Motion in AI 3D; nil for a 3D film or without a coordinator.
    private(set) var monoSharedFields: AnalysisTrackFieldProvider?
    @ObservationIgnored private var sharedFieldsTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var error: String?
    /// Whether the player window (or the iOS sheet) is showing.
    var isPlayerOpen = false

    #if os(visionOS)
    // Shared with the separate adjustments window; the picture host owns
    // the decoder, while both windows edit this same presentation state.
    var stereoEnabled = false
    var stereoSettings = Pseudo3DSettings.default
    /// The stereo source whose tap is on the player's picture. A film window
    /// closing late (after the next one opened) clears only its own.
    @ObservationIgnored var stereoTapOwner: ObjectIdentifier?
    #endif
    /// The film player view showing `player` now. One closing after its
    /// replacement appeared mustn't pause or close the new playback.
    @ObservationIgnored var activePlayerView: UUID?

    /// visionOS: whether the listener's assumed distance from the player
    /// window follows the window's dynamic scale (`FilmListenerDistance.automatic`).
    /// A window can't see the head, so either way it is a guess.
    var listenerDistanceAuto = true
    /// visionOS: the listener's distance in real metres while not automatic.
    var listenerDistance: Float = 1.5
    /// visionOS: the player window's dynamic scale, as the stage last read it.
    var windowScale: Float = 1

    #if os(visionOS)
    var listenerPlacement: FilmListenerDistance {
        listenerDistanceAuto ? .automatic() : .fixed(listenerDistance)
    }
    #endif
    /// tvOS: whether PHASE turns the listener with the wearer's head
    /// (AirPods). Persisted with the rest of the sound settings.
    var headTracking = true
    /// Bumped by a Recenter button; the stage recentres on each change.
    var recenterRequest = 0

    private init() {
        player.onCaptionSourceChanged = { [weak self] in
            guard let self else { return }
            self.subtitles.bindGeneratedFilm(self.player)
        }
        restoreSound()
        subtitles.playhead = { [weak self] in self?.player.currentTime ?? 0 }
        SleepTimer.shared.register(self) { [weak self] in
            guard let player = self?.player, player.isPlaying else { return false }
            player.pause()
            return true
        }
        Self.excludeFromOtherCredentials(server)
        // Starts watching the network, so Auto object-audio quality knows
        // the path by the time a film loads.
        _ = NetworkCost.shared
    }

    // MARK: Sound settings

    /// The player's sound tuning as saved between launches. Not every
    /// platform uses every field: PHASE (tvOS) ignores `roomSource`, and
    /// RealityKit's stage reads the preset only while `roomSource` is
    /// `.virtual`.
    private struct SoundSettings: Codable {
        var masterGainDB: Float
        var lfeGainDB: Float
        var reverbDB: Float
        var reverbPreset: RAVEReverbPreset
        var roomHalfWidth: Float
        var roomHalfDepth: Float
        var roomHeight: Float
        var avOffsetMs: Double
        var headTracking: Bool
        /// Optional: settings saved before it existed decode as `.system`.
        var roomSource: FilmRoomSource?
        /// Optional: settings saved before they existed decode as automatic.
        var listenerDistanceAuto: Bool?
        var listenerDistance: Float?
    }

    private static let soundKey = "filmPlayer.sound"

    func saveSound() {
        let settings = SoundSettings(
            masterGainDB: player.masterGainDB, lfeGainDB: player.lfeGainDB, reverbDB: player.reverbDB,
            reverbPreset: player.reverbPreset, roomHalfWidth: player.roomHalfWidth,
            roomHalfDepth: player.roomHalfDepth, roomHeight: player.roomHeight,
            avOffsetMs: player.avOffsetMs, headTracking: headTracking, roomSource: player.roomSource,
            listenerDistanceAuto: listenerDistanceAuto, listenerDistance: listenerDistance
        )
        if let data = try? JSONEncoder().encode(settings) {
            HypnosDefaults.store.set(data, forKey: Self.soundKey)
        }
    }

    private func restoreSound() {
        guard let data = HypnosDefaults.store.data(forKey: Self.soundKey),
              let settings = try? JSONDecoder().decode(SoundSettings.self, from: data) else {
            #if os(tvOS)
            // PHASE's send is linear: 0 dB would be fully wet. RealityKit's
            // per-source level keeps its own 0 dB default elsewhere.
            player.reverbDB = -12
            #endif
            return
        }
        player.masterGainDB = settings.masterGainDB
        player.lfeGainDB = settings.lfeGainDB
        player.reverbDB = settings.reverbDB
        player.reverbPreset = settings.reverbPreset
        player.roomSource = settings.roomSource ?? .system
        player.roomHalfWidth = settings.roomHalfWidth
        player.roomHalfDepth = settings.roomHalfDepth
        player.roomHeight = settings.roomHeight
        player.avOffsetMs = settings.avOffsetMs
        headTracking = settings.headTracking
        listenerDistanceAuto = settings.listenerDistanceAuto ?? true
        listenerDistance = settings.listenerDistance ?? listenerDistance
    }

    /// Whether a Jellyfin server is configured at all — the gate for
    /// showing the Library tab (hidden until this is true, per the Library
    /// feature's decision #3) on every platform.
    var isConfigured: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Jellyfin's `Authorization` header token accepts a signed-in session's access
    /// token exactly the same way it accepts a plain API key, so a signed-in
    /// user needs no separate token here — prefer that session (it's what
    /// makes watch-progress reporting work at all, see
    /// `JellyfinServerSection`'s header comment) and fall back to the manual
    /// API key.
    private var effectiveToken: String? {
        if let sessionToken = JellyfinAuth.shared.session?.accessToken, !sessionToken.isEmpty {
            return sessionToken
        }
        return apiKey.isEmpty ? nil : apiKey
    }

    private var serverURL: URL? {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard effectiveToken != nil,
              let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              url.scheme != nil else { return nil }
        return url
    }

    func search(_ term: String) async {
        guard let serverURL, let token = effectiveToken else {
            error = "Set the Jellyfin server URL, then sign in or set an API key."
            return
        }
        do {
            searchResults = try await FilmServerClient.search(baseURL: serverURL, token: token, term: term)
            error = searchResults.isEmpty ? "No items match “\(term)”." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads `item` into the player. True when its picture is ready to play.
    /// - Parameter picture: the item's picture is decoded on the device
    ///   (`MVCPictureSource`) from the raw file: a Blu-ray disc image or
    ///   folder, a 3D Blu-ray remuxed to Matroska, or both views in one
    ///   transport stream (read and sounded as a disc is). The plugin's video
    ///   segments are unavailable for a disc and 2D for a remux; the plugin
    ///   still supplies the object audio.
    func load(_ item: FilmLibraryItem, picture: FilmDecodedPicture? = nil) async -> Bool {
        if let record = LibraryOfflineStore.shared.record(for: item.id), record.playback != .video {
            return await loadDownloaded(record, item: item)
        }
        guard let serverURL, let token = effectiveToken, !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        stereoFormatTask?.cancel()
        stereoFormat = nil
        playbackInfo = nil
        chapters = []
        chaptersTask?.cancel()
        chaptersTask = Task { [weak self] in
            let loaded = await LibraryService.current()?.chapters(itemId: item.id) ?? []
            guard !Task.isCancelled, let self else { return }
            self.chapters = loaded
        }
        var ownSoundUsed = false
        var disc: MVCPictureSource?
        if let picture {
            let url = serverURL.appending(path: "Videos/\(item.id)/stream").appending(queryItems: [.init(name: "static", value: "true")])
            let headers = ["Authorization": JellyfinClientIdentity.authorizationHeader(token: token)]
            do {
                disc = switch picture {
                case .disc: try await MVCPictureSource.open(url: url, headers: headers)
                case .matroskaMVC: try await MVCPictureSource.openMatroska(url: url, headers: headers)
                case .transportStreamMVC: try await MVCPictureSource.openTransportStream(url: url, headers: headers)
                }
            } catch {
                self.error = picture == .disc ? "The disc couldn't be read: \(error.localizedDescription)"
                    : "The 3D picture couldn't be read: \(error.localizedDescription)"
                AppLogger.filmPlayer.error("Decoded picture open failed: \(error.localizedDescription)")
                subtitles.load(nil)
                return false
            }
        }
        var client = FilmServerClient(baseURL: serverURL, token: token, itemID: item.id)
        ObjectAudioQuality.preferred.apply(to: &client)
        client.applyEdition()
        if let disc {
            // The remux's reader authenticates by query, as the video
            // window's on-device remux of a Library file does.
            await Self.load(player, client: client, decoded: disc, pictureHeight: FilmPictureQuality.preferred.height) {
                ownSoundUsed = true
                return disc.isDisc
                    ? (try? disc.audioSource(itemID: item.id))
                    : await MatroskaFilmAudioSource.open(
                        itemID: item.id, url: disc.sourceURL.appending(queryItems: [.init(name: "ApiKey", value: token)]),
                        durationSeconds: disc.durationSeconds)
            }
        } else {
            // A fixed lower tier opens there when the plugin offers it.
            await player.load(client, pictureHeight: FilmPictureQuality.preferred.height)
        }
        guard player.video.isLoaded else {
            error = player.video.status
            subtitles.load(nil)
            return false
        }
        loadedItem = item
        subtitles.load(disc?.subtitles.map { .disc($0, itemId: item.id) } ?? .jellyfin(itemId: item.id))
        subtitles.bindGeneratedFilm(player)
        if let disc {
            // The eyes come top and bottom out of MVCPictureSource's stereo frames.
            stereoFormat = disc.isStereo ? .overUnder : nil
            playbackInfo = PlaybackInfo(
                route: .deviceDecode, severity: .normal, server: "Jellyfin",
                reasons: ownSoundUsed ? ["the server has no object audio for this film, so its own sound plays, decoded on this device"] : [],
                picture: "\(disc.isStereo ? "3D" : "2D") · \(String(format: "%.3f", disc.frameRate)) fps",
                range: nil, rangeFromFrames: false, transcode: nil,
                source: "\(disc.summary) · \(ownSoundUsed ? "the file's own sound" : "object audio from the plugin")")
            AppLogger.filmPlayer.info("Loaded \(item.name): \(disc.summary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
            return true
        }
        let pictureHeight = FilmPictureQuality.preferred.height
        playbackInfo = PlaybackInfo(
            route: pictureHeight == nil ? .serverRemux : .serverTranscode,
            severity: pictureHeight == nil ? .normal : .chosen, server: "Jellyfin",
            reasons: pictureHeight.map { ["picture quality set to \($0)p"] } ?? [],
            picture: player.video.formatSummary.isEmpty ? nil : player.video.formatSummary, range: nil, rangeFromFrames: false, transcode: nil,
            source: "\(player.hasAudioScene ? "object audio" : "no object audio")")
        stereoFormatTask = Task { [weak self] in
            let format = try? await LibraryService.current()?.item(id: item.id).stereoFormat
            guard !Task.isCancelled, let self, self.loadedItem?.id == item.id else { return }
            self.stereoFormat = format
        }
        AppLogger.filmPlayer.info("Loaded \(item.name): \(self.player.video.formatSummary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
        return true
    }

    /// Plays a Library download from the device: an object-audio film from
    /// its package (the plugin's own video and audio, kept as streamed), a
    /// disc from its image with the package's object audio when it has one,
    /// else the disc's 5.1. Works with no server; subtitles are the sidecars.
    private func loadDownloaded(_ record: LibraryOfflineRecord, item: FilmLibraryItem) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        stereoFormatTask?.cancel()
        stereoFormat = nil
        let media = LibraryOfflineStore.mediaURL(record)
        // The download's sidecars, through the same Jellyfin-keyed source
        // (JellyfinLibrary answers a download's subtitles from the device).
        var subtitleSource = SubtitleSource.jellyfin(itemId: record.id)
        switch record.playback {
        case .film:
            let package = FilmPackage(itemId: record.id, video: media)
            await player.load(FilmServerClient(itemID: record.id, offline: package))
            stereoFormat = record.item.stereoFormat
        case .disc:
            let disc: MVCPictureSource
            do {
                disc = try await MVCPictureSource.open(url: media, headers: [:])
            } catch {
                self.error = "The disc couldn't be read: \(error.localizedDescription)"
                subtitles.load(nil)
                return false
            }
            if record.hasObjectAudio {
                await player.load(picture: disc, audio: FilmServerClient(itemID: record.id, offline: FilmPackage(itemId: record.id, video: nil)))
            } else {
                await player.load(picture: disc, audio: try? disc.audioSource(itemID: record.id))
            }
            stereoFormat = disc.isStereo ? .overUnder : nil
            if let discSubtitles = disc.subtitles { subtitleSource = .disc(discSubtitles, itemId: record.id) }
        case .video:
            return false
        }
        guard player.video.isLoaded else {
            error = player.video.status
            subtitles.load(nil)
            return false
        }
        loadedItem = item
        subtitles.load(subtitleSource)
        subtitles.bindGeneratedFilm(player)
        AppLogger.filmPlayer.info("Loaded a downloaded \(record.playback.rawValue, privacy: .public) film: \(self.player.video.formatSummary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
        return true
    }

    /// Loads a Blu-ray disc image on the device: its picture decoded here,
    /// its sound the disc's own 5.1 (`DiscAudioSource`), its subtitles the
    /// disc's PGS. No server involved.
    func loadLocalDisc(_ url: URL, title: String) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        stereoFormatTask?.cancel()
        stereoFormat = nil
        let disc: MVCPictureSource
        do {
            disc = try await MVCPictureSource.open(url: url, headers: [:])
        } catch {
            self.error = "The disc couldn't be read: \(error.localizedDescription)"
            AppLogger.filmPlayer.error("Local disc open failed: \(error.localizedDescription)")
            subtitles.load(nil)
            return false
        }
        let item = FilmLibraryItem(id: Self.localItemPrefix + UUID().uuidString, name: title, productionYear: nil)
        let audio: DiscAudioSource?
        do {
            audio = try disc.audioSource(itemID: item.id)
        } catch {
            audio = nil
            AppLogger.filmPlayer.error("Local disc audio unavailable: \(error.localizedDescription)")
        }
        await player.load(picture: disc, audio: audio)
        guard player.video.isLoaded else {
            error = player.video.status
            subtitles.load(nil)
            return false
        }
        loadedItem = item
        subtitles.load(disc.subtitles.map { .disc($0, itemId: item.id, includeServer: false) })
        subtitles.bindGeneratedFilm(player)
        stereoFormat = disc.isStereo ? .overUnder : nil
        AppLogger.filmPlayer.info("Loaded a local disc: \(disc.summary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
        return true
    }

    private func loadSharedFields() {
        sharedFieldsTask?.cancel()
        sharedFields = nil
        monoSharedFields = nil
        guard let item = loadedItem else { return }
        sharedFieldsTask = Task { [weak self] in
            let fields = await SmoothMotionTracks.fields(name: item.name, id: item.id)
            guard !Task.isCancelled, let self, self.loadedItem?.id == item.id else { return }
            self.sharedFields = fields
            // No 3D track: a 2D film's comes from the coordinator (which refuses a 3D one).
            guard fields == nil else { return }
            let mono = await SmoothMotionTracks.monoFields(id: item.id)
            guard !Task.isCancelled, self.loadedItem?.id == item.id else { return }
            self.monoSharedFields = mono
        }
    }

    /// Plays the loaded disc's own 5.1 instead of the plugin's object audio,
    /// from where it is (the `filmDiscAudio` debug command: the path a disc
    /// without the plugin, or on the device, takes). False for a film that
    /// isn't a disc.
    func switchToDiscAudio() async -> Bool {
        guard let disc = player.video.pictureSource as? MVCPictureSource, disc.isDisc, let item = loadedItem else { return false }
        let position = player.currentTime
        let wasPlaying = player.isPlaying
        await player.load(picture: disc, audio: try? disc.audioSource(itemID: item.id), startAt: position)
        if wasPlaying { player.play() }
        return player.hasAudioScene
    }

    /// Ids of films that aren't Jellyfin items (a disc on the device), which
    /// mustn't be reported to the server or looked up there.
    static let localItemPrefix = "local:"

    static func isServerItem(_ id: String?) -> Bool {
        guard let id else { return false }
        return !id.hasPrefix(localItemPrefix)
    }

    /// Loads a Library-tab item directly by its Jellyfin id, without going
    /// through `search` first — the Library detail page knows exactly which
    /// item to play. `name`/`productionYear` are for display only (the
    /// tuning section's title, the log line above).
    /// Loads a picture decoded on the device with the plugin's object audio,
    /// or with the file's own sound (`ownSound`: a disc's 5.1, read from the
    /// same image or transport stream, or a Matroska remux's track decoded
    /// here) when the plugin has none for it: no plugin, no object track, or
    /// a track it lists but has no objects in. It lists a TrueHD track before
    /// decoding it, and a plain 7.1 one then answers 422; the picture would
    /// otherwise play silent.
    static func load(_ player: FilmPlayer, client: FilmServerClient, decoded picture: MVCPictureSource,
                     pictureHeight: Int?, ownSound: () async -> (any FilmAudioSource)?) async {
        if await (try? client.audioTracks(languages: FilmServerClient.deviceLanguages))?.isEmpty ?? true {
            await player.load(picture: picture, audio: await ownSound())
            return
        }
        await player.load(client, picture: picture, pictureHeight: pictureHeight)
        guard player.video.isLoaded, !player.hasAudioScene else { return }
        AppLogger.filmPlayer.info("No object audio from the plugin (\(player.audioStatus, privacy: .public)); playing the file's own sound")
        await player.load(picture: picture, audio: await ownSound())
    }

    func load(itemId: String, name: String, productionYear: Int?, picture: FilmDecodedPicture? = nil) async -> Bool {
        await load(FilmLibraryItem(id: itemId, name: name, productionYear: productionYear), picture: picture)
    }
}

/// A film whose picture the device decodes from the raw file, because
/// neither Apple's decoders nor Jellyfin's streams carry its 3D.
enum FilmDecodedPicture: Sendable, Equatable {
    /// A Blu-ray disc image or BDMV folder.
    case disc
    /// A 3D Blu-ray remuxed to Matroska: MVC in one H.264 track.
    case matroskaMVC
    /// Both views in one transport stream (.m2ts): a disc's SSIF copied
    /// out, a tsMuxeR remux, a 3D camcorder clip.
    case transportStreamMVC
}
