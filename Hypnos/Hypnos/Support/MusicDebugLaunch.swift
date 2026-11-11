/*
 Hypnos - Music section: launch defaults for checking it without clicking (DEBUG only)

 Like `libraryAutoOpenItemId` for the Library: `-UITest -UITestDefault key=value` puts the Music section in a
 state worth looking at, so a Mac run against the dev Jellyfin (`scripts/dev-jellyfin.sh`, plus
 `scripts/gen-dev-music.py` for a library with some size) can be screenshotted by a script.

   musicShowMusic=1          open the Library on Music rather than Movies & TV
   musicSection=albums       the first section (a `MusicSection` raw value)
   musicSort=random          the first order (a `MusicSort` raw value)
   musicAutoPlay=<n>         play up to n songs, in album order, muted, once
   musicAutoVisualizer=1     open the visualizer window after that (macOS)
   musicOpenAlbum=<name>     push the first album whose name contains this
   musicChrome=1             keep the visualizer's controls up (they hide after a few seconds)
   musicNowPlaying=1         open Now Playing once something plays (iOS, visionOS; musicAutoVisualizer then covers it on iOS)
 */

#if DEBUG

import DebugTrace
import Foundation

@MainActor
enum MusicDebugLaunch {
    private static var defaults: UserDefaults { HypnosDefaults.store }

    static var showsMusic: Bool { defaults.bool(forKey: "musicShowMusic") }
    static var section: MusicSection? { defaults.string(forKey: "musicSection").flatMap(MusicSection.init(rawValue:)) }
    static var sort: MusicSort? { defaults.string(forKey: "musicSort").flatMap(MusicSort.init(rawValue:)) }
    static var opensVisualizer: Bool { defaults.bool(forKey: "musicAutoVisualizer") }
    static var opensNowPlaying: Bool { defaults.bool(forKey: "musicNowPlaying") }
    static var keepsChromeUp: Bool { defaults.bool(forKey: "musicChrome") }

    private static var played = false

    /// Plays `musicAutoPlay` songs, muted (the dev library is sine tones), once per launch. True when it started.
    @discardableResult
    static func autoPlayIfRequested() async -> Bool {
        let count = defaults.integer(forKey: "musicAutoPlay")
        AppLogger.app.notice("MusicDebugLaunch: autoplay \(count, privacy: .public)")
        guard count > 0, !played else { return false }
        await waitForDevSignIn()
        guard let library = LibraryService.current() else { AppLogger.app.error("MusicDebugLaunch: no library"); return false }
        played = true
        var request = MusicRequest(section: .songs)
        request.sort = .album
        let page: JellyfinMusicPage
        do { page = try await library.musicPage(request, start: 0, limit: count) } catch {
            AppLogger.app.error("MusicDebugLaunch: no songs: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard let first = page.Items.first else { AppLogger.app.error("MusicDebugLaunch: empty page"); return false }
        AppLogger.app.notice("MusicDebugLaunch: playing \(page.Items.count, privacy: .public) songs")
        let music = JellyfinMusicSession.shared
        music.play(first, from: page.Items)
        if !music.isMuted { music.toggleMute() }
        return true
    }

    /// `DevJellyfinSignIn` signs in beside the launch and replaces the saved token with a new one, so a request made
    /// first would carry the old token and be refused. Give the sign-in a moment to land.
    private static func waitForDevSignIn() async {
        guard ProcessInfo.processInfo.environment["HYPNOS_DEV_JELLYFIN_SIGNIN_USER"] != nil else { return }
        try? await Task.sleep(for: .seconds(3))
    }

    /// The album named by `musicOpenAlbum`, to push.
    static func albumToOpen() async -> JellyfinMusicItem? {
        guard let name = defaults.string(forKey: "musicOpenAlbum"), !name.isEmpty else { return nil }
        await waitForDevSignIn()
        guard let library = LibraryService.current() else { return nil }
        var request = MusicRequest(section: .albums)
        request.search = ""
        guard let page = try? await library.musicPage(request, start: 0, limit: 200) else { return nil }
        return page.Items.first { $0.Name.localizedCaseInsensitiveContains(name) }
    }
}

#endif
