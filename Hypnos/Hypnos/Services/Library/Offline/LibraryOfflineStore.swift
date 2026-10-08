/*
 Hypnos - Library downloads: what is on the device

 A downloaded Library title is more than its file. To play it offline the way
 it plays streamed, the device also keeps the item's metadata (and its
 show's, for an episode), its artwork, its skippable segments, its subtitles
 as sidecar files, and its watch position, which is synced back to the
 server once it can be reached.

 Where things live:
 - The media file and its subtitle sidecars: `Documents/Videos/Jellyfin/…`,
   so they show in the Files app and in the Local library like any file the
   user put there. Movies under `Movies/<Title (Year)>/`, episodes under
   `<Show>/Season N/`.
 - Everything else: `Application Support/LibraryOffline/<item id>/`
   (excluded from backup): `artwork/`, and for an object-audio film the
   plugin's audio scene and the byte offsets of its video segments inside
   the media file (see `FilmPackage`).
 - `index.json` beside them lists every download (`LibraryOfflineRecord`).

 Thread-safe and synchronous on purpose: `JellyfinLibrary.imageURL` is a
 nonisolated synchronous call, and it asks here for cached artwork.
 */

import DebugTrace
import Foundation
import os

/// One downloaded title.
struct LibraryOfflineRecord: Codable, Identifiable, Sendable {
    /// Which player a download plays in.
    enum Playback: String, Codable, Sendable {
        /// An AVFoundation-playable file (the original, or a server remux to
        /// MP4), in the generic video window.
        case video
        /// The object-audio film player: the plugin's video segments, joined
        /// into one fragmented MP4, plus its audio scene.
        case film
        /// A Blu-ray disc image, decoded on the device, with the plugin's
        /// object audio when it had any (else the disc's own 5.1).
        case disc
    }

    var id: String { item.id }
    var item: LibraryItem
    /// An episode's show, for its detail page and artwork offline.
    var series: LibraryItem?
    var playback: Playback
    /// The media file, relative to Documents.
    var mediaPath: String
    /// Subtitle sidecars, relative to Documents.
    var subtitlePaths: [String] = []
    /// `"<owner id>:<kind>"` → a file name under the item's artwork folder.
    var artwork: [String: String] = [:]
    var segments: [LibraryMediaSegment] = []
    /// Whether `film`/`disc` playback has the plugin's audio scene with it.
    var hasObjectAudio = false
    var bytes: Int64 = 0
    var downloadedAt = Date()

    /// Watch state played on the device, newer than the server's while
    /// `needsSync` is set.
    var localPosition: Double?
    var localPlayed: Bool?
    var localChangedAt: Date?
    var needsSync = false

    /// The item as offline screens should show it: the server's copy with
    /// any watch state from the device laid over it.
    var displayItem: LibraryItem {
        var item = item
        if let localPlayed { item.userData.isPlayed = localPlayed }
        if let localPosition { item.userData.playbackPositionTicks = Int64(localPosition * 10_000_000) }
        if let localChangedAt { item.userData.lastPlayedDate = localChangedAt }
        return item
    }
}

final class LibraryOfflineStore: @unchecked Sendable {
    static let shared = LibraryOfflineStore()

    private struct State {
        var records: [String: LibraryOfflineRecord] = [:]
        /// Artwork lookups (`"<owner>:<kind>"` → file), across all records:
        /// a show's art is shared by its episodes.
        var artwork: [String: URL] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let ioQueue = DispatchQueue(label: "LibraryOfflineStore.io", qos: .utility)

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LibraryOffline", isDirectory: true)
    }

    /// Where downloads appear in the Files app.
    static var mediaRoot: URL {
        LocalMediaSource.videosDirectory.appendingPathComponent("Jellyfin", isDirectory: true)
    }

    private static var indexURL: URL { root.appendingPathComponent("index.json") }

    static func itemDirectory(_ itemId: String) -> URL {
        root.appendingPathComponent(safeComponent(itemId), isDirectory: true)
    }

    static func artworkDirectory(_ itemId: String) -> URL {
        itemDirectory(itemId).appendingPathComponent("artwork", isDirectory: true)
    }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        var root = Self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)

        guard let data = try? Data(contentsOf: Self.indexURL),
              let records = try? JSONDecoder().decode([LibraryOfflineRecord].self, from: data)
        else { return }
        // A file the user deleted in the Files app takes its download with it.
        var kept: [String: LibraryOfflineRecord] = [:]
        for record in records {
            if fm.fileExists(atPath: Self.mediaURL(record).path) {
                kept[record.id] = record
            } else {
                AppLogger.library.info("Download's file is gone; forgetting it")
                try? fm.removeItem(at: Self.itemDirectory(record.id))
            }
        }
        let loaded = kept
        state.withLock { state in
            state.records = loaded
            state.artwork = Self.artworkIndex(loaded.values)
        }
        if kept.count != records.count { persist() }
    }

    // MARK: Reading

    func record(for itemId: String) -> LibraryOfflineRecord? {
        state.withLock { $0.records[itemId] }
    }

    var records: [LibraryOfflineRecord] {
        state.withLock { Array($0.records.values) }
    }

    var isEmpty: Bool { state.withLock { $0.records.isEmpty } }

    static func mediaURL(_ record: LibraryOfflineRecord) -> URL {
        LocalMediaSource.documentsDirectory.appendingPathComponent(record.mediaPath)
    }

    /// A downloaded file of `ownerId`'s `kind` art, if any record has one.
    func artworkURL(ownerId: String, kind: LibraryImageKind) -> URL? {
        state.withLock { $0.artwork["\(ownerId):\(kind.rawValue)"] }
    }

    /// The downloaded episodes of `seriesId`, in airing order.
    func episodes(seriesId: String) -> [LibraryOfflineRecord] {
        records
            .filter { $0.item.kind == .episode && $0.item.seriesId == seriesId }
            .sorted { ($0.item.seasonNumber ?? 0, $0.item.episodeNumber ?? 0) < ($1.item.seasonNumber ?? 0, $1.item.episodeNumber ?? 0) }
    }

    // MARK: Writing

    func save(_ record: LibraryOfflineRecord) {
        state.withLock { state in
            state.records[record.id] = record
            state.artwork = Self.artworkIndex(state.records.values)
        }
        persist()
    }

    /// Deletes a download: its file and sidecars, and everything kept beside them.
    func remove(itemId: String) {
        guard let record = state.withLock({ state -> LibraryOfflineRecord? in
            let removed = state.records.removeValue(forKey: itemId)
            state.artwork = Self.artworkIndex(state.records.values)
            return removed
        }) else { return }
        let fm = FileManager.default
        let media = Self.mediaURL(record)
        try? fm.removeItem(at: media)
        for path in record.subtitlePaths {
            try? fm.removeItem(at: LocalMediaSource.documentsDirectory.appendingPathComponent(path))
        }
        try? fm.removeItem(at: Self.itemDirectory(itemId))
        Self.removeEmptyFolders(from: media.deletingLastPathComponent())
        persist()
    }

    /// Updates a record in place; nil when there is no such download.
    @discardableResult
    func update(itemId: String, _ change: (inout LibraryOfflineRecord) -> Void) -> LibraryOfflineRecord? {
        let updated = state.withLockUnchecked { state -> LibraryOfflineRecord? in
            guard var record = state.records[itemId] else { return nil }
            change(&record)
            state.records[itemId] = record
            return record
        }
        if updated != nil { persist() }
        return updated
    }

    /// Notes where a downloaded title was left on the device. `synced` says
    /// whether the server already has it (the report reached it).
    func noteLocalPosition(itemId: String, seconds: Double, synced: Bool) {
        update(itemId: itemId) { record in
            let runtime = record.item.runtimeSeconds ?? 0
            // Jellyfin's own rule: past 90% counts as watched.
            if runtime > 0, seconds >= runtime * 0.9 {
                record.localPlayed = true
                record.localPosition = 0
            } else {
                record.localPlayed = false
                record.localPosition = seconds
            }
            record.localChangedAt = Date()
            record.needsSync = !synced
        }
    }

    // MARK: Helpers

    private func persist() {
        let records = self.records
        ioQueue.async {
            do {
                let data = try JSONEncoder().encode(records)
                try data.write(to: Self.indexURL, options: .atomic)
            } catch {
                AppLogger.library.error("Couldn't save the downloads index: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }

    private static func artworkIndex(_ records: some Sequence<LibraryOfflineRecord>) -> [String: URL] {
        var index: [String: URL] = [:]
        for record in records {
            let folder = artworkDirectory(record.id)
            for (key, file) in record.artwork where index[key] == nil {
                index[key] = folder.appendingPathComponent(file)
            }
        }
        return index
    }

    /// Climbs out of a removed download's folder, deleting folders it left
    /// empty, up to (not including) the downloads root.
    private static func removeEmptyFolders(from folder: URL) {
        let fm = FileManager.default
        var folder = folder.standardizedFileURL
        let stop = mediaRoot.standardizedFileURL.path
        while folder.path.hasPrefix(stop), folder.path != stop,
              let contents = try? fm.contentsOfDirectory(atPath: folder.path),
              contents.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
    }

    /// A string safe as one path component in the Files app: no slashes or
    /// colons, no leading dot, not empty.
    static func safeComponent(_ name: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var cleaned = String(name.unicodeScalars.map { banned.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "Untitled" }
        return String(cleaned.prefix(180))
    }
}
