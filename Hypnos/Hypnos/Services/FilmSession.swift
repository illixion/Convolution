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
import Foundation
import Observation

@MainActor
@Observable
final class FilmSession {
    static let shared = FilmSession()

    let player = FilmPlayer()

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

    /// visionOS: how far in front of the player window the listener is
    /// assumed to sit. A window can't see the head, so this is a guess.
    var listenerDistance: Float = 1.5
    /// Whether the player overlays the object map. A developer setting,
    /// remembered between launches.
    var showMap = UserDefaults.standard.bool(forKey: "filmPlayer.showMap") {
        didSet { UserDefaults.standard.set(showMap, forKey: "filmPlayer.showMap") }
    }
    /// tvOS: whether PHASE turns the listener with the wearer's head
    /// (AirPods). Persisted with the rest of the sound settings.
    var headTracking = true
    /// Bumped by a Recenter button; the stage recentres on each change.
    var recenterRequest = 0

    private init() {
        restoreSound()
        Self.excludeFromOtherCredentials(server)
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
    func load(_ item: FilmLibraryItem) async -> Bool {
        guard let serverURL, let token = effectiveToken, !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        await player.load(FilmServerClient(baseURL: serverURL, token: token, itemID: item.id))
        guard player.video.index != nil else {
            error = player.video.status
            return false
        }
        loadedItem = item
        AppLogger.filmPlayer.info("Loaded \(item.name): \(self.player.video.formatSummary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
        return true
    }

    /// Loads a Library-tab item directly by its Jellyfin id, without going
    /// through `search` first — the Library detail page knows exactly which
    /// item to play. `name`/`productionYear` are for display only (the
    /// tuning section's title, the log line above).
    func load(itemId: String, name: String, productionYear: Int?) async -> Bool {
        await load(FilmLibraryItem(id: itemId, name: name, productionYear: productionYear))
    }
}
