/*
 Hypnos - Stereoscopic Video View

 View for displaying stereoscopic 3D video converted to MV-HEVC.
 Handles download and conversion, then launches immersive space for 3D playback.
 Controls (Edit Settings, Revert to 2D) are in VideoOrnamentsView.
 */

import AVFoundation
import AVKit
import DebugTrace
import SwiftUI

#if os(visionOS)

struct StereoscopicVideoView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @StateObject private var player = StereoscopicVideoPlayer()
    @State private var fallbackTo2D = false
    @State private var hasEnteredImmersiveSpace = false
    @State private var currentSettings: Video3DSettings?

    let video: GalleryVideo

    /// The owning window's model — used to register the immersive session so the
    /// immersive player reads this window's stereoscopic override.
    let windowModel: VideoWindowModel

    /// Optional initial settings (if provided, uses these instead of tag-detected)
    var initialSettings: Video3DSettings?

    /// Callback when user wants to revert to 2D mode
    var onRevertTo2D: (() -> Void)?

    /// Callback when settings change (so parent can track)
    var onSettingsChanged: ((Video3DSettings) -> Void)?

    var body: some View {
        ZStack {
            if fallbackTo2D {
                // Fallback to 2D web player with original stream
                WebVideoPlayerView(videoURL: video.streamURL)
            } else if hasEnteredImmersiveSpace {
                // Show minimal UI when in immersive space
                immersiveSpaceActiveView
            } else {
                // Show progress/error overlays during download/conversion
                Color.black
                    .aspectRatio(16/9, contentMode: .fit)

                overlayContent
            }
        }
        .onAppear {
            // Use initial settings if provided, otherwise load from tracker or use tag defaults
            Task {
                await loadSettingsAndStartPlayback()
            }
        }
        .onDisappear {
            Task {
                await exitImmersiveSpace()
            }
            player.stop()
        }
        .onChange(of: player.state) { oldState, newState in
            // When playback is ready, open immersive space
            if case .playing = newState, !hasEnteredImmersiveSpace, !fallbackTo2D {
                Task {
                    await enterImmersiveSpace()
                }
            }
        }
        .onChange(of: initialSettings) { _, newSettings in
            // Handle per-window settings change from the ornament's Edit Settings
            if let newSettings = newSettings, newSettings != currentSettings {
                applyNewSettings(newSettings)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stereoscopicFallbackTo2D)) { notification in
            if let notificationVideo = notification.userInfo?["video"] as? GalleryVideo,
               notificationVideo.id == video.id {
                Task {
                    await exitImmersiveSpace()
                }
                fallbackTo2D = true
            }
        }
    }

    // MARK: - Immersive Space Active View

    private var immersiveSpaceActiveView: some View {
        // Empty view - immersive space handles its own UI
        Color.clear
            .frame(width: 1, height: 1)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlayContent: some View {
        switch player.state {
        case .downloading(let progress):
            progressOverlay(
                title: "Downloading Video",
                progress: progress,
                detail: player.currentChunkInfo
            )

        case .converting(let progress):
            progressOverlay(
                title: "Converting to 3D",
                progress: progress,
                detail: player.currentChunkInfo
            )

        case .error(let message):
            errorOverlay(message: message)

        case .playing, .paused, .idle:
            // Show loading indicator while transitioning to immersive space
            if !hasEnteredImmersiveSpace && player.convertedFileURL != nil {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Entering 3D mode...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }

        // Format indicator badge (only during loading states)
        if case .downloading = player.state {
            formatBadgeView
        } else if case .converting = player.state {
            formatBadgeView
        }
    }

    private var formatBadgeView: some View {
        VStack {
            HStack {
                Spacer()
                formatBadge
                    .padding()
            }
            Spacer()
        }
    }

    private func progressOverlay(title: String, progress: Double, detail: String) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 250)
                .tint(.white)

            Text("\(Int(progress * 100))%")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.white)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private func errorOverlay(message: String) -> some View {
        let isSimulatorError = message.contains("Simulator") || message.contains("physical device")

        return VStack(spacing: 16) {
            Image(systemName: isSimulatorError ? "visionpro" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(isSimulatorError ? .blue : .orange)

            Text(isSimulatorError ? "Device Required" : "Playback Error")
                .font(.title2)
                .fontWeight(.semibold)

            Text(isSimulatorError
                 ? "Stereoscopic 3D video conversion requires a physical Apple Vision Pro. The Simulator cannot encode MV-HEVC video."
                 : message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if isSimulatorError {
                Button("Play as 2D Instead") {
                    revertTo2D()
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 16) {
                    Button("Retry") {
                        Task {
                            await startPlaybackWithSettings()
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Play as 2D") {
                        revertTo2D()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private var formatBadge: some View {
        HStack(spacing: 6) {
            if let settings = currentSettings {
                Text(settings.format.shortLabel)
            } else if let format = video.stereoscopicFormat {
                Text(format.shortLabel)
            } else {
                Text("3D")
            }
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func loadSettingsAndStartPlayback() async {
        // Priority: initialSettings > saved settings > tag-detected defaults
        if let initial = initialSettings {
            currentSettings = initial
        } else if let saved = await Video3DSettingsTracker.shared.loadSettings(videoId: video.identity) {
            currentSettings = saved
        } else if let tagSettings = Video3DSettings.from(video: video) {
            currentSettings = tagSettings
        } else {
            // No tags and no saved settings - this shouldn't happen in normal flow
            // but provide a default just in case
            currentSettings = Video3DSettings.defaults(for: .sideBySide)
        }

        await startPlaybackWithSettings()
    }

    private func startPlaybackWithSettings() async {
        fallbackTo2D = false
        hasEnteredImmersiveSpace = false

        guard let settings = currentSettings else {
            // Fallback to tag-based playback if somehow settings are nil
            await player.play(video: video)
            return
        }

        await player.play(video: video, customSettings: settings)
    }

    private func applyNewSettings(_ newSettings: Video3DSettings) {
        // Check if settings actually changed
        guard newSettings != currentSettings else {
            AppLogger.stereoscopicPlayer.info("Settings unchanged, skipping apply")
            return
        }

        AppLogger.stereoscopicPlayer.info("Applying new 3D settings: format=\(newSettings.format.rawValue, privacy: .public), eyesReversed=\(newSettings.eyesReversed), cacheKey=\(newSettings.cacheKey, privacy: .public)")

        // Reset fallbackTo2D IMMEDIATELY (before async task) to show progress UI
        fallbackTo2D = false

        currentSettings = newSettings

        // Save to tracker for future sessions
        Task {
            await Video3DSettingsTracker.shared.saveSettings(
                videoId: video.identity,
                settings: newSettings
            )
        }

        // Note: Don't call onSettingsChanged here - the change came FROM appModel.video3DSettings
        // Calling it would create a circular update loop

        // Invalidate cache and restart playback
        Task {
            AppLogger.stereoscopicPlayer.info("Starting settings change task...")

            // Exit immersive space first if we're in it
            // This allows re-entry when new conversion completes
            await exitImmersiveSpace()

            // Stop current playback
            player.stop()

            // Remove cached versions (settings changed)
            AppLogger.stereoscopicPlayer.info("Removing cached versions...")
            await DiskVideoCache.shared.removeAllCachedVersions(videoId: video.identity)

            // Restart with new settings
            AppLogger.stereoscopicPlayer.info("Restarting playback with new settings...")
            await startPlaybackWithSettings()

            AppLogger.stereoscopicPlayer.info("Settings change task completed")
        }
    }

    private func revertTo2D() {
        Task {
            await exitImmersiveSpace()
        }
        player.stop()
        fallbackTo2D = true
        onRevertTo2D?()
    }

    private func enterImmersiveSpace() async {
        guard let convertedURL = player.convertedFileURL else {
            AppLogger.immersiveVideo.warning("No converted URL available for immersive playback")
            return
        }

        // Store video info in AppModel for ImmersiveVideoView, and register this
        // window as the immersive session's owner so the immersive player reads
        // this window's stereoscopic override.
        appModel.immersiveVideo = video
        appModel.immersiveVideoURL = convertedURL
        appModel.immersiveVideoOwner = windowModel

        // Stop the player since ImmersiveVideoView will create its own
        player.stop()

        // Open the immersive space
        switch await openImmersiveSpace(id: "StereoscopicVideoSpace") {
        case .opened:
            hasEnteredImmersiveSpace = true
            appModel.isStereoscopicImmersiveSpaceShown = true
            AppLogger.immersiveVideo.info("Immersive space opened successfully")
        case .error:
            AppLogger.immersiveVideo.error("Failed to open immersive space")
            fallbackTo2D = true
        case .userCancelled:
            AppLogger.immersiveVideo.info("User cancelled immersive space")
            fallbackTo2D = true
        @unknown default:
            AppLogger.immersiveVideo.warning("Unknown immersive space result")
            fallbackTo2D = true
        }
    }

    private func exitImmersiveSpace() async {
        if hasEnteredImmersiveSpace {
            await dismissImmersiveSpace()
            hasEnteredImmersiveSpace = false
            appModel.isStereoscopicImmersiveSpaceShown = false
            appModel.immersiveVideo = nil
            appModel.immersiveVideoURL = nil
            appModel.immersiveVideoOwner = nil
        }
    }
}

// MARK: - Preview

#if DEBUG
struct StereoscopicVideoView_Previews: PreviewProvider {
    static var previews: some View {
        let appModel = AppModel()
        let video = GalleryVideo(
            identity: "preview",
            thumbnailURL: URL(string: "https://example.com/thumb.jpg")!,
            streamURL: URL(string: "https://example.com/video.mp4")!,
            title: "Preview Video",
            duration: 120,
            isStereoscopic: true,
            stereoscopicFormat: .sideBySide
        )
        return StereoscopicVideoView(
            video: video,
            windowModel: VideoWindowModel(windowValue: VideoWindowValue(video: video), appModel: appModel)
        )
        .environment(appModel)
    }
}
#endif

#endif

#if !os(visionOS)

/// iOS stand-in: no `ImmersiveSpace`/MV-HEVC stereo playback on this
/// platform. Same init shape as the visionOS view so `VideoWindowView`
/// compiles unchanged; offers a way back to the flat player instead of a
/// dead end.
struct StereoscopicVideoView: View {
    let video: GalleryVideo

    /// The owning window's model — unused on iOS, kept for call-site parity.
    let windowModel: VideoWindowModel

    /// Optional initial settings (if provided, uses these instead of tag-detected)
    var initialSettings: Video3DSettings?

    /// Callback when user wants to revert to 2D mode
    var onRevertTo2D: (() -> Void)?

    /// Callback when settings change (so parent can track)
    var onSettingsChanged: ((Video3DSettings) -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("Immersive 3D video needs Apple Vision Pro", systemImage: "visionpro")
        } actions: {
            Button("Play as 2D") {
                onRevertTo2D?()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#endif
