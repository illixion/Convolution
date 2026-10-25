/*
 Hypnos - macOS video player window

 The `video-detail` window's content: a direct `NSViewRepresentable` wrapping
 AppKit's `AVPlayerView` (the seam this app's macOS UIKit-gap notes call for),
 which gives the platform's own transport UI for free — the Mac equivalent of
 `TVVideoPlayerView`'s "reach for the platform's own player chrome rather than
 porting `VideoControlBar`" choice, and the same reasoning: none of
 `VideoWindowView`'s ornament/fake-3D/adjustments machinery is Mac-shaped.

 Wraps `AVPlayerView` directly rather than going through SwiftUI's `VideoPlayer`
 (which wraps the same class internally): `VideoPlayer` crashed at launch on
 this Xcode 27 / macOS 26 pairing with "failed to demangle superclass of
 VideoPlayerView from mangled name 'So12AVPlayerViewC'" — a Swift runtime
 metadata bug in SwiftUI's own wrapper, reproduced consistently. Going one
 layer down to the AppKit class directly avoids whatever synthesized type
 trips it.

 Follows the same two moves every other AVFoundation path in the app makes
 before opening a URL — see `TVVideoPlayerView`'s doc comment for the reasons
 in full:

 1. **Auth** — every URL goes through `MediaAuthorization`.
 2. **Stream-URL strategy** — `NativeVideoDecodeProbe` decides native vs.
    Stash's HLS transcode (VP9 is registered as a supplemental decoder at
    launch on macOS too — see `HypnosApp.init` — so VP9-in-MP4 may decode
    natively; VP9-in-WebM still needs WebKit, which isn't wired up on macOS
    this pass, so it falls to the transcode same as tvOS).

 A `photos-asset:///` identity (Photos library source) resolves through
 `PhotosAssetStore` first, same as everywhere else.

 A YouTube video starts in YouTube's stereo and moves to its 5.1 track at
 the playhead when YouTube lets that play (`YouTubeSurroundSwap`), back to
 stereo if it fails. A restored window whose YouTube URL has expired
 resolves the video again first.
 */

#if os(macOS)

import AVKit
import DebugTrace
import SwiftUI

struct MacVideoPlayerWindow: View {
    let video: GalleryVideo
    @State private var player: AVPlayer?
    @State private var failureMessage: String?
    /// Library (Jellyfin) videos only: watch progress back to the server.
    @State private var progressReporter: GenericProgressReporter?
    #if HYPNOS_YOUTUBE
    /// YouTube videos only: progress to the watch history on the backend.
    @State private var youTubeReporter: YouTubeWatchReporter?
    /// YouTube videos only: moves the player onto the surround master.
    @State private var surroundSwap = YouTubeItemSwap()
    #endif
    @State private var timeObserver: Any?
    /// Skip Intro / Skip Credits for a Library video.
    @State private var skipper = MediaSegmentSkipper()
    @State private var segmentObserver: Any?
    @State private var playhead: Double = 0

    var body: some View {
        Group {
            if let player {
                MacAVPlayerView(player: player)
                    // Above AVPlayerView's floating controls.
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            if let segment = skipper.segment(at: playhead) {
                                SkipSegmentButton(segment: segment) { skip(segment, player: player) }
                            } else if let undo = skipper.undo {
                                UndoSkipButton(undo: undo) { undoSkip(player: player) }
                            }
                        }
                        .padding(.trailing, 24)
                        .padding(.bottom, 90)
                    }
                    .animation(.easeInOut(duration: 0.2), value: skipper.segment(at: playhead))
                    .animation(.easeInOut(duration: 0.2), value: skipper.undo)
                    .task { await startPlayback(player) }
                    .onDisappear {
                        player.pause()
                        if let timeObserver { player.removeTimeObserver(timeObserver) }
                        timeObserver = nil
                        if let segmentObserver { player.removeTimeObserver(segmentObserver) }
                        segmentObserver = nil
                        progressReporter?.finish()
                        progressReporter = nil
                        #if HYPNOS_YOUTUBE
                        youTubeReporter?.finish()
                        youTubeReporter = nil
                        surroundSwap.stop()
                        #endif
                    }
            } else if let failureMessage {
                ContentUnavailableView(
                    "Can't Play This Video",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failureMessage)
                )
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .navigationTitle(video.title ?? "Video")
        .task { await resolve() }
        .onReceive(NotificationCenter.default.publisher(for: .hypnosTogglePlayPause)) { _ in
            guard let player else { return }
            player.timeControlStatus == .playing ? player.pause() : player.play()
        }
    }

    /// Seeks to a Library resume point if one was handed over, starts
    /// playback, and wires progress reporting for a Library video.
    private func startPlayback(_ player: AVPlayer) async {
        if let start = LibraryResumePoints.take(for: video.identity), start > 0 {
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        player.play()
        if timeObserver == nil, let reporter = GenericProgressReporter(video: video) {
            progressReporter = reporter
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                                                          queue: .main) { [weak player] time in
                guard let player else { return }
                MainActor.assumeIsolated {
                    reporter.report(currentTime: time.seconds, isPaused: player.rate == 0)
                }
            }
        }
        #if HYPNOS_YOUTUBE
        if timeObserver == nil, let reporter = YouTubeWatchReporter(video: video) {
            youTubeReporter = reporter
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                          queue: .main) { [weak player] time in
                guard let player else { return }
                MainActor.assumeIsolated {
                    reporter.update(position: time.seconds, duration: player.currentItem?.duration.seconds,
                                    isPaused: player.rate == 0)
                }
            }
        }
        #endif
        await watchSegments(player)
        #if HYPNOS_YOUTUBE
        await swapInSurround(player)
        #endif
    }

    #if HYPNOS_YOUTUBE
    /// YouTube's 5.1, swapped in at the playhead once YouTube lets it play;
    /// back to stereo, where it was, if it won't play.
    private func swapInSurround(_ player: AVPlayer) async {
        guard let stereo = (player.currentItem?.asset as? AVURLAsset)?.url,
              let surround = await YouTubeSurroundSwap.surroundMaster(for: video, playing: stereo),
              !Task.isCancelled else { return }
        AppLogger.youtube.info("[macOS] Switching to surround at \(player.currentTime().seconds, format: .fixed(precision: 1), privacy: .public) s")
        let swap = surroundSwap
        swap.swap(player, to: Self.youTubeItem(surround)) {
            AppLogger.youtube.error("[macOS] The surround stream failed; back to stereo")
            swap.swap(player, to: Self.youTubeItem(stereo)) {}
        }
    }

    /// YouTube's saved quality; other sources play whatever they offer.
    private static func youTubeItem(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(asset: MediaAuthorization.shared.asset(for: url))
        item.preferredMaximumResolution = YouTubeQuality.maximumResolution(height: YouTubeQuality.preferred.height)
        return item
    }
    #endif

    /// Loads a Library video's skippable segments and follows the playhead
    /// while it has any.
    private func watchSegments(_ player: AVPlayer) async {
        await skipper.load(videoIdentity: video.identity)
        guard segmentObserver == nil, !skipper.segments.isEmpty else { return }
        segmentObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                         queue: .main) { time in
            MainActor.assumeIsolated { playhead = time.seconds }
        }
    }

    private func skip(_ segment: LibraryMediaSegment, player: AVPlayer) {
        let duration = player.currentItem?.duration.seconds ?? 0
        let target = MediaSegmentSkipper.target(for: segment, duration: duration.isFinite ? duration : 0)
        skipper.noteSkipped(segment, from: player.currentTime().seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Back to where the last skip left from.
    private func undoSkip(player: AVPlayer) {
        guard let returnTo = skipper.takeUndo() else { return }
        player.seek(to: CMTime(seconds: returnTo, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func resolve() async {
        var source = video.streamURL

        if PhotosAssetURL.isPhotosAsset(source) {
            guard let playable = await PhotosAssetStore.shared.playableURL(for: source) else {
                failureMessage = "This video is no longer available in Photos."
                return
            }
            player = AVPlayer(url: playable)
            return
        }

        #if HYPNOS_YOUTUBE
        // A restored window's YouTube URL expires after ~6 h.
        if let id = YouTubeVideoID(videoIdentity: video.identity), YouTubeResolver.needsRefresh(source) {
            do {
                source = try await YouTubeResolver.resolve(id).video.streamURL
            } catch {
                failureMessage = error.localizedDescription
                return
            }
        }
        #endif

        let authenticated = MediaAuthorization.shared.authorizedURL(source)
        if await NativeVideoDecodeProbe.canPlayNatively(url: authenticated) {
            AppLogger.videoWindow.info("[macOS] playing original: \(authenticated.loggableDescription)")
            #if HYPNOS_YOUTUBE
            if YouTubeVideoID(videoIdentity: video.identity) != nil {
                player = AVPlayer(playerItem: Self.youTubeItem(authenticated))
                return
            }
            #endif
            player = AVPlayer(playerItem: AVPlayerItem(asset: MediaAuthorization.shared.asset(for: authenticated)))
            return
        }

        // An MKV/WebM the player can't open, remuxed to HLS on the device
        // (lossless, ahead of the server's transcode). Library titles keep
        // Jellyfin's own streams.
        if LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) == nil,
           let remuxed = await MatroskaRemuxService.shared.playlistURL(for: authenticated, fileName: video.fileName) {
            AppLogger.videoWindow.info("[macOS] playing the original remuxed to HLS")
            player = AVPlayer(playerItem: AVPlayerItem(asset: MediaAuthorization.shared.asset(for: remuxed)))
            return
        }

        guard let transcode = video.transcodeStreamURL else {
            failureMessage = "This video's format isn't supported, and no server transcode is available."
            return
        }
        AppLogger.videoWindow.info("[macOS] original undecodable — falling back to server transcode")
        source = MediaAuthorization.shared.authorizedURL(transcode)
        player = AVPlayer(playerItem: AVPlayerItem(asset: MediaAuthorization.shared.asset(for: source)))
    }
}

/// Direct `NSViewRepresentable` over `AVPlayerView` — see the file header for
/// why this replaces SwiftUI's `VideoPlayer`.
private struct MacAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

#endif
