/*
 Hypnos - Photos Index Store

 The actor that owns the index database. Every read and write to SQLite goes
 through here, which is what serializes access — the wrapper relies on that
 rather than on SQLite's own threading modes.

 Excluded from backup, like the other caches: it is derived from the photo
 library and re-buildable at any time, so backing it up would cost the user
 space to store something they already have.
 */

import DebugTrace
import Foundation
import Photos

actor PhotosIndexStore {
    static let shared = PhotosIndexStore()

    private var database: SQLiteDatabase?

    private var directoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PhotosIndex", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent("index.sqlite")
    }

    private init() {}

    // MARK: - Lifecycle

    /// Opens the database, creating it if needed, and drops it if the schema has
    /// moved on. Safe to call repeatedly.
    ///
    /// Returns whether the index needs a full build — either it is brand new, or
    /// the previous build never finished covering the library.
    @discardableResult
    func prepare() throws -> Bool {
        if database == nil {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var directory = directoryURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)

            let handle = try SQLiteDatabase(path: fileURL.path)
            database = handle
            try handle.execute(PhotosIndexSchema.statements)

            let stored = try handle.queryInt("SELECT CAST(value AS INTEGER) FROM meta WHERE key = ?",
                                             [.text(PhotosIndexSchema.MetaKey.schemaVersion)])
            if Int(stored ?? -1) != PhotosIndexSchema.version {
                AppLogger.photosIndex.info(
                    "Schema \(Int(stored ?? -1), privacy: .public) → \(PhotosIndexSchema.version, privacy: .public), rebuilding"
                )
                try resetLocked()
            }
        }
        return try !(metaFlag(PhotosIndexSchema.MetaKey.assetPassComplete))
    }

    /// Empties the index. The caller is expected to rebuild.
    func reset() throws {
        guard database != nil else { return }
        try resetLocked()
    }

    private func resetLocked() throws {
        guard let database else { return }
        try database.transaction {
            for table in ["asset", "album", "album_asset", "person", "person_asset", "meta"] {
                try database.run("DELETE FROM \(table)")
            }
            try database.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                             [.text(PhotosIndexSchema.MetaKey.schemaVersion),
                              .integer(Int64(PhotosIndexSchema.version))])
        }
    }

    /// Deletes the database entirely. For revoked access, where keeping a mirror
    /// of a library we may no longer read would be indefensible.
    func destroy() throws {
        database = nil
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fileURL.path + suffix)
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
            }
        }
    }

    // MARK: - Meta

    func metaData(_ key: String) throws -> Data? {
        guard let database else { return nil }
        var result: Data?
        try database.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { row in
            result = row.data(0)
        }
        return result
    }

    func metaString(_ key: String) throws -> String? {
        guard let database else { return nil }
        var result: String?
        try database.query("SELECT CAST(value AS TEXT) FROM meta WHERE key = ?", [.text(key)]) { row in
            result = row.string(0)
        }
        return result
    }

    func metaFlag(_ key: String) throws -> Bool {
        try metaString(key) == "1"
    }

    func setMeta(_ key: String, data: Data) throws {
        try database?.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                          [.text(key), .blob(data)])
    }

    func setMeta(_ key: String, string: String) throws {
        try database?.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                          [.text(key), .text(string)])
    }

    // MARK: - Writes

    /// Inserts or updates a batch of assets.
    ///
    /// `random_rank` is assigned once and then left alone — that is the whole
    /// point of storing it, so re-indexing an asset does not move it in a random
    /// ordering. `filename` is likewise preserved: it costs an XPC round trip to
    /// learn and does not change when the metadata around it does.
    func upsertAssets(_ rows: [PhotosIndexAssetRow]) throws {
        guard let database, !rows.isEmpty else { return }
        try database.transaction {
            for row in rows {
                try database.run(
                    """
                    INSERT INTO asset (id, kind, subtypes, favorite, created, modified,
                                       width, height, duration, filename, filename_folded, random_rank)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind = excluded.kind,
                        subtypes = excluded.subtypes,
                        favorite = excluded.favorite,
                        created = excluded.created,
                        modified = excluded.modified,
                        width = excluded.width,
                        height = excluded.height,
                        duration = excluded.duration
                    """,
                    [
                        .text(row.id),
                        .integer(Int64(row.kind)),
                        .integer(Int64(row.subtypes)),
                        .bool(row.favorite),
                        .optionalDate(row.created),
                        .optionalDate(row.modified),
                        .integer(Int64(row.width)),
                        .integer(Int64(row.height)),
                        .real(row.duration),
                        .integer(Int64.random(in: 0...Int64.max)),
                    ]
                )
            }
        }
    }

    func deleteAssets(ids: [String]) throws {
        guard let database, !ids.isEmpty else { return }
        try database.transaction {
            for id in ids {
                // Membership is cleaned up here rather than by a cascade; see
                // PhotosIndexSchema for why there are no foreign keys.
                try database.run("DELETE FROM asset WHERE id = ?", [.text(id)])
                try database.run("DELETE FROM album_asset WHERE asset_id = ?", [.text(id)])
                try database.run("DELETE FROM person_asset WHERE asset_id = ?", [.text(id)])
            }
        }
    }

    /// Replaces the album list and all membership in one transaction.
    ///
    /// Wholesale rather than incremental: album membership has no change
    /// notification granular enough to trust, the row count is small next to the
    /// asset table, and a half-applied album edit is the kind of inconsistency
    /// that shows up as photos missing from an album with no explanation.
    func replaceAlbums(_ albums: [PhotosIndexAlbumRow]) throws {
        guard let database else { return }
        try database.transaction {
            try database.run("DELETE FROM album")
            try database.run("DELETE FROM album_asset")
            for album in albums {
                try database.run(
                    "INSERT OR REPLACE INTO album (id, title, is_smart, sort_order) VALUES (?, ?, ?, ?)",
                    [.text(album.id), .text(album.title), .bool(album.isSmart), .integer(Int64(album.sortOrder))]
                )
                for (position, assetId) in album.assetIds.enumerated() {
                    try database.run(
                        "INSERT OR IGNORE INTO album_asset (album_id, asset_id, position) VALUES (?, ?, ?)",
                        [.text(album.id), .text(assetId), .integer(Int64(position))]
                    )
                }
            }
        }
    }

    /// Records filenames learned by the backfill pass.
    func setFilenames(_ named: [String: String]) throws {
        guard let database, !named.isEmpty else { return }
        try database.transaction {
            for (id, filename) in named {
                try database.run(
                    "UPDATE asset SET filename = ?, filename_folded = ? WHERE id = ?",
                    [.text(filename), .text(filename.lowercased()), .text(id)]
                )
            }
        }
    }

    /// The next assets with no filename yet, oldest-first so the backfill walks
    /// the library in a stable order and can be interrupted freely.
    func idsMissingFilenames(limit: Int) throws -> [String] {
        guard let database else { return [] }
        var ids: [String] = []
        try database.query(
            "SELECT id FROM asset WHERE filename IS NULL ORDER BY created DESC, id LIMIT ?",
            [.integer(Int64(limit))]
        ) { row in
            if let id = row.string(0) { ids.append(id) }
        }
        return ids
    }

    // MARK: - Reads

    func page(criteria: PhotosFilterCriteria,
              mediaType: PHAssetMediaType,
              page: Int,
              pageSize: Int,
              convertedIdentifiers: [String]?) throws -> (assets: [PhotosIndexedAsset], total: Int) {
        guard let database else { return ([], 0) }
        let query = PhotosIndexQueryBuilder.build(criteria: criteria,
                                                  mediaType: mediaType,
                                                  convertedIdentifiers: convertedIdentifiers)

        let total = Int(try database.queryInt(query.countSQL, query.whereParameters) ?? 0)

        var assets: [PhotosIndexedAsset] = []
        assets.reserveCapacity(pageSize)
        try database.query(query.pageSQL, query.pageParameters(limit: pageSize, offset: page * pageSize)) { row in
            guard let id = row.string(0) else { return }
            assets.append(
                PhotosIndexedAsset(id: id,
                                   filename: row.string(1),
                                   width: row.int(2),
                                   height: row.int(3),
                                   duration: row.double(4))
            )
        }
        return (assets, total)
    }

    /// Albums holding at least one asset of `mediaType`, with counts.
    ///
    /// This is what the N+1 PhotoKit fetch the album picker used to do becomes
    /// once membership is indexed: one grouped query.
    func albums(mediaType: PHAssetMediaType) throws -> [PhotoAlbum] {
        guard let database else { return [] }
        var albums: [PhotoAlbum] = []
        // The correlated subquery picks the album's first asset *of this media
        // type* so a chip in the Videos filter shows a video, not whatever
        // happens to sit at position 0. Both placeholders are the same value;
        // the one in the SELECT list binds first because it comes first in the
        // statement text.
        try database.query(
            """
            SELECT album.id, album.title, album.is_smart, COUNT(*) AS n,
                   (SELECT inner_membership.asset_id
                      FROM album_asset AS inner_membership
                      JOIN asset AS inner_asset
                        ON inner_asset.id = inner_membership.asset_id AND inner_asset.kind = ?
                     WHERE inner_membership.album_id = album.id
                     ORDER BY inner_membership.position
                     LIMIT 1) AS key_asset
            FROM album
            JOIN album_asset ON album_asset.album_id = album.id
            JOIN asset ON asset.id = album_asset.asset_id AND asset.kind = ?
            GROUP BY album.id
            ORDER BY album.is_smart, album.sort_order
            """,
            [.integer(Int64(mediaType.rawValue)), .integer(Int64(mediaType.rawValue))]
        ) { row in
            guard let id = row.string(0), let title = row.string(1) else { return }
            albums.append(PhotoAlbum(id: id,
                                     name: title,
                                     isSmart: row.bool(2),
                                     count: row.int(3),
                                     keyAssetId: row.string(4)))
        }
        return albums
    }

    /// People with at least one asset of `mediaType`, most-photographed first.
    func people(mediaType: PHAssetMediaType) throws -> [IndexedPerson] {
        guard let database else { return [] }
        var people: [IndexedPerson] = []
        try database.query(
            """
            SELECT person.id, person.name, person.key_asset_id, COUNT(*) AS n
            FROM person
            JOIN person_asset ON person_asset.person_id = person.id
            JOIN asset ON asset.id = person_asset.asset_id AND asset.kind = ?
            GROUP BY person.id
            ORDER BY n DESC, person.sort_order
            """,
            [.integer(Int64(mediaType.rawValue))]
        ) { row in
            guard let id = row.string(0), let name = row.string(1) else { return }
            people.append(IndexedPerson(id: id, name: name, keyAssetId: row.string(2), count: row.int(3)))
        }
        return people
    }

    /// Total rows, and how many still lack a filename. Drives indexing progress.
    func progressCounts() throws -> (total: Int, unnamed: Int) {
        guard let database else { return (0, 0) }
        let total = Int(try database.queryInt("SELECT COUNT(*) FROM asset") ?? 0)
        let unnamed = Int(try database.queryInt("SELECT COUNT(*) FROM asset WHERE filename IS NULL") ?? 0)
        return (total, unnamed)
    }
}
