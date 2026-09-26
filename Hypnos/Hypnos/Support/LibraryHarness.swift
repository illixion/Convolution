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

import Foundation

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
            log("home.hero=\(home.hero?.title ?? "nil")")
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
                case "Crimson Tide": crimson = results.first
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
                let continueWatching = home.shelves.first(where: { $0.id == "continue-watching" })
                log("continueWatching.containsCrimson=\(continueWatching?.items.contains(where: { $0.id == crimson.id }) ?? false)")
            } catch {
                log("home re-check FAILED: \(error)")
            }
        }

        log("DONE")
    }

    private static func describeRoute(_ route: PlaybackRoute) -> String {
        switch route {
        case .atmosFilmPlayer: return "atmosFilmPlayer"
        case .genericPlayer(let plan): return "genericPlayer(\(plan.method), \(plan.streamURL.path))"
        }
    }
}

#endif
