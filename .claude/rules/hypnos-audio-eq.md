---
paths:
  - "Hypnos/Hypnos/Services/AudioEQ/**"
  - "Hypnos/Hypnos/Views/AudioEQ/**"
  - "Hypnos/Hypnos/Services/Subtitles/*CaptionAudio.swift"
  - "Packages/GeneratedCaptions/Sources/GeneratedCaptions/*Audio*.swift"
  - "Packages/GeneratedCaptions/Sources/GeneratedCaptions/HLS*.swift"
---

# Hypnos: audio equalizer

One parametric EQ for the whole app (up to 16 bands, shelves, preamp, freehand draw, presets), ported from
Longwave on 2026-11-11. It is the **listener's**, like the volume: one curve, saved in `HypnosDefaults.store`
(`audioEQSettings`, `audioEQCustomPresets`), default off, applied to every player live.

## Where the code is

Not in this app: **RAVESDK's `RAVEMedia/Audio`**, because Raven (its removed Native Player) and Longwave
(`AVAudioEngine`) had their own and this is the third consumer.

- `EQSettings` / `EQPreset` / `EQEditorView`: the model, the RBJ curve maths and the editor, as Longwave left them
  (the editor gained `defaults:` for its presets and a two-row header on a phone).
- `EQProcessor`: the real-time biquad cascade (Double state, per channel, lock-free for the audio thread:
  a `try`-lock picks up new coefficients, enable/preamp changes ramp over a buffer). Tested against the
  analytic response at 32/44.1/48 kHz.
- `EQAudioTap` + `RAVEAudioEQ`: the `MTAudioProcessingTap` and the app-wide controller (`attach(to:player:)`,
  `audioMix(for:)`, `follow(_:)`, auto preamp). `AVPlayerItem.attachAudioEQ(player:)` is the one-liner hosts call
  **once the item has its player**, with `RAVEMediaPolicy.audioEQ` as the app's EQ.
- `EQStreamPlayback` (2026-11-11): the HLS path, below.
- RAVEFilm: `AtmosObjectAudio.equalizer` filters every Atmos object where it renders (linear, so the same
  filter on each object is the EQ on the mix) and the room reverb's four outputs; `FilmPlayer.audioEQ` links it.

Here: `AudioEQ.shared` (the controller, installed in `AppModel.init`, with `StreamEQAudio` as its stream
source), `AudioEQMenu` (bar button: switch, presets, "Edit Equalizer…" sheet), `AudioEQTVMenu` (tvOS UIKit
transport menu: switch + presets), `AudioEQSettings` (Settings → Equalizer; a preset picker on tvOS), and a
section in `MusicAudioOptionsMenu`.

## What it reaches

| Source | Path | Equalised |
|---|---|---|
| Local / Photos video, Stash and Nextcloud originals, Jellyfin Direct Play | `NativeMetalVideoPlayerView` item → tap | yes |
| Stereo (AI 3D / live 3D) player | RAVEMedia engine's item → tap or stream (`RAVEMediaPolicy.audioEQ`) | yes |
| tvOS player | `observe(_:in:)` → tap or stream | yes |
| Jellyfin music | `attachEQ(_:in:)` → tap (direct play) or stream (songs it transcodes, HLS TS) | yes |
| Film player (object audio) | `FilmPlayer.audioEQ` | yes: objects and room |
| **HLS**: YouTube master (packed ADTS; surround EC-3 fMP4), the MKV remux (its fragments), Jellyfin remuxes and transcodes (fMP4), Stash transcodes (TS) | `EQStreamPlayback` | yes |
| tvOS slideshow clips | tap only (muted clips) | files |
| WebKit player | none | **no** |

## HLS: the stream path

**No tap reaches HLS.** Measured on macOS 27.2 (fMP4 and TS HLS, tap attached via `item.tracks` after
`readyToPlay`, before play, and via the asset): `loadTracks(.audio)` is empty, `prepare` never runs. So the EQ
plays the sound itself (`EQStreamPlayback`, RAVEMedia):
- **The audio is read by the AI captions reader** (`StreamEQAudio` → `MatroskaCaptionAudio` for a device remux,
  else `StreamCaptionAudio` → `HLSCaptionAudio` over the playlist, with the stream's credentials; Jellyfin's
  `universal` song URL is followed to the playlist it redirects to). The rendition the player has selected,
  from the playhead; a media-selection change restarts it.
- **It plays through an `AVSampleBufferAudioRenderer` on the item's clock**: a 20 ms loop reads the item's
  timebase against the host clock and keeps an `AVSampleBufferRenderSynchronizer` at the same time and rate
  (pause, stalls, speed), re-set at 30 ms of drift, restarted at the playhead on a jump (a seek). Measured on
  the Mac: within 0.02 ms of the item after start and after a seek (`EQStreamPlaybackTests`).
- **Only 0.3 s is with the renderer** (an EQ change is heard within that); the reader decodes up to 6 s ahead.
- **The player is muted under it only while it sounds.** Before it primes, while it re-primes after a seek, if
  the reader falls behind, and for good if it fails, the player's own (unequalised) sound plays. A write to
  `isMuted` by the app while it holds the player muted becomes the listener's mute; **read
  `AVPlayer.listenerIsMuted`, not `isMuted`**, for what a mute button shows (the players' state reports do).
  `volume`, the time-pitch algorithm and, on visionOS, the player's `intendedSpatialAudioExperience` and the
  item's spatialisation formats are copied to the renderer. Off during AirPlay video.
- **A failure is reported**: `onResult` is called again with `.failed(reason)` and the menu says so
  ("this stream is protected", an unreadable format); a stream with nothing to read is `.noAudioTrack`.
- **Costs**: a Jellyfin or Stash stream that muxes audio into its video segments has the lightest variant's
  segments fetched a second time while the EQ is on (bandwidth, not decoding); YouTube and the remux read audio
  renditions only. 6 s of decoded audio in memory.

**Timing** (`HLSAudioTimingTests` in `Packages/GeneratedCaptions`, five ffmpeg fixtures with a click a second:
fMP4 audio-only and muxed, TS muxed and audio-only, packed ADTS; read from 0 and after a seek). Each click must
land where the container puts it, which with video is on the frame AVPlayer shows (frame k at k/24 s, measured
with `AVPlayerItemVideoOutput`): TS by PTS against the segment's first video frame, fMP4 by its edit lists
(ffmpeg's muxed fMP4 lines audio up with an empty edit and a media time, not in the timestamps; ignoring them
put the audio 21-106 ms off). Seams are clean (largest step the tone's own). **AVPlayer's own decoded audio**
(`AVPlayerItemSampleBufferOutput`, macOS 27.2) reports those clicks 2112 samples earlier on every AAC stream but
audio-only fMP4 (it assumes Apple's AAC priming; ffmpeg's is 1024), and on muxed fMP4 106 ms early. Whether that
is what AVPlayer plays or only how that output labels buffers wasn't settled; the stream path follows the
container. **That output can't replace our reader**: it gives no audio on visionOS 27.2, and doesn't silence the
player.

**Not yet heard on a device**: lip sync on a real YouTube, Jellyfin and Stash stream, the handover glitch when
the EQ's sound takes over or gives back, 5.1 EC-3 through the renderer, and on visionOS whether the renderer's
sound sits where the player's did (it follows the spatial experience, but a player lent to a RealityKit
`VideoPlayerComponent`, the Cinema's HUD, has its sound placed at that entity, which a renderer can't be).

## Decisions and gotchas

- **Pre-effects tap**: EQ first, then volume and mute.
- **A band's centre frequency is clamped below Nyquist** and coefficients are built at the rate `prepare` reports,
  never the 48 kHz display rate: 44.1 kHz audio through 48 kHz coefficients lands every band 8.8% high.
- **Auto preamp lives in `RAVEAudioEQ.settings`'s `didSet`** (as in Longwave's manager), not in the editor:
  the editor leaves it to its host, so any new host of `EQEditorView` must bind to the controller.
- **The Cinema HUD cannot present a sheet**, so `AudioEQMenu` hides "Edit Equalizer…" there
  (`raveImmersivePlayerPresentation != nil`); the switch and presets still work. Edit from the window.
- Preset rows keep the popover open on purpose (auditioning); the switch too.
- Not in Settings → Backup (its fields are an explicit list; nothing for the sleep timer either).
- **Not device-tested.** The tap, the processor, the stream path and the film path are covered by
  RAVEMediaTests/RAVEFilmTests (offline `AVAssetReader` through the real tap; a real `AVPlayer` driving the
  stream renderer) and the builds, and the stream path ran end to end on the Mac against the HLS fixtures (a
  scratch harness, not kept). Nobody has heard it on a headset, a phone, an Apple TV, or checked the film's room
  reverb being EQ'd, the editor's layout on a phone, or the bar's room with the extra button.
