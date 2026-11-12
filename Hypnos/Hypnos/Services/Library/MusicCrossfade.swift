/*
 Hypnos - how one song gives way to the next: gapless, or a crossfade, and when an album is seamless.

 Every join is gapless unless Crossfade is on (Off by default, 2–12 s, iTunes's range). With it on,
 songs that merely follow each other in the queue crossfade; what happens between an album's
 consecutive tracks is `MusicAlbumCrossfade`:
 - **Unless Seamless** (default): listen to the seam. Continuous albums (a live album, a DJ mix, a
   concept album whose tracks run into each other) have sound on both sides of every track boundary;
   an ordinary album's songs end in a fade or silence. `MusicSeams` measures the last 0.3 s of one song
   and the first 0.3 s of the next from the files the engine fetched; when both carry sound the join is
   gapless, and the album is remembered as seamless for the rest of the session (so one quiet seam in
   it doesn't get faded). Until both edges are measured the join stays gapless (never a wrong fade).
   This is what iTunes needed its manual "Part of a gapless album" checkbox for.
 - **Never**: an album played in order is always gapless.
 - **Always**: albums crossfade like anything else.

 "Consecutive" means the same album (by id) and the next track number, or the next disc's track 1:
 an album in shuffle, or a playlist that skips about, crossfades.
 */

import Foundation

enum MusicAlbumCrossfade: String, CaseIterable, Identifiable, Sendable {
    case unlessSeamless
    case never
    case always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unlessSeamless: "Unless the Album Is Seamless"
        case .never: "Never Within an Album"
        case .always: "Always"
        }
    }
}

/// What the edges of a seam sound like.
enum MusicSeam: Equatable, Sendable {
    /// Sound on both sides: the songs run into each other.
    case continuous
    /// A fade or silence on at least one side.
    case separate
}

/// A song's first and last moments, in dBFS.
struct MusicEdges: Equatable, Sendable {
    let head: Double
    let tail: Double
}

enum MusicTransitionRules {
    /// The crossfade lengths offered, in seconds; 0 is Off.
    static let crossfadeChoices: [Double] = [0, 2, 4, 6, 8, 10, 12]
    /// Louder than this at a song's edge is sound, not a fade or silence. Room tone between classical
    /// movements (−60 dB and below) stays under it; crowd noise on a live album (−35 dB) is over it.
    static let soundThreshold = -50.0

    /// Whether `b` is the track after `a` on the same album.
    static func isAlbumSequence(_ a: JellyfinMusicItem, _ b: JellyfinMusicItem) -> Bool {
        guard let album = a.AlbumId, album == b.AlbumId, let ta = a.IndexNumber, let tb = b.IndexNumber else { return false }
        let da = a.ParentIndexNumber ?? 1, db = b.ParentIndexNumber ?? 1
        return (db == da && tb == ta + 1) || (db == da + 1 && tb == 1)
    }

    static func seam(_ a: MusicEdges?, _ b: MusicEdges?) -> MusicSeam? {
        guard let a, let b else { return nil }
        return a.tail > soundThreshold && b.head > soundThreshold ? .continuous : .separate
    }

    /// How playback should go from `a` to `b`.
    static func transition(from a: JellyfinMusicItem, to b: JellyfinMusicItem, crossfadeSeconds: Double,
                           albums: MusicAlbumCrossfade, seam: MusicSeam?, albumIsSeamless: Bool,
                           repeatingOne: Bool) -> MusicTimeline.Transition {
        guard crossfadeSeconds > 0, !repeatingOne else { return .gapless }
        let fade = MusicTimeline.Transition.crossfade(seconds: crossfadeSeconds)
        guard isAlbumSequence(a, b) else { return fade }
        switch albums {
        case .never: return .gapless
        case .always: return fade
        case .unlessSeamless:
            if albumIsSeamless { return .gapless }
            return seam == .separate ? fade : .gapless
        }
    }
}

/// Measures songs' edges from the engine's files, once each, in the background.
@MainActor
final class MusicSeams {
    static let shared = MusicSeams()
    private var edges: [String: MusicEdges] = [:]
    private var pending: [String: Task<MusicEdges?, Never>] = [:]
    /// Albums found to run into themselves this session.
    private(set) var seamlessAlbums: Set<String> = []

    func known(_ itemID: String) -> MusicEdges? { edges[itemID] }

    func markSeamless(album: String?) {
        if let album { seamlessAlbums.insert(album) }
    }

    /// The edges of `item`'s song, measured once `file` is complete. Calls `done` when they arrive.
    func measure(_ item: JellyfinMusicItem, file: MusicSongFile, done: @escaping @MainActor () -> Void) {
        guard edges[item.Id] == nil, pending[item.Id] == nil else { return }
        let task = Task.detached(priority: .utility) { () -> MusicEdges? in
            // Wait for the whole file (it is already downloading for playback).
            while !file.progress.complete {
                if file.progress.failure != nil || Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return Self.edges(of: file.fileURL)
        }
        pending[item.Id] = task
        Task {
            let result = await task.value
            pending[item.Id] = nil
            if let result {
                edges[item.Id] = result
                done()
            }
        }
    }

    /// RMS in dBFS of a song's first and last `window` seconds.
    nonisolated static func edges(of url: URL, window: Double = 0.3) -> MusicEdges? {
        guard let head = MusicFileDecoder(url: url) else { return nil }
        var format: MusicOutputFormat?
        var start: [Float] = []
        while start.count < Int(window * 2 * 96_000) {
            guard case .audio(let chunk) = head.read(maxFrames: 4096, output: &format) else { break }
            start += chunk
        }
        guard let rate = format?.sampleRate, let total = head.totalFrames else { return nil }
        let wanted = Int(window * rate)
        let headLevel = level(Array(start.prefix(wanted * 2)))
        // The tail: decode the last second and keep its last `window`.
        let seconds = Double(total) / rate
        guard let tailDecoder = MusicFileDecoder(url: url, startSeconds: max(0, seconds - 1)) else { return nil }
        var tailFormat = format
        var end: [Float] = []
        while true {
            switch tailDecoder.read(maxFrames: 4096, output: &tailFormat) {
            case .audio(let chunk): end += chunk; continue
            default: break
            }
            break
        }
        return MusicEdges(head: headLevel, tail: level(Array(end.suffix(wanted * 2))))
    }

    nonisolated static func level(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return 10 * log10(power + 1e-12)
    }
}
