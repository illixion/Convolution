/*
 Hypnos - tvOS fullscreen video player

 `AVPlayerViewController` rather than the native Metal path used elsewhere
 in the app: on tvOS it already gives the platform's own transport UI,
 scrubbing, and Menu-button dismissal for free, which is exactly the 10-foot
 experience this needs and none of `VideoWindowView`'s ornament/gesture
 machinery is built for a remote anyway (see `Hypnos/CLAUDE.md` "tvOS").

 There is no WebKit fallback on tvOS (`Hypnos/CLAUDE.md` "tvOS"), so this
 plays through AVFoundation only — but it does follow the same two moves the
 other players make before handing AVFoundation a URL:

 1. **Auth.** Every AVFoundation path in this app goes through
    `MediaAuthorization.shared.asset(for:)` (Hypnos commit ea220b7) so a
    Stash server behind a login, or Nextcloud's Basic auth, doesn't 401 —
    building a bare `AVPlayerItem(url:)` here would silently break exactly
    those two sources.
 2. **Stream-URL strategy.** `GalleryVideo.streamURL` is the original file;
    `NativeVideoDecodeProbe` decides whether AVFoundation can actually open
    it (VP9 in MP4 may now decode thanks to the supplemental decoder
    registered at launch — see `HypnosApp.init` — but WebM containers still
    can't). When it can't, and unlike the WebKit-based players elsewhere,
    there is no second player tier here — the *only* fallback is Stash's
    live HLS transcode (`GalleryVideo.transcodeStreamURL`). A source with
    neither simply can't play on tvOS; the view reports that rather than
    presenting a stuck black screen.

 A Photos-sourced video is a `photos-asset:///` identity, not something
 AVPlayer can open at all, so it is resolved to a real file URL first via
 `PhotosAssetStore`, the same as `VideoWindowModel.resolvePlaybackRenderer`.
 */

#if os(tvOS)

import AVKit
import DebugTrace
import SwiftUI

struct TVVideoPlayerView: View {
    let video: GalleryVideo
    /// Optional periodic (position, duration, paused) callback — a no-op
    /// for every existing caller (`TVVideosTabView`'s plain
    /// `TVVideoPlayerView(video:)`); the Library tab wires it to
    /// `GenericProgressReporter` for a Jellyfin-sourced video.
    var onProgress: (Double, Double, Bool) -> Void = { _, _, _ in }
    /// Where to start, in seconds (the Library's Resume); nil plays from
    /// the beginning.
    var startSeconds: Double?
    /// Called once when playback reaches the end (the Library autoplays the
    /// next episode from here). Nil leaves the player on its last frame.
    var onPlayedToEnd: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedURL: URL?
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let resolvedURL {
                TVAVPlayerViewControllerRepresentable(url: resolvedURL, startSeconds: startSeconds,
                                                      onProgress: onProgress, onPlayedToEnd: onPlayedToEnd) {
                    failureMessage = "This video's format isn't supported on Apple TV."
                    self.resolvedURL = nil
                }
                .ignoresSafeArea()
                // Belt-and-suspenders: `AVPlayerViewController` normally handles
                // its own Menu-button exit when *presented* modally through
                // UIKit, but here it's embedded inside a SwiftUI
                // `fullScreenCover` via a plain representable, not presented
                // itself — verify on-device/simulator that Menu dismisses this,
                // and keep this handler either way.
                .onExitCommand { dismiss() }
            } else if let failureMessage {
                ContentUnavailableView(
                    "Can't Play This Video",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failureMessage)
                )
                .onExitCommand { dismiss() }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onExitCommand { dismiss() }
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        var source = video.streamURL

        if PhotosAssetURL.isPhotosAsset(source) {
            guard let playable = await PhotosAssetStore.shared.playableURL(for: source) else {
                failureMessage = "This video is no longer available in Photos."
                return
            }
            source = playable
            // A resolved Photos file plays directly — nothing to authenticate
            // and no server transcode to fall back to.
            resolvedURL = source
            return
        }

        let authenticated = MediaAuthorization.shared.authorizedURL(source)
        if await NativeVideoDecodeProbe.canPlayNatively(url: authenticated) {
            AppLogger.videoWindow.info("[tvOS] playing original: \(authenticated.loggableDescription)")
            resolvedURL = authenticated
            return
        }

        guard let transcode = video.transcodeStreamURL else {
            failureMessage = "This video's format isn't supported on Apple TV, and no server transcode is available."
            return
        }
        AppLogger.videoWindow.info("[tvOS] original undecodable — falling back to server transcode")
        resolvedURL = MediaAuthorization.shared.authorizedURL(transcode)
    }
}

private struct TVAVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let url: URL
    var startSeconds: Double?
    var onProgress: (Double, Double, Bool) -> Void = { _, _, _ in }
    var onPlayedToEnd: (() -> Void)?
    var onPlaybackFailed: () -> Void = {}

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let asset = MediaAuthorization.shared.asset(for: url)
        let item = AVPlayerItem(asset: asset)
        item.applySpatialAudioPolicy()
        let player = AVPlayer(playerItem: item)
        controller.player = player

        // Both observers are queued/dispatched on `.main`, so `Coordinator`
        // (`@unchecked Sendable`, like the app's other cross-boundary bridge
        // types — `SendableAVAsset`, `SendableTexture`) really is only ever
        // touched there; that conformance is what lets it cross into these
        // `@Sendable` NotificationCenter/KVO closures at all.
        let coordinator = context.coordinator
        coordinator.failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak coordinator] _ in
            coordinator?.onPlaybackFailed()
        }
        let startSeconds = startSeconds ?? 0
        coordinator.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak coordinator, weak player] observedItem, _ in
            switch observedItem.status {
            case .failed:
                DispatchQueue.main.async {
                    coordinator?.onPlaybackFailed()
                }
            case .readyToPlay:
                // Resume: a seek issued before the item is ready is dropped,
                // so it waits for readiness, and playback starts after it so
                // the resume point is the first frame shown.
                DispatchQueue.main.async {
                    guard let coordinator, let player, !coordinator.didStart else { return }
                    coordinator.didStart = true
                    guard startSeconds > 0 else { player.play(); return }
                    player.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { _ in
                        player.play()
                    }
                }
            default:
                break
            }
        }
        // Library-feature progress sync: every ~5s, report (position,
        // duration, paused) up to the SwiftUI view — a no-op for every
        // caller that doesn't pass `onProgress` (see `TVVideoPlayerView`'s
        // default).
        coordinator.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1),
            queue: .main
        ) { [weak coordinator, weak player] time in
            guard let coordinator, let player else { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            coordinator.onProgress(time.seconds, duration.isFinite ? duration : 0, player.rate == 0)
        }

        coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak coordinator] _ in
            coordinator?.onPlayedToEnd?()
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onPlaybackFailed = onPlaybackFailed
        context.coordinator.onProgress = onProgress
        context.coordinator.onPlayedToEnd = onPlayedToEnd
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onPlaybackFailed: onPlaybackFailed, onProgress: onProgress)
        coordinator.onPlayedToEnd = onPlayedToEnd
        return coordinator
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.statusObservation?.invalidate()
        if let observer = coordinator.failureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = coordinator.endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let timeObserver = coordinator.timeObserver {
            uiViewController.player?.removeTimeObserver(timeObserver)
        }
        uiViewController.player?.pause()
        uiViewController.player = nil
    }

    /// `@unchecked Sendable`: every access happens on the main queue (both
    /// observers above are registered with `queue: .main` / dispatched
    /// there), so the unchecked conformance states a real invariant rather
    /// than papering over one, the same shape as `SendableAVAsset` /
    /// `SendableTexture` elsewhere in the app.
    final class Coordinator: @unchecked Sendable {
        var onPlaybackFailed: () -> Void
        var onProgress: (Double, Double, Bool) -> Void
        var onPlayedToEnd: (() -> Void)?
        /// Set once the first play (after any resume seek) has been issued.
        var didStart = false
        var failureObserver: NSObjectProtocol?
        var endObserver: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?
        var timeObserver: Any?

        init(onPlaybackFailed: @escaping () -> Void, onProgress: @escaping (Double, Double, Bool) -> Void) {
            self.onPlaybackFailed = onPlaybackFailed
            self.onProgress = onProgress
        }
    }
}

#endif
