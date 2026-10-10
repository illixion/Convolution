/*
 Hypnos - Library downloads: getting titles onto the device

 One queue behind every Download button and menu item in the Library. A job
 takes an item from the server to a `LibraryOfflineRecord`:

 1. Fresh metadata, and the server's say on whether it may be downloaded
    (`CanDownload`: the account's "Allow media downloading" policy and the
    item being a file). A refusal is shown on the button and in the menu
    before anything is asked; a 403 from the download itself says the same.
 2. Artwork (the item's and its show's), skippable segments, and text
    subtitles as WebVTT sidecars beside the file, which the Local library's
    subtitle reader already understands.
 3. For object audio (`JellyfinLibrary.downloadPlan`), the plugin decodes
    the whole film on the server, then its scene and every segment are
    fetched into a `FilmPackage`.
 4. The media file. A plain file or remux goes through a background
    `URLSession`, so it keeps going while the app is suspended and finishes
    even if the app was closed (the job's draft record is on disk under
    `pending/`, and the session is reconnected at launch). An object-audio
    film's video comes as the plugin's segments, appended in order to one
    MP4; that part runs while the app is open, and picks up where it
    stopped when retried.

 Watch state played offline is synced back from here when the server
 returns (`syncPendingWatchState`). tvOS has no downloads: its storage is a
 purgeable cache the system clears at will.
 */

import DebugTrace
import Foundation
import Observation
import RAVEFilm

/// How one item gets downloaded; see `JellyfinLibrary.downloadPlan(for:)`.
struct LibraryDownloadPlan: Sendable {
    var playback: LibraryOfflineRecord.Playback
    /// The media file's request; nil for an object-audio film, whose video
    /// comes as segments.
    var mediaRequest: URLRequest?
    var isRemux: Bool
    /// The server's file size: exact for an original, a guide for a remux.
    var expectedBytes: Int64?
    var fileExtension: String
    var subtitleTracks: [LibrarySubtitleTrack]
    var objectAudio: Bool
}

/// One download in the queue or under way.
struct LibraryDownloadJob: Identifiable, Equatable {
    enum Phase: Equatable {
        case queued
        case preparing
        case downloading
        case failed(String)
    }

    let id: String
    var item: LibraryItem
    var phase: Phase = .queued
    /// 0...1 when known.
    var fraction: Double?
    /// What the job is doing, for a caption under its title.
    var detail: String?

    var isActive: Bool {
        if case .failed = phase { return false }
        return true
    }
}

/// Whether an item can be downloaded, and if not, why.
enum LibraryDownloadAvailability: Equatable {
    case available
    case denied(String)
    /// Not something with a file (a collection), or a platform without downloads.
    case unsupported
}

@MainActor
@Observable
final class LibraryDownloads {
    static let shared = LibraryDownloads()

    /// Downloads have somewhere lasting to go (not tvOS).
    static var isSupported: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    private(set) var jobs: [String: LibraryDownloadJob] = [:]
    /// Bumped whenever a download is added or removed.
    private(set) var revision = 0
    /// The account's download permission, once asked (nil until then).
    private(set) var accountAllowsDownloads: Bool?
    /// The server didn't answer the last request.
    private(set) var isOffline = false

    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var mediaWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var expectedBytes: [String: Int64] = [:]
    @ObservationIgnored private var started = false
    /// Which server downloads come from; the macOS harness points it at the
    /// dev instance.
    @ObservationIgnored var libraryProvider: @MainActor () -> JellyfinLibrary? = { LibraryService.current() }
    @ObservationIgnored private lazy var session: URLSession = {
        let identifier = (Bundle.main.bundleIdentifier ?? "com.illixion.hypnos") + ".library-downloads"
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration, delegate: SessionDelegate.shared, delegateQueue: nil)
    }()

    private init() {}

    // MARK: Launch

    /// Reconnects transfers that ran while the app was closed, and restores
    /// the queue. Called once at launch.
    func start() {
        guard Self.isSupported, !started else { return }
        started = true
        let store = LibraryOfflineStore.shared
        _ = store.isEmpty  // load and prune the index now, off the first screen
        for draft in PendingDownload.all() {
            jobs[draft.record.id] = LibraryDownloadJob(id: draft.record.id, item: draft.record.item, phase: .downloading,
                                                       detail: "Downloading")
            expectedBytes[draft.record.id] = draft.expectedBytes
        }
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in self.reconcile(liveTasks: live) }
        }
        for item in Self.savedQueue() where jobs[item.id] == nil {
            jobs[item.id] = LibraryDownloadJob(id: item.id, item: item)
            order.append(item.id)
        }
        runQueue()
        Task { await syncPendingWatchState() }
    }

    /// Drafts whose transfer the system no longer has (the app was removed
    /// from memory mid-download long enough for it to give up) fail with a
    /// retry rather than spinning forever.
    private func reconcile(liveTasks: Set<String>) {
        for draft in PendingDownload.all() where !liveTasks.contains(draft.record.id) {
            if case .downloading = jobs[draft.record.id]?.phase, running[draft.record.id] == nil {
                jobs[draft.record.id]?.phase = .failed("The download stopped. Try again.")
            }
        }
    }

    // MARK: State for the UI

    func record(for itemId: String) -> LibraryOfflineRecord? {
        _ = revision
        return LibraryOfflineStore.shared.record(for: itemId)
    }

    var records: [LibraryOfflineRecord] {
        _ = revision
        return LibraryOfflineStore.shared.records
    }

    func job(for itemId: String) -> LibraryDownloadJob? { jobs[itemId] }

    /// Jobs in queue order, the active one first.
    var orderedJobs: [LibraryDownloadJob] {
        let queued = order.compactMap { jobs[$0] }
        let others = jobs.values.filter { !order.contains($0.id) }.sorted { $0.item.title < $1.item.title }
        return others + queued
    }

    func availability(for item: LibraryItem) -> LibraryDownloadAvailability {
        guard Self.isSupported else { return .unsupported }
        switch item.kind {
        case .movie, .episode:
            if item.canDownload == false {
                return .denied(accountAllowsDownloads == false
                    ? Self.accountDeniedMessage
                    : "The server doesn't allow downloading this title.")
            }
        case .series, .season:
            break
        case .collection, .unknown:
            return .unsupported
        }
        if accountAllowsDownloads == false { return .denied(Self.accountDeniedMessage) }
        return .available
    }

    static let accountDeniedMessage = "Downloads are turned off for your account on the Jellyfin server."

    /// Asks the server whether this account may download. Library screens
    /// call it when they load; the answer greys out Download buttons.
    func refreshPolicy() async {
        guard Self.isSupported, let library = libraryProvider() else { return }
        if let allowed = try? await library.downloadsAllowed() {
            accountAllowsDownloads = allowed
        }
    }

    func connectivityChanged(offline: Bool) {
        guard isOffline != offline else { return }
        isOffline = offline
        if !offline {
            Task { await syncPendingWatchState() }
        }
    }

    // MARK: Actions

    /// Queues a movie or episode; a show or season queues its episodes.
    func download(_ item: LibraryItem) {
        guard availability(for: item) == .available else { return }
        switch item.kind {
        case .movie, .episode:
            enqueue(item)
        case .series, .season:
            Task { await downloadEpisodes(of: item) }
        default:
            break
        }
    }

    private func downloadEpisodes(of container: LibraryItem) async {
        guard let library = libraryProvider() else { return }
        do {
            let seasons = container.kind == .season ? [container] : try await library.seasons(seriesId: container.id)
            for season in seasons {
                for episode in try await library.episodes(seasonId: season.id) where episode.canDownload != false {
                    enqueue(episode)
                }
            }
        } catch {
            AppLogger.library.error("Couldn't list episodes to download: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    private func enqueue(_ item: LibraryItem) {
        if LibraryOfflineStore.shared.record(for: item.id) != nil { return }
        if let job = jobs[item.id], job.isActive { return }
        jobs[item.id] = LibraryDownloadJob(id: item.id, item: item)
        order.removeAll { $0 == item.id }
        order.append(item.id)
        saveQueue()
        runQueue()
    }

    func retry(itemId: String) {
        guard let job = jobs[itemId] else { return }
        jobs[itemId] = nil
        PendingDownload.remove(itemId: itemId)
        enqueue(job.item)
    }

    /// Stops a download and deletes what it fetched so far.
    func cancel(itemId: String) {
        running[itemId]?.cancel()
        running[itemId] = nil
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == itemId }.forEach { $0.cancel() }
        }
        mediaWaiters.removeValue(forKey: itemId)?.resume(throwing: CancellationError())
        if let draft = PendingDownload.load(itemId: itemId) {
            Self.deleteFiles(of: draft.record)
        }
        PendingDownload.remove(itemId: itemId)
        try? FileManager.default.removeItem(at: LibraryOfflineStore.itemDirectory(itemId))
        jobs[itemId] = nil
        order.removeAll { $0 == itemId }
        saveQueue()
        runQueue()
    }

    /// Deletes a finished download from the device.
    func remove(itemId: String) {
        LibraryOfflineStore.shared.remove(itemId: itemId)
        revision += 1
    }

    /// Removes every download of a show (or one season of it).
    func removeEpisodes(of container: LibraryItem) {
        for record in LibraryOfflineStore.shared.records where record.item.kind == .episode {
            let matches = container.kind == .season
                ? record.item.seasonId == container.id
                : record.item.seriesId == container.id
            if matches { LibraryOfflineStore.shared.remove(itemId: record.id) }
        }
        revision += 1
    }

    /// Downloaded episodes of a show or season.
    func downloadedEpisodeCount(of container: LibraryItem) -> Int {
        records.filter { record in
            record.item.kind == .episode && (container.kind == .season
                ? record.item.seasonId == container.id
                : record.item.seriesId == container.id)
        }.count
    }

    // MARK: Watch-state sync

    /// Sends the server where offline watching left each download.
    func syncPendingWatchState() async {
        let pending = LibraryOfflineStore.shared.records.filter(\.needsSync)
        guard !pending.isEmpty, let library = libraryProvider() else { return }
        var synced = 0
        for record in pending {
            let played = record.localPlayed ?? false
            do {
                try await library.syncUserData(itemId: record.id, positionSeconds: played ? 0 : (record.localPosition ?? 0),
                                               played: played, lastPlayed: record.localChangedAt)
                LibraryOfflineStore.shared.update(itemId: record.id) { record in
                    record.needsSync = false
                    record.item.userData.isPlayed = played
                    record.item.userData.playbackPositionTicks = Int64((played ? 0 : record.localPosition ?? 0) * 10_000_000)
                }
                synced += 1
            } catch {
                AppLogger.library.error("Watch state sync failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                break
            }
        }
        if synced > 0 {
            AppLogger.library.info("Synced offline watch state for \(synced, privacy: .public) download(s)")
            LibraryWatchState.shared.changed()
        }
    }

    // MARK: The queue

    private func runQueue() {
        guard runner == nil else { return }
        runner = Task {
            while let next = order.first(where: { jobs[$0]?.phase == .queued }) {
                let task = Task { await self.perform(itemId: next) }
                running[next] = task
                await task.value
                running[next] = nil
            }
            runner = nil
        }
    }

    private func perform(itemId: String) async {
        guard let job = jobs[itemId] else { return }
        jobs[itemId]?.phase = .preparing
        jobs[itemId]?.detail = "Preparing"
        do {
            try await download(job.item)
            jobs[itemId] = nil
            order.removeAll { $0 == itemId }
            saveQueue()
            revision += 1
        } catch is CancellationError {
            // `cancel` cleaned up.
        } catch {
            guard jobs[itemId] != nil else { return }
            let message = Self.message(for: error)
            AppLogger.library.error("Download failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            jobs[itemId]?.phase = .failed(message)
            jobs[itemId]?.detail = nil
            order.removeAll { $0 == itemId }
            saveQueue()
        }
    }

    private static func message(for error: Error) -> String {
        if case JellyfinLibraryError.http(_, 403) = error { return "The Jellyfin server doesn't allow downloading this." }
        if case FilmServerError.http(_, 403) = error { return "The Jellyfin server doesn't allow downloading this." }
        if JellyfinLibrary.isUnreachable(error) { return "Couldn't reach the server. Try again when you're online." }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace { return "There isn't enough storage on this device." }
        return error.localizedDescription
    }

    // MARK: One download

    private func download(_ requested: LibraryItem) async throws {
        guard let library = libraryProvider() else { throw JellyfinLibraryError.notConfigured }
        let itemId = requested.id
        var item = try await library.item(id: itemId)
        if item.canDownload == false { throw JellyfinLibraryError.http(path: "Download", status: 403) }
        var series: LibraryItem?
        if item.kind == .episode, let seriesId = item.seriesId {
            series = try? await library.item(id: seriesId)
        }
        let plan = try await library.downloadPlan(for: item)
        try Task.checkCancellation()

        let base = Self.basePath(for: item, series: series)
        var record = LibraryOfflineRecord(item: item, series: series, playback: plan.playback,
                                          mediaPath: base + "." + plan.fileExtension)
        record.mediaPath = Self.unusedPath(record.mediaPath)
        let fm = FileManager.default
        try fm.createDirectory(at: LibraryOfflineStore.documents(record.mediaPath).deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        jobs[itemId]?.detail = "Artwork and subtitles"
        record.artwork = await fetchArtwork(for: item, series: series, library: library)
        record.segments = (try? await library.mediaSegments(itemId: itemId)) ?? []
        record.subtitlePaths = await fetchSubtitles(plan.subtitleTracks, item: item,
                                                    mediaPath: record.mediaPath, library: library)
        try Task.checkCancellation()

        let package = FilmPackage(itemId: itemId, video: plan.playback == .film
            ? LibraryOfflineStore.documents(record.mediaPath) : nil)
        if plan.objectAudio {
            try await fetchObjectAudio(itemId: itemId, package: package, library: library)
            record.hasObjectAudio = true
        }

        if plan.playback == .film {
            // Joined beside the package and moved into Documents complete, so
            // the Files app and the Local library never show half a film.
            let partial = package.directory.appendingPathComponent("video.partial.mp4")
            try await fetchFilmVideo(itemId: itemId, package: package, into: partial, library: library)
            try FileManager.default.moveItem(at: partial, to: LibraryOfflineStore.documents(record.mediaPath))
            finish(record)
            return
        }

        guard let request = plan.mediaRequest else { throw JellyfinLibraryError.http(path: "Download", status: 404) }
        jobs[itemId]?.phase = .downloading
        jobs[itemId]?.detail = plan.isRemux ? "Downloading (converted to MP4 on the server)" : "Downloading"
        jobs[itemId]?.fraction = 0
        expectedBytes[itemId] = plan.expectedBytes
        PendingDownload(record: record, expectedBytes: plan.expectedBytes, keepsServerName: !plan.isRemux).save()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mediaWaiters[itemId] = continuation
            let task = session.downloadTask(with: request)
            task.taskDescription = itemId
            if let bytes = plan.expectedBytes, bytes > 0 { task.countOfBytesClientExpectsToReceive = bytes }
            task.resume()
        }
    }

    /// The background transfer for `itemId` ended (in this launch or an
    /// earlier one): file it, or fail the job.
    fileprivate func mediaCompleted(itemId: String, outcome: SessionDelegate.Outcome) {
        let waiter = mediaWaiters.removeValue(forKey: itemId)
        guard let draft = PendingDownload.load(itemId: itemId) else {
            waiter?.resume(throwing: CancellationError())
            return
        }
        do {
            switch outcome {
            case .failed(let error):
                throw error
            case .status(let status):
                throw JellyfinLibraryError.http(path: "Download", status: status)
            case .file(let staged, let suggestedName):
                var record = draft.record
                // The original keeps its own extension (.mkv stays .mkv, .m4v
                // stays .m4v), sidecars and all, which share the base name.
                if draft.keepsServerName, let ext = suggestedName.map({ ($0 as NSString).pathExtension.lowercased() }),
                   !ext.isEmpty, ext != (record.mediaPath as NSString).pathExtension.lowercased() {
                    record.mediaPath = Self.unusedPath((record.mediaPath as NSString).deletingPathExtension + "." + ext)
                }
                let destination = LibraryOfflineStore.documents(record.mediaPath)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staged, to: destination)
                PendingDownload.remove(itemId: itemId)
                finish(record)
                if let waiter {
                    waiter.resume()
                } else {
                    // Finished while no job was waiting (an earlier launch's).
                    jobs[itemId] = nil
                    order.removeAll { $0 == itemId }
                    saveQueue()
                }
            }
        } catch {
            PendingDownload.remove(itemId: itemId)
            if let waiter {
                waiter.resume(throwing: error)
            } else {
                jobs[itemId]?.phase = .failed(Self.message(for: error))
            }
        }
    }

    fileprivate func mediaProgress(itemId: String, written: Int64, expected: Int64) {
        let total = expected > 0 ? expected : (expectedBytes[itemId] ?? 0)
        guard total > 0 else { return }
        // A remux has no length; its source's size is a guide, never 100%.
        jobs[itemId]?.fraction = min(expected > 0 ? 1 : 0.99, Double(written) / Double(total))
    }

    private func finish(_ record: LibraryOfflineRecord) {
        var record = record
        record.downloadedAt = Date()
        record.bytes = Self.size(of: LibraryOfflineStore.documents(record.mediaPath))
            + Self.size(of: LibraryOfflineStore.itemDirectory(record.id))
        LibraryOfflineStore.shared.save(record)
        revision += 1
        AppLogger.library.info("Downloaded a \(record.playback.rawValue, privacy: .public) title, \(record.bytes, privacy: .public) bytes")
    }

    // MARK: Pieces

    /// Each artwork the item shows, and its show's, into the item's folder.
    private func fetchArtwork(for item: LibraryItem, series: LibraryItem?, library: JellyfinLibrary) async -> [String: String] {
        let folder = LibraryOfflineStore.artworkDirectory(item.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var refs: [(owner: String, kind: LibraryImageKind)] = item.images.map { ($0.ownerId ?? item.id, $0.kind) }
        if let series { refs += series.images.map { ($0.ownerId ?? series.id, $0.kind) } }
        var saved: [String: String] = [:]
        for ref in refs {
            let key = "\(ref.owner):\(ref.kind.rawValue)"
            guard saved[key] == nil, let data = try? await library.artworkData(ownerId: ref.owner, kind: ref.kind) else { continue }
            let file = "\(LibraryOfflineStore.safeComponent(ref.owner))-\(ref.kind.rawValue).img"
            if (try? data.write(to: folder.appendingPathComponent(file))) != nil { saved[key] = file }
        }
        return saved
    }

    /// Text subtitles as WebVTT beside the media: `Film.en.vtt`,
    /// `Film.fr.forced.vtt`, `Film.en.Commentary.vtt`.
    private func fetchSubtitles(_ tracks: [LibrarySubtitleTrack], item: LibraryItem, mediaPath: String,
                                library: JellyfinLibrary) async -> [String] {
        let base = (mediaPath as NSString).deletingPathExtension
        var used = Set<String>()
        var paths: [String] = []
        for track in tracks {
            guard let data = try? await library.subtitleData(itemId: item.id, track: track) else { continue }
            var words: [String] = []
            if let language = track.language { words.append(language) }
            if let name = track.name, !name.isEmpty {
                let cleaned = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
                if !cleaned.isEmpty, cleaned.lowercased() != track.language?.lowercased() { words.append(cleaned) }
            }
            if track.isForced { words.append("forced") }
            if track.isHearingImpaired { words.append("sdh") }
            var stem = ([base] + words).joined(separator: ".")
            var n = 2
            while used.contains(stem) { stem = ([base] + words + [String(n)]).joined(separator: "."); n += 1 }
            used.insert(stem)
            let path = stem + ".vtt"
            if (try? data.write(to: LibraryOfflineStore.documents(path))) != nil { paths.append(path) }
        }
        return paths
    }

    /// The plugin decodes the film's whole audio track (it otherwise decodes
    /// only what is played), then the scene and every segment come down.
    /// Segments already on disk from an earlier try are kept.
    private func fetchObjectAudio(itemId: String, package: FilmPackage, library: JellyfinLibrary) async throws {
        try FileManager.default.createDirectory(at: package.audioDirectory, withIntermediateDirectories: true)
        let root = "AtmosObjects/\(itemId)"

        var query: [URLQueryItem] = []
        if let tracksData = try? await library.data(path: "\(root)/Tracks", query: [
            .init(name: "languages", value: FilmServerClient.deviceLanguages.joined(separator: ",")),
        ]), let tracks = try? JSONDecoder().decode([FilmAudioTrack].self, from: tracksData),
           let chosen = tracks.first(where: \.isDefault) ?? tracks.first,
           let entries = try? JSONSerialization.jsonObject(with: tracksData) as? [[String: Any]] {
            // Only the track that would play is kept, so it is the only one
            // the player lists: the copy answers every track with this one.
            let kept = entries.filter { ($0["index"] as? Int) == chosen.index }.map { entry in
                entry.merging(["isDefault": true]) { $1 }
            }
            try JSONSerialization.data(withJSONObject: kept).write(to: package.tracksURL)
            query = [.init(name: "audioStream", value: String(chosen.index))]
        }

        jobs[itemId]?.detail = "Preparing object audio on the server"
        await library.prepareObjectAudio(itemId: itemId)
        while true {
            try Task.checkCancellation()
            let state = try await library.objectAudioState(itemId: itemId)
            if state.state == "ready" { break }
            if state.state == "failed" || state.state == "unsupported" {
                throw JellyfinLibraryError.http(path: "AtmosObjects", status: 422)
            }
            jobs[itemId]?.fraction = state.progress.map { $0 * 0.1 }
            try await Task.sleep(for: .seconds(3))
        }

        let sceneData = try await library.data(path: "\(root)/Scene", query: query + [.init(name: "startSeconds", value: "0")], timeout: 120)
        let scene = try JSONDecoder().decode(AtmosScene.self, from: sceneData)
        try sceneData.write(to: package.sceneURL)

        jobs[itemId]?.phase = .downloading
        jobs[itemId]?.detail = "Downloading object audio"
        let segmentCount = scene.segmentCount
        let groupCount = scene.groups.count
        let audioQuery = query
        var done = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            while done < segmentCount {
                while next < segmentCount, next - done < 4 {
                    let n = next
                    group.addTask {
                        try await Self.fetchAudioSegment(n, groups: groupCount, root: root, query: audioQuery,
                                                         package: package, library: library)
                    }
                    next += 1
                }
                try await group.next()
                done += 1
                jobs[itemId]?.fraction = 0.1 + 0.2 * Double(done) / Double(max(1, segmentCount))
            }
        }
    }

    /// One audio segment's events and channel groups, unless already kept.
    private nonisolated static func fetchAudioSegment(_ n: Int, groups: Int, root: String, query: [URLQueryItem],
                                                      package: FilmPackage, library: JellyfinLibrary) async throws {
        let events = package.eventsURL(segment: n)
        if !FileManager.default.fileExists(atPath: events.path) {
            let data = try await library.data(path: "\(root)/Segments/\(n)/Events", query: query, timeout: 120)
            try data.write(to: events, options: .atomic)
        }
        for g in 0..<groups {
            let url = package.groupURL(segment: n, group: g)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            let data = try await library.data(path: "\(root)/Segments/\(n)/\(g)", query: query, timeout: 120)
            try data.write(to: url, options: .atomic)
        }
    }

    /// The plugin's video, init then every segment, appended to `file`.
    /// Ranges are written as it goes, so a retry continues from the last one.
    ///
    /// A Dolby Vision profile 5 film is kept as the plugin's converted 1080p
    /// HDR10 tier instead of its original: only the system's renderer shows
    /// profile 5 right, so the original couldn't play in 3D, and with no
    /// server to convert it offline, the download carries the copy that does
    /// both. Its index is stored saying HDR10, so playback treats it as such.
    private func fetchFilmVideo(itemId: String, package: FilmPackage, into file: URL, library: JellyfinLibrary) async throws {
        let root = "AtmosObjects/\(itemId)"
        var indexData = try await library.data(path: "\(root)/Video")
        let index = try JSONDecoder().decode(FilmVideoIndex.self, from: indexData)
        let tier = index.needsSystemRenderer ? FilmPictureQuality.stepDown(from: nil, offering: index.pictureHeights) : nil
        let query = tier.map { [URLQueryItem(name: "height", value: String($0))] } ?? []
        if tier != nil, var described = try JSONSerialization.jsonObject(with: indexData) as? [String: Any] {
            described["videoRange"] = "HDR10"
            described["dvProfile"] = NSNull()
            described["dolbyVision"] = false
            described["pictureHeights"] = [Int]()
            indexData = try JSONSerialization.data(withJSONObject: described)
            AppLogger.library.info("Downloading the converted \(FilmPictureQuality.name(of: tier), privacy: .public) HDR10 picture of a Dolby Vision profile 5 film")
        }
        try FileManager.default.createDirectory(at: package.directory, withIntermediateDirectories: true)
        try indexData.write(to: package.videoIndexURL)

        var ranges = (try? JSONDecoder().decode([[Int64]].self, from: Data(contentsOf: package.videoRangesURL))) ?? []
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            ranges = []
            fm.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // Drop anything past the last recorded segment (a write cut short).
        let end = ranges.last.map { $0[0] + $0[1] } ?? 0
        try handle.truncate(atOffset: UInt64(end))
        try handle.seekToEnd()

        let total = index.segmentStarts.count + 1  // with the init segment
        jobs[itemId]?.phase = .downloading
        jobs[itemId]?.detail = "Downloading"
        func path(_ piece: Int) -> String { piece == 0 ? "\(root)/Video/Init" : "\(root)/Video/Segments/\(piece - 1)" }

        // A few requests in flight, written strictly in order.
        var pending: [Int: Task<Data, Error>] = [:]
        defer { pending.values.forEach { $0.cancel() } }
        var piece = ranges.count
        var offset = end
        while piece < total {
            try Task.checkCancellation()
            for ahead in piece..<min(total, piece + 4) where pending[ahead] == nil {
                let requestPath = path(ahead)
                pending[ahead] = Task { try await library.data(path: requestPath, query: query, timeout: 120) }
            }
            let data = try await pending.removeValue(forKey: piece)!.value
            try handle.write(contentsOf: data)
            ranges.append([offset, Int64(data.count)])
            offset += Int64(data.count)
            piece += 1
            if piece % 10 == 0 || piece == total {
                try JSONEncoder().encode(ranges).write(to: package.videoRangesURL, options: .atomic)
            }
            jobs[itemId]?.fraction = 0.3 + 0.7 * Double(piece) / Double(total)
        }
    }

    // MARK: Files

    /// `Videos/Jellyfin/Movies/Title (Year)/Title (Year)` or
    /// `Videos/Jellyfin/Show/Season 1/Show - S01E02 - Title`, relative to Documents.
    private static func basePath(for item: LibraryItem, series: LibraryItem?) -> String {
        let root = "Videos/Jellyfin"
        let safe = LibraryOfflineStore.safeComponent
        if item.kind == .episode {
            let show = safe(item.seriesName ?? series?.title ?? "Show")
            let season = item.seasonNumber.map { "Season \($0)" } ?? "Episodes"
            var name = show
            if let s = item.seasonNumber, let e = item.episodeNumber {
                name += String(format: " - S%02dE%02d", s, e)
            }
            name += " - " + item.title
            return "\(root)/\(show)/\(season)/\(safe(name))"
        }
        let title = safe(item.year.map { "\(item.title) (\($0))" } ?? item.title)
        return "\(root)/Movies/\(title)/\(title)"
    }

    /// `path`, or `path (2)` and so on when something already has the name.
    private static func unusedPath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: LibraryOfflineStore.documents(path).path) else { return path }
        let ext = (path as NSString).pathExtension
        let stem = (path as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: LibraryOfflineStore.documents("\(stem) (\(n)).\(ext)").path) { n += 1 }
        return "\(stem) (\(n)).\(ext)"
    }

    private static func deleteFiles(of record: LibraryOfflineRecord) {
        let fm = FileManager.default
        try? fm.removeItem(at: LibraryOfflineStore.documents(record.mediaPath))
        for path in record.subtitlePaths { try? fm.removeItem(at: LibraryOfflineStore.documents(path)) }
    }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        for case let file as URL in fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) ?? .init() {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Queue persistence

    private static let queueKey = "library.downloadQueue"

    private func saveQueue() {
        let items = order.compactMap { jobs[$0] }.filter { $0.phase == .queued || $0.phase == .preparing }.map(\.item)
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.queueKey)
    }

    private static func savedQueue() -> [LibraryItem] {
        guard let data = UserDefaults.standard.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([LibraryItem].self, from: data)) ?? []
    }
}

extension LibraryOfflineStore {
    /// A path relative to Documents as a file URL.
    static func documents(_ path: String) -> URL {
        LocalMediaSource.documentsDirectory.appendingPathComponent(path)
    }
}

// MARK: - A download whose file is still on its way

/// Everything a download has besides its media file, written before the
/// background transfer starts so the transfer can be filed even when it
/// finishes in a later launch.
private struct PendingDownload: Codable {
    var record: LibraryOfflineRecord
    var expectedBytes: Int64?
    /// The original file: keep the server's extension.
    var keepsServerName: Bool

    private static var folder: URL { LibraryOfflineStore.root.appendingPathComponent("pending", isDirectory: true) }
    private static func url(_ itemId: String) -> URL {
        folder.appendingPathComponent(LibraryOfflineStore.safeComponent(itemId) + ".json")
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url(record.id), options: .atomic)
    }

    static func load(itemId: String) -> PendingDownload? {
        (try? Data(contentsOf: url(itemId))).flatMap { try? JSONDecoder().decode(PendingDownload.self, from: $0) }
    }

    static func remove(itemId: String) {
        try? FileManager.default.removeItem(at: url(itemId))
    }

    static func all() -> [PendingDownload] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(PendingDownload.self, from: $0) } }
    }

    /// Where a finished transfer waits to be filed.
    static func stagingURL(_ itemId: String) -> URL {
        folder.appendingPathComponent(LibraryOfflineStore.safeComponent(itemId) + ".download")
    }
}

// MARK: - Background session delegate

private final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = SessionDelegate()

    enum Outcome {
        case file(URL, suggestedName: String?)
        case status(Int)
        case failed(Error)
    }

    /// Set by didFinishDownloading, read by didComplete, which always follows it.
    private var finished: [Int: Outcome] = [:]
    private let lock = NSLock()
    private var lastProgress: [Int: Date] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let itemId = downloadTask.taskDescription ?? ""
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        let outcome: Outcome
        if status == 200 {
            // The system deletes `location` when this returns.
            let staged = PendingDownload.stagingURL(itemId)
            try? FileManager.default.removeItem(at: staged)
            do {
                try FileManager.default.moveItem(at: location, to: staged)
                outcome = .file(staged, suggestedName: downloadTask.response?.suggestedFilename)
            } catch {
                outcome = .failed(error)
            }
        } else {
            outcome = .status(status)
        }
        lock.withLock { finished[downloadTask.taskIdentifier] = outcome }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            if let last = lastProgress[downloadTask.taskIdentifier], now.timeIntervalSince(last) < 0.5 { return false }
            lastProgress[downloadTask.taskIdentifier] = now
            return true
        }
        guard due, let itemId = downloadTask.taskDescription else { return }
        Task { @MainActor in
            LibraryDownloads.shared.mediaProgress(itemId: itemId, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let itemId = task.taskDescription else { return }
        let outcome = lock.withLock { () -> Outcome? in
            lastProgress[task.taskIdentifier] = nil
            return finished.removeValue(forKey: task.taskIdentifier)
        }
        if let error, (error as? URLError)?.code == .cancelled { return }
        let result = outcome ?? .failed(error ?? URLError(.unknown))
        Task { @MainActor in LibraryDownloads.shared.mediaCompleted(itemId: itemId, outcome: result) }
    }
}
