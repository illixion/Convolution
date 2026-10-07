/*
 Hypnos - subtitles for one player

 The app's players own their pictures (the film player's sample-buffer
 layer, the stereo warp, the immersive video material), so subtitles are
 drawn by RAVEUI's `RAVESubtitleOverlay` rather than by AVFoundation. This
 is the part each player shares: which tracks the item offers, which one is
 showing, fetching and parsing it, and the timing offset.

 A track comes from a `SubtitleSource`, so the controller doesn't know which
 server it talks to. Jellyfin converts every text stream it has (sidecar
 SRT/ASS, embedded tracks) to WebVTT; image subtitles are listed but can't
 be selected.

 Which track starts is `SubtitlePreference`: the language last picked, or
 none if the user last turned subtitles off. Until they have chosen either
 way, only a forced track (foreign dialogue in an otherwise native film)
 shows.
 */

import DebugTrace
import Foundation
import Observation
import RAVEUI

/// Where a player's subtitle tracks come from.
struct SubtitleSource: Sendable {
    /// Identifies the item, so a reload for the same item is a no-op.
    var id: String
    var tracks: @Sendable () async throws -> [LibrarySubtitleTrack]
    var data: @Sendable (LibrarySubtitleTrack) async throws -> Data

    /// A Jellyfin item's streams, or nil when no server is configured.
    @MainActor
    static func jellyfin(itemId: String) -> SubtitleSource? {
        guard let library = LibraryService.current() else { return nil }
        return SubtitleSource(
            id: "jellyfin:\(itemId)",
            tracks: { try await library.subtitleTracks(itemId: itemId) },
            data: { try await library.subtitleData(itemId: itemId, track: $0) }
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

    /// Whichever source `video` came from, if it has subtitles at all.
    @MainActor
    static func forVideo(_ video: GalleryVideo) -> SubtitleSource? {
        if let itemId = LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) {
            return .jellyfin(itemId: itemId)
        }
        return .stash(video)
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
        let text = tracks.filter(\.isText)
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
    private(set) var tracks: [LibrarySubtitleTrack] = []
    private(set) var selected: LibrarySubtitleTrack?
    /// The parsed cues of `selected`, once fetched.
    private(set) var cues: RAVESubtitleTrack?
    private(set) var isFetching = false
    private(set) var error: String?
    /// Seconds; positive shows each cue later.
    var delay: Double = 0

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
                if let initial = SubtitlePreference.initialTrack(in: tracks) {
                    self.fetch(initial)
                }
                AppLogger.subtitles.info("\(tracks.count, privacy: .public) subtitle tracks, \(tracks.filter(\.isText).count, privacy: .public) text")
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.subtitles.error("Subtitle tracks failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }

    /// The user's pick from the menu; remembered for later films.
    func select(_ track: LibrarySubtitleTrack?) {
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
        listTask?.cancel()
        fetchTask?.cancel()
        source = nil
        tracks = []
        selected = nil
        cues = nil
        error = nil
        isFetching = false
        delay = 0
        parsed = [:]
    }

    private func fetch(_ track: LibrarySubtitleTrack) {
        guard track.isText, let source else { return }
        fetchTask?.cancel()
        selected = track
        error = nil
        if let cached = parsed[track.id] {
            cues = cached
            isFetching = false
            return
        }
        cues = nil
        isFetching = true
        fetchTask = Task { [weak self] in
            do {
                let data = try await source.data(track)
                let cues = try await Task.detached(priority: .userInitiated) { try RAVESubtitleTrack(data: data) }.value
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
}
