---
paths:
  - "Hypnos/Hypnos/Services/AudioEQ/**"
  - "Hypnos/Hypnos/Views/AudioEQ/**"
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
- `EQAudioTap` + `RAVEAudioEQ`: the `MTAudioProcessingTap` and the app-wide controller (`attach(to:)`,
  `audioMix(for:)`, `follow(_:)`, auto preamp). `AVPlayerItem.attachAudioEQ` is the one-liner hosts call after
  creating an item, with `RAVEMediaPolicy.audioEQ` as the app's EQ.
- RAVEFilm: `AtmosObjectAudio.equalizer` filters every Atmos object where it renders (linear, so the same
  filter on each object is the EQ on the mix) and the room reverb's four outputs; `FilmPlayer.audioEQ` links it.

Here: `AudioEQ.shared` (the controller, installed in `AppModel.init`), `AudioEQMenu` (bar button: switch,
presets, "Edit Equalizer…" sheet), `AudioEQTVMenu` (tvOS UIKit transport menu: switch + presets),
`AudioEQSettings` (Settings → Equalizer; a preset picker on tvOS), and a section in
`MusicAudioOptionsMenu`.

## What it reaches

| Source | Path | Equalised |
|---|---|---|
| Local / Photos video, Stash and Nextcloud originals, Jellyfin Direct Play | `NativeMetalVideoPlayerView` item → tap | yes |
| Stereo (AI 3D / live 3D) player | RAVEMedia engine's item → tap (`RAVEMediaPolicy.audioEQ`) | yes, same files |
| tvOS player, tvOS slideshow clips | `makeItem` / slideshow item → tap | yes |
| Jellyfin music | `makePlayerItem` → tap | mp3/aac/m4a/flac/wav/alac (Jellyfin direct-plays them) |
| Film player (object audio) | `FilmPlayer.audioEQ` | yes: objects and room |
| **HLS** (YouTube master, the on-device MKV remux, Jellyfin and Stash transcodes, songs Jellyfin transcodes) | none | **no** |
| WebKit player | none | **no** |

**HLS cannot be tapped.** Measured on macOS 27.2 (fMP4 and TS HLS, tap attached via `item.tracks` after
`readyToPlay`, before play, and via the asset): `loadTracks(.audio)` is empty, `prepare` never runs, no audio
reaches the tap. Files and progressive MP3/MP4 over HTTP work. Raven found the same ("a tap cannot attach to
HLS at all"). So `RAVEAudioEQ.attach` returns `.noAudioTrack`, the item is left alone, and the player's
equalizer menu says why (`AudioEQ.explanation`) instead of showing a switch that does nothing:
`VideoWindowModel.audioEQResult`, `JellyfinMusicSession.eqResult`, the tvOS menu's disabled first row.

**Do not "fix" HLS by playing the audio elsewhere** without a design: it means a second audio path with its own
clock beside AVPlayer (the film player is that, and it is a subsystem). The cheaper levers, if wanted: prefer
Jellyfin Direct Play when the EQ is on and the container is MP4/MOV, or serve the remux progressively.

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
- **Not device-tested.** The tap, the processor and the film path are covered by RAVEMediaTests/RAVEFilmTests
  (offline `AVAssetReader` through the real tap) and the builds; nobody has heard it on a headset, a phone, an
  Apple TV, or checked the film's room reverb being EQ'd, the editor's layout on a phone, or the bar's room with
  the extra button.
