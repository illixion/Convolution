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

## Dependencies

| Library | Used for | Distribution | Licence |
|---|---|---|---|
| [truehdd](https://github.com/truehdd/truehdd) | TrueHD decode (external subprocess) | Source pinned + patched, built locally (`truehdd/build.sh`) | Apache-2.0 |
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
| `GET /AtmosObjects/{itemId}` | `{state, progressSeconds, durationSeconds, error}`, where `state` is `none`, `partial`, `preparing`, `ready`, `unsupported` or `failed` |
| `POST /AtmosObjects/{itemId}/Prepare` | Decodes the whole film into the cache in the background |
| `GET /AtmosObjects/{itemId}/Video` | The video index: segment start times and range info (see [Video](#video)) |
| `GET /AtmosObjects/{itemId}/Video/Init` | The video's fragmented-MP4 init segment |
| `GET /AtmosObjects/{itemId}/Video/Segments/{n}` | Video segment `n`: one keyframe interval, in film time |

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

## Cache and sessions

```
<cache>/v2/<itemId>/scene.json
<cache>/v2/<itemId>/seg/<n>.events.json
<cache>/v2/<itemId>/seg/<n>-<g>.flac      16-bit FLAC with TPDF dither, ≤8 channels
<cache>/v2/<itemId>/video/index.json      keyframe index
<cache>/v2/<itemId>/video/init.mp4        video init segment
<cache>/v2/<itemId>/video/<n>.m4s         video segment n (LRU-trimmed)
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
