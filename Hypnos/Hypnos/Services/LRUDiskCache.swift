/*
 Hypnos - LRU Disk Cache Engine

 Shared engine behind every on-disk cache (images, videos, thumbnails,
 auto-enhance, background removal, GIF conversions, thumbnail dioramas). Each
 cache keeps its own key scheme and file formats; the engine owns the parts
 they used to copy-paste:

 - Directory setup: creation, backup exclusion, format versioning
   (DiskCacheVersion).
 - Size accounting: an incrementally-maintained byte counter updated on each
   write/removal, so routine saves never enumerate the directory. The counter
   is seeded by one enumeration on first use and fully resynced whenever an
   eviction pass runs (which must enumerate anyway), so drift can't accumulate.
 - LRU eviction against CacheBudget's device-capacity-derived caps: oldest
   modification date first (reads touch mtime), trimming to 80% of the cap.
   Hooks let a cache delete companion files alongside an entry (video
   metadata), prioritize evicting entries that lost their reason to exist
   (orphaned enhance renders), and account for bytes a pending download has
   committed but not yet written.

 Thread-safe via an internal lock — usable from actors and detached tasks
 alike. Eviction runs inline under the lock; it's rare (only when over cap)
 and bounded by one directory enumeration.
 */

import DebugTrace
import Foundation

final class LRUDiskCache: @unchecked Sendable {
    let directory: URL
    private let domain: CacheBudget.Domain
    private let log: DebugLogger
    private let fileManager = FileManager.default
    private let lock = NSLock()

    /// Files deleted alongside an evicted entry (e.g. sidecar metadata).
    /// Their sizes are not counted by this engine (companion directories are
    /// tracked by the owning cache if needed).
    var companionURLs: (@Sendable (URL) -> [URL])?
    /// Entries reporting true are evicted before LRU order — e.g. derived
    /// renders whose source entry is gone.
    var evictsFirst: (@Sendable (URL) -> Bool)?
    /// Bytes committed but not yet on disk (in-progress downloads), counted
    /// against the cap so a large download starts making room immediately.
    var pendingBytes: (@Sendable () -> Int64)?

    /// Incrementally tracked directory size; nil until first computed.
    private var trackedSize: Int64?

    init(directory: URL, domain: CacheBudget.Domain, log: DebugLogger, formatVersion: Int? = nil) {
        self.directory = directory
        self.domain = domain
        self.log = log
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let formatVersion {
            DiskCacheVersion.enforce(formatVersion, at: directory, fileManager: fileManager)
        }
        Self.excludeFromBackup(directory)
    }

    static func excludeFromBackup(_ directory: URL) {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(resourceValues)
    }

    // MARK: - Size accounting

    /// Size of a file on disk right now (0 if absent). Callers grab this for
    /// the existing file before overwriting, then pass it to `noteWrite`.
    func sizeOnDisk(of url: URL) -> Int64 {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Current tracked size, seeding the counter with one enumeration on
    /// first use.
    func currentSize() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return currentSizeLocked()
    }

    private func currentSizeLocked() -> Int64 {
        if let trackedSize { return trackedSize }
        let size = enumeratedSize()
        trackedSize = size
        return size
    }

    /// Record a completed write and evict if the cache is now over budget.
    /// `replacedSize` is what the same path held before the write (0 for new).
    func noteWrite(at url: URL, replacing replacedSize: Int64 = 0) {
        let newSize = sizeOnDisk(of: url)
        lock.lock()
        trackedSize = max(0, currentSizeLocked() + newSize - replacedSize)
        evictIfNeededLocked()
        lock.unlock()
    }

    /// Record an out-of-band removal (the owning cache deleted files itself).
    func noteRemoval(bytes: Int64) {
        lock.lock()
        trackedSize = max(0, currentSizeLocked() - bytes)
        lock.unlock()
    }

    /// Stamp an entry's access time for LRU ordering (call on reads).
    func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: - Eviction

    /// Re-check the budget and evict if needed — for external triggers
    /// (preset change, low-disk response), not per-write use.
    func evictIfNeeded() {
        lock.lock()
        _ = currentSizeLocked()
        evictIfNeededLocked()
        lock.unlock()
    }

    private func evictIfNeededLocked() {
        let pending = pendingBytes?() ?? 0
        let committed = (trackedSize ?? 0) + pending
        guard committed > CacheBudget.cap(for: domain, currentSize: committed) else { return }

        // Over budget: enumerate once (also resyncing the counter — eviction
        // is the periodic drift correction), then trim oldest-first to 80%.
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, date: Date, evictFirst: Bool)] = []
        var actualSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { continue }
            let date = values.contentModificationDate ?? .distantPast
            files.append((fileURL, Int64(size), date, evictsFirst?(fileURL) ?? false))
            actualSize += Int64(size)
        }
        trackedSize = actualSize

        let total = actualSize + pending
        let cap = CacheBudget.cap(for: domain, currentSize: total)
        guard total > cap else { return }

        log.notice("\(self.domain.label, privacy: .public) cache \(total / 1024 / 1024, privacy: .public) MB over \(cap / 1024 / 1024, privacy: .public) MB cap, evicting…")

        files.sort {
            if $0.evictFirst != $1.evictFirst { return $0.evictFirst }
            return $0.date < $1.date
        }

        let target = Int64(Double(cap) * 0.8)
        var freed: Int64 = 0
        let toFree = total - target
        for file in files {
            guard freed < toFree else { break }
            do {
                try fileManager.removeItem(at: file.url)
                freed += file.size
                for companion in companionURLs?(file.url) ?? [] {
                    try? fileManager.removeItem(at: companion)
                }
            } catch {
                log.warning("Failed to evict cache file: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
        trackedSize = max(0, actualSize - freed)
        log.info("\(self.domain.label, privacy: .public) cache freed \(freed / 1024 / 1024, privacy: .public) MB")
    }

    // MARK: - Maintenance

    /// Remove everything and recreate the directory.
    func clear() {
        lock.lock()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        trackedSize = 0
        lock.unlock()
        log.notice("\(self.domain.label, privacy: .public) cache cleared")
    }

    func stats() -> (fileCount: Int, totalSize: Int64) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var count = 0
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            count += 1
            total += Int64(size)
        }
        return (count, total)
    }

    private func enumeratedSize() -> Int64 {
        stats().totalSize
    }

    // MARK: - Shared key + origin-link helpers

    /// SHA-256 hex of a key string — the filename scheme every cache uses.
    static func sha256Key(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Derived-render caches (auto-enhance, background removal) tag each entry
    /// with the disk-image-cache key of its source via an extended attribute,
    /// so eviction can prioritize entries whose original has left the image
    /// cache. Old entries without the tag just follow normal LRU order.
    private static let originKeyXattr = "com.hypnos.origin-key"

    static func setOriginKey(_ key: String, for url: URL) {
        key.utf8CString.withUnsafeBufferPointer { buf in
            _ = setxattr(url.path, originKeyXattr, buf.baseAddress, buf.count - 1, 0, 0)
        }
    }

    static func originKey(of url: URL) -> String? {
        let length = getxattr(url.path, originKeyXattr, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buf in
            getxattr(url.path, originKeyXattr, buf.baseAddress, length, 0, 0)
        }
        guard read == length else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

import CommonCrypto
