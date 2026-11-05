/*
 Hypnos - Music section: fuzzy search over the names in a Jellyfin music library.

 The matching is Worldcast's (`EpisodeSearch.swift`, itself a port of the backend's fuzzy.js): every word of the
 query must match a word of the item, and each word is matched in tiers - exact, prefix, one typo, substring, two
 typos - so "beatels", "sgt pep" and "motorhed" all find what is meant. Unlike Worldcast, an item has several
 weighted fields (a song's title outweighs its artist, which outweighs its album) and the index keeps an inverted
 word -> items list, so a library of tens of thousands of songs searches in a few milliseconds.

 Foundation only: it is compiled by `scripts/check-music-player.sh` on its own.
 */

import Foundation

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
    private static let maxTypoWordLength = 40

    private struct Entry: Sendable {
        let id: String
        let kind: MusicSearchKind
        let nameLength: Int
        let nameText: String
        let nameWords: [Int32]
        let artistWords: [Int32]
        let albumWords: [Int32]
    }

    private let entries: [Entry]
    private let vocabulary: [(word: String, scalars: [Unicode.Scalar])]
    /// For each vocabulary word, the entries that contain it in any field.
    private let postings: [[Int32]]

    var count: Int { entries.count }

    init(docs: [MusicSearchDoc]) {
        var ids: [String: Int32] = [:]
        var words: [String] = []
        func intern(_ list: [String]) -> [Int32] {
            var out: [Int32] = []
            for word in list {
                let id: Int32
                if let known = ids[word] { id = known } else {
                    id = Int32(words.count); ids[word] = id; words.append(word)
                }
                if !out.contains(id) { out.append(id) }
            }
            return out
        }
        var built: [Entry] = []
        built.reserveCapacity(docs.count)
        for doc in docs {
            let nameList = Self.words(doc.name)
            // "AC/DC" is also typed "acdc", and "P!nk" "pnk": the name with its punctuation closed up is a word too.
            var nameTokens = nameList
            if nameList.count > 1 {
                let joined = nameList.joined()
                if joined.count <= 24 { nameTokens.append(joined) }
            }
            built.append(Entry(
                id: doc.id, kind: doc.kind, nameLength: doc.name.count, nameText: nameList.joined(separator: " "),
                nameWords: intern(nameTokens),
                artistWords: intern(Self.words(doc.artist ?? "")),
                albumWords: intern(Self.words(doc.album ?? ""))))
        }
        var lists = [[Int32]](repeating: [], count: words.count)
        for (index, entry) in built.enumerated() {
            for word in Set(entry.nameWords + entry.artistWords + entry.albumWords) { lists[Int(word)].append(Int32(index)) }
        }
        entries = built
        vocabulary = words.map { ($0, Array($0.unicodeScalars)) }
        postings = lists
    }

    /// Every word of `query` must match a word of an item's name, artist or album. Best first.
    func search(_ query: String, limit: Int = 100) -> [MusicSearchHit] {
        var seen = Set<String>()
        let terms = Self.words(query).filter { seen.insert($0).inserted }
        guard !terms.isEmpty, !entries.isEmpty else { return [] }

        // Resolve each term against the vocabulary once; entries are then scored by lookup.
        var matches: [[Int32: Double]] = []
        for term in terms {
            let scalars = Array(term.unicodeScalars)
            var matched: [Int32: Double] = [:]
            for (index, word) in vocabulary.enumerated() {
                let score = Self.termMatch(scalars, word.scalars, word: word.word, term: term)
                if score > 0 { matched[Int32(index)] = score }
            }
            if matched.isEmpty { return [] }
            matches.append(matched)
        }

        // Candidates: the entries that hold a match of every term, found through the postings.
        var candidates: Set<Int32>?
        for matched in matches.sorted(by: { $0.count < $1.count }) {
            var found = Set<Int32>()
            for word in matched.keys { found.formUnion(postings[Int(word)]) }
            candidates = candidates.map { $0.intersection(found) } ?? found
            if candidates?.isEmpty == true { return [] }
        }

        let phrase = terms.joined(separator: " ")
        var scored: [(hit: MusicSearchHit, length: Int)] = []
        for index in candidates ?? [] {
            let entry = entries[Int(index)]
            var total = 0.0
            var ok = true
            for matched in matches {
                var best = 0.0
                for word in entry.nameWords { if let s = matched[word] { best = max(best, s * Self.nameWeight) } }
                for word in entry.artistWords { if let s = matched[word] { best = max(best, s * Self.artistWeight) } }
                for word in entry.albumWords { if let s = matched[word] { best = max(best, s * Self.albumWeight) } }
                if best == 0 { ok = false; break }
                total += best
            }
            guard ok else { continue }
            // Typing the title, or the start of it, is the surest sign of what was meant.
            if entry.nameText == phrase { total += 6 }
            else if entry.nameText.hasPrefix(phrase) { total += 3 }
            else if terms.count > 1, entry.nameText.contains(phrase) { total += 2 }
            scored.append((MusicSearchHit(id: entry.id, kind: entry.kind, score: total), entry.nameLength))
        }
        scored.sort {
            if $0.hit.score != $1.hit.score { return $0.hit.score > $1.hit.score }
            if $0.hit.kind != $1.hit.kind { return $0.hit.kind.rank < $1.hit.kind.rank }
            return $0.length < $1.length
        }
        return scored.prefix(limit).map(\.hit)
    }

    // MARK: - Text

    /// Fold case and diacritics: "Beyoncé" -> "beyonce".
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Text -> folded words. Letters and digits only; everything else splits.
    static func words(_ text: String) -> [String] {
        fold(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // MARK: - Matching

    /// How well `term` matches vocabulary word `word`: 0 (no match) to 1 (exact). A one-typo word outranks a
    /// mere substring ("aple" -> "apple" over "maple").
    private static func termMatch(_ term: [Unicode.Scalar], _ other: [Unicode.Scalar], word: String, term text: String) -> Double {
        if word == text { return 1 }
        let length = term.count
        if length >= 2, word.hasPrefix(text) { return 0.8 }
        let maxEdits = length >= 8 ? 2 : length >= 4 ? 1 : 0
        let typoOk = maxEdits > 0 && other.count <= maxTypoWordLength
        let distance = typoOk ? editDistance(term, other[...], limit: maxEdits) : Int.max
        if distance == 1 { return 0.6 }
        if length >= 3, word.contains(text) { return 0.5 }
        if distance == 2, maxEdits == 2 { return 0.3 }
        // A half-typed word with a typo ("motorhad" -> "motorhead"); only from five letters on, since a short
        // prefix with a typo matches nearly anything.
        if typoOk, length >= 5, other.count > length,
           editDistance(term, other[..<length], limit: maxEdits) <= maxEdits { return 0.4 }
        return 0
    }

    /// Optimal-string-alignment distance (a swap of neighbours costs one), or `limit + 1` once it must exceed `limit`.
    static func editDistance(_ a: [Unicode.Scalar], _ bSlice: ArraySlice<Unicode.Scalar>, limit: Int) -> Int {
        let b = Array(bSlice)
        if abs(a.count - b.count) > limit { return limit + 1 }
        let n = b.count
        var previous2: [Int] = []
        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)
        for i in stride(from: 1, through: a.count, by: 1) {
            current[0] = i
            var rowMinimum = i
            for j in stride(from: 1, through: n, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if !previous2.isEmpty, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                if value < rowMinimum { rowMinimum = value }
            }
            if rowMinimum > limit { return limit + 1 }
            previous2 = previous
            previous = current
        }
        return previous[n]
    }
}
