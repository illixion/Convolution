/*
 Hypnos - Music section: fuzzy search over the names in a Jellyfin music library.

 The matching is RAVESDK's `RAVEFuzzyIndex` (lifted from here and Worldcast's episode search, which each wrote
 it): every word of the query must match a word of the item, in tiers - exact, prefix, one typo, substring, two
 typos - so "beatels", "sgt pep" and "motorhed" all find what is meant. This file only says what a music
 library asks of it: three weighted fields (a song's title outweighs its artist, which outweighs its album),
 titles typed in full or from the start preferred, "AC/DC" also found as "acdc", and an artist listed before an
 album before a song when they score alike.

 Foundation and RAVESearch only: `scripts/check-music-player.sh` compiles it on its own, with RAVESearch's sources.
 */

import Foundation
#if canImport(RAVESearch)
import RAVESearch
#endif

enum MusicSearchKind: String, Codable, Sendable, CaseIterable {
    case artist, album, song

    /// Jellyfin's item type for this kind.
    var itemType: String {
        switch self {
        case .artist: "MusicArtist"
        case .album: "MusicAlbum"
        case .song: "Audio"
        }
    }

    /// The order results of an equal score list in: an artist before the albums before the songs.
    fileprivate var rank: Int { self == .artist ? 0 : self == .album ? 1 : 2 }
}

/// What the index keeps of one item: just the words a listener types. Everything shown (artwork, favorites,
/// stars) is fetched for the hits that are on screen.
struct MusicSearchDoc: Codable, Sendable, Hashable {
    let id: String
    let kind: MusicSearchKind
    let name: String
    let artist: String?
    let album: String?
}

struct MusicSearchHit: Sendable, Hashable {
    let id: String
    let kind: MusicSearchKind
    let score: Double
}

struct MusicSearchIndex: Sendable {
    static let nameWeight = 3.0
    static let artistWeight = 1.5
    static let albumWeight = 1.0

    private struct Key: Hashable, Sendable {
        let id: String
        let kind: MusicSearchKind
    }

    private let index: RAVEFuzzyIndex<Key>

    var count: Int { index.count }

    init(docs: [MusicSearchDoc]) {
        index = RAVEFuzzyIndex(
            weights: [Self.nameWeight, Self.artistWeight, Self.albumWeight],
            documents: docs.map { doc in
                RAVEFuzzyDocument(
                    id: Key(id: doc.id, kind: doc.kind),
                    fields: [doc.name, doc.artist ?? "", doc.album ?? ""],
                    // Artists, then albums, then songs; the shorter name first within a kind.
                    priority: doc.kind.rank * 100_000 + min(doc.name.count, 99_999))
            },
            // Typing the title, or the start of it, is the surest sign of what was meant.
            options: RAVEFuzzyOptions(phraseBonus: 2, primaryExactBonus: 6, primaryPrefixBonus: 3, joinPrimaryWords: true))
    }

    /// Every word of `query` must match a word of an item's name, artist or album. Best first.
    func search(_ query: String, limit: Int = 100) -> [MusicSearchHit] {
        index.search(query, limit: limit).map { MusicSearchHit(id: $0.id.id, kind: $0.id.kind, score: $0.score) }
    }
}
