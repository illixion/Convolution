/*
 Hypnos - Disk Cache Versioning

 Stale-cache invalidation for the persistent on-disk asset caches.

 Each cache stores derived assets keyed by a SHA256 of the source URL. The key
 carries no information about the *algorithm* or *format* that produced the
 entry, so when that pipeline changes (e.g. background removal stopped cropping
 transparent margins — see `BackgroundRemover`, commit "Preserve source frame
 size in background removal output"), entries written by the old code keep
 being served verbatim and reintroduce the very bug the change fixed.

 The fix is a version stamp per cache directory. On launch each cache calls
 `enforce(_:at:)` with its current format version; if the stored stamp is
 missing or older, the directory's contents are purged and the stamp rewritten,
 so the next access regenerates from the current pipeline.

 The stamp lives in UserDefaults (keyed by the directory name), NOT in a marker
 file inside the cache directory — a marker file would be visible to each
 cache's size-accounting and LRU eviction passes, and could be evicted, which
 would silently trigger a full wipe on the next launch.
 */

import DebugTrace
import Foundation

enum DiskCacheVersion {
    /// Bump a cache's version (at its `enforce` call site) whenever the format
    /// or generating algorithm of its stored assets changes, so entries written
    /// by an older app build are purged instead of served stale.
    ///
    /// History:
    ///  - v1: initial versioning. The first launch after this shipped purges all
    ///        pre-versioning caches once, clearing background-removal entries
    ///        cropped by the pre-`f748109` pipeline among others.

    private static let defaultsKeyPrefix = "DiskCacheVersion."

    /// Ensure `directory` holds assets at `version`. If the stored version is
    /// absent (unversioned cache) or different, every file in the directory is
    /// removed and the stored version updated. Call once from the owning cache's
    /// `init`, after the directory has been created and before serving entries.
    ///
    /// Cheap: a single UserDefaults read in the common (matching) case; the
    /// directory enumeration only runs on an actual version change.
    static func enforce(_ version: Int, at directory: URL, fileManager: FileManager = .default) {
        let key = defaultsKeyPrefix + directory.lastPathComponent
        let stored = UserDefaults.standard.object(forKey: key) as? Int
        guard stored != version else { return }

        if let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in contents {
                try? fileManager.removeItem(at: fileURL)
            }
            AppLogger.diskCache.notice(
                "Cache \(directory.lastPathComponent, privacy: .public) version \(stored ?? -1, privacy: .public) → \(version, privacy: .public): purged \(contents.count, privacy: .public) stale entr\(contents.count == 1 ? "y" : "ies", privacy: .public)"
            )
        }

        UserDefaults.standard.set(version, forKey: key)
    }
}
