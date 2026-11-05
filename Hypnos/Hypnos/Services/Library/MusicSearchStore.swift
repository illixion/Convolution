/*
 Hypnos - Music section: the fuzzy search index of the signed-in library, kept on disk.

 Jellyfin's `SearchTerm` is a substring match, so "beatels" finds nothing. The index holds the names of every
 artist, album and song (see `MusicSearchIndex`), built in bounded pages of names only and saved to the caches
 folder; later launches load it at once and ask the server only for the three totals to know whether it is still
 current. Until an index exists, search falls back to the server's own, so it works from the first keystroke.

 The index is made when the listener first searches (or at once when a saved one exists), never for someone who
 does not search: a large library is tens of thousands of names.
 */

import Foundation
import Observation

@MainActor @Observable
final class MusicSearchStore {
    static var shared = MusicSearchStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MusicSearch", isDirectory: true))

    enum State: Equatable, Sendable { case idle, building(Double), ready, failed }

    private(set) var state = State.idle
    /// Counts up each time a new index is swapped in, so a screen showing results can ask again.
    private(set) var generation = 0

    @ObservationIgnored private var index: MusicSearchIndex?
    @ObservationIgnored private var signature: String?
    @ObservationIgnored private var configuration: String?
    @ObservationIgnored private var verified = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let pageSize: Int
    /// A saved index older than this is rebuilt even when the totals agree (a rename keeps the counts).
    private static let maxAge: TimeInterval = 3 * 24 * 3600

    init(directory: URL?, pageSize: Int = 500) {
        self.directory = directory
        self.pageSize = pageSize
    }

    /// Whether searching can use the index now.
    var isReady: Bool { index != nil }

    /// Make or refresh the index of the library in force. With `onlyIfCached`, nothing is built from scratch.
    func prepare(onlyIfCached: Bool = false) {
        let key = LibraryService.configurationKey
        if configuration != key {
            task?.cancel(); task = nil
            configuration = key
            index = nil; signature = nil; verified = false
            state = .idle
        }
        guard task == nil, !verified else { return }
        if onlyIfCached, index == nil, !hasSavedIndex(for: key) { return }
        guard let library = LibraryService.current() else { return }
        task = Task { await self.refresh(library: library, key: key) }
    }

    /// The library changed under the index. With `rebuild` the names themselves did, so the index is made again
    /// from the server; without it the totals are checked once more.
    func invalidate(rebuild: Bool = false) {
        verified = false
        if rebuild { savedAt = .distantPast }
        if configuration != nil, index != nil { prepare() }
    }

    /// The best matches for `query`, nil while there is no index to ask.
    func hits(for query: String, limit: Int = 80) async -> [MusicSearchHit]? {
        guard let index else { return nil }
        return await Task.detached(priority: .userInitiated) { index.search(query, limit: limit) }.value
    }

    // MARK: - Building

    private func refresh(library: JellyfinLibrary, key: String) async {
        defer { if configuration == key { task = nil } }
        do {
            if index == nil, let saved = await load(key: key) {
                guard key == configuration else { return }
                index = saved.index; signature = saved.signature
                savedAt = saved.built
                state = .ready
                generation += 1
            }
            var totals: [MusicSearchKind: Int] = [:]
            for kind in MusicSearchKind.allCases {
                totals[kind] = try await library.musicSearchPage(kind: kind, start: 0, limit: 1).total
            }
            let current = MusicSearchKind.allCases.map { String(totals[$0] ?? 0) }.joined(separator: "/")
            if index != nil, signature == current, Date().timeIntervalSince(savedAt) < Self.maxAge {
                guard key == configuration else { return }
                verified = true
                state = .ready
                return
            }
            let grand = max(1, totals.values.reduce(0, +))
            var docs: [MusicSearchDoc] = []
            if index == nil { state = .building(0) }
            for kind in MusicSearchKind.allCases {
                var start = 0
                let total = totals[kind] ?? 0
                while start < total {
                    try Task.checkCancellation()
                    let page = try await library.musicSearchPage(kind: kind, start: start, limit: pageSize)
                    guard !page.docs.isEmpty else { break }
                    docs += page.docs
                    start += page.docs.count
                    if index == nil { state = .building(Double(docs.count) / Double(grand)) }
                }
            }
            try Task.checkCancellation()
            guard key == configuration else { return }
            let built = await Task.detached(priority: .utility) { MusicSearchIndex(docs: docs) }.value
            guard key == configuration else { return }
            index = built
            signature = current
            savedAt = Date()
            verified = true
            state = .ready
            generation += 1
            save(docs: docs, signature: current, key: key)
        } catch is CancellationError {
        } catch {
            guard key == configuration else { return }
            state = index == nil ? .failed : .ready
        }
    }

    @ObservationIgnored private var savedAt = Date.distantPast

    // MARK: - On disk

    private struct Saved: Codable {
        var signature: String
        var built: Date
        var docs: [MusicSearchDoc]
    }

    private func file(for key: String) -> URL? {
        // FNV-1a: the key holds the server address and account, which a file name should not.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return directory?.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    private func hasSavedIndex(for key: String) -> Bool {
        guard let url = file(for: key) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func load(key: String) async -> (index: MusicSearchIndex, signature: String, built: Date)? {
        guard let url = file(for: key) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
            return (MusicSearchIndex(docs: saved.docs), saved.signature, saved.built)
        }.value
    }

    private func save(docs: [MusicSearchDoc], signature: String, key: String) {
        guard let url = file(for: key), let directory else { return }
        let saved = Saved(signature: signature, built: savedAt, docs: docs)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: url, options: .atomic)
            // A rebuilt index is a cache: keep it out of backups.
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var target = url
            try? target.setResourceValues(excluded)
        }
    }
}
