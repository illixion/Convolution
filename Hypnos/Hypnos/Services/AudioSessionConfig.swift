/*
 Hypnos - Audio Session Configuration

 Central audio-session setup. The app uses a mixable playback category so its
 videos never steal audio focus from other apps (music, other players) on
 visionOS — videos start muted, and even when unmuted they mix rather than
 interrupt.

 Without this, AVPlayer-backed players (native Metal, fake-3D) inherit the
 default `.soloAmbient` category, which interrupts other audio the moment a
 clip with an audio track begins — even while muted. WebKit manages its own
 mixable session, which is why only the native path exhibited the interruption.

 The per-player and per-item *spatial-audio* policies that used to live here
 moved to RAVEMedia (`RAVESpatialAudio.swift`) — the stereo engine applies them
 to every player it creates. This session category stayed: it is a whole-app
 decision about audio focus, not a property of one player.
 */

import AVFoundation
import CoreMedia
import DebugTrace

enum AudioSessionConfig {
    /// Configure a mixable playback session. Idempotent; safe to call repeatedly.
    ///
    /// `AVAudioSession` doesn't exist on macOS — there is no per-app audio
    /// focus/category system there the way there is on iOS/tvOS/visionOS; a
    /// Mac app's audio always mixes with everything else unless it explicitly
    /// takes exclusive device access (which this app never does). So this is
    /// a no-op on macOS rather than a port.
    static func configureMixedPlayback() {
        #if os(macOS)
        return
        #else
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        } catch {
            AppLogger.appModel.error("Failed to set mixable audio session: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
        #endif
    }

    #if os(tvOS) || os(iOS)
    /// The film player's session while it is showing: not mixable, because
    /// only a non-mixable session can be the Now Playing app — without that,
    /// AirPods' play/pause went to Music, which then took the session and
    /// cut the film off (tvOS, 2026-09-27). `configureMixedPlayback()`
    /// restores the app-wide policy when the player closes.
    static func configureFilmPlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            AppLogger.filmPlayer.error("Failed to set film audio session: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }
    #endif
}
