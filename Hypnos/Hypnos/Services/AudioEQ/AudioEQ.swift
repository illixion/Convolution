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

 - **HLS** (YouTube's master, the on-device MKV remux, Jellyfin's and Stash's transcodes, songs
   Jellyfin transcodes), which no tap reaches (measured, macOS 27.2; see `EQAudioTap`): the stream's
   audio is read and decoded here (`StreamEQAudio`, the AI captions reader) and RAVEMedia's
   `EQStreamPlayback` plays it through the curve on the player item's clock, the player muted
   under it. So the players attach the EQ once the item has its player.

 The WebKit player isn't reached (no tap on a web view's audio; Raven's Web Audio route reads
 silence on MSE); a stream whose audio can't be read (encrypted) says so in its menu.
 */

import AVFoundation
import RAVEMedia

@MainActor
enum AudioEQ {
    /// The app's EQ. Touching it (`install()` at launch) also hands it to RAVEMedia's players.
    static let shared: RAVEAudioEQ = {
        let eq = RAVEAudioEQ(defaults: HypnosDefaults.store)
        eq.streamSource = { item, start in try await StreamEQAudio.reader(item: item, start: start) }
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
        case .none, .some(.attached), .some(.streamed):
            nil
        case .some(.noAudioTrack):
            "The equalizer can't reach this sound."
        case .some(.failed(let reason)):
            "The equalizer couldn't shape this sound: \(reason)"
        }
    }
}
