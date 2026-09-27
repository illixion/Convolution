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
 */

#if os(macOS)

import AVKit
import os
import SwiftUI

struct MacVideoPlayerWindow: View {
    let video: GalleryVideo
    @State private var player: AVPlayer?
    @State private var failureMessage: String?
    /// Library (Jellyfin) videos only: watch progress back to the server.
    @State private var progressReporter: GenericProgressReporter?
    @State private var timeObserver: Any?

    var body: some View {
        Group {
            if let player {
                MacAVPlayerView(player: player)
                    .task { await startPlayback(player) }
                    .onDisappear {
                        player.pause()
                        if let timeObserver { player.removeTimeObserver(timeObserver) }
                        timeObserver = nil
                        progressReporter?.finish()
                        progressReporter = nil
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
        guard timeObserver == nil, let reporter = GenericProgressReporter(video: video) else { return }
        progressReporter = reporter
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                                                      queue: .main) { [weak player] time in
            guard let player else { return }
            MainActor.assumeIsolated {
                reporter.report(currentTime: time.seconds, isPaused: player.rate == 0)
            }
        }
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

        let authenticated = MediaAuthorization.shared.authorizedURL(source)
        if await NativeVideoDecodeProbe.canPlayNatively(url: authenticated) {
            AppLogger.videoWindow.info("[macOS] playing original: \(authenticated.loggableDescription, privacy: .public)")
            player = AVPlayer(playerItem: AVPlayerItem(asset: MediaAuthorization.shared.asset(for: authenticated)))
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
