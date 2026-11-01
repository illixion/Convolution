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

import DebugTrace
import Foundation

@MainActor
enum LibraryPlaybackCoordinator {
    private static let identityPrefix = "jellyfin:"

    /// The video identity a Jellyfin item plays under (depth caches and
    /// window state are keyed by it).
    static func videoIdentity(jellyfinItemId itemId: String) -> String {
        identityPrefix + itemId
    }

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
            identity: videoIdentity(jellyfinItemId: item.id),
            thumbnailURL: thumbnail,
            streamURL: plan.streamURL,
            transcodeStreamURL: plan.transcodeURL,
            title: item.title,
            duration: item.runtimeSeconds,
            // A 3D film opens in live 3D, like a Stash video tagged SBS.
            isStereoscopic: item.stereoFormat != nil,
            stereoscopicFormat: item.stereoFormat
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
    ///
    /// `currentTime` answers nil when the player no longer shows `video`;
    /// the stop then reports the last position seen for it.
    static func reportGenericPlaybackProgress(
        video: GalleryVideo,
        currentTime: @escaping @MainActor () -> Double?,
        isPaused: @escaping @MainActor () -> Bool,
        playedToEnd: @escaping @MainActor () -> Double? = { nil },
        interval: Duration = .seconds(10)
    ) async {
        guard let itemId = jellyfinItemId(fromVideoIdentity: video.identity),
              let library = LibraryService.current()
        else { return }

        var started = false
        var lastPosition: Double = 0
        defer {
            // The title played to its end: the stop is at its duration and the
            // title is marked watched. After an autoplay the window already
            // shows the next episode, so `currentTime` has nothing for this one
            // and the last 10 s sample would be what the server heard. Jellyfin
            // counts a stop as watched only past a share of the runtime it
            // holds, which a title whose metadata runs long never reaches.
            let endedAt = playedToEnd().flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            // The position at close, not at the last 10 s sample.
            let current = currentTime().flatMap { $0.isFinite ? $0 : nil } ?? lastPosition
            let position = endedAt ?? FilmPlayerView.safeStopPosition(current: current, lastReported: lastPosition)
            let wasStarted = started
            Task {
                if wasStarted {
                    await library.reportPlaybackStopped(itemId: itemId, positionSeconds: position)
                } else {
                    // A stop report also ends the server's transcode for this play;
                    // one that never started has to end it explicitly.
                    await library.stopTranscoding(itemId: itemId)
                }
                if endedAt != nil {
                    // After the stop, so the server's last word is "watched, no resume point".
                    do { try await library.setPlayed(itemId: itemId, played: true) } catch {
                        AppLogger.library.error("Marking a finished title watched failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                    }
                }
            }
        }

        while !Task.isCancelled {
            guard let position = currentTime() else { break }
            // Not a time (a player losing its item): skip the sample.
            guard position.isFinite else {
                try? await Task.sleep(for: interval)
                continue
            }
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
    private var lastDuration: Double = 0

    /// nil when `video` isn't Jellyfin-sourced or no server is configured —
    /// callers should just skip wiring `onProgress`/`finish()` in that case.
    init?(video: GalleryVideo) {
        guard let itemId = LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity),
              let library = LibraryService.current()
        else { return nil }
        self.itemId = itemId
        self.library = library
    }

    func report(currentTime: Double, duration: Double = 0, isPaused: Bool) {
        lastPosition = currentTime
        if duration.isFinite, duration > 0 { lastDuration = duration }
        Task {
            if !started, currentTime > 0 {
                started = true
                await library.reportPlaybackStarted(itemId: itemId, positionSeconds: currentTime)
            } else if started {
                await library.reportPlaybackProgress(itemId: itemId, positionSeconds: currentTime, isPaused: isPaused)
            }
        }
    }

    /// - Parameter playedToEnd: the player ran to the end of the title (autoplay's
    ///   trigger): the stop is at its duration, not at the last periodic
    ///   sample, and the title is marked watched after it.
    func finish(playedToEnd: Bool = false) {
        let endedAt = playedToEnd && lastDuration > 0 ? lastDuration : nil
        guard started else {
            Task { [library, itemId] in
                await library.stopTranscoding(itemId: itemId)
                if endedAt != nil { try? await library.setPlayed(itemId: itemId, played: true) }
            }
            return
        }
        started = false
        let position = endedAt ?? lastPosition
        Task {
            await library.reportPlaybackStopped(itemId: itemId, positionSeconds: position)
            if endedAt != nil { try? await library.setPlayed(itemId: itemId, played: true) }
        }
    }
}
