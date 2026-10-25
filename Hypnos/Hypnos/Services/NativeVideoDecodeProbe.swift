/*
 Hypnos - Native Video Decode Probe

 Shared "can AVFoundation decode this?" check. Being AVFoundation-decodable is
 what unlocks the native Metal player and, with it, real-time fake-3D — the
 stereo pump pulls frames from an `AVPlayerItemVideoOutput`, so a source only
 WebKit can decode (a WebM or MKV the Matroska remux declines) has to be
 routed through a transcode first or played flat.

 Used by `VideoWindowModel.resolvePlaybackRenderer` (which renderer to mount)
 and by `SlideshowEngine` (whether a slideshow video can be converted to 3D).
 */

import AVFoundation

enum NativeVideoDecodeProbe {
    /// True when `AVURLAsset` reports the source playable with a usable video
    /// track. Any error (bad URL, auth, TLS, unsupported container) is a "no" —
    /// the caller falls back to WebKit / flat playback.
    static func canPlayNatively(url: URL) async -> Bool {
        // Authenticated, or a server that needs a header answers 401 and the
        // probe reads that as "undecodable" — see MediaAuthorization.asset.
        let asset = MediaAuthorization.shared.asset(for: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { return false }
            // HLS assets expose their video through AVAssetVariant rather than
            // classic tracks, so `loadTracks(.video)` comes back empty even when
            // the stream is perfectly playable. Requiring a non-empty track list
            // would wrongly route HLS to WebKit (disabling the native renderer
            // and the fake-3D toggle), so trust `isPlayable` for HLS.
            if url.pathExtension.lowercased() == "m3u8" {
                return true
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return !tracks.isEmpty
        } catch {
            return false
        }
    }

    /// `canPlayNatively` bounded by `timeout` seconds. A probe that hasn't
    /// answered by then is treated as "no" — the caller has a flat fallback and
    /// blocking a slideshow transition on a stalled asset load is worse than
    /// playing the clip in 2D.
    static func canPlayNatively(url: URL, timeout: TimeInterval) async -> Bool {
        let probe = Task { await canPlayNatively(url: url) }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            probe.cancel()
        }
        let result = await probe.value
        watchdog.cancel()
        return result
    }
}
