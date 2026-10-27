/*
 Hypnos - subtitles for one player

 The app's players own their pictures (the film player's sample-buffer
 layer, the stereo warp, the immersive video material), so subtitles are
 drawn by RAVEUI's `RAVESubtitleOverlay` rather than by AVFoundation. This
 is the part each player shares: which tracks the item offers, which one is
 showing, fetching and parsing it, and the timing offset.

 A track comes from a `SubtitleSource`, so the controller doesn't know which
 server it talks to. Jellyfin converts every text stream it has (sidecar
 SRT/ASS, embedded tracks) to WebVTT, and serves an embedded PGS stream as
 a `.sup` file (`PGSSupFile`); other image subtitles (VobSub, DVB) are
 listed but can't be selected. A disc's own PGS the film player reads from
 the disc itself (`SubtitleSource.disc`, `DiscSubtitles`).

 Which track starts is `SubtitlePreference`: the language last picked, or
 none if the user last turned subtitles off. Until they have chosen either
 way, only a forced track (foreign dialogue in an otherwise native film)
 shows.

 A track inside an MKV or WebM the player is remuxing comes from the remux
 itself (`SubtitleSource.matroska`), read near the playhead as it moves.

 An embedded text track is streamed (`SubtitleSource.progressive`, the
 plugin's `FilmSubtitles` route) rather than fetched whole: Jellyfin's own
 `Stream.vtt` reads the whole video file before answering, 15–90 s for an
 Archer episode on a network share. The stream starts just before the
 player's playhead, the cues show as they arrive, and a seek outside what
 has arrived starts it again from there. Once a run reaches the end of the
 file, the stretch before it is fetched from the start and merged. Without
 the plugin (a 404) the track is fetched whole as before.
 */

import AVFoundation
import GeneratedCaptions
import RAVEFilm
import DebugTrace
import Foundation
import MatroskaRemux
import Observation
import RAVEUI

/// Where a player's subtitle tracks come from.
struct SubtitleSource: Sendable {
    /// Identifies the item, so a reload for the same item is a no-op.
    var id: String
    var tracks: @Sendable () async throws -> [LibrarySubtitleTrack]
    var data: @Sendable (LibrarySubtitleTrack) async throws -> Data
    /// An embedded text track from a start time on, growing as it arrives;
    /// nil when the source can't stream that track.
    var progressive: (@Sendable (LibrarySubtitleTrack, Double) -> AsyncThrowingStream<SubtitleStreamChunk, Error>?)? = nil
    /// Cues that grow while the film plays, each element replacing the
    /// last: a disc's bitmap tracks, a remuxed file's tracks. Given the
    /// player's position, as what is read can follow it; nil for a track
    /// the source doesn't serve this way.
    var live: (@Sendable (LibrarySubtitleTrack, @escaping @MainActor @Sendable () -> Double)
        -> AsyncStream<RAVESubtitleTrack>?)? = nil

    /// The same source without the tracks inside the video file.
    func excludingEmbedded() -> SubtitleSource {
        var source = self
        let tracks = self.tracks
        source.id += ":external"
        source.tracks = { try await tracks().filter { !$0.isEmbedded } }
        return source
    }

    /// A Jellyfin item's streams, or nil when no server is configured.
    @MainActor
    static func jellyfin(itemId: String) -> SubtitleSource? {
        guard let library = LibraryService.current() else { return nil }
        return SubtitleSource(
            id: "jellyfin:\(itemId)",
            tracks: { try await library.subtitleTracks(itemId: itemId) },
            data: { try await library.subtitleData(itemId: itemId, track: $0) },
            progressive: { library.subtitleStream(itemId: itemId, track: $0, from: $1) }
        )
    }

    /// A Blu-ray disc played from a Jellyfin item: the disc's own PGS tracks,
    /// read with the picture, then any text tracks Jellyfin has for it
    /// (sidecar files; it lists the disc's own streams as images).
    @MainActor
    static func disc(_ subtitles: DiscSubtitles, itemId: String, includeServer: Bool = true) -> SubtitleSource {
        let server = includeServer ? jellyfin(itemId: itemId) : nil
        var seen: [String: Int] = [:]
        let discTracks = subtitles.tracks.map { track in
            let key = track.language ?? ""
            seen[key, default: 0] += 1
            return LibrarySubtitleTrack(id: Int(track.pid), sourceId: "disc", language: track.language,
                                        name: seen[key]! > 1 ? "Track \(seen[key]!)" : nil,
                                        isText: false, isBitmap: true)
        }
        return SubtitleSource(
            // Per opening: each one reads the disc afresh.
            id: "disc:\(itemId):\(ObjectIdentifier(subtitles).hashValue)",
            tracks: {
                let text = (try? await server?.tracks()) ?? []
                return discTracks + text.filter(\.isText)
            },
            data: { track in
                guard let server else { throw URLError(.resourceUnavailable) }
                return try await server.data(track)
            },
            live: { track, _ in track.isBitmap ? subtitles.cues(pid: UInt16(clamping: track.id)) : nil }
        )
    }

    /// A Stash scene's sidecar captions, which Stash serves as WebVTT
    /// whatever their original format.
    static func stash(_ video: GalleryVideo) -> SubtitleSource? {
        guard let base = video.captionsURL, !video.captions.isEmpty else { return nil }
        let captions = video.captions
        let tracks = captions.enumerated().map { index, caption in
            LibrarySubtitleTrack(id: index, sourceId: "", language: caption.languageCode == "00" ? nil : caption.languageCode,
                                 name: caption.type.uppercased())
        }
        return SubtitleSource(
            id: "stash:\(video.identity)",
            tracks: { tracks },
            data: { track in
                let caption = captions[track.id]
                let url = base.appending(queryItems: [
                    URLQueryItem(name: "lang", value: caption.languageCode),
                    URLQueryItem(name: "type", value: caption.type),
                ])
                let (data, response) = try await URLSession.shared.data(for: MediaAuthorization.shared.request(for: url))
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Caption: HTTP \(status)"]) }
                return data
            }
        )
    }

    /// A YouTube video's own captions (sideload builds), else a Stash scene's.
    private static func youTubeOrStash(_ video: GalleryVideo) -> SubtitleSource? {
        #if HYPNOS_YOUTUBE
        if let id = YouTubeVideoID(videoIdentity: video.identity) { return .youTube(id) }
        #endif
        return .stash(video)
    }

    /// Whichever source `video` came from, if it has subtitles at all, with
    /// the tracks inside the MKV/WebM when the player plays it remuxed
    /// (`remuxSource`: the URL the remux was opened from).
    @MainActor
    static func forVideo(_ video: GalleryVideo, remuxing remuxSource: URL? = nil) -> SubtitleSource? {
        let base: SubtitleSource?
        if let itemId = LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) {
            base = .jellyfin(itemId: itemId)
        } else if video.streamURL.isFileURL {
            base = .localFile(video.streamURL, identity: video.identity)
        } else {
            base = Self.youTubeOrStash(video)
        }
        guard let remuxSource, let session = MatroskaRemuxService.shared.session(for: remuxSource),
              !session.subtitleTracks.isEmpty else { return base }
        // A Library title's embedded tracks come from the file the device
        // reads anyway; the server keeps its sidecar files.
        let others = LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) != nil
            ? base?.excludingEmbedded() : base
        return .matroska(session, identity: video.identity, adding: others)
    }
}

/// The user's subtitle choice, carried from one film to the next.
enum SubtitlePreference {
    private static let key = "subtitles.language"

    /// Remembers `track`'s language, or "off" for nil.
    static func remember(_ track: LibrarySubtitleTrack?) {
        UserDefaults.standard.set(track.map { normalized($0.language) } ?? "off", forKey: key)
    }

    /// Jellyfin tags ISO 639-2 ("eng"), Stash the file's own suffix ("en"):
    /// both compare as the two-letter code where one exists.
    static func normalized(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "" }
        return Locale.Language(identifier: language).languageCode?.identifier(.alpha2) ?? language.lowercased()
    }

    static func initialTrack(in tracks: [LibrarySubtitleTrack]) -> LibrarySubtitleTrack? {
        let text = tracks.filter { $0.isPlayable && !$0.isAutoGenerated }
        switch UserDefaults.standard.string(forKey: key) {
        case "off":
            return nil
        case let language?:
            let matching = text.filter { normalized($0.language) == language }
            return matching.first { !$0.isForced && $0.isDefault }
                ?? matching.first { !$0.isForced }
                ?? matching.first
        case nil:
            return text.first { $0.isForced }
        }
    }
}

@MainActor
@Observable
final class SubtitleController {
    let generated = RAVEGeneratedCaptions()
    private(set) var canGenerate = false
    private static let generatedTrack = LibrarySubtitleTrack(id: -10000, sourceId: "generated", language: nil, name: "AI Captions")

    init() {
        generated.onChange = { [weak self] in
            guard let self, self.selected == Self.generatedTrack else { return }
            self.cues = RAVESubtitleTrack(cues: self.generated.captions.map { caption in
                let prefix = caption.speaker.map { "Speaker \($0): " } ?? ""
                return RAVESubtitleCue(start: caption.start, end: caption.end, text: AttributedString(prefix + caption.text))
            })
        }
    }
    func bindAnalysisPlayer(_ player: AVPlayer?, buffering: ((Bool) -> Void)? = nil) {
        // Release the previous transport before handing the hold callback to
        // the new renderer. A late teardown must not hold its replacement.
        generated.bind(player: nil)
        generated.onBuffering = buffering
        canGenerate = player != nil
        generated.bind(player: player)
    }
    func bindGeneratedFilm(_ player: FilmPlayer) {
        let resume = generated.enabled
        generated.stop()
        generated.onBuffering = { [weak player] held in player?.setAnalysisBuffering(held) }
        generated.bindExternal(position: { [weak player] in player?.currentTime ?? 0 },
            duration: { [weak player] in player?.duration ?? 0 },
            speed: { [weak player] in player?.speed ?? 1 },
            playing: { [weak player] in player?.isPlaying == true && player?.analysisBuffering == false },
            source: { [weak player] start in
                guard let player else { throw URLError(.cancelled) }
                let filmSource = try await player.captionAudioSource(start: start)
                return RAVECaptionAudioSource {
                    try await filmSource.next().map { RAVECaptionAudioChunk(buffer: $0.buffer, time: $0.time) }
                }
            })
        canGenerate = player.hasAudioScene
        if resume, canGenerate { generated.start() }
    }
    func selectGenerated() {
        guard canGenerate else { return }
        if selected == Self.generatedTrack, generated.enabled {
            select(nil)
            return
        }
        fetchTask?.cancel()
        selectionMadeForSource = true
        selected = Self.generatedTrack
        cues = nil; error = nil; isFetching = false
        generated.start()
    }
    private(set) var tracks: [LibrarySubtitleTrack] = []
    private(set) var selected: LibrarySubtitleTrack?
    private var selectionMadeForSource = false
    /// The parsed cues of `selected`, once fetched.
    private(set) var cues: RAVESubtitleTrack?
    private(set) var isFetching = false
    private(set) var error: String?
    /// Seconds; positive shows each cue later.
    var delay: Double = 0
    /// The player's position, where a streamed track starts and what a seek
    /// is measured against. Set by the player that owns this controller.
    @ObservationIgnored var playhead: @MainActor () -> Double = { 0 }

    @ObservationIgnored private var source: SubtitleSource?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// Parsed tracks of the current item, so switching back is instant.
    @ObservationIgnored private var parsed: [Int: RAVESubtitleTrack] = [:]

    /// The track time for a picture showing `filmTime`.
    func cueTime(forFilmTime filmTime: Double) -> Double { filmTime - delay }

    /// Lists `source`'s tracks and starts the preferred one. Nil clears.
    func load(_ source: SubtitleSource?) {
        guard source?.id != self.source?.id else { return }
        reset()
        self.source = source
        guard let source else { return }
        listTask = Task { [weak self] in
            do {
                let tracks = try await source.tracks()
                guard let self, !Task.isCancelled else { return }
                self.tracks = tracks
                if !self.selectionMadeForSource, let initial = SubtitlePreference.initialTrack(in: tracks) {
                    self.fetch(initial)
                }
                AppLogger.subtitles.info("\(tracks.count, privacy: .public) subtitle tracks, \(tracks.filter(\.isPlayable).count, privacy: .public) playable")
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.subtitles.error("Subtitle tracks failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }

    /// The user's pick from the menu; remembered for later films.
    func select(_ track: LibrarySubtitleTrack?) {
        selectionMadeForSource = true
        generated.stop()
        SubtitlePreference.remember(track)
        guard let track else {
            fetchTask?.cancel()
            selected = nil
            cues = nil
            error = nil
            isFetching = false
            return
        }
        fetch(track)
    }

    func reset() {
        generated.stop()
        listTask?.cancel()
        fetchTask?.cancel()
        source = nil
        tracks = []
        selected = nil
        selectionMadeForSource = false
        cues = nil
        error = nil
        isFetching = false
        delay = 0
        parsed = [:]
    }

    private func fetch(_ track: LibrarySubtitleTrack) {
        guard track.isPlayable, let source else { return }
        fetchTask?.cancel()
        selected = track
        error = nil
        if let live = source.live?(track, { [weak self] in self?.playhead() ?? 0 }) {
            cues = nil
            isFetching = true
            fetchTask = Task { [weak self] in
                for await cues in live {
                    guard let self, !Task.isCancelled, self.selected == track else { return }
                    self.cues = cues
                    self.isFetching = false
                }
            }
            return
        }
        if let cached = parsed[track.id] {
            cues = cached
            isFetching = false
            return
        }
        cues = nil
        isFetching = true
        if track.isText, track.isEmbedded, let progressive = source.progressive {
            fetchTask = Task { [weak self] in
                await self?.stream(track, progressive: progressive, fallback: source)
            }
            return
        }
        fetchWhole(track, from: source)
    }

    private func fetchWhole(_ track: LibrarySubtitleTrack, from source: SubtitleSource) {
        fetchTask = Task { [weak self] in
            do {
                let data = try await source.data(track)
                let isBitmap = track.isBitmap
                let trackID = track.id
                let cues = try await Task.detached(priority: .userInitiated) {
                    isBitmap ? try PGSSupFile.track(from: data, trackID: trackID) : try RAVESubtitleTrack(data: data)
                }.value
                guard let self, !Task.isCancelled, self.selected == track else { return }
                self.parsed[track.id] = cues
                self.cues = cues
                self.isFetching = false
                AppLogger.subtitles.info("Subtitle track \(track.id, privacy: .public): \(cues.cues.count, privacy: .public) cues")
            } catch {
                guard let self, !Task.isCancelled, self.selected == track else { return }
                self.isFetching = false
                self.error = error.localizedDescription
                AppLogger.subtitles.error("Subtitle track \(track.id, privacy: .public) failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }

    // MARK: Streamed tracks

    /// How a streamed run ended.
    private enum RunEnd {
        /// It reached the end of the file (or the server sent the whole track).
        case finished(wholeTrack: Bool)
        /// The playhead left what the run covers; start again there.
        case moved(to: Double)
        /// The source can't stream this track (no plugin route): fetch it whole.
        case unsupported
    }

    /// Where a run for a playhead at `time` starts: a little before it, for
    /// a cue already showing, and from the top near the beginning, where one
    /// run gets the whole track (which the server then keeps).
    private static func runStart(at time: Double) -> Double {
        time < 90 ? 0 : time - 30
    }

    private func stream(_ track: LibrarySubtitleTrack,
                        progressive: @escaping @Sendable (LibrarySubtitleTrack, Double) -> AsyncThrowingStream<SubtitleStreamChunk, Error>?,
                        fallback source: SubtitleSource) async {
        let began = Date.now
        var have: [RAVESubtitleCue] = []
        var start = Self.runStart(at: playhead())
        var tailStart = start
        do {
            // From the playhead to the end of the file, restarting on a seek.
            runs: while true {
                guard let run = progressive(track, start) else {
                    return fetchWhole(track, from: source)
                }
                switch try await consume(run, of: track, from: start, merging: &have, began: began) {
                case .unsupported:
                    AppLogger.subtitles.info("Subtitle track \(track.id, privacy: .public): no streaming route, fetching it whole")
                    return fetchWhole(track, from: source)
                case .moved(let time):
                    start = Self.runStart(at: time)
                    AppLogger.subtitles.info("Subtitle track \(track.id, privacy: .public): seek outside what has arrived, streaming from \(start, format: .fixed(precision: 0), privacy: .public) s")
                case .finished(let wholeTrack):
                    tailStart = wholeTrack ? 0 : start
                    break runs
                }
            }
            // The stretch before the run that reached the end.
            if tailStart > 0, let head = progressive(track, 0) {
                _ = try await consume(head, of: track, from: 0, until: tailStart, merging: &have, began: began)
            }
            guard !Task.isCancelled, selected == track else { return }
            let complete = RAVESubtitleTrack(cues: have)
            parsed[track.id] = complete
            cues = complete
            isFetching = false
            AppLogger.subtitles.info("Subtitle track \(track.id, privacy: .public): \(have.count, privacy: .public) cues, whole track in \(Date.now.timeIntervalSince(began), format: .fixed(precision: 1), privacy: .public) s")
        } catch {
            guard !Task.isCancelled, selected == track else { return }
            if have.isEmpty {
                isFetching = false
                self.error = error.localizedDescription
            }
            AppLogger.subtitles.error("Subtitle track \(track.id, privacy: .public) stream failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    /// Reads one run into `have`, showing the cues as they come. With
    /// `until`, stops once the run reaches it (the head before a tail);
    /// otherwise stops early when the playhead leaves what the run covers.
    private func consume(_ run: AsyncThrowingStream<SubtitleStreamChunk, Error>, of track: LibrarySubtitleTrack,
                         from start: Double, until: Double? = nil,
                         merging have: inout [RAVESubtitleCue], began: Date) async throws -> RunEnd {
        do {
            for try await chunk in run {
                try Task.checkCancellation()
                guard selected == track else { throw CancellationError() }
                let data = chunk.data
                let received = await Task.detached(priority: .userInitiated) {
                    (try? RAVESubtitleTrack(data: data))?.cues ?? []
                }.value
                let reached = received.last?.start ?? start
                let kept = until.map { limit in received.filter { $0.start < limit } } ?? received
                have = Self.merged(have, kept)
                if !have.isEmpty {
                    if isFetching {
                        AppLogger.subtitles.info("Subtitle track \(track.id, privacy: .public): first cues after \(Date.now.timeIntervalSince(began), format: .fixed(precision: 1), privacy: .public) s")
                    }
                    cues = RAVESubtitleTrack(cues: have)
                    isFetching = false
                }
                if chunk.isFinished { return .finished(wholeTrack: chunk.isWholeTrack) }
                if chunk.isWholeTrack { continue }
                if let until {
                    if reached >= until { return .finished(wholeTrack: false) }
                    continue
                }
                // A seek ahead of what has arrived, or behind where the run began.
                let time = playhead()
                if time > reached + 120 || time < start - 5 { return .moved(to: time) }
            }
            return .finished(wholeTrack: false)
        } catch JellyfinLibraryError.http(_, 404) {
            return .unsupported
        }
    }

    /// `old` and `new` together in start order, each cue once.
    private static func merged(_ old: [RAVESubtitleCue], _ new: [RAVESubtitleCue]) -> [RAVESubtitleCue] {
        guard !old.isEmpty else { return new }
        var seen = Set(old.map(CueKey.init))
        var all = old
        for cue in new where seen.insert(CueKey(cue)).inserted { all.append(cue) }
        return all.sorted { $0.start < $1.start }
    }

    private struct CueKey: Hashable {
        let start: Int
        let end: Int
        let text: String

        init(_ cue: RAVESubtitleCue) {
            start = Int((cue.start * 1000).rounded())
            end = Int((cue.end * 1000).rounded())
            text = cue.plainText
        }
    }
}
