/*
 Hypnos - Library feature: playback routing + progress-sync glue

 Turns a `LibraryItem` into whichever player actually plays it
 (`PlaybackRoute`, resolved by `JellyfinLibrary.playbackRoute(for:)`) and
 builds the one adapter value the generic-player route needs: a synthetic
 `GalleryVideo` carrying Jellyfin's stream URL, following the exact same
 shape `IncomingURLHandler.openStreamVideo` already uses for an arbitrary
 remote URL with no Stash backing (`identity`/`thumbnailURL`/`streamURL`/
 `title`, nothing else) — so `VideoWindowView`/`TVVideoPlayerView` need no
 Jellyfin-specific change to play one.

 Progress reporting (`reportGenericPlaybackProgress`) is a small, identity-
 gated bolt-on: it never touches `VideoWindowModel`'s internals, it only
 reads the plain `currentTime`/`duration`/`isPaused` it already publishes.
 Being gated on `isJellyfinVideo(_:)` means it is a no-op for every
 Stash/Nextcloud/Photos/Local video already flowing through the same window.
 */

import Foundation

@MainActor
enum LibraryPlaybackCoordinator {
    private static let identityPrefix = "jellyfin:"

    static func jellyfinItemId(fromVideoIdentity identity: String) -> String? {
        guard identity.hasPrefix(identityPrefix) else { return nil }
        return String(identity.dropFirst(identityPrefix.count))
    }

    /// Builds the generic-player adapter for a Jellyfin item that isn't
    /// routed to the Atmos `FilmPlayer`. Poster art as the placeholder
    /// thumbnail (there's no separate "loading" art the way a Stash gallery
    /// grid has one on hand already).
    static func makeGalleryVideo(item: LibraryItem, plan: GenericPlaybackPlan, library: JellyfinLibrary) -> GalleryVideo {
        let thumbnail = library.imageURL(item: item, kind: .primary, size: .thumbnail)
            ?? library.imageURL(item: item, kind: .thumb, size: .thumbnail)
            ?? plan.streamURL
        return GalleryVideo(
            identity: identityPrefix + item.id,
            thumbnailURL: thumbnail,
            streamURL: plan.streamURL,
            title: item.title,
            duration: item.runtimeSeconds
        )
    }

    /// Reports playback start once positive progress is observed, then
    /// polls every `interval` seconds while the window stays open, and
    /// reports a stop with the last known position when the task is
    /// cancelled (the window closed/the view disappeared) — the same
    /// start → progress → stopped sequence `scripts/dev-jellyfin.sh`'s
    /// `report_partial_progress` proved end to end in Phase 1.
    ///
    /// Call as a `.task(id: video.identity) { await ... }` from the generic
    /// player's window view; cancellation on disappear/id-change is what
    /// drives the final stop report.
    static func reportGenericPlaybackProgress(
        video: GalleryVideo,
        currentTime: @escaping @MainActor () -> Double,
        isPaused: @escaping @MainActor () -> Bool,
        interval: Duration = .seconds(10)
    ) async {
        guard let itemId = jellyfinItemId(fromVideoIdentity: video.identity),
              let library = LibraryService.current()
        else { return }

        var started = false
        var lastPosition: Double = 0
        defer {
            if started {
                Task { await library.reportPlaybackStopped(itemId: itemId, positionSeconds: lastPosition) }
            }
        }

        while !Task.isCancelled {
            let position = currentTime()
            let paused = isPaused()
            if !started, position > 0 {
                started = true
                await library.reportPlaybackStarted(itemId: itemId, positionSeconds: position)
            } else if started {
                await library.reportPlaybackProgress(itemId: itemId, positionSeconds: position, isPaused: paused)
            }
            lastPosition = position
            try? await Task.sleep(for: interval)
        }
    }
}

/// Push-driven counterpart to `reportGenericPlaybackProgress`, for a player
/// with no polling hook of its own — `TVVideoPlayerView`'s bare
/// `AVPlayerViewController` only offers a periodic time-observer callback,
/// not an observable `currentTime`/`isPaused` a `.task` loop could read.
/// Same start → progress → stopped sequence; the caller feeds it from that
/// callback and calls `finish()` when the player is dismissed.
@MainActor
final class GenericProgressReporter {
    private let itemId: String
    private let library: JellyfinLibrary
    private var started = false
    private var lastPosition: Double = 0

    /// nil when `video` isn't Jellyfin-sourced or no server is configured —
    /// callers should just skip wiring `onProgress`/`finish()` in that case.
    init?(video: GalleryVideo) {
        guard let itemId = LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity),
              let library = LibraryService.current()
        else { return nil }
        self.itemId = itemId
        self.library = library
    }

    func report(currentTime: Double, isPaused: Bool) {
        lastPosition = currentTime
        Task {
            if !started, currentTime > 0 {
                started = true
                await library.reportPlaybackStarted(itemId: itemId, positionSeconds: currentTime)
            } else if started {
                await library.reportPlaybackProgress(itemId: itemId, positionSeconds: currentTime, isPaused: isPaused)
            }
        }
    }

    func finish() {
        guard started else { return }
        started = false
        Task { await library.reportPlaybackStopped(itemId: itemId, positionSeconds: lastPosition) }
    }
}
