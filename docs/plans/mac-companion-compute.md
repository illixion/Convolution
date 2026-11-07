# A Mac doing the heavy work for the headset

Status: plan, restored 2026-11-07 from the 2026-11-01 Smooth Motion work, where it was agreed ("the
plan sounds good… we should start code-sharing", user, 2026-11-01) and kept as a short "later" section
of `blu-ray-3d-smooth-motion.md`. The transport and the data format have been built since; the live
Mac has not been started.

## Goal

The headset's own compute, not its displays, sets the picture quality today:
- **Smooth Motion:** flow runs at a quarter of the eye's size, because RIFE at 960×576 takes 48 ms on
  the headset's ANE.
- **AI 3D real-time:** uses the small depth model (~28 ms a map, 38–45 ms beside the interpolator),
  holds depth for up to a frame, and steps quality down when warm.
- **AI HDR for video:** would have to share the same Neural Engine.

A paired Mac has a GPU about 1.5× the headset's and nothing else to do. So the Mac runs the networks
at full working size, and the headset only presents: warps, blends, gain lookups and the compositor.
The aim is to use what the displays can show:
- in-between frames at the display's rate (96 Hz for 24 fps, 100/120 for 50/60);
- the pre-processed depth quality without waiting for a conversion;
- HDR highlights within the measured 2.5–3× headroom.

The Mac is the user's own computer (this M2 Max), Convolution's own macOS build, and nothing new to
install.

## Principles (agreed 2026-11-01)

1. **Results cross, never frames.** The Mac opens the same media and decodes it itself, then sends
   back only small fields keyed by presentation time.
2. **One format for every producer.** Vergence's analysis track (`VergenceCore/AnalysisTrack.swift`)
   is written by the `vergence analyze` CLI, the Jellyfin plugin and, next, the live Mac. Record kinds
   already exist for `flowPair`, `disparity`, `depth` and `gainMap`.
3. **Split by time.** The headset asks for what is ahead of the playhead, and the Mac works ahead of
   it. On a seek the headset asks for the new place and the old requests are cancelled.
4. **The headset never waits.** A missing or late record means the headset's own quarter-size work,
   or a pass-through, exactly as with a server chunk that hasn't arrived. A dropped connection means
   headset-only. Playback never holds for the Mac.

## What is built

| Piece | Where | State |
| --- | --- | --- |
| Pairing and encrypted channels | RAVESDK `RAVECompanion` (d302e78), lifted from Longwave (fa7a9f1) | Longwave runs on it; wire format pinned by golden vectors; **pairing not yet tested on hardware**. Hypnos does not link it yet |
| Analysis track format | Vergence `AnalysisTrack` (6abe4b0) | Used. Flow + disparity ≈ 25 KB a frame |
| Producer | `vergence analyze` (VergenceCLI) | Mac, 35–39 fps on the M2 Max (flow + disparity, 1080p 3D). CLI only: reads raw frames piped from ffmpeg |
| Chunked consumer | Vergence `StreamingAnalysisTrack` + Hypnos `SmoothMotionTracks` | Plays tracks from the Jellyfin plugin in 10 s chunks (≈ 4.4 MB each). The fetch is the caller's |
| Player passes | Vergence `SharedFieldInterpolator` | 3D discs and live 3D Library titles |

The chunked consumer is the key piece: **the live Mac can answer the same chunk requests the plugin
answers**, so the headset side is one more fetcher behind `StreamingAnalysisTrack`, not a new
pipeline.

## Workloads

| Workload | Headset alone (M5) | On the Mac | Record kind | Headset's part |
| --- | --- | --- | --- | --- |
| Smooth Motion, 3D titles | NeuFlow 512×288, 14 ms | Already produced offline. Live adds titles the server hasn't analysed | `flowPair`, `disparity` | `SharedFieldInterpolator`, ~2 ms |
| Smooth Motion, 2D and AI 3D | VideoToolbox (≤1080p, 15–19 ms on the ANE) or GPU flow | RIFE 960×576, 13.5 ms on the M2 Max GPU | `flowPair` (one eye) | A mono shared-field pass (new; the stereo one is the template) |
| AI 3D depth | Real-time model, ~28 ms, ≤1-frame hold | A larger depth model at a larger size, with the pre-processed path's refinement (bilateral, ±2-frame lookahead, cut-aware range) | `depth` | Warp only; the ANE is left idle |
| AI HDR for video | GMNet keyframes competing for the ANE | GMNet every few frames or every frame, fitted to a gain grid | `gainMap` (grid layout to pin) | One 3D-texture lookup in the warp or draw shader |

With every workload on the Mac, the headset's Neural Engine is idle, and its GPU runs only the
presentation shaders.

### AI HDR for video, in short (proposed 2026-11-07, not started)

It is meant to work on the headset alone too, with the Mac as a quality upgrade.
- **Gain grid, not gain image:**
  - GMNet (the photos' AI HDR model) runs on keyframes: every cut, plus about every 0.5–1 s.
  - Its gain map is fitted into a bilateral grid, gain over (x, y, luma), e.g. 16×9×8.
  - Every frame looks its gain up with its own luma. Moving highlights keep their boost, and
    in-between frames and both stereo eyes get consistent gains for free.
- **SDR until the last shader:** interpolation and depth see SDR, which their models are trained on.
  The expansion is folded into the shader that already runs:
  - `imageFragmentShader` into an EDR `rgba16Float` drawable for flat video;
  - an SDR-in/PQ-out variant of the stereo warp into the pump's existing `xf20` HDR eyes for AI 3D.
  - The pump's reserve stays BGRA.
- **Stable within a shot:**
  - Ease the grid between keyframes and snap at cuts, using the depth pipeline's luma-grid cut
    detector.
  - Ramp in on engage and after a seek.
  - Cap the frame-average gain below the window brightness limiter (2.5–3×).
- **Step-down order on the headset:** keep depth first, then interpolation, then HDR updates (to cuts
  only, then the held grid). Never switch it off mid-shot.
- **Unknown cost:** the photo path's 0.63 s includes CPU resampling of a full-resolution photo and
  enumerated input shapes. The first step is a fixed-shape 512×288 conversion timed on the headset,
  on the ANE and the GPU.

## Design

### Mac: worker mode in Convolution for macOS

- **Hosting:** a `RAVECompanion` host under Convolution's own namespace (not `.longwave`, so the two
  never answer each other), announced over Bonjour. Ports open only while a paired device knocks.
- **Pairing:** the six-digit pairing from Settings on both sides.
- **Running:** the app can work as a menu-bar or background worker with no window open. While
  serving, it holds a power assertion so the Mac doesn't sleep.
- **Producer as a library:** `analyze`'s producer moves out of VergenceCLI into a library target that
  the app and the CLI share. It decodes with AVFoundation instead of ffmpeg, which also gives it Stash
  and Jellyfin URLs.

### Channel

- **Request:**
  - media identity, the exact stream (see below), kinds and quality;
  - "chunk n" in the plugin's chunk terms;
  - a lead hint: the playhead and the rate.
- **Reply:** a chunk as a small analysis track, the same bytes `SmoothMotionService` serves, so one
  consumer path handles both.
- **Chunk length:** 10 s chunks are too coarse for live work. On the M2 Max, the first 10 s chunk of
  24 fps material is ready about 7 s after a seek. Use 2 s chunks live, or stream records within a
  chunk as they're made.
- **Cancel:** a seek cancels outstanding chunks.

### Headset

- **Precedence:** a local file, then a finished server track, then the live Mac, then the headset's
  own work. This is per chunk, so a Mac can fill gaps in a partly analysed server track.
- **Governor:** when Mac records arrive within their lead, the headset's own interpolation and depth
  steps stand down, but stay warm for an instant fallback.
- **Display rate:** chosen from what is actually arriving. A 96 Hz request is made only when the
  flow fields for the next chunk are there.

## Open questions

1. **Same frames on both sides.** Records are keyed by presentation time. A Jellyfin *transcode* is
   per play session, and its start offset depends on where it began. If the Mac opens its own
   transcode it can drift from the headset's, and reusing the headset's play session might end
   it. Proposal: the Mac always reads the **original file**, the plugin's own route, and keys
   records by media time. Flow, depth and gain maps are smooth, so a different resolution only
   rescales them.
2. **Media access.** Prefer a short-lived authorised URL handed over the encrypted channel, so the
   Mac stores no Stash or Jellyfin keys. Alternatively `RAVEDeviceSetup`'s QR code can copy the
   credentials once.
3. **Files only on the headset** (Local, shared files). The Mac can't open them. The headset would
   serve the file's bytes to the Mac over the channel, in pieces as the MKV remux reads them. This
   doesn't break principle 1: it sends the compressed file, never decoded frames.
4. **Lead after open and seek.** The first second or two is always headset-only. That's acceptable
   if the switch from the headset's own fields to the Mac's is seamless. The two flow sizes differ,
   so check that the handover doesn't show.
5. **Throughput.** The Mac must run faster than real time per workload combination. Flow + disparity
   is 1.5× at 24 fps on the M2 Max. Depth and gain-grid costs on the Mac are unmeasured. servo's M1
   (16.3 fps) is too slow to be a live worker; it stays the nightly producer.
6. **Waking the Mac.** A sleeping Mac with "Wake for network access" wakes on a TCP SYN to a listening
   port, but Bonjour over Tailscale doesn't. Decide whether the worker keeps the Mac awake while
   Convolution plays, or only while a session is open.

## Order

1. **Pair for real.** Hypnos links `RAVECompanion` with its own namespace; the headset pairs with the
   Mac and opens a channel. This is also the first hardware test of `RAVECompanion` pairing.
2. **Mac serves chunks of a track that already exists.** Ready Player One 3D's `.vgat` is enough.
   The headset plays it through a `StreamingAnalysisTrack` whose fetcher is the channel. This proves
   the transport and precedence with no live analysis.
3. **Producer as a library, decoding with AVFoundation, live on request.** Start with 3D titles the
   server hasn't analysed: the player side exists and the quality is known.
4. **Mono flow** for 2D and AI 3D Smooth Motion at the Mac's working size, with a mono shared-field
   pass on the headset.
5. **Depth** for AI 3D, then **gain grids** for AI HDR video (pin the grid layout in
   `AnalysisTrack`'s `gainMap` record first).
6. **Measure on the headset** for each: the share of frames on Mac results, the handover after a
   seek, the headset's ANE and GPU load, and thermals over a film.
