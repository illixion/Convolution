/*
 Hypnos - film player session (Settings → Developer → Film Player)

 App glue around RAVEFilm's `FilmPlayer`: the Jellyfin server and API
 key, library search, which item is loaded, and whether the player is
 showing. The player itself (picture, Atmos object audio, one clock) lives
 in RAVESDK's `RAVEFilm` target. The server needs the Atmos
 Objects plugin (`JellyfinPlugin/`), which serves both the video segments
 and the object audio.
 */

import RAVEFilm
import Foundation
import Observation
import os

@MainActor
@Observable
final class FilmSession {
    static let shared = FilmSession()

    let player = FilmPlayer()

    var server: String = UserDefaults.standard.string(forKey: "filmPlayer.jellyfinServer")
        ?? UserDefaults.standard.string(forKey: "atmosSpike.jellyfinServer") ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: "filmPlayer.jellyfinServer") }
    }
    var apiKey: String = KeychainStore.string(for: .jellyfinAPIKey) ?? "" {
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
    var showMap = false

    private init() {}

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
        AppLogger.filmPlayer.info("Loaded \(item.name, privacy: .public): \(self.player.video.formatSummary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
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
