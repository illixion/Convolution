/*
 Hypnos - Photos Library Indexer

 Builds and maintains the local mirror of the photo library.

 The whole design turns on one cost: **filenames are the only expensive part.**
 Everything else about an asset — dates, dimensions, duration, subtypes,
 favourite, album membership — is available from `PHAsset` with no round trip, so
 the whole library can be swept in a second or two. A filename is only reachable
 through `PHAssetResource.assetResources(for:)`, which is an XPC call to
 photolibraryd per asset, with no batch form in the public API. At roughly a
 millisecond each that is a minute of work on a large library.

 So indexing is two passes. The cheap one runs to completion up front and the
 gallery is usable the moment it lands. Filenames are backfilled afterwards at
 utility priority, resumable, and search simply covers more of the library as it
 progresses. Blocking the gallery on the slow pass would have traded a working
 app for a progress bar.

 Incremental sync uses `PHPersistentChangeToken`, which is the API built for
 exactly this: persist a token, ask what changed since, get inserted / updated /
 deleted identifiers directly. No enumerate-and-diff. When the token outlives
 Photos' change history it throws `persistentChangeTokenExpired`, and the only
 answer to that is a full rebuild.
 */

import DebugTrace
import Foundation
import Photos

@MainActor
@Observable
final class PhotosLibraryIndexer {
    static let shared = PhotosLibraryIndexer()

    enum Phase: Equatable {
        case idle
        /// The cheap pass, which the gallery waits on.
        case scanning(done: Int, total: Int)
        /// The filename backfill, which it does not.
        case naming(done: Int, total: Int)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Whether the index can answer queries. False only before the first cheap
    /// pass completes, or after a failure.
    var isQueryable: Bool {
        switch phase {
        case .ready, .naming: return true
        case .idle, .scanning, .failed: return false
        }
    }

    /// Human-readable progress for the gallery's placeholder, or nil when there
    /// is nothing to report.
    var progressDescription: String? {
        switch phase {
        case .scanning(let done, let total):
            return total > 0 ? "Indexing your library… \(done) of \(total)" : "Indexing your library…"
        case .naming(let done, let total):
            return "Reading file names… \(done) of \(total)"
        case .failed(let message):
            return message
        case .idle, .ready:
            return nil
        }
    }

    /// Why the gallery has nothing to show, when the reason is the index rather
    /// than the library. Nil once there is content to draw.
    ///
    /// The filename pass is deliberately absent: it does not block content, only
    /// search, and the Filters tab says so where that matters.
    var blockingMessage: String? {
        switch phase {
        case .scanning(let done, let total):
            return total > 0
                ? "Reading your photo library — \(done) of \(total)."
                : "Reading your photo library."
        case .failed(let message):
            return "\(message) Try Rebuild Library Index in the Filters tab."
        case .idle, .naming, .ready:
            return nil
        }
    }

    /// Bumped whenever indexed content changes, so views can react.
    private(set) var generation: Int = 0

    /// Called after each change to indexed content. Set by `AppModel`, which
    /// reloads the galleries — the grid that loaded before the first scan
    /// finished is showing an empty table and has no other way to learn better.
    var onIndexUpdated: (@MainActor () -> Void)?

    private let store = PhotosIndexStore.shared
    private var observer: LibraryObserver?
    private var runTask: Task<Void, Never>?
    private var namingTask: Task<Void, Never>?
    private var coalesceTask: Task<Void, Never>?
    /// The library changed while a sync was already running.
    private var resyncPending = false

    /// How long to wait for a burst of library notifications to settle.
    private static let coalesceInterval: Double = 2

    /// Assets per store transaction during the cheap pass. Large enough that the
    /// per-transaction cost disappears, small enough that progress moves.
    ///
    /// `nonisolated` because the passes that read these run off the main actor,
    /// which is the whole point of those passes being nonisolated.
    private nonisolated static let scanBatchSize = 500
    /// Assets per filename batch. Each one is that many XPC calls, so this is
    /// also the granularity at which the pass can be interrupted.
    private nonisolated static let nameBatchSize = 200

    private init() {}

    // MARK: - Entry points

    /// Brings the index up to date, building it first if necessary.
    ///
    /// Safe to call on every launch and whenever authorization changes; the work
    /// is coalesced so overlapping calls do not double-index.
    func start() {
        guard runTask == nil else {
            // A change arriving mid-run would otherwise be dropped: this run
            // already read its token before that change existed.
            resyncPending = true
            return
        }
        runTask = Task { [weak self] in
            await self?.run(forceRebuild: false)
            self?.finishRun()
        }
    }

    /// Discards the index and rebuilds it. The manual escape hatch, for when
    /// what is on screen is not trusted.
    func rebuild() {
        runTask?.cancel()
        namingTask?.cancel()
        runTask = Task { [weak self] in
            await self?.run(forceRebuild: true)
            self?.finishRun()
        }
    }

    private func finishRun() {
        runTask = nil
        guard resyncPending else { return }
        resyncPending = false
        start()
    }

    /// Called when photo authorization is revoked. Keeping a mirror of a library
    /// we may no longer read is not defensible, so it goes.
    func handleAccessRevoked() {
        runTask?.cancel()
        namingTask?.cancel()
        runTask = nil
        namingTask = nil
        phase = .idle
        unregisterObserver()
        Task { try? await store.destroy() }
    }

    // MARK: - Run

    private func run(forceRebuild: Bool) async {
        guard PhotosAuthorization.isReadable else {
            phase = .idle
            return
        }

        do {
            var needsFullBuild = try await store.prepare() || forceRebuild
            if forceRebuild {
                try await store.reset()
            }

            // A `.limited` index is a subset of the library. Once the user
            // widens the grant it must not go on posing as complete.
            let scope = Self.currentScope
            let storedScope = try await store.metaString(PhotosIndexSchema.MetaKey.authScope)
            if let storedScope, storedScope != scope {
                AppLogger.photosIndex.info(
                    "Authorization \(storedScope, privacy: .public) → \(scope, privacy: .public), rebuilding"
                )
                try await store.reset()
                needsFullBuild = true
            }

            var contentChanged = needsFullBuild
            if !needsFullBuild {
                switch try await applyIncrementalChanges() {
                case .rebuildNeeded:
                    needsFullBuild = true
                    contentChanged = true
                case .applied(let changed):
                    contentChanged = changed
                }
            }

            if needsFullBuild {
                try await fullBuild(scope: scope)
            }

            registerObserver()
            phase = .ready
            // Only when something actually moved. PhotoKit posts change
            // notifications constantly on an iCloud library — thumbnail
            // generation, metadata sync, memories being recomputed — and
            // bumping unconditionally turned every one of them into a gallery
            // reload, which is what the periodic flicker was.
            if contentChanged {
                bumpGeneration()
            }
            startNamingPass()
        } catch is CancellationError {
            // A rebuild superseded this run; the new one owns the phase.
        } catch {
            AppLogger.photosIndex.error("Index failed: \(String(describing: error), privacy: .public)")
            phase = .failed("Couldn't index your photo library.")
        }
    }

    private func bumpGeneration() {
        generation += 1
        onIndexUpdated?()
    }

    private static var currentScope: String {
        PhotosAuthorization.status == .limited ? "limited" : "authorized"
    }

    // MARK: - Full build

    private func fullBuild(scope: String) async throws {
        AppLogger.photosIndex.info("Full index build starting")
        let started = Date()

        // Taken *before* the sweep, so anything that changes while it runs is
        // caught by the next incremental pass rather than falling in the gap.
        let token = PHPhotoLibrary.shared().currentChangeToken

        phase = .scanning(done: 0, total: 0)
        try await scanAssets { [weak self] done, total in
            self?.phase = .scanning(done: done, total: total)
        }
        try await scanAlbums()

        if let tokenData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            try await store.setMeta(PhotosIndexSchema.MetaKey.changeToken, data: tokenData)
        }
        try await store.setMeta(PhotosIndexSchema.MetaKey.authScope, string: scope)
        try await store.setMeta(PhotosIndexSchema.MetaKey.assetPassComplete, string: "1")

        let counts = try await store.progressCounts()
        AppLogger.photosIndex.info(
            "Full build indexed \(counts.total, privacy: .public) assets in \(Int(-started.timeIntervalSinceNow * 1000), privacy: .public)ms"
        )
    }

    /// Sweeps every image and video into the index.
    ///
    /// `nonisolated` so the enumeration and the store writes run off the main
    /// actor — `PHFetchResult` materializes assets in batches as it is walked,
    /// and a library-sized walk on the main thread would stall the compositor.
    private nonisolated func scanAssets(progress: @escaping @MainActor (Int, Int) -> Void) async throws {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(with: options)
        let total = assets.count
        await progress(0, total)

        var batch: [PhotosIndexAssetRow] = []
        batch.reserveCapacity(Self.scanBatchSize)
        var done = 0

        for index in 0..<total {
            try Task.checkCancellation()
            batch.append(PhotosIndexAssetRow(asset: assets.object(at: index)))
            if batch.count >= Self.scanBatchSize {
                try await store.upsertAssets(batch)
                done += batch.count
                batch.removeAll(keepingCapacity: true)
                await progress(done, total)
            }
        }
        if !batch.isEmpty {
            try await store.upsertAssets(batch)
            done += batch.count
            await progress(done, total)
        }
    }

    /// Rebuilds the album list and all membership.
    ///
    /// Fetched with nil options deliberately: that is the only way PhotoKit
    /// surrenders an album's *manual* order, which becomes the stored position
    /// and so the "Album Order" sort.
    private nonisolated func scanAlbums() async throws {
        var rows: [PhotosIndexAlbumRow] = []
        for (order, collection) in PhotosAlbumCatalog.collections().enumerated() {
            try Task.checkCancellation()
            var assetIds: [String] = []
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assetIds.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in assetIds.append(asset.localIdentifier) }
            guard !assetIds.isEmpty else { continue }
            rows.append(
                PhotosIndexAlbumRow(id: collection.localIdentifier,
                                    title: collection.localizedTitle ?? "Album",
                                    isSmart: collection.assetCollectionType == .smartAlbum,
                                    sortOrder: order,
                                    assetIds: assetIds)
            )
        }
        try await store.replaceAlbums(rows)
    }

    // MARK: - Incremental sync

    enum SyncOutcome {
        /// The index cannot be brought up to date incrementally — no token, an
        /// unreadable one, or one older than the change history Photos holds.
        case rebuildNeeded
        /// Applied. `contentChanged` is whether the *set* of assets moved, which
        /// is a different question from whether anything changed at all.
        case applied(contentChanged: Bool)
    }

    /// Applies everything that changed since the stored token.
    private nonisolated func applyIncrementalChanges() async throws -> SyncOutcome {
        guard let tokenData = try await store.metaData(PhotosIndexSchema.MetaKey.changeToken),
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self,
                                                                  from: tokenData) else {
            return .rebuildNeeded
        }

        let library = PHPhotoLibrary.shared()
        let changes: PHPersistentChangeFetchResult
        do {
            changes = try library.fetchPersistentChanges(since: token)
        } catch let error as NSError {
            if error.domain == PHPhotosErrorDomain,
               error.code == PHPhotosError.persistentChangeTokenExpired.rawValue {
                AppLogger.photosIndex.info("Change token expired, rebuilding")
                return .rebuildNeeded
            }
            throw error
        }

        var inserted = Set<String>()
        var updated = Set<String>()
        var deleted = Set<String>()
        var collectionsChanged = false

        for change in changes {
            try Task.checkCancellation()
            if let details = try? change.changeDetails(for: .asset) {
                inserted.formUnion(details.insertedLocalIdentifiers)
                updated.formUnion(details.updatedLocalIdentifiers)
                deleted.formUnion(details.deletedLocalIdentifiers)
            }
            if let details = try? change.changeDetails(for: .assetCollection),
               !details.insertedLocalIdentifiers.isEmpty
                || !details.updatedLocalIdentifiers.isEmpty
                || !details.deletedLocalIdentifiers.isEmpty {
                collectionsChanged = true
            }
        }

        // A deletion and a re-insertion of the same identifier cannot both be
        // true; the live state wins, so deletes are applied first and then only
        // identifiers that still resolve are upserted.
        if !deleted.isEmpty {
            try await store.deleteAssets(ids: Array(deleted))
        }

        let touched = inserted.union(updated)
        if !touched.isEmpty {
            var rows: [PhotosIndexAssetRow] = []
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(touched), options: nil)
            assets.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                rows.append(PhotosIndexAssetRow(asset: asset))
            }
            try await store.upsertAssets(rows)

            // Identifiers that reported a change but no longer resolve are gone
            // in a way the delete set did not mention. Drop them.
            let resolved = Set(rows.map(\.id))
            let vanished = touched.subtracting(resolved)
            if !vanished.isEmpty {
                try await store.deleteAssets(ids: Array(vanished))
            }
        }

        // Album membership changes when assets are added to or removed from an
        // album, which surfaces as an assetCollection change — but so does a
        // rename, and the details do not say which. Re-scanning is cheap next to
        // the asset table, so it is not worth guessing.
        if collectionsChanged || !touched.isEmpty || !deleted.isEmpty {
            try await scanAlbums()
        }

        let newToken = library.currentChangeToken
        if let newTokenData = try? NSKeyedArchiver.archivedData(withRootObject: newToken,
                                                               requiringSecureCoding: true) {
            try await store.setMeta(PhotosIndexSchema.MetaKey.changeToken, data: newTokenData)
        }

        if !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty {
            AppLogger.photosIndex.info(
                "Synced +\(inserted.count, privacy: .public) ~\(updated.count, privacy: .public) -\(deleted.count, privacy: .public)"
            )
        }

        // Inserts and deletes change which assets exist and so what the grid
        // should show. A pure update does not: the row is already rewritten, and
        // any of the metadata it touched (favourite, modification date) will be
        // picked up by the next reload the user's own actions cause. Treating
        // updates as content changes meant iCloud's steady trickle of metadata
        // writes reloaded the grid under the user's hands.
        return .applied(contentChanged: !inserted.isEmpty || !deleted.isEmpty)
    }

    // MARK: - Filename backfill

    private func startNamingPass() {
        guard namingTask == nil else { return }
        namingTask = Task(priority: .utility) { [weak self] in
            await self?.runNamingPass()
            self?.namingTask = nil
        }
    }

    private func runNamingPass() async {
        do {
            let counts = try await store.progressCounts()
            guard counts.unnamed > 0 else {
                phase = .ready
                return
            }
            phase = .naming(done: counts.total - counts.unnamed, total: counts.total)
            try await backfillFilenames { [weak self] done, total in
                self?.phase = .naming(done: done, total: total)
            }
            phase = .ready
            bumpGeneration()
            AppLogger.photosIndex.info("Filename pass complete")
        } catch is CancellationError {
            // Resumable by construction: the pass asks the store for whatever is
            // still unnamed, so the next run picks up exactly where this stopped.
        } catch {
            AppLogger.photosIndex.error("Filename pass failed: \(String(describing: error), privacy: .public)")
            // Not a failure of the index — search is incomplete, everything else
            // works — so the phase stays ready rather than reporting an error.
            phase = .ready
        }
    }

    private nonisolated func backfillFilenames(progress: @escaping @MainActor (Int, Int) -> Void) async throws {
        let counts = try await store.progressCounts()
        let total = counts.total
        var done = total - counts.unnamed

        while true {
            try Task.checkCancellation()
            let ids = try await store.idsMissingFilenames(limit: Self.nameBatchSize)
            guard !ids.isEmpty else { return }

            var named: [String: String] = [:]
            named.reserveCapacity(ids.count)
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            assets.enumerateObjects { asset, _, _ in
                named[asset.localIdentifier] = asset.originalFilename ?? ""
            }
            // Anything that did not resolve, or resolved without surrendering a
            // name, is recorded as empty. Leaving it null would hand the same
            // identifiers back on the next iteration, forever.
            for id in ids where named[id] == nil {
                named[id] = ""
            }

            try await store.setFilenames(named)
            done += ids.count
            await progress(min(done, total), total)
            await Task.yield()
        }
    }

    // MARK: - Change observation

    /// Forwards `PHPhotoLibraryChangeObserver` without dragging NSObject into
    /// the `@Observable` model — the same split `WebPageWindowModel` uses.
    ///
    /// The callback deliberately captures nothing: it reaches the singleton
    /// directly, so there is no non-Sendable capture to explain to the compiler.
    private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
        func photoLibraryDidChange(_ changeInstance: PHChange) {
            Task { @MainActor in
                PhotosLibraryIndexer.shared.libraryDidChange()
            }
        }
    }

    private func registerObserver() {
        guard observer == nil else { return }
        let observer = LibraryObserver()
        self.observer = observer
        PHPhotoLibrary.shared().register(observer)
    }

    private func unregisterObserver() {
        guard let observer else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
        self.observer = nil
    }

    /// A photo taken or edited while the app is open. Re-enters the same
    /// token-driven sync the launch path uses.
    ///
    /// Coalesced, because PhotoKit does not post one notification per user
    /// action — a single import or an iCloud catch-up arrives as a burst. Each
    /// one is a full token fetch, so answering them individually is wasted work
    /// even now that a no-op sync no longer reloads anything.
    private func libraryDidChange() {
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.coalesceInterval))
            guard !Task.isCancelled else { return }
            self?.coalesceTask = nil
            self?.start()
        }
    }
}
