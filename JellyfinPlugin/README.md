# Atmos Objects (Jellyfin plugin)

Serves the Atmos objects inside a film's audio track as separate audio stems
plus their position metadata, so Convolution can place its own spatial sources on
the Vision Pro instead of needing a Dolby renderer. No Dolby code is involved.
Two source formats are supported, picked per item (TrueHD preferred, since
it's the higher-quality format and lossless; EAC3 as a fallback):

- **TrueHD Atmos** — decoded by an external subprocess,
  [truehdd](https://github.com/truehdd/truehdd), an open-source TrueHD
  decoder, with a small patch of ours (below).
- **E-AC-3 with JOC objects** (Dolby Digital Plus Atmos) — decoded in-process
  by [Cavern](https://github.com/VoidXH/Cavern), an open-source spatial audio
  engine, via its `Cavern.Format` NuGet package. See "Dependencies" below for
  the licence terms this brings — Cavern must stay confined to this plugin.

Either way the plugin's own output — `scene.json`, segment Events (DAMF
room-space positions), FLAC channel groups — is identical, so Convolution clients
need no changes to play either source. See `Eac3AtmosDecoder.cs` for the
Cavern→DAMF coordinate mapping and why E-AC-3 needs no restart-point search
the way TrueHD does.

Decoding is live: a client can start or seek anywhere in a film and the
plugin decodes from that point on request. It serves the first segment about
a second later, and each segment it decodes is cached for next time.

## Blu-ray discs (ISO or BDMV folder)

ffmpeg reads a disc only through its `bluray:` input (libbluray), which reads
an ISO at a few MB/s and can't seek in usable time: on servo a cut an hour
into *Bumblebee 3D* took 75 s to start, and passing the raw `.iso` path the
way a file is passed fails outright. For a disc item (`VideoType` BluRay, or
an ISO whose `IsoType` is BluRay) the plugin instead feeds ffmpeg through its
stdin from `vergence stream DISC --seek S` (`DiscFeed.cs`). Vergence is an MIT
Swift Blu-ray reader (not yet published) that jumps to the clip entry point
before `S` straight from the disc's EP map. It writes the feature
playlist's own clips, so ffmpeg sees the streams in the order Jellyfin's
`bluray:` probe lists them, and with the clip's own timestamps, which `bluray:` passes
through as well. The stream indexes in MediaStreams, the origin probe and the
seek arithmetic are unchanged; Vergence seeks in playlist time, so the plugin
subtracts the origin. Measured on servo with the same pipeline: first decoded
audio 3.7 s after a seek to one hour, then about 6.5× realtime.

Blu-ray carries object audio only in TrueHD, so a disc has no E-AC-3 path.
## Audio tracks

`GET /AtmosObjects/{id}/Tracks?languages=eng,deu` lists an item's object-audio
tracks (TrueHD first, then E-AC-3; a disc has only TrueHD) with index, codec,
language and a display title, the default marked. Every audio request takes
`audioStream=<index>` to name a track; each track is its own scene, decoded and
cached separately (`AtmosTracks.cs`: the scene id is derived from the item id and
the stream index), so switching back and forth keeps both. Without
`audioStream`, the default is the first track in the first of `languages` (a
client sends its device languages), then `PreferredAudioLanguage` (default
`eng`), then the first track; codes are compared in ISO 639-2/T form (`ger` and
`de` count as `deu`). `bluray:` reports no languages, so a disc's come from
`vergence streams` (the playlist's STN table), matched to ffmpeg's index by PID;
*Bumblebee 3D* is a German release that lists German first. A cache from before
per-track scenes is adopted by its track's scene (`track.txt`, else the first
TrueHD track).
Known limits: both tools pick the feature as the longest title (Vergence the
longest 3D one), which agrees on ordinary discs; a feature made of several
clips restarts its timestamps at each clip, as it does through `bluray:`.

## Dependencies

| Library | Used for | Distribution | Licence |
|---|---|---|---|
| [truehdd](https://github.com/truehdd/truehdd) | TrueHD decode (external subprocess) | Source pinned + patched, built locally (`truehdd/build.sh`) | Apache-2.0 |
| Vergence | Reading Blu-ray ISOs and folders (external subprocess, disc items only) | Built from source (`swift build -c release`) | MIT |
| [Cavern](https://github.com/VoidXH/Cavern) / `Cavern.Format` | E-AC-3 JOC decode (in-process) | Official NuGet packages, `Cavern`/`Cavern.Format` 2.1.0, referenced by the `.csproj` | Custom, free but requires crediting the creator — see below |

Full licence texts and the required Cavern credit are in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) at the repo root.
**Cavern's licence requires naming the creator with a link
(<http://en.sbence.hu>) wherever it's used publicly or commercially** — that
credit is in the notices file; don't drop it if this plugin is redistributed.

## Install

1. Build the plugin: `dotnet build Jellyfin.Plugin.AtmosObjects -c Release`.
   This targets .NET 9 and Jellyfin 10.11. `Cavern`/`Cavern.Format` restore
   from NuGet automatically; nothing extra to build for the EAC3 path.
2. Build truehdd (only needed for the TrueHD path — EAC3 items decode without
   it): `truehdd/build.sh`. It clones upstream at a pinned commit, applies
   `truehdd/*.patch` and runs `cargo build --release`.
3. Copy `bin/Release/net9.0/Jellyfin.Plugin.AtmosObjects.dll` into
   `<jellyfin data>/plugins/AtmosObjects_0.1.0.0/` (this now also carries the
   `Cavern.dll`/`Cavern.Format.dll` NuGet assemblies — `dotnet build` copies
   them into the same output folder, no separate step), and point the plugin
   at truehdd in
   `<jellyfin data>/plugins/configurations/Jellyfin.Plugin.AtmosObjects.xml`:

   ```xml
   <PluginConfiguration>
     <TruehddPath>/path/to/truehdd/checkout/target/release/truehdd</TruehddPath>
     <Mvc3dPath />                 <!-- empty: vergence (or mvc3d, from before the rename) next to the default truehdd; only Blu-ray items need it -->
     <PreferredAudioLanguage>eng</PreferredAudioLanguage>  <!-- ISO 639-2, among several object-audio tracks -->
     <CacheDirectory />            <!-- empty: <jellyfin cache>/atmos-objects -->
     <SegmentSeconds>10</SegmentSeconds>
     <EncoderParallelism>4</EncoderParallelism>
     <VideoCacheMegabytes>4096</VideoCacheMegabytes>
   </PluginConfiguration>
   ```
4. Restart Jellyfin.

### The truehdd patch

Upstream truehdd writes object audio only as a CAF file, and it seeks back
at the end to fill in the length, so the audio can't be read while the
decode is still running. `truehdd/audio-stdout.patch` adds
`decode --audio-stdout`, which streams the same samples to stdout as raw
24-bit little-endian PCM. The DAMF header and metadata still go to files;
upstream already flushes the metadata after every update. The patch is small
and self-contained, and could be offered upstream.

## API

Every endpoint needs normal Jellyfin authentication (an API key or a user token).

| Request | Returns |
|---|---|
| `GET /AtmosObjects/{itemId}/Scene?startSeconds=T` | The layout. With nothing cached, it starts a decode at `T` and waits for it. 422 if the track has no objects |
| `GET /AtmosObjects/{itemId}/Segments/{n}/Events` | Position/gain events for segment `n` |
| `GET /AtmosObjects/{itemId}/Segments/{n}/{g}` | FLAC audio for segment `n`, channel group `g` |
| `GET /AtmosObjects/{itemId}/Segments/{n}/Bundle?codec=aac\|opus&bitrate=B&budget=T` | Every channel of segment `n` in one lossy bundle: `B` the average bits per second per audible channel, `T` an optional cap on the whole segment (see [Compressed bundles](#compressed-bundles)) |
| `GET /AtmosObjects/{itemId}` | `{state, progressSeconds, durationSeconds, error}`, where `state` is `none`, `partial`, `preparing`, `ready`, `unsupported` or `failed` |
| `POST /AtmosObjects/{itemId}/Prepare` | Decodes the whole film into the cache in the background |
| `GET /AtmosObjects/{itemId}/Video` | The video index: segment start times and range info (see [Video](#video)) |
| `GET /AtmosObjects/{itemId}/Video/Init` | The video's fragmented-MP4 init segment |
| `GET /AtmosObjects/{itemId}/Video/Segments/{n}` | Video segment `n`: one keyframe interval, in film time |

| `GET /Spatial/{itemId}` | Whether the item is spatial video, and its side-by-side stream: `{spatial, reason, width, height, eyeWidth, eyeHeight, video3DFormat, hdr, durationSeconds, segmentSeconds, segments, bitsPerSecond, playlist}` (see [Spatial video](#spatial-video)) |
| `GET /Spatial/{itemId}/main.m3u8` | HLS media playlist of the side-by-side stream |
| `GET /Spatial/{itemId}/init.mp4`, `/Segments/{n}.m4s` | Its init segment and segment `n`, converted on request |

A segment request waits until that segment has been decoded, up to 45 s. It
starts a decode at that segment unless one is already running just before
it.

The layout (`scene.json`, version 2) contains:

- `sampleRate`, `segmentFrames` and `segmentCount`.
- `frameCount`: estimated from the item's runtime until a decode reaches the
  end; `frameCountExact` says which.
- `groups`: the audio channels in each group's FLAC, in file order.
- `startSeconds`: the container time of frame 0, which is the audio
  track's first access unit (TrueHD) or the first sample of the EAC3 decode.
- `elements`: `{id, channel, kind: bed|object, bedChannel?}`.

Events are `{id, t, ramp, gain, pos?}`:
- `t` and `ramp` are scene frames and `gain` is in dB.
- `pos` is DAMF room space: x from −1 (left) to +1 (right), y from −1 (back)
  to +1 (front), z from 0 (ear level) to 1 (ceiling).
- A position is reached linearly over `ramp` frames.
- Each segment's list opens with a snapshot of every element as it stands at
  the segment's first frame, so a segment can be used on its own.

## Compressed bundles

For links that can't carry lossless object audio (cellular, a hotel's Wi-Fi), a
segment can be fetched as one bundle holding a mono AAC (M4A) or Opus (Ogg)
stream per channel. The scene's `bundleCodecs` lists what the plugin serves; a
client that doesn't see it stays on FLAC. Bundles are made from the cached FLAC
the first time they're asked for and kept next to it
(`seg/<n>.<codec>-<kbps>k[-t<kbps>k].b2.aob`).

- **`bitrate` is the average per audible channel, `budget` the cap on the
  whole segment.** `bitrate` is 16–256 kbps in steps of 8 (default 64): each
  distinct value is a file kept for every segment, so a request is rounded to
  it. `budget` is bits per second as sent, containers included, in steps of
  32 kbps from 64 kbps; with it a client says what its link carries however
  many channels the scene has (128 audible channels at 64 kbps would be
  8 Mbps).
- **The bits are not shared evenly** (`BundlePlanner`). Every channel is its
  own stream, so a flat rate spends as much on the low-frequency bed and on a
  whisper under the mix as on the dialogue. Instead:
  - The LFE gets a third of the average (16–32 kbps), and what it doesn't use
    goes to the others. It is not low-passed first: a 160 Hz biquad delays it
    1.5 ms against every other channel for a 1% saving, which the encoder's
    own bandwidth at that rate gives anyway.
  - Roles come from **where the element sits** in the segment's events, not
    from its bed name: a Dolby Atmos track's only bed is usually the LFE (the
    speaker channels arrive as objects; the demo's centre is an object at
    (0, 1, 0)). Front centre, where dialogue is, weighs 1.5; the rest of the
    front stage 1.25.
  - Coding noise is heard against the mix, so a channel far under the loudest
    needs fewer bits: weight 1 within 12 dB of it, falling to 0.45 at 48 dB
    under (about 1 kbps per dB at 64 kbps).
  - Nobody gets under half the average, or over twice it.
  - Levels include the element's metadata gain, which the client applies: a
    channel its gain mutes is silent whatever its PCM holds, and isn't sent.
  - Under a budget the floors fall to 16 kbps, and past that the quietest
    channels are **left out** rather than every channel coded badly. A left-out
    channel has no stream but an audible peak in the header.
- **One request per segment, whatever the channel count.** A scene with
  hundreds of objects would otherwise be hundreds of requests per segment.
- **One mono stream per channel.** Objects are rendered one by one, so joint
  stereo coding has nothing to exploit, and mono never meets an encoder's
  channel-layout limits (`libfdk_aac` and Apple's decoders top out at 8
  channels; Apple won't decode multichannel Ogg Opus at all).
- **Silent channels aren't sent.** Idle objects cost 12 header bytes. The
  FLAC is dithered, so "silent" means a peak under −80 dBFS.
- **Each stream starts with 100 ms of the previous segment** (pre-roll), which
  the client drops. Measured on a chirp: at a join, the error RMS was 0.0057
  for one continuous encode, 0.0069 with the pre-roll and 0.0086 without.
  The decoded audio lines up with the FLAC to the sample, on every channel
  (check lags, not just SNR: an aligned comparison hid a filter's delay once).
- **Per-channel RMS and peak in the header**, as heard (gain included), so a
  client that can't decode everything before the segment plays can keep the
  loudest channels.
- AAC is AAC-LC through `libfdk_aac`. jellyfin-ffmpeg's build has no HE-AAC
  ("Unable to set the AOT 5"). Its M4A container costs about 2.6 kbps a stream
  (a 16 kbps stream comes to 18.8): `budget` accounts for it.

Layout, little-endian, version 1:

| Offset | Field |
|---|---|
| 0 | `"AOB1"` |
| 4 | u16 version (1) |
| 6 | u16 codec: 1 AAC/M4A, 2 Opus/Ogg |
| 8 | u32 sample rate |
| 12 | u32 frames in the segment |
| 16 | u32 pre-roll frames |
| 20 | u32 channel count (the scene's channels, in channel order) |
| 24 | per channel, 12 bytes: u32 stream length (0 = not sent), f32 RMS dBFS, f32 peak dBFS (both as heard). Not sent with a peak under −80: silent. Not sent above it: left out for the budget |
| … | the streams, in channel order; each decodes to pre-roll + frames samples |

Measured on the Dolby demo (12 channels, 10 s segments; 8–10 audible), against
the same audio at a flat rate and the same bytes (waveform SNR of the sum of
all channels against the sum of their errors, as a stand-in for what is heard
against the mix):

| Segment, rate | Flat | Planned |
|---|---|---|
| 3 @ 64 kbps | 18.96 dB | 19.17 dB |
| 5 @ 64 kbps | 25.24 dB | 27.17 dB |
| 5 @ 32 kbps | 17.45 dB | 19.18 dB |
| 9 @ 32 kbps | 25.42 dB | 27.43 dB |
| 2 @ 32 kbps | 24.38 dB | 24.50 dB |

The gain is small where the channels are alike and up to 2 dB where the LFE or
a quiet channel was being overpaid; it was never negative. The centre gains
1.8 dB of its own SNR. The LFE at a third of the average still decodes at 29–40
dB SNR, with its noise 67–72 dB under full scale. The budget holds: 192 / 96 /
64 kbps requests came to 196 / 96 / 65 kbps on the wire.

Overall: FLAC 3.99 MB (3.2 Mbps) against 0.67–0.84 MB (AAC at 64 kbps); built
in about 0.4 s. Server cost: one encoder run of 64 mono 10 s channels takes
0.71 s (AAC) or 1.17 s (Opus) in the dev container, and runs go
`EncoderParallelism` at a time. Client cost (RAVEFilm, M-series Mac): 224 AAC
channels × 10 s decode in 0.31 s on 6 cores. `dotnet run` on
`JellyfinPlugin/BundlePlannerCheck` checks the planner's rules.

A client on Android or a Quest decodes the Opus streams with libopus or
MediaCodec (`audio/opus`, after reading the Ogg pages); the bundle needs
nothing else from the platform. Ogg's pages cost nothing worth counting and
the encoder runs variable-rate, so an Opus bundle comes in at or under what
was asked.

## Video

The plugin also serves the film's video track, copied untouched, so a
client can render it on the same clock as the object audio (Convolution feeds it
to `AVSampleBufferDisplayLayer`, which does the decoding and Dolby Vision
display management itself).

- **Segments are keyframe intervals** read from the Matroska Cues, the
  file's own seek index. Reading it takes a fraction of a second, where
  scanning packets would read the whole file. On a UHD remux the intervals
  run 1–10 s, 5 s on average. Only Matroska is supported for now.
- **Each segment is fragmented MP4 in film time:** its first frame presents
  at `segmentStarts[n]`, the same time base as the scene's `startSeconds`.
- **Dolby Vision profiles 5, 8 and 10 keep their configuration** (`dvh1`
  with `dvcC`/`dvvC`). Profile 7's enhancement layer can't be decoded on
  Apple hardware, so it is served as its HDR10 base layer (`hvc1`).

The index (`index.json`) contains `segmentStarts`, `durationSeconds`,
`codec`, `videoRange` (Jellyfin's range type), `dvProfile` and
`dolbyVision`.

A request for a segment that isn't cached starts a run: jellyfin-ffmpeg seeks
and copies up to two minutes of video through its HLS muxer, split at every
keyframe, and each finished segment is moved into the cache. Two ffmpeg
quirks are corrected rather than trusted to flags:

- **The seek can land one keyframe interval early.** A second output
  (`mkvtimestamp_v2`) reports the first packet's original decode time,
  which identifies the keyframe the run really starts on.
- **The HLS muxer rebases timestamps to zero.** Each segment's `tfdt` is
  shifted back so its first frame presents at the keyframe's film time.

Segments are the film's own bitstream, so a full cache would duplicate the
file. Beyond `VideoCacheMegabytes` per item (default 4096) the least
recently used segments are dropped.

On The Wild Robot (UHD, Dolby Vision profile 8.1), from a Mac over the tailnet:
- The index is served in 0.26 s.
- A cold mid-film segment arrives in 1–2 s.
- Segments the same run has already copied arrive in about 0.1 s.
- Consecutive segments are continuous in decode time, and each first frame
  lands on its index time within the Cues' 1 ms rounding.

## How live decoding stays sample-exact

Segments from different decodes must line up to the sample, because a seek
can start a new decode while neighbouring segments came from an older one.

1. jellyfin-ffmpeg seeks and copies the TrueHD track out as Matroska
   (`-c copy -copyts`), so every packet keeps its container timestamp.
2. Packets are held back until there is a continuous run that starts at a
   major sync (a TrueHD restart point). Right after a seek, the Matroska
   demuxer delivers the restart-point packet and then jumps a whole restart
   interval ahead. Any timestamp gap drops the run.
3. Every access unit holds a fixed number of samples (40 at 48 kHz), and
   timestamps are rounded to 1 ms. Intersecting the windows allowed by a
   few hundred consecutive packets leaves exactly one possible start frame.
4. The run is fed to truehdd, which decodes it from its first access unit.
   The decoded PCM is placed on the global segment grid, and any partial
   segment at the start is dropped.

On an Endgame UHD remux:
- A decode cut at 20:34 and one cut at 1:30:00 each matched a continuous
  decode of the whole film to the sample.
- The same segment decoded from two different cut points gave bit-identical
  FLAC and identical events.

## EAC3: coordinate mapping and verification

`Eac3AtmosDecoder.cs` decodes E-AC-3+JOC with Cavern instead of solving for a
restart-point run: E-AC-3 frames are independently decodable, so the plugin
just has ffmpeg stream the track as a raw `.ec3` elementary stream on stdout,
from a little before the target segment. The raw stream carries no
timestamps, so a one-packet ffmpeg run with the same input arguments
(`-copyts`, `framecrc` output) reports the container time the cut lands on
first; ffprobe's `-read_intervals` seek read linearly through a 4K Matroska
file on a USB disk and took minutes. Cavern decodes the pipe as it arrives, a short warm-up prefix
(`Eac3PrerollSeconds`, 0.75 s) is discarded, and the rest feeds the same
`Grid` class the TrueHD path uses. The session stops, and kills its ffmpeg,
under the same rules as TrueHD: a newer seek, reaching already-cached
segments, or 10 minutes without a request. Cutting to a file first instead
would make ffmpeg demux to the end of the film before the first segment.

**Cavern → DAMF coordinate mapping**, worked out from
`ObjectInfoBlock.UpdateSource` in Cavern.Format
(`Decoders/EnhancedAC3/ObjectInfoBlock.cs`), whose final line returns
`Listener.EnvironmentSize * new Vector3(x*2-1, rawZ, y*-2+1)` for an OAMD
object's own room-relative coordinates `x`/`y`/`z` (left-right, front-back,
floor-ceiling, each roughly 0..1, raw `z` roughly -1..1):

| DAMF | Cavern world axis | Formula |
|---|---|---|
| `x` (−1 left … +1 right) | `Position.X` | `x / EnvironmentSize.X` |
| `y` (−1 back … +1 front) | `Position.Z` (**not** `.Y`) | `z_cavern / EnvironmentSize.Z` |
| `z` (0 ear … 1 ceiling) | `Position.Y` (Cavern's up axis) | `clamp(y_cavern / EnvironmentSize.Y, 0, 1)` |

X carries straight over; DAMF's front-back `y` is Cavern's *depth* axis
(named `Z` there); DAMF's floor-ceiling `z` is Cavern's *up* axis (named `Y`
there, and clamped to 0 since DAMF has no below-ear-level convention — nor
does truehdd's own TrueHD DAMF output ever emit a negative `z`).

**Verified against the public Dolby Atmos demo** (`DolbyElement4K_VisionAtmos.mkv`,
110 s, TrueHD + EAC3/JOC tracks over the same picture — see
`scripts/dev-jellyfin.sh`'s seeded items) two ways:
- A standalone decode of the EAC3 track (Cavern directly, before this
  mapping reached the plugin) found two objects pinned at the ceiling
  (Cavern's raw, un-mapped Y ≈ 1.0 for ~68% of the run) — through the
  mapping above they come out at `z` within 0.01 of 1.0, as expected.
- **Cross-checked against truehdd's own DAMF output for the same demo's
  TrueHD track**: its two elevated objects (IDs 16/17 in that decode) sit at
  `pos: [-1, 0, 1]` and `[1, 0, 1]` — **exactly** the positions the EAC3 path
  reports for its own two elevated objects (element ids 7/8) through the
  plugin's live `/Segments/{n}/Events` endpoint on the dev instance. The
  non-elevated objects' left/right/front/back spread matches too (front-left,
  front-center, left-side, right-side, back-left, back-right, plus one object
  panning left→right — the same quantized position set turns up in both
  decodes of the same content).

**Decode speed** (this Mac, EAC3 → Cavern, inside the dev Jellyfin
container): a cold decode of the full 109.8 s track — ffmpeg's stream-copy
cut plus Cavern's decode plus FLAC-encoding all 11 segments × 2 channel
groups — completed in 11.8 s wall clock, **≈9.3× real time**.

**A Cavern.Format 2.1.0 bug worth knowing about**: `EnhancedAC3Renderer.Dispose()`
unconditionally disposes its `JointObjectCodingApplier`, which is only ever
constructed on the object-based (JOC) rendering path — decoding a plain,
channel-based E-AC-3 track (no JOC objects at all) and then disposing the
renderer throws `NullReferenceException` inside Cavern's own `Dispose()`.
`DecodeEac3Async` works around this by checking `HasObjects` **before**
entering the `using (renderer)` block, so a no-objects renderer is never
disposed at all (safe here — nothing else holds an unmanaged handle through
it; the underlying reader is disposed separately). Confirmed against
`NoAtmosTest.mkv`, the dev instance's plain-EAC3 seeded item.

## Spatial video

A Vision Pro or iPhone recording is MV-HEVC: two views in one HEVC stream,
of which a Quest or an Android phone decodes only the first. The plugin
streams such an item side by side instead (full resolution per eye, BT.709,
the stereo AAC copied), converting while it plays with Vergence's
`vergence sbs --segments` (the same CLI the disc path uses). Nothing is
converted ahead of time, and the whole video is never stored:

- **`GET /Spatial/{itemId}`** asks `vergence sbs --info` once per item (only
  for HEVC in MOV/MP4; anything else is answered at once) and keeps the
  answer in `info.json`, until the file changes (not when vergence is missing
  or fails, so installing or updating it needs no restart). Convolution's Quest app asks
  for every HEVC MOV/MP4 it plays, and plays `playlist` instead of the file
  when `spatial` is true, as `video3DFormat` (`FullSideBySide`).
- **Segments are on a fixed grid** (`SpatialSegmentSeconds`, default 4 s, from
  the start), not the recording's own keyframes, so a segment's number says
  where it is. Each starts with a keyframe and carries the video's own times,
  so any one can be made alone and segments made by different runs play as
  one stream.
- **A request for a segment that isn't cached starts a run**: `vergence`
  converts two minutes from that segment, and each segment is served the
  moment it is written. A run stops before a segment that is already cached,
  so rewatching converts only what is missing. A request well past a run's
  progress (a seek) cancels it and starts another there; a run nobody has
  asked anything of for two minutes stops.
- **At most `SpatialRuns` (default 2) convert at once** on the server; beyond
  that, the run whose viewer asked least recently stops.
- **The cache is shared and capped**: `SpatialCacheMegabytes` (default 4096)
  for all items together, the least recently served segments dropped first.
  A Vision Pro recording at the default quality is about 35 Mbps, 16 MB a
  segment, so the default keeps about 15 minutes.
- **`SpatialHalfWidth`, `SpatialMaxEye` and `SpatialQuality`** (low, standard,
  high, max) set the picture. The segments of each setting are kept apart.

`dotnet run` on `JellyfinPlugin/SpatialStreamCheck` checks these rules (the
playlist, run ranges, what a seek or the run limit stops, cache trimming and
when `info.json` holds), which live in `SpatialStreamPlanning.cs`.

Decoding MV-HEVC needs Apple's frameworks: this works on a Jellyfin server
running on a Mac (`Mvc3dPath` names `vergence`), and elsewhere every item
answers `spatial: false` with the reason. Converting 4400×2200 runs at about
40 fps on an M5 MacBook Pro, so a 30 fps recording streams with a little to
spare; set `SpatialMaxEye` (1920 gives 3840×1920) on a slower Mac.

Tested on Jellyfin 10.11.11 on macOS with a Vision Pro recording: the stream
fetched in any order, or played straight through by ffmpeg and AVPlayer
(seeks included), holds every frame once at its own time (within 2 ticks of
1/96000 s) and every audio packet, joined across runs.

## Cache and sessions

```
<cache>/v2/<itemId>/scene.json
<cache>/v2/<itemId>/seg/<n>.events.json
<cache>/v2/<itemId>/seg/<n>-<g>.flac      16-bit FLAC with TPDF dither, ≤8 channels
<cache>/v2/<itemId>/video/index.json      keyframe index
<cache>/v2/<itemId>/video/init.mp4        video init segment
<cache>/v2/<itemId>/video/<n>.m4s         video segment n (LRU-trimmed)
<cache>/spatial/<itemId>/<variant>/info.json   what vergence --info said
<cache>/spatial/<itemId>/<variant>/init.mp4    side-by-side init segment
<cache>/spatial/<itemId>/<variant>/<n>.m4s     side-by-side segment n (LRU-trimmed across items)
```

- A segment counts as cached once its last group's FLAC exists. Each file is
  written under a temporary name and then renamed into place.
- A decode keeps running ahead of the viewer. It stops at the end of the
  film, after running into two cached segments, or when nobody has asked for
  the item in 10 minutes.
- Reaching the end records the exact frame count. If every segment is then
  cached, the item is marked `ready`.
- The kept FLAC costs about 1 GB per hour of film.
- A track that decodes cleanly without an Atmos object presentation (TrueHD)
  or without any JOC dynamic objects (EAC3) is marked `unsupported` and isn't
  retried. An item with neither a TrueHD nor an EAC3 audio track at all is
  marked `unsupported` immediately, with no decode attempt.
