/*
 Hypnos - Library downloads: verification harness (macOS, DEBUG only)

 Like `LibraryHarness`, but for downloads: launch the macOS build with
 `-LibraryDownloadHarness` and the dev Jellyfin in the environment
 (HYPNOS_HARNESS_JELLYFIN_URL / _APIKEY, plus _NODL_TOKEN / _NODL_USER for
 an account with downloads turned off). It downloads one title of each
 kind (an MP4 kept as is, an MKV remuxed to MP4, an object-audio film as a
 package), plays each back from the device (the object-audio one through
 an offline `FilmServerClient`), then answers the Library from a server
 that isn't there, and checks a downloads-disabled account is refused.
 Prints `HARNESS:` lines, deletes what it downloaded, and exits.

 Only ever against the disposable dev Jellyfin (`scripts/dev-jellyfin.sh up`).
 */

#if DEBUG && os(macOS)

import AVFoundation
import Foundation
import RAVEFilm

@MainActor
enum LibraryDownloadHarness {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-LibraryDownloadHarness") else { return }
        let env = ProcessInfo.processInfo.environment
        guard let server = env["HYPNOS_HARNESS_JELLYFIN_URL"].flatMap(URL.init(string:)),
              let apiKey = env["HYPNOS_HARNESS_JELLYFIN_APIKEY"] else {
            log("FAIL missing HYPNOS_HARNESS_JELLYFIN_URL / _APIKEY")
            exit(1)
        }
        Task {
            await run(server: server, apiKey: apiKey, noDownloads: env["HYPNOS_HARNESS_NODL_TOKEN"].map { ($0, env["HYPNOS_HARNESS_NODL_USER"]) })
            exit(0)
        }
    }

    private static func log(_ line: String) {
        print("HARNESS: \(line)")
        fflush(stdout)
    }

    private static func run(server: URL, apiKey: String, noDownloads: (String, String?)?) async {
        let library = JellyfinLibrary(baseURL: server, accessToken: apiKey, userId: nil)
        let downloads = LibraryDownloads.shared
        downloads.libraryProvider = { library }
        downloads.start()
        await downloads.refreshPolicy()
        log("policy.accountAllowsDownloads=\(downloads.accountAllowsDownloads.map(String.init) ?? "nil")")

        var targets: [LibraryItem] = []
        for term in ["Crimson Tide Station", "NoAtmosTest", "DolbyElement4K", "Twin Horizon"] {
            guard let item = try? await library.search(term).first(where: { $0.kind == .movie }) else {
                log("FAIL search \(term)")
                continue
            }
            log("item \(item.title) canDownload=\(item.canDownload.map(String.init) ?? "nil") availability=\(downloads.availability(for: item))")
            if let plan = try? await library.downloadPlan(for: item) {
                log("plan \(item.title): \(plan.playback.rawValue) remux=\(plan.isRemux) objectAudio=\(plan.objectAudio) subtitles=\(plan.subtitleTracks.count)")
            }
            targets.append(item)
        }

        for item in targets { downloads.download(item) }
        let deadline = Date().addingTimeInterval(900)
        var lastLine = ""
        while Date() < deadline, downloads.jobs.values.contains(where: \.isActive) {
            let line = downloads.orderedJobs.map { "\($0.item.title)=\($0.phase) \(Int(($0.fraction ?? 0) * 100))%" }.joined(separator: ", ")
            if line != lastLine { log("progress \(line)"); lastLine = line }
            try? await Task.sleep(for: .seconds(2))
        }
        for job in downloads.jobs.values { log("FAIL job \(job.item.title) \(job.phase)") }

        for item in targets {
            guard let record = LibraryOfflineStore.shared.record(for: item.id) else {
                log("FAIL no record for \(item.title)")
                continue
            }
            let media = LibraryOfflineStore.mediaURL(record)
            log("record \(item.title): \(record.playback.rawValue) \(record.mediaPath) bytes=\(record.bytes) art=\(record.artwork.count) segments=\(record.segments.count) subtitles=\(record.subtitlePaths)")
            switch record.playback {
            case .video:
                let asset = AVURLAsset(url: media)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let tracks = (try? await asset.load(.tracks).map(\.mediaType.rawValue)) ?? []
                log("\(playable ? "PASS" : "FAIL") local file plays: duration=\(String(format: "%.1f", duration)) tracks=\(tracks)")
            case .film, .disc:
                let client = FilmServerClient(itemID: record.id, offline: FilmPackage(itemId: record.id, video: media))
                do {
                    let index = try await client.videoIndex()
                    let initSegment = try await client.videoInit()
                    _ = try FragmentedMP4Track(initSegment: initSegment)
                    let last = try await client.videoSegment(index.segmentStarts.count - 1)
                    let tracks = try await client.audioTracks(languages: ["eng"])
                    guard let scene = try await client.audioScene(startSeconds: 0) else { throw CocoaError(.fileNoSuchFile) }
                    let audio = try await client.with(audioStream: tracks.first?.index).audioSegment(scene.segmentCount - 1, of: scene)
                    log("PASS offline film: \(index.segmentStarts.count) video segments (last \(last.count) B), \(tracks.count) track(s), \(scene.segmentCount) audio segments, last has \(audio.buffers.map(\.frameLength))")
                } catch {
                    log("FAIL offline film: \(error)")
                }
                let joined = AVURLAsset(url: media)
                log("joined mp4 isPlayable=\((try? await joined.load(.isPlayable)) ?? false) duration=\(String(format: "%.1f", (try? await joined.load(.duration).seconds) ?? 0))")
            }
            if let route = try? await library.playbackRoute(for: item) {
                switch route {
                case .genericPlayer(let plan): log("route \(item.title): generic \(plan.streamURL.isFileURL ? "local file" : plan.streamURL.absoluteString)")
                case .atmosFilmPlayer: log("route \(item.title): film player")
                }
            }
            if let tracks = try? await library.subtitleTracks(itemId: item.id), !tracks.isEmpty {
                let first = try? await library.subtitleData(itemId: item.id, track: tracks[0])
                log("subtitles from the device: \(tracks.map(\.title)) first=\(first?.count ?? -1) B")
            }
        }

        // The server gone: the same calls, answered from the downloads.
        let offline = JellyfinLibrary(baseURL: URL(string: "http://127.0.0.1:9")!, accessToken: apiKey, userId: "x")
        do {
            let home = try await offline.home()
            log("PASS offline home: \(home.shelves.map { "\($0.title)(\($0.items.count))" }) featured=\(home.featured.count)")
        } catch {
            log("FAIL offline home: \(error)")
        }
        if let first = targets.first {
            let item = try? await offline.item(id: first.id)
            log("\(item != nil ? "PASS" : "FAIL") offline item \(item?.title ?? "nil"), art=\(item.flatMap { offline.imageURL(item: $0, kind: .primary, size: .poster) }?.isFileURL ?? false ? "local" : "remote")")
            await offline.reportPlaybackStopped(itemId: first.id, positionSeconds: 7)
            let record = LibraryOfflineStore.shared.record(for: first.id)
            log("\(record?.needsSync == true && record?.localPosition == 7 ? "PASS" : "FAIL") offline position kept: \(record?.localPosition ?? -1) needsSync=\(record?.needsSync ?? false)")
            let resumed = try? await offline.item(id: first.id)
            log("offline resume point \(resumed?.userData.resumeSeconds ?? -1)")
            await downloads.syncPendingWatchState()
            let fresh = try? await library.item(id: first.id)
            log("\(LibraryOfflineStore.shared.record(for: first.id)?.needsSync == false && fresh?.userData.resumeSeconds == 7 ? "PASS" : "FAIL") synced: server resume=\(fresh?.userData.resumeSeconds ?? -1)")
            try? await library.syncUserData(itemId: first.id, positionSeconds: 0, played: false, lastPlayed: nil)
        }

        // An account with downloads turned off.
        if let (token, user) = noDownloads, let movie = targets.first {
            let denied = JellyfinLibrary(baseURL: server, accessToken: token, userId: user)
            let allowed = try? await denied.downloadsAllowed()
            let item = try? await denied.item(id: movie.id)
            log("\(allowed == false && item?.canDownload == false ? "PASS" : "FAIL") no-download account: policy=\(allowed.map(String.init) ?? "nil") canDownload=\(item?.canDownload.map(String.init) ?? "nil")")
            downloads.libraryProvider = { denied }
            await downloads.refreshPolicy()
            if let item {
                log("no-download availability: \(downloads.availability(for: item))")
            }
            downloads.libraryProvider = { library }
            await downloads.refreshPolicy()
        }

        for item in targets { downloads.remove(itemId: item.id) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: LibraryOfflineStore.mediaRoot.path)) ?? []
        log("cleaned up; left in Jellyfin folder: \(left)")
    }
}

#endif
