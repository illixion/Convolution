/*
 Hypnos - the listener's equalizer

 One EQ for the whole app, like the listening volume: `RAVEAudioEQ` (RAVEMedia) holds the curve,
 persists it in `HypnosDefaults.store` and moves every live processor as it changes. It reaches
 sound three ways, all through the same curve:

 - **Any file-backed `AVPlayer` item** (a local or Photos video, a Stash or Nextcloud original, a
   Jellyfin Direct Play, every Jellyfin song): an `MTAudioProcessingTap` on the item
   (`AVPlayerItem.attachAudioEQ`, called where Hypnos makes the item).
 - **The film player's object audio**: `FilmPlayer.audioEQ`; every Atmos object and the room's
   reverb is filtered where it renders.
 - **The stereo (AI 3D) player's item**, which RAVEMedia's engine makes: it reads
   `RAVEMediaPolicy.audioEQ`, set by `install()`.

 **What it cannot reach: HLS.** A tap needs real asset tracks and an HLS asset has none (measured,
 macOS 27.2; see `EQAudioTap`). So YouTube's HLS master, the on-device MKV remux, and Jellyfin's and
 Stash's HLS transcodes play unequalised, and each player says so (`AudioEQMenu`'s note) instead of
 showing an EQ that does nothing. The WebKit player isn't reached either (no tap on a web view's
 audio; Raven's Web Audio route reads silence on MSE).
 */

import AVFoundation
import RAVEMedia

@MainActor
enum AudioEQ {
    /// The app's EQ. Touching it (`install()` at launch) also hands it to RAVEMedia's players.
    static let shared: RAVEAudioEQ = {
        let eq = RAVEAudioEQ(defaults: HypnosDefaults.store)
        RAVEMediaPolicy.audioEQ = eq
        return eq
    }()

    /// Call once at launch, before any player exists.
    static func install() { _ = shared }

    /// "Off", a preset's name, or "Custom": what a settings row or a badge says.
    static var statusLabel: String {
        let eq = shared
        guard eq.isActive else { return "Off" }
        return eq.matchingPresetName ?? "Custom"
    }

    /// Why the equalizer isn't shaping this audio, when it isn't; nil when it is (or when nothing
    /// has been learned yet).
    static func explanation(for result: EQAttachResult?) -> String? {
        switch result {
        case .none, .some(.attached):
            nil
        case .some(.noAudioTrack):
            "The equalizer can't reach this sound. Streams played as HLS (YouTube, server transcodes, some MKV files) can't be equalised."
        case .some(.failed):
            "The equalizer couldn't attach to this sound."
        }
    }
}
