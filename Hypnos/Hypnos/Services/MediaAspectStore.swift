/*
 Hypnos - Media Aspect Store

 Remembers the true aspect ratio of images whose source did not report
 dimensions (a Nextcloud library that was bulk-scanned rather than uploaded,
 local files), learned the first time their thumbnail loads.

 The justified gallery lays out from metadata alone. Without a stored ratio
 an item is laid out provisionally at 1:1 and its row reflows once when the
 thumbnail arrives; with one it is right from the first frame on every later
 launch, so each item reflows at most once per install.

 Persisted as one small JSON file (identity -> ratio). It is re-derivable,
 so it lives in Application Support excluded from backup.
 */

import DebugTrace
import Foundation
import Observation

@MainActor
@Observable
final class MediaAspectStore {
    static let shared = MediaAspectStore()

    /// Bumped (debounced) when new ratios were learned, so the grid knows to
    /// lay out again. One bump per burst of arrivals rather than one per
    /// thumbnail keeps the reflow to a single pass while scrolling.
    private(set) var revision = 0

    @ObservationIgnored private var ratios: [String: Float] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var pendingRevision: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private init() {}

    /// Debounce before the grid re-lays-out after new ratios arrive.
    private static let revisionDelay: Duration = .milliseconds(400)
    private static let saveDelay: Duration = .seconds(3)

    func ratio(for identity: String) -> CGFloat? {
        loadIfNeeded()
        return ratios[identity].map { CGFloat($0) }
    }

    /// Records a ratio measured from a loaded thumbnail. Ignores a ratio that
    /// matches what is already known, so re-loading a thumbnail is free.
    func record(ratio: CGFloat, for identity: String) {
        loadIfNeeded()
        guard ratio.isFinite, ratio > 0 else { return }
        let value = Float(ratio)
        if let existing = ratios[identity], abs(existing - value) / existing < 0.01 { return }
        ratios[identity] = value

        pendingRevision?.cancel()
        pendingRevision = Task { [weak self] in
            try? await Task.sleep(for: Self.revisionDelay)
            guard !Task.isCancelled else { return }
            self?.revision += 1
        }
        scheduleSave()
    }

    func clear() {
        ratios.removeAll()
        loaded = true
        try? FileManager.default.removeItem(at: Self.fileURL)
        revision += 1
    }

    // MARK: - Persistence

    private nonisolated static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MediaAspectRatios.json")
    }()

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: Float].self, from: data) else { return }
        ratios = decoded
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.ratios
            await Task.detached(priority: .utility) { Self.write(snapshot) }.value
        }
    }

    private nonisolated static func write(_ snapshot: [String: Float]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        var url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            AppLogger.diskCache.error("Failed to save aspect ratios: \(error.logCode, privacy: .public)")
        }
    }
}
