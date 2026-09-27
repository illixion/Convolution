/*
 Hypnos - Library feature: starting playback

 One controller behind every Play button in the Library (the hero, a detail
 page's Play/Resume/Start Over, an episode row), so routing, resume, and
 what happens when an episode ends are decided in one place:

 - A series plays its Next Up episode (`MediaServerLibrary.nextUp`).
 - The route comes from `playbackRoute(for:)`: the Atmos `FilmPlayer`, or
   the app's generic video player with a direct or transcoded stream.
 - Resume seeks to the saved position on either route; Start Over doesn't.
 - When an episode plays to the end in the tvOS player, the next one starts
   (`episode(after:)`), the way the Apple TV app autoplays a series.

 Presentation is per platform, applied by `.libraryPlayback(_:)`: tvOS has
 one scene, so the players are full-screen covers; visionOS, macOS and iOS
 open the existing "Film Player" / "video-detail" windows (iOS through its
 window router).
 */

import RAVEFilm
import SwiftUI

/// A generic-player presentation: the adapter video plus where to start.
struct LibraryVideoPresentation: Identifiable, Equatable {
    let id = UUID()
    let item: LibraryItem
    let video: GalleryVideo
    let startSeconds: Double?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
@Observable
final class LibraryPlayback {
    /// The item whose route is being resolved, for a spinner on its button.
    private(set) var resolvingItemId: String?
    /// The last failure, shown under the buttons that caused it.
    var error: String?

    /// tvOS: the Atmos player cover.
    var showsFilmPlayer = false
    /// tvOS: the generic player cover. Replacing it while presented swaps
    /// to the next episode.
    var videoPresentation: LibraryVideoPresentation?
    /// Other platforms: a window the view modifier should open, consumed
    /// as soon as it has been.
    var pendingWindow: LibraryVideoPresentation?
    var pendingFilmWindow = false

    private(set) var progressReporter: GenericProgressReporter?

    /// Bumped whenever a player closes, so screens showing watch state
    /// (Continue Watching, a detail page's Resume) reload it.
    private(set) var finishedCount = 0

    var isResolving: Bool { resolvingItemId != nil }

    /// Plays `item`: a movie or episode directly, a series via its Next Up
    /// episode. `fromStart` ignores any saved position.
    func play(_ item: LibraryItem, fromStart: Bool = false) async {
        guard let library = LibraryService.current(), !isResolving else { return }
        resolvingItemId = item.id
        error = nil
        defer { resolvingItemId = nil }
        do {
            var target = item
            if !item.isPlayable {
                guard item.kind == .series, let episode = try await library.nextUp(seriesId: item.id) else {
                    error = "Nothing to play in \(item.title) yet."
                    return
                }
                target = episode
            }
            try await start(target, fromStart: fromStart, library: library)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Autoplay: the episode after the one that just finished, if any;
    /// otherwise the player closes.
    func playNextEpisode() async {
        guard let finished = videoPresentation?.item, let library = LibraryService.current() else { return }
        progressReporter?.finish()
        progressReporter = nil
        guard let next = try? await library.episode(after: finished) else {
            videoPresentation = nil
            return
        }
        do {
            try await start(next, fromStart: true, library: library)
        } catch {
            videoPresentation = nil
            self.error = error.localizedDescription
        }
    }

    /// The generic player was dismissed: send the final progress report.
    func videoDismissed() {
        // Swapping in the next episode can also fire the cover's onDismiss;
        // only a real dismissal (nothing presented any more) ends reporting.
        guard videoPresentation == nil else { return }
        progressReporter?.finish()
        progressReporter = nil
        finishedCount += 1
    }

    /// The Atmos player was dismissed (tvOS cover). FilmPlayer reports its
    /// own progress; this only prompts the reload.
    func filmDismissed() {
        finishedCount += 1
    }

    private func start(_ item: LibraryItem, fromStart: Bool, library: JellyfinLibrary) async throws {
        let resume = fromStart ? nil : item.userData.resumeSeconds
        switch try await library.playbackRoute(for: item) {
        case .atmosFilmPlayer:
            _ = await FilmSession.shared.load(itemId: item.id, name: item.title, productionYear: item.year)
            if let resume { FilmSession.shared.player.seek(to: resume) }
            FilmSession.shared.player.play()
            #if os(tvOS)
            showsFilmPlayer = true
            #else
            pendingFilmWindow = true
            #endif
        case .genericPlayer(let plan):
            let video = LibraryPlaybackCoordinator.makeGalleryVideo(item: item, plan: plan, library: library)
            let presentation = LibraryVideoPresentation(item: item, video: video, startSeconds: resume)
            #if os(tvOS)
            progressReporter = GenericProgressReporter(video: video)
            videoPresentation = presentation
            #else
            // VideoWindowView reports progress itself (see its
            // `reportGenericPlaybackProgress` task).
            pendingWindow = presentation
            #endif
        }
    }
}

extension View {
    /// Presents whatever `playback` starts. Attach once per screen that has
    /// Play buttons.
    func libraryPlayback(_ playback: LibraryPlayback) -> some View {
        modifier(LibraryPlaybackPresenter(playback: playback))
    }
}

private struct LibraryPlaybackPresenter: ViewModifier {
    @Bindable var playback: LibraryPlayback
    #if !os(tvOS)
    @OpenWindowProxy private var openWindow
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .fullScreenCover(isPresented: $playback.showsFilmPlayer, onDismiss: { playback.filmDismissed() }) {
                FilmPlayerView()
            }
            .fullScreenCover(item: $playback.videoPresentation, onDismiss: { playback.videoDismissed() }) { presentation in
                TVVideoPlayerView(
                    video: presentation.video,
                    onProgress: { position, _, isPaused in
                        playback.progressReporter?.report(currentTime: position, isPaused: isPaused)
                    },
                    startSeconds: presentation.startSeconds,
                    onPlayedToEnd: presentation.item.kind == .episode
                        ? { Task { await playback.playNextEpisode() } }
                        : nil
                )
                // A new episode is a new player, not an update of this one.
                .id(presentation.id)
            }
        #else
        content
            .onChange(of: playback.pendingFilmWindow) { _, pending in
                guard pending else { return }
                playback.pendingFilmWindow = false
                openWindow(id: FilmPlayerView.windowID)
            }
            .onChange(of: playback.pendingWindow) { _, presentation in
                guard let presentation else { return }
                playback.pendingWindow = nil
                #if os(macOS)
                // The Mac's video-detail scene takes a bare GalleryVideo
                // (MacVideoPlayerWindow), so the start point travels beside it.
                LibraryResumePoints.set(presentation.startSeconds, for: presentation.video.identity)
                openWindow(id: "video-detail", value: presentation.video)
                #else
                var value = VideoWindowValue(video: presentation.video, galleryVideos: [presentation.video])
                value.startSeconds = presentation.startSeconds
                openWindow(id: "video-detail", value: value)
                #endif
            }
        #endif
    }
}

#if os(macOS)
/// Start positions for Library videos opened in the Mac's video-detail
/// window, whose scene value is a plain `GalleryVideo` with no room for one.
/// Taken (and cleared) by `MacVideoPlayerWindow` when it starts playing.
@MainActor
enum LibraryResumePoints {
    private static var points: [String: Double] = [:]

    static func set(_ seconds: Double?, for identity: String) {
        points[identity] = seconds
    }

    static func take(for identity: String) -> Double? {
        points.removeValue(forKey: identity)
    }
}
#endif
