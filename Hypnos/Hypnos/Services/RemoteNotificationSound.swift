/*
 Hypnos - Remote Notification Sound

 Plays a short audio clip received from RoboFrame as a system alert.
 Uses AudioServices (the alert channel) so the sound mixes with any
 currently-playing video or other apps' media — visionOS doesn't
 interrupt the user's music for a chime.

 Hard-capped at 30 seconds because AudioServices SystemSound APIs
 reject anything longer; we check up front so the rejection is logged
 helpfully instead of failing as a cryptic OSStatus.

 Window-independent: AudioServicesPlayAlertSound runs at the app level,
 so it works regardless of whether any hypnos window is on
 screen, snapped to a wall, or in the user's current room.
 */

import AVFoundation
import AudioToolbox
import DebugTrace
import Foundation

@MainActor
final class RemoteNotificationSound {
    static let shared = RemoteNotificationSound()

    /// Active local file URLs we've created — kept around so cleanup can
    /// remove them after the sound finishes playing. Keyed by SystemSoundID.
    private var activeSounds: [SystemSoundID: URL] = [:]

    private init() {}

    /// Download a remote URL and play it through the system alert channel.
    /// Silently drops clips longer than 30s with a warning log.
    func play(remoteURL: URL) {
        Task { await self.downloadAndPlay(remoteURL) }
    }

    private func downloadAndPlay(_ remoteURL: URL) async {
        let dest: URL
        do {
            dest = try await downloadToTemp(remoteURL)
        } catch {
            AppLogger.remoteViewer.warning("notification sound download failed for \(remoteURL.absoluteString, privacy: .private): \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return
        }

        if let seconds = await durationSeconds(of: dest), seconds > 30 {
            AppLogger.remoteViewer.warning("notification sound clip is \(seconds, privacy: .public)s, > 30s limit; ignoring")
            cleanup(dest)
            return
        }

        await MainActor.run { self.playLocal(dest) }
    }

    private func downloadToTemp(_ url: URL) async throws -> URL {
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-sound-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func durationSeconds(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            // Couldn't read metadata — let AudioServices try anyway and
            // surface its own error if the file is malformed.
            return nil
        }
    }

    @MainActor
    private func playLocal(_ url: URL) {
        var soundID: SystemSoundID = 0
        let res = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard res == kAudioServicesNoError else {
            AppLogger.remoteViewer.warning("AudioServicesCreateSystemSoundID failed: \(res, privacy: .public)")
            cleanup(url)
            return
        }
        activeSounds[soundID] = url
        AudioServicesPlayAlertSound(soundID)
        // Cleanup after the longest possible playback (30s) plus a small
        // grace window. AudioServicesAddSystemSoundCompletion would be
        // tighter but adds C-callback bridging for marginal benefit.
        Task {
            try? await Task.sleep(for: .seconds(35))
            await MainActor.run { self.dispose(soundID) }
        }
    }

    @MainActor
    private func dispose(_ soundID: SystemSoundID) {
        AudioServicesDisposeSystemSoundID(soundID)
        if let url = activeSounds.removeValue(forKey: soundID) {
            cleanup(url)
        }
    }

    private nonisolated func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
