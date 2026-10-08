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
        return player
    }()
    /// The loaded item's subtitle tracks, drawn over the picture by the player view.
    let subtitles = SubtitleController()
    /// How the loaded film packs its eyes, when it is a 3D film (Jellyfin's
    /// `Video3DFormat`). The player view plays it as real 3D, cropped per
    /// eye, instead of the fake-3D warp. Arrives just after the picture.
    private(set) var stereoFormat: StereoscopicFormat?
    @ObservationIgnored private var stereoFormatTask: Task<Void, Never>?

    var server: String = FilmSession.storedServer {
        didSet {
            UserDefaults.standard.set(server, forKey: "filmPlayer.jellyfinServer")
            Self.excludeFromOtherCredentials(server)
        }
    }

    private nonisolated static var storedServer: String {
        UserDefaults.standard.string(forKey: "filmPlayer.jellyfinServer")
            ?? UserDefaults.standard.string(forKey: "atmosSpike.jellyfinServer") ?? ""
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
    private(set) var loadedItem: FilmLibraryItem?
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

    /// visionOS: how far in front of the player window the listener is
    /// assumed to sit. A window can't see the head, so this is a guess.
    var listenerDistance: Float = 1.5
    /// tvOS: whether PHASE turns the listener with the wearer's head
    /// (AirPods). Persisted with the rest of the sound settings.
    var headTracking = true
    /// Bumped by a Recenter button; the stage recentres on each change.
    var recenterRequest = 0

    private init() {
        restoreSound()
        Self.excludeFromOtherCredentials(server)
        // Starts watching the network, so Auto object-audio quality knows
        // the path by the time a film loads.
        _ = NetworkCost.shared
    }

    // MARK: Sound settings

    /// The player's sound tuning as saved between launches. Not every
    /// platform uses every field: the reverb preset and head tracking are
    /// the tvOS PHASE stage's; RealityKit's stage reads only the level.
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
    }

    private static let soundKey = "filmPlayer.sound"

    func saveSound() {
        let settings = SoundSettings(
            masterGainDB: player.masterGainDB, lfeGainDB: player.lfeGainDB, reverbDB: player.reverbDB,
            reverbPreset: player.reverbPreset, roomHalfWidth: player.roomHalfWidth,
            roomHalfDepth: player.roomHalfDepth, roomHeight: player.roomHeight,
            avOffsetMs: player.avOffsetMs, headTracking: headTracking
        )
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.soundKey)
        }
    }

    private func restoreSound() {
        guard let data = UserDefaults.standard.data(forKey: Self.soundKey),
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
        player.roomHalfWidth = settings.roomHalfWidth
        player.roomHalfDepth = settings.roomHalfDepth
        player.roomHeight = settings.roomHeight
        player.avOffsetMs = settings.avOffsetMs
        headTracking = settings.headTracking
    }

    /// Whether a Jellyfin server is configured at all — the gate for
    /// showing the Library tab (hidden until this is true, per the Library
    /// feature's decision #3) on every platform.
    var isConfigured: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Jellyfin's `X-Emby-Token` header accepts a signed-in session's access
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
    /// - Parameter isBlurayDisc: the item is a Blu-ray disc image or folder:
    ///   its picture is read from the raw disc and decoded on the device
    ///   (`MVCPictureSource`), the plugin's video segments being unavailable
    ///   for a disc; the plugin still supplies the audio.
    func load(_ item: FilmLibraryItem, isBlurayDisc: Bool = false) async -> Bool {
        if let record = LibraryOfflineStore.shared.record(for: item.id), record.playback != .video {
            return await loadDownloaded(record, item: item)
        }
        guard let serverURL, let token = effectiveToken, !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        stereoFormatTask?.cancel()
        stereoFormat = nil
        var disc: MVCPictureSource?
        if isBlurayDisc {
            let url = serverURL.appending(path: "Videos/\(item.id)/stream").appending(queryItems: [.init(name: "static", value: "true")])
            do {
                disc = try await MVCPictureSource.open(url: url, headers: ["X-Emby-Token": token])
            } catch {
                self.error = "The disc couldn't be read: \(error.localizedDescription)"
                AppLogger.filmPlayer.error("Disc open failed: \(error.localizedDescription)")
                subtitles.load(nil)
                return false
            }
        }
        var client = FilmServerClient(baseURL: serverURL, token: token, itemID: item.id)
        client.encoding = ObjectAudioQuality.preferred.encoding
        if let disc, await (try? client.audioTracks(languages: FilmServerClient.deviceLanguages))?.isEmpty ?? true {
            // No object audio from the plugin (not installed, or no TrueHD on
            // the disc): the disc's own 5.1, read from the same image.
            await player.load(picture: disc, audio: try? disc.audioSource(itemID: item.id))
        } else {
            await player.load(client, picture: disc)
        }
        guard player.video.isLoaded else {
            error = player.video.status
            subtitles.load(nil)
            return false
        }
        loadedItem = item
        subtitles.load(disc.map { .disc($0.subtitles, itemId: item.id) } ?? .jellyfin(itemId: item.id))
        if let disc {
            // The eyes come top and bottom out of MVCPictureSource's stereo frames.
            stereoFormat = disc.isStereo ? .overUnder : nil
            AppLogger.filmPlayer.info("Loaded \(item.name): \(disc.summary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
            return true
        }
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
            subtitleSource = .disc(disc.subtitles, itemId: record.id)
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
        subtitles.load(.disc(disc.subtitles, itemId: item.id, includeServer: false))
        stereoFormat = disc.isStereo ? .overUnder : nil
        AppLogger.filmPlayer.info("Loaded a local disc: \(disc.summary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
        return true
    }

    /// Plays the loaded disc's own 5.1 instead of the plugin's object audio,
    /// from where it is (the `filmDiscAudio` debug command: the path a disc
    /// without the plugin, or on the device, takes). False for a film that
    /// isn't a disc.
    func switchToDiscAudio() async -> Bool {
        guard let disc = player.video.pictureSource as? MVCPictureSource, let item = loadedItem else { return false }
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
    func load(itemId: String, name: String, productionYear: Int?, isBlurayDisc: Bool = false) async -> Bool {
        await load(FilmLibraryItem(id: itemId, name: name, productionYear: productionYear), isBlurayDisc: isBlurayDisc)
    }
}
