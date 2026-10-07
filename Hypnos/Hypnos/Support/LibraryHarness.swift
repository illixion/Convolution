/*
 Hypnos - Library feature: throwaway verification harness (macOS, DEBUG only)

 There's no unit-test target in this project (see Hypnos/CLAUDE.md's "UI
 Tests" section — `HypnosUITests` is XCUITest-only, visionOS-only), and
 standing one up just for this would be a bigger change than the feature
 itself warrants. So `JellyfinLibrary` is exercised for real here instead:
 launch the macOS build with `-LibraryHarness` and the dev Jellyfin's
 address + API key in the environment, and it drives home/detail/seasons/
 episodes/image URLs/playback routing/progress-and-state writes against a
 live server, prints one `HARNESS:` line per check, and exits — no simulator,
 no UI, just the network+model layer this feature is built on.

 Never point this at anything but the disposable dev Jellyfin
 (`scripts/dev-jellyfin.sh up`, http://127.0.0.1:8097) — see the HARD RULES
 in the Library feature's brief.
 */

#if DEBUG && os(macOS)

import AVFoundation
import Foundation
import RAVEUI

enum LibraryHarness {
    private static let launchFlag = "-LibraryHarness"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchFlag) else { return }
        guard let serverString = ProcessInfo.processInfo.environment["HYPNOS_HARNESS_JELLYFIN_URL"],
              let server = URL(string: serverString),
              let apiKey = ProcessInfo.processInfo.environment["HYPNOS_HARNESS_JELLYFIN_APIKEY"], !apiKey.isEmpty
        else {
            print("HARNESS: FAIL missing HYPNOS_HARNESS_JELLYFIN_URL / HYPNOS_HARNESS_JELLYFIN_APIKEY")
            exit(1)
        }

        Task {
            await run(server: server, apiKey: apiKey)
            exit(0)
        }
    }

    private static func log(_ line: String) {
        print("HARNESS: \(line)")
        fflush(stdout)
    }

    private static func run(server: URL, apiKey: String) async {
        let library = JellyfinLibrary(baseURL: server, accessToken: apiKey, userId: nil)

        // Home: shelves + hero.
        do {
            let home = try await library.home()
            log("home.featured=\(home.featured.map(\.title)) images=\(home.featured.first?.images ?? [])")
            if let hero = home.featured.first {
                log("home.featured[0].logoURL=\(library.imageURL(item: hero, kind: .logo, size: .thumbnail)?.absoluteString ?? "nil")")
            }
            for shelf in home.shelves {
                log("home.shelf[\(shelf.id)]=\"\(shelf.title)\" count=\(shelf.items.count) style=\(shelf.style)")
            }
        } catch {
            log("home FAILED: \(error)")
        }

        // Search: movies + the series.
        var crimson: LibraryItem?
        var quietLedger: LibraryItem?
        var wideStatic: LibraryItem?
        var atmosDemo: LibraryItem?
        var series: LibraryItem?
        do {
            let movies = try await library.search("")
            log("search(empty).count=\(movies.count)")
        } catch {
            log("search(empty) FAILED: \(error)")
        }
        for term in ["Crimson Tide", "Quiet Ledger", "Wide Static", "DolbyElement4K", "Nebula Drift"] {
            do {
                let results = try await library.search(term)
                log("search(\"\(term)\").count=\(results.count) first=\(results.first?.title ?? "nil") kind=\(results.first?.kind.rawValue ?? "-")")
                switch term {
                case "Crimson Tide":
                    crimson = results.first
                    log("search result overview=\(results.first?.overview ?? "nil") genres=\(results.first?.genres ?? [])")
                case "Quiet Ledger": quietLedger = results.first
                case "Wide Static": wideStatic = results.first
                case "DolbyElement4K": atmosDemo = results.first
                case "Nebula Drift": series = results.first
                default: break
                }
            } catch {
                log("search(\"\(term)\") FAILED: \(error)")
            }
        }

        // Detail + seasons + episodes.
        if let series {
            do {
                let detail = try await library.item(id: series.id)
                log("item(series).title=\(detail.title) genres=\(detail.genres)")
                let seasons = try await library.seasons(seriesId: series.id)
                log("seasons.count=\(seasons.count) names=\(seasons.map(\.title))")
                if let season1 = seasons.first(where: { $0.seasonNumber == 1 }) {
                    let episodes = try await library.episodes(seasonId: season1.id)
                    log("episodes(season1).count=\(episodes.count) labels=\(episodes.map { $0.episodeLabel ?? "?" })")
                    if let ep1 = episodes.first {
                        log("episode1.userData=\(ep1.userData)")
                    }
                } else {
                    log("seasons: no season 1 found FAILED")
                }
            } catch {
                log("series detail/seasons/episodes FAILED: \(error)")
            }
        } else {
            log("series lookup FAILED: Nebula Drift not found")
        }

        // Similar.
        if let crimson {
            do {
                let similar = try await library.similar(itemId: crimson.id)
                log("similar(Crimson Tide Station).count=\(similar.count)")
            } catch {
                log("similar FAILED: \(error)")
            }
        }

        // Image URLs: fetch real bytes for each kind and confirm 200 + a
        // plausible size (not an empty/error body).
        if let crimson {
            let full = try? await library.item(id: crimson.id)
            for kind in [LibraryImageKind.primary, .backdrop, .logo] {
                guard let url = library.imageURL(item: full ?? crimson, kind: kind, size: .thumbnail) else {
                    log("imageURL(\(kind)) = nil")
                    continue
                }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    log("image(\(kind)) status=\(status) bytes=\(data.count)")
                } catch {
                    log("image(\(kind)) FAILED: \(error)")
                }
            }
        }

        // Playback routing: Atmos item should route to the FilmPlayer path;
        // a plain movie should route to the generic player, direct or HLS.
        if let atmosDemo {
            do {
                let route = try await library.playbackRoute(for: atmosDemo)
                log("playbackRoute(AtmosDemo)=\(describeRoute(route))")
            } catch {
                log("playbackRoute(AtmosDemo) FAILED: \(error)")
            }
        }
        if let wideStatic {
            do {
                let route = try await library.playbackRoute(for: wideStatic)
                log("playbackRoute(WideStaticField-webm)=\(describeRoute(route))")
            } catch {
                log("playbackRoute(WideStaticField) FAILED: \(error)")
            }
        }
        if let crimson {
            do {
                let route = try await library.playbackRoute(for: crimson)
                log("playbackRoute(CrimsonTideStation)=\(describeRoute(route))")
            } catch {
                log("playbackRoute(CrimsonTideStation) FAILED: \(error)")
            }
        }

        await checkStreams(library: library, server: server, apiKey: apiKey,
                           items: [wideStatic, crimson].compactMap { $0 }, atmosDemo: atmosDemo)

        // Progress / played / favorite writes, read back through the API.
        if let quietLedger {
            do {
                try await library.setFavorite(itemId: quietLedger.id, favorite: true)
                let after = try await library.item(id: quietLedger.id)
                log("setFavorite(QuietLedger)=true readback.isFavorite=\(after.userData.isFavorite)")
                try await library.setFavorite(itemId: quietLedger.id, favorite: false)
                let reverted = try await library.item(id: quietLedger.id)
                log("setFavorite(QuietLedger)=false readback.isFavorite=\(reverted.userData.isFavorite)")

                try await library.setPlayed(itemId: quietLedger.id, played: false)
                let unplayed = try await library.item(id: quietLedger.id)
                log("setPlayed(QuietLedger)=false readback.isPlayed=\(unplayed.userData.isPlayed)")
                try await library.setPlayed(itemId: quietLedger.id, played: true)
                let played = try await library.item(id: quietLedger.id)
                log("setPlayed(QuietLedger)=true readback.isPlayed=\(played.userData.isPlayed)")
            } catch {
                log("played/favorite writes FAILED: \(error)")
            }
        }

        if let crimson {
            await library.reportPlaybackStarted(itemId: crimson.id, positionSeconds: 0)
            await library.reportPlaybackProgress(itemId: crimson.id, positionSeconds: 12, isPaused: false)
            await library.reportPlaybackStopped(itemId: crimson.id, positionSeconds: 12)
            if let after = try? await library.item(id: crimson.id) {
                log("progressReport(CrimsonTideStation).positionSeconds=\(after.userData.playbackPositionSeconds ?? -1) playedPct=\(after.userData.playedPercentage ?? -1)")
            }
            do {
                let home = try await library.home()
                let continueWatching = home.shelves.first(where: { $0.id == "up-next" })
                log("continueWatching.containsCrimson=\(continueWatching?.items.contains(where: { $0.id == crimson.id }) ?? false)")
            } catch {
                log("home re-check FAILED: \(error)")
            }
        }

        await checkStereoFormats(library: library)

        if let atmosDemo {
            await checkSubtitles(library: library, item: atmosDemo)
            await checkSignedInProgress(server: server, item: atmosDemo)
        }

        checkUpNextOrdering()
        checkChapterNames()
        if let series {
            await checkSegmentsAndFreshResume(library: library, server: server, series: series)
        }

        log("DONE")
    }

    /// Every movie's 3D format, through browse (the list DTO) and item (the
    /// detail DTO the film player looks up). The seed's Twin Horizon is HSBS.
    private static func checkStereoFormats(library: JellyfinLibrary) async {
        do {
            let movies = try await library.browse(kind: .movie, startIndex: 0, limit: 100)
            for movie in movies where movie.stereoFormat != nil {
                let detail = try await library.item(id: movie.id)
                log("stereo(\(movie.title)): list=\(movie.stereoFormat?.rawValue ?? "nil") item=\(detail.stereoFormat?.rawValue ?? "nil")")
            }
            log("stereo: \(movies.filter { $0.stereoFormat != nil }.count) of \(movies.count) movies are 3D")
        } catch {
            log("stereo FAILED: \(error)")
        }
    }

    /// Lists the item's subtitle streams and fetches and parses each text one
    /// the way the players do.
    private static func checkSubtitles(library: JellyfinLibrary, item: LibraryItem) async {
        do {
            let tracks = try await library.subtitleTracks(itemId: item.id)
            log("subtitles(\(item.title)).tracks=\(tracks.map { "\($0.id):\($0.title):text=\($0.isText)" })")
            for track in tracks where track.isText {
                let cues = try RAVESubtitleTrack(data: try await library.subtitleData(itemId: item.id, track: track))
                log("subtitles(\(item.title))[\(track.id)].cues=\(cues.cues.count) first=\"\(cues.cues.first?.plainText ?? "")\" at10s=\(cues.cues(at: 10).map(\.plainText))")
            }
        } catch {
            log("subtitles(\(item.title)) FAILED: \(error)")
        }
    }

    /// The film player's start → progress → stop sequence, as a signed-in
    /// user (`/Sessions/Playing*` silently ignores a bare API key), read back
    /// through the API. Needs HYPNOS_HARNESS_JELLYFIN_USER / _PASS.
    private static func checkSignedInProgress(server: URL, item: LibraryItem) async {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["HYPNOS_HARNESS_JELLYFIN_USER"], let pass = env["HYPNOS_HARNESS_JELLYFIN_PASS"] else {
            log("signedInProgress SKIPPED: no HYPNOS_HARNESS_JELLYFIN_USER/_PASS")
            return
        }
        do {
            let session = try await JellyfinAuth.authenticate(serverURL: server, username: user, password: pass)
            let library = JellyfinLibrary(baseURL: server, accessToken: session.accessToken, userId: session.userId)
            await library.reportPlaybackStarted(itemId: item.id, positionSeconds: 30)
            await library.reportPlaybackProgress(itemId: item.id, positionSeconds: 40, isPaused: false)
            await library.reportPlaybackStopped(itemId: item.id, positionSeconds: 42)
            let after = try await library.item(id: item.id)
            log("signedInProgress(\(item.title)).positionSeconds=\(after.userData.playbackPositionSeconds ?? -1) resume=\(after.userData.resumeSeconds ?? -1) (expect 42)")
        } catch {
            log("signedInProgress FAILED: \(error)")
        }
    }

    /// Up Next: most recently watched first, one entry per show, a show's
    /// paused episode beating its next one only when it was the last watched.
    private static func checkUpNextOrdering() {
        func episode(_ id: String, series: String, played: Date?) -> LibraryItem {
            var item = LibraryItem(id: id, kind: .episode, title: id)
            item.seriesId = series
            item.userData.lastPlayedDate = played
            return item
        }
        let now = Date()
        var movie = LibraryItem(id: "movie", kind: .movie, title: "movie")
        movie.userData.lastPlayedDate = now.addingTimeInterval(-3600)
        let resume = [movie,
                      episode("A2-paused", series: "A", played: now.addingTimeInterval(-7200)),
                      episode("B1-paused", series: "B", played: now.addingTimeInterval(-60))]
        let nextUp = [episode("A4-next", series: "A", played: nil),
                      episode("B1-paused", series: "B", played: now.addingTimeInterval(-60)),
                      episode("C3-next", series: "C", played: nil)]
        let watched = [episode("A3", series: "A", played: now.addingTimeInterval(-600)),
                       episode("C2", series: "C", played: now.addingTimeInterval(-30))]
        let ids = JellyfinLibrary.upNext(resume: resume, nextUp: nextUp, watchedEpisodes: watched).map(\.id)
        let expected = ["C3-next", "B1-paused", "A4-next", "movie"]
        log("upNextOrdering=\(ids) \(ids == expected ? "OK" : "FAIL expected \(expected)")")
    }

    private static func checkChapterNames() {
        let cases: [(String, LibraryMediaSegment.Kind?)] = [
            ("Intro", .intro), ("Opening Credits", .intro), ("OP", .intro), ("Recap", .recap),
            ("Previously on...", .recap), ("End Credits", .outro), ("Credits", .outro), ("ED", .outro),
            ("Preview", .preview), ("Chapter 3", nil), ("Scene 12", nil), ("Introduction to Physics", .intro),
        ]
        let failures = cases.filter { JellyfinLibrary.chapterKind($0.0) != $0.1 }
        log("chapterNames \(failures.isEmpty ? "OK" : "FAIL \(failures.map { "\($0.0)->\(String(describing: JellyfinLibrary.chapterKind($0.0)))" })")")
    }

    /// The chaptered seed episode's segments, then the Up Next bug itself:
    /// a stop report moves the resume point, `LibraryWatchState` bumps once
    /// the server has it, and a fresh read (what Play does) sees it.
    @MainActor
    private static func checkSegmentsAndFreshResume(library: JellyfinLibrary, server: URL, series: LibraryItem) async {
        do {
            let seasons = try await library.seasons(seriesId: series.id)
            var coldOpen: LibraryItem?
            for season in seasons {
                coldOpen = try await library.episodes(seasonId: season.id).first { $0.title == "Cold Open" }
                if coldOpen != nil { break }
            }
            guard let coldOpen else {
                log("segments SKIPPED: no \"Cold Open\" episode (re-run scripts/dev-jellyfin.sh up)")
                return
            }
            let segments = try await library.mediaSegments(itemId: coldOpen.id)
            log("segments(Cold Open)=\(segments.map { "\($0.kind.rawValue) \($0.startSeconds)-\($0.endSeconds)" })")
            log("segment.target(credits, duration 40)=\(segments.last.map { MediaSegmentSkipper.target(for: $0, duration: 40) } ?? -1) (expect 39.5)")

            let env = ProcessInfo.processInfo.environment
            guard let user = env["HYPNOS_HARNESS_JELLYFIN_USER"], let pass = env["HYPNOS_HARNESS_JELLYFIN_PASS"] else {
                log("freshResume SKIPPED: no HYPNOS_HARNESS_JELLYFIN_USER/_PASS")
                return
            }
            let session = try await JellyfinAuth.authenticate(serverURL: server, username: user, password: pass)
            let signedIn = JellyfinLibrary(baseURL: server, accessToken: session.accessToken, userId: session.userId)
            for position in [10.0, 25.0] {
                let before = LibraryWatchState.shared.revision
                await signedIn.reportPlaybackStarted(itemId: coldOpen.id, positionSeconds: position - 5)
                await signedIn.reportPlaybackStopped(itemId: coldOpen.id, positionSeconds: position)
                let fresh = try await signedIn.item(id: coldOpen.id)
                let shelf = try await signedIn.home().shelves.first { $0.id == "up-next" }
                let first = shelf?.items.first
                log("freshResume(stop at \(position)) revision+\(LibraryWatchState.shared.revision - before) resume=\(fresh.userData.resumeSeconds ?? -1) upNext[0]=\(first?.title ?? "nil")@\(first?.userData.resumeSeconds ?? -1)")
            }
            let home = try await signedIn.home()
            for shelf in home.shelves where shelf.style == .landscape {
                log("home.\(shelf.id)=\(shelf.items.map { "\($0.seriesName ?? $0.title) \($0.episodeLabel ?? "")" })")
            }
        } catch {
            log("segments/freshResume FAILED: \(error)")
        }
    }

    /// Plays each routed stream through the app's own AVFoundation entry
    /// point (`MediaAuthorization.asset(for:)`) with a Stash-style query
    /// credential registered for the same host — the reverse-proxy layout
    /// where the Stash key used to land on Jellyfin URLs and 401 them.
    private static func checkStreams(library: JellyfinLibrary, server: URL, apiKey: String,
                                     items: [LibraryItem], atmosDemo: LibraryItem?) async {
        guard let host = server.host else { return }
        let auth = MediaAuthorization.shared
        auth.register(host: host, credential: .queryParam(name: "apikey", value: "harness-not-a-jellyfin-key"))
        defer {
            auth.unregister(host: host)
            auth.excludeCredentials(under: nil, owner: "jellyfin")
        }

        var streams: [(String, URL)] = []
        for item in items {
            if case .genericPlayer(let plan)? = try? await library.playbackRoute(for: item) {
                streams.append(("\(item.title) [\(plan.method)]", plan.streamURL))
            }
        }
        if let atmosDemo {
            // Routes to FilmPlayer through the plugin; its HLS form is the
            // 4K HDR HEVC case the generic player has to handle when the
            // plugin isn't installed.
            streams.append(("\(atmosDemo.title) [hls]", JellyfinLibrary.hlsStreamURL(
                baseURL: server, itemId: atmosDemo.id, mediaSourceId: atmosDemo.id,
                sourceVideoCodec: "hevc", playSessionId: UUID().uuidString, token: apiKey)))
        }

        for (label, url) in streams {
            auth.excludeCredentials(under: nil, owner: "jellyfin")
            log("stream(\(label)) sameHostCredential=applied \(await playProbe(url))")
            auth.excludeCredentials(under: server, owner: "jellyfin")
            let untouched = auth.authorizedURL(url) == url
            log("stream(\(label)) sameHostCredential=excluded urlUntouched=\(untouched) \(await playProbe(url))")
        }

        // A token the server rejects has to fail at routing, under the Play
        // button, not as a player window that never shows a frame.
        let revoked = JellyfinLibrary(baseURL: server, accessToken: "revoked-token", userId: "revoked-user")
        if let item = items.first {
            do {
                _ = try await revoked.playbackRoute(for: item)
                log("playbackRoute(revokedToken)=ROUTED (expected a failure)")
            } catch {
                log("playbackRoute(revokedToken) failed as expected: \(error.localizedDescription)")
            }
        }
    }

    /// Plays `url` for up to 20 s and describes what came out.
    @MainActor
    private static func playProbe(_ url: URL) async -> String {
        let item = AVPlayerItem(asset: MediaAuthorization.shared.asset(for: url))
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause() }
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            if item.status == .failed {
                return "FAILED: \(item.error?.localizedDescription ?? "unknown")"
            }
            if player.timeControlStatus == .playing, item.presentationSize != .zero {
                let hasAudio = item.tracks.contains { $0.assetTrack?.mediaType == .audio }
                return String(format: "playing after %.1fs size=%.0fx%.0f audio=%@",
                              Date().timeIntervalSince(start), item.presentationSize.width,
                              item.presentationSize.height, hasAudio ? "yes" : "no")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return "STALLED (\(player.reasonForWaitingToPlay?.rawValue ?? "paused"))"
    }

    private static func describeRoute(_ route: PlaybackRoute) -> String {
        switch route {
        case .atmosFilmPlayer: return "atmosFilmPlayer"
        case .genericPlayer(let plan): return "genericPlayer(\(plan.method), \(plan.streamURL.path))"
        }
    }
}

#endif
