# Analysis workers and the Vergence desktop app

Status: plan, revised 2026-11-07. It started on 2026-11-01 as "a Mac helping the headset", agreed then
and kept as a short note in `blu-ray-3d-smooth-motion.md`. Decided with the user on 2026-11-07:
- **Media servers only: Jellyfin and Stash.** Both have direct and transcode URLs. Nextcloud could
  join later the same way; files that exist only on a headset are out.
- **Each node connects to the media servers on its own,** with its own credentials.
- **A coordinator outside the media servers.** The Jellyfin plugin was the convenient host, but Stash
  can't host one: its plugins only run tasks and hooks and serve static files. So the queue moves
  into a service of its own, and the plugin keeps its routes during the move.
- **A Vergence desktop app for Mac and Windows,** so Quest users can run the analysis on their own
  computer. Apparition's desktop shell is its base, and Longwave's pairing and companion work feed it.
- **The desktop app also converts files:** point it at any video or film and it writes an AI 3D
  side-by-side copy that any 3D player can play (see "AI 3D to side-by-side files").
- **CUDA PCs are optional:** one on the LAN and one remote, only if the M2 Max and the M5 prove
  insufficient. Which machines these are is kept out of this public repo.

## Goal

A headset's own compute, not its displays, sets the picture quality today:
- **On a Vision Pro:**
  - Smooth Motion's flow runs at a quarter of the eye's size, because RIFE at 960×576 takes 48 ms on
    its ANE.
  - AI 3D real-time uses the small depth model (~28 ms a map, 38–45 ms beside the interpolator) and
    steps down when warm.
  - AI HDR for video would share the same Neural Engine.
- **On a Quest,** none of this runs on the headset at all.

Other machines run the networks at full working size, ahead of the playhead, and the headset only
presents: warps, blends, gain lookups and the compositor. The aim is to use what the displays can
show:
- in-between frames at the display's rate (96 Hz for 24 fps, 100/120 for 50/60);
- the pre-processed depth quality without waiting for a conversion;
- HDR highlights within the headset's headroom.

## Shape

```
  players: Vision Pro (Metal passes) · Quest (GLES passes)         media servers
     │ fetch chunks, say where they're playing                    Jellyfin · Stash
     ▼                                                                ▲  ▲
  coordinator ── queue · chunk store · source adapters · pairing     │  │ each node reads
     │  runs headless on a server, or inside the Vergence desktop app │  │ with its own key
     ▼                                                                │  │
  workers ── claim pieces, read the media, run models, upload ────────┘  │
     Mac: vergence (Core ML) · Windows/Linux: ONNX Runtime (CUDA, DirectML)
  players also read their own stream from the media servers ─────────────┘
```

- **Players** fetch analysis chunks from the coordinator and tell it where they're playing. They
  never wait for it: a missing chunk means their own work (Vision Pro) or a pass-through.
- **The coordinator** knows nothing about either server beyond its source adapters. It holds the
  queue and the chunks, and it pairs players and workers.
- **Workers** read the media from the servers themselves and post results back. Results cross the
  network; decoded frames never do.
- **One coordinator, two hosts:** the same code runs headless (`vergenced`, under launchd or systemd)
  on the user's home server and inside the desktop app on a Quest user's PC. That's why it is Rust:
  the desktop shell it shares a process with is Rust.

## What is built

| Piece | Where | State |
| --- | --- | --- |
| Analysis track format | Vergence `AnalysisTrack` (6abe4b0) | Used. Kinds `flowPair`, `disparity`, `depth`, `gainMap`. Flow + disparity ≈ 25 KB a frame |
| Producer | `vergence analyze` (VergenceCLI, Core ML) | Mac. Fed raw frames by ffmpeg. 35–39 fps on the M2 Max, 16.3 on servo's M1 (flow + disparity, 1080p 3D) |
| Server analysis + chunk routes | Jellyfin plugin `SmoothMotionService`, `SmoothMotion/` routes | Nightly, one title at a time, 3D titles only, local process only |
| Chunked consumer | `StreamingAnalysisTrack` + `SmoothMotionTracks` | Vision Pro plays server tracks around the playhead |
| Player passes | Vergence `SharedFieldInterpolator` (Metal) | 3D discs and live 3D Library titles |
| Pairing protocol | RAVESDK `RAVECompanion` (Swift); Longwave Windows Companion `Devices/` (C#, BouncyCastle TLS-PSK); QuestControllerBridge `protocol/` (C) | Same wire format, pinned by `longwave-golden.json` |
| Desktop shell | Apparition `desktop/` (Tauri) + `service/` + `installer/` | Mac and Windows, shipping |

## Workloads

| Workload | Vision Pro alone (M5) | On a worker | Record kind | Player's part |
| --- | --- | --- | --- | --- |
| Smooth Motion, 3D titles | NeuFlow 512×288, 14 ms | Today's track, made live for titles not yet analysed | `flowPair`, `disparity` | Shared-field pass, ~2 ms (Metal) |
| Smooth Motion, 2D and AI 3D | VideoToolbox (≤1080p, 15–19 ms) or GPU flow | RIFE at 960×576 (13.5 ms on the M2 Max GPU) or larger | `flowPair` (one eye) | A mono shared-field pass (new) |
| AI 3D depth | Real-time model, ~28 ms, ≤1-frame hold | A larger depth model at a larger size, with the pre-processed refinement | `depth` | Warp only |
| AI HDR for video | GMNet keyframes competing for the ANE | GMNet every few frames or every frame, fitted to a gain grid | `gainMap` (grid layout to pin) | One 3D-texture lookup |

**On a Quest,** the worker column is the only source; the Quest's own NPU doesn't matter (the user's
call, 2026-11-01). The Quest port needs GLES (or Vulkan) versions of the player passes:
- the shared-field interpolation, one fragment pass;
- the stereo warp;
- the gain lookup.

These are small next to the networks. That keeps one track format and a few MB/s on the network.
Sending finished, re-encoded video instead would mean a GPU encode per title, seconds of latency
after a seek, and several times the bandwidth. Keep that only as a fallback for a headset too weak
for the passes.

## The coordinator

### Source adapters

| | Jellyfin | Stash |
| --- | --- | --- |
| Identity | item id | scene id + the file's oshash; a replaced file invalidates its track, and a scene can have several files |
| Direct stream (LAN workers) | static stream, byte ranges | `/scene/{id}/stream` |
| Proxy (remote workers) | its transcode, or the coordinator's own | `stream.mp4?resolution=…`, or the coordinator's own |
| Library listing (backfill) | items API | `findScenes` |
| Stereo layout | `Video3DFormat` | none: the app's stereo-format detection or a tag |

- **Records are keyed by the original file's presentation time.** Players map what they play,
  including a transcode, to media time, as Library playback already does for resume and progress.
- **Stash's live transcode starts ffmpeg at the requested time,** so its timestamps may restart at
  zero. Every upload is checked against the title's frame index, which catches it. If it can't be
  mapped reliably, the coordinator makes its own working-size proxy from the direct stream.
- **Tests run against `scripts/dev-jellyfin.sh` and `scripts/dev-stash.sh`,** never a real server.

### Queue

- **Unit of work:** a 2 s **piece** of a 10 s chunk, for one set of kinds and one profile.
  - Chunks stay 10 s for storage and downloads, assembled from their pieces.
  - A chunk request serves the pieces ready so far.
- **Demand comes from the players:** their chunk requests, plus a "playing item X at media time t,
  rate r, kinds K" message on open, on seek and every few seconds. Works the same for both servers,
  and reacts to a seek faster than Jellyfin's progress reports.
- **Priority:**
  1. **Live:** pieces within ~30 s of a playhead.
  2. **Ahead:** the rest of that title.
  3. **Backfill:** the library, including today's nightly 3D work.
- **Placement:** the nearest pieces go to the lowest-latency worker that keeps up. Far-ahead pieces
  and backfill can go anywhere, including a remote worker.
- **Leases:** a worker claims a piece with a lease of about twice its measured time, and an expired
  lease goes back to the queue. After a seek, pieces behind the new playhead drop to backfill
  instead of being cancelled.
- **Profiles:**
  - A profile is one model, working size, precision and backend family per kind.
  - **One title uses one profile per kind,** so neighbouring chunks never come from numerically
    different networks.
  - A better profile can later replace a whole title.
  - Core ML and ONNX Runtime running "the same" model can share a profile only once
    `scripts/check-analysis-track.py` shows they agree within its tolerances.

### Pairing and auth

- **Pair with the RAVECompanion protocol:** Bonjour discovery, six-digit numeric comparison, a token
  per device with grants. Players and workers pair with the coordinator once, and it never sees
  their media credentials.
  - A Vision Pro uses the Swift implementation, a Quest the C one from QuestControllerBridge, and the
    coordinator a Rust port.
  - The port is tested against `longwave-golden.json`, the way RAVECompanion was.
- **Grants:**
  - `play` (fetch chunks, report the playhead);
  - `work` (claim pieces, upload);
  - `admin` (the desktop app's own UI).
- **Transport:** the chunk and worker API runs over the paired TLS-PSK channel. rustls has no
  external-PSK support, so the Rust side needs OpenSSL bindings or a port. The Windows Companion hit
  the same wall in .NET and uses BouncyCastle.
- **Remote workers** reach a home coordinator over the user's VPN; nothing is exposed publicly.

## Workers and engines

- **Mac: `vergence worker`,** a new mode of today's CLI.
  - Core ML on the ANE or GPU, decoding with ffmpeg as `analyze` does, or AVFoundation.
  - Run by the desktop app as a sidecar, or by launchd on a headless Mac.
- **Windows and Linux: an ONNX Runtime engine** inside the Rust worker:
  - Execution providers: CUDA or TensorRT on NVIDIA, DirectML elsewhere on Windows.
  - The models are exported to ONNX from the same PyTorch sources `scripts/convert-interp-model.py`
    converts to Core ML.
  - Not a Python/PyTorch install: that's fine on a developer's own machine, but not something to
    hand a Quest user. Python stays the reference the parity checks run against.
- **Decoding** goes through an ffmpeg executable, an LGPL build run as a separate process, so the
  MIT app links none of it.
- **A shared machine must yield.** Workers run at low priority, stop claiming pieces, and give up
  their leases whenever the GPU or its memory is wanted by anything else (a game, a stream, another
  model). Longwave's Windows Companion already tracks game and streaming sessions on a gaming PC;
  reuse its detection.
- **A LAN PC that sleeps** can be woken by Wake-on-LAN when live demand needs it. The coordinator
  treats it as optional.

## The Vergence desktop app

**For Quest users,** it's the one thing to install on their Mac or Windows PC:
- the coordinator and a worker in one tray (menu-bar) app;
- sign in to Jellyfin and/or Stash, with credentials held in the Rust process and never in the
  webview;
- pair the headset by its six-digit code;
- pick the GPU and the profiles;
- watch the queue, throughput and cache;
- start at login, hidden;
- **convert files to AI 3D side by side** (below), which needs no headset, server or pairing.

On the user's own setup the same coordinator also runs headless on the home server, and the desktop
app on the Mac only adds a worker.

**Where it lives:** a Cargo workspace inside the `vergence` repo (`coordinator/`, `desktop/`,
`vergenced`), beside the Swift package, MIT like the rest. It's Vergence's app, not Convolution's.

**What comes from Apparition** (MIT, Tauri, Mac and Windows):
- `desktop/src/companion.rs`: the tray icon, autostart with `--hidden`, keeps running with the window
  closed.
- `desktop/src/updater.rs` and `update-windows.ps1`: updates checked against a pinned SSHSIG
  manifest before anything runs.
- `desktop/src/service.rs`: credentials stay in Rust memory, and the webview gets a bounded set of
  operations.
- The installer packaging for Windows and macOS, and the release signers.
- `service/`: an HTTP service with sessions, for the coordinator's admin side.

The UI is plain HTML and JS embedded in the app, with no remote scripts, like Apparition's.

**What comes from Longwave** (MIT):
- The RAVECompanion wire format and its golden vectors, plus the C# `Devices/` implementation as a
  second reference for the Rust port.
- QuestControllerBridge's C pairing client (`protocol/`), linked into the Quest port so it pairs
  with the desktop app.
- The Windows Companion's game and streaming-session detection, for yielding.
- Its Windows conventions: run unelevated, and control the backend through an ACL'd local channel.
- **Not its stack:** the Mac and Windows companions are two codebases (SwiftUI; Electron + .NET)
  that share no compiled code. One Tauri app avoids repeating that.

**Shared code:** if Longwave's companion later moves onto the same shell, the shared parts (pairing,
tray, updater) can become a crate both repos use. Until there's a second consumer, they're
Vergence's.

### AI 3D to side-by-side files (asked for 2026-11-07)

Drop a video, a film or a folder on the window, or use "Open with" from Finder or Explorer. The app
writes a 3D copy beside it, or into a chosen folder, that plays in any SBS-capable player: a Quest's
own player or Skybox, Jellyfin, a 3D TV. This needs no headset, media server or pairing, so it is
also the simplest way to try Vergence.

**Pipeline:** the offline AI 3D path Convolution's Pre-Process uses, run to a file instead of a
cache:
1. **Decode.**
2. **Depth:** inference, then the pre-processed refinement:
   - joint-bilateral filtering on the frame's own edges;
   - ±2-frame lookahead, cut-aware;
   - Stable Depth anchoring and the soft-knee depth budget.
3. **Warp each eye:** the depth-displaced mesh, with the layered or boundary warp once those are
   validated.
4. **Encode** HEVC side by side, and mux.

Two passes over a file are fine offline. Depth can be made over the whole shot before warping,
which a live player can't do.

**What exists:**
- **VergenceApple** has every stage: `DepthConverter` with its two-stage pipeline and two-pass cache,
  `DepthRefinement` (VergenceCore), the Metal warps, `StereoPixelBufferMaker`, and VideoToolbox
  encode. The README lists "2D to 3D from estimated depth (the library; the command line comes
  later)".
- **`vergence sbs`** already writes side-by-side HEVC MP4 with an `st3d` box and the
  `.3D.FSBS`/`.3D.HSBS` names that Jellyfin and players read.
- **`vergence make`** turns side-by-side into MV-HEVC spatial video.

**What's new:**
- **A `vergence convert` command** (Mac) joining those stages: decode, depth, warp and encode. The
  desktop app runs it like the worker, as a sidecar.
- **Windows:** the same stages in the Rust engine:
  - ONNX Runtime depth, as for the workers;
  - the warp in WGSL through wgpu (D3D12 or Vulkan);
  - ffmpeg with NVENC (or another hardware HEVC encoder) to encode.
  - The depth maths (anchoring, budget, cut detection, percentiles) is VergenceCore Swift, so it is
    either ported to Rust against fixtures VergenceCore produces, or VergenceCore is built for
    Windows and called through a C ABI. Decide once a spike shows which is less work; the
    Package.swift comment claims Windows but it has never been built there.
  - **Parity:** the same frames and depth through Metal and wgpu must give the same picture within
    a set PSNR, checked on the paused-frame fixtures.
- **The depth also feeds Vision Pros:** the conversion writes its depth as analysis-track `depth`
  records too, so a title converted for a Quest also serves a Vision Pro's live AI 3D through the
  coordinator.

**Options in the app** (defaults first):

| Option | Choices |
| --- | --- |
| Layout | full SBS; half SBS (for players and TVs that want the original width); top-and-bottom; **spatial video** (MV-HEVC, Mac first, through `make`, for a Vision Pro or iPhone) |
| Depth | Convolution's Subtle strength and convergence (`Pseudo3DSettings` defaults) with a slider, and the model (see licences below) |
| Preview | a frame shown side by side or as anaglyph before starting, and a 10 s sample render |
| Smooth Motion | off by default; can bake in-between frames (24 → 48 fps) with the same flow models |
| HDR | an HDR source stays HDR (10-bit HEVC, its transfer and primaries copied); depth runs on a tone-mapped copy |
| Audio | every track copied as is. MP4 when the audio fits in it, else MKV (TrueHD, DTS) |
| Subtitles | text tracks copied; optionally burned in at the right depth with Vergence's `StereoSubtitleCompositor`, so they sit in front of the scene and not inside it |

**Running:**
- A queue in the same window, with progress and time left per file.
- Pause, resume after a quit, cancel.
- It yields to games and other GPU use like a worker does.
- An interrupted conversion picks up from its depth cache instead of starting over.
- Conversions run below live analysis work, which has a playhead waiting.

**Model licences:**
- The shipping model, Depth Anything V2 Small from Apple's Core ML repo, is Apache-2.0.
- Larger depth models (Depth Anything V2 Base/Large, Video Depth Anything Large, Depth Pro) need
  their weights' licences checked before the app offers them. Several are, as far as known,
  non-commercial only. If so, offer them only as an opt-in download with the licence shown, never
  bundled.

### AI HDR for video, in short (proposed 2026-11-07, not started)

It is meant to work on a Vision Pro alone too, with workers as a quality upgrade.
- **Gain grid, not gain image:**
  - GMNet runs on keyframes: every cut, plus about every 0.5–1 s.
  - Its gain map is fitted into a bilateral grid, gain over (x, y, luma), e.g. 16×9×8.
  - Every frame looks its gain up with its own luma. Moving highlights keep their boost, and
    in-between frames and both stereo eyes get consistent gains for free.
- **SDR until the last shader:** interpolation and depth see SDR. On the Vision Pro the expansion
  goes into shaders that already run:
  - `imageFragmentShader` into an EDR `rgba16Float` drawable for flat video;
  - an SDR-in/PQ-out stereo warp into the pump's existing `xf20` HDR eyes for AI 3D.
  - The pump's reserve stays BGRA.
- **Stable within a shot:**
  - Ease the grid between keyframes and snap at cuts, using the depth pipeline's luma-grid cut
    detector.
  - Ramp in on engage and after a seek.
  - Cap the frame-average gain below the window brightness limiter (2.5–3×).
- **Step-down order on the headset:** keep depth first, then interpolation, then HDR updates. Never
  switch it off mid-shot.
- **Unknown cost:** the photo path's 0.63 s includes CPU resampling of a full-resolution photo and
  enumerated input shapes. The first step is a fixed-shape 512×288 conversion timed on the headset.

## Open questions

1. **Lead after open and seek.** The first second or two runs without workers. Check on the Vision
   Pro that the switch to a worker's larger fields doesn't show. On a Quest, it plays without
   enhancement until pieces arrive.
2. **Mapping a transcode to media time,** for Jellyfin HLS and Stash's live transcode, to within a
   frame.
3. **Core ML vs ONNX Runtime parity** for each model. If they don't agree within tolerance, each
   backend family gets its own profile, and a title sticks to one family.
4. **Worker throughput by kind** (unmeasured): the M2 Max for mono flow at 960×576, larger depth and
   GMNet; every model on ONNX Runtime with CUDA.
5. **TLS-PSK in Rust:** OpenSSL bindings, or which other library.
6. **Quest player passes:** GLES vs Vulkan in the Quest port's renderer (Spatial SDK, Media3
   surfaces); see `quest-parity-roadmap.md`.
7. **Stash stereo layout:** detection only, or a tag convention as well.
8. **The Windows converter's depth maths:** a Rust port, or VergenceCore built for Windows.
9. **Spatial video on Windows:** whether a usable MV-HEVC encoder exists there. Until then, spatial
   output is Mac only.
10. **Depth model licences** for anything beyond Depth Anything V2 Small.
11. **Conversion speed** on the M2 Max and on CUDA per model and resolution (unmeasured). It sets
    whether a film is an evening's or a night's job.

## Order

1. **Coordinator core in Rust:** source adapters for Jellyfin and Stash, pieces, leases, priorities,
   chunk routes compatible with the plugin's, and upload checks. Headless `vergenced` on the home
   server, tested against the two dev servers.
2. **`vergence worker` on the M2 Max** with today's 3D profile, against the coordinator: the live
   path end to end, with a player side that already exists. Token auth first; pairing comes in
   step 4.
3. **Vision Pro:** fetch from the coordinator, report the playhead, partial chunks. Measure the lead
   after open and seek. The Jellyfin plugin's routes keep working meanwhile.
4. **Pairing:** port RAVECompanion to Rust against the golden vectors, then pair the Vision Pro and
   the worker.
5. **Desktop app on Apparition's shell:** tray, sign-in, pairing, queue view, updater; a Mac build
   first, then Windows.
   - **`vergence convert` and the convert window.** This can start in parallel with steps 1–4,
     since it needs no coordinator, server or pairing: the CLI first, then drag-and-drop, options,
     preview and queue on the Mac.
6. **ONNX Runtime engine:** export the models, check parity against Core ML, CUDA on Windows. This is
   also where the CUDA PCs come in, if step 2's measurements fall short. Then the Windows converter
   (wgpu warp, NVENC encode, the depth-maths decision), checked against the Mac's output.
7. **More kinds:** mono flow, depth and gain grids, one at a time with their Vision Pro passes.
8. **Quest:** C pairing client, coordinator fetch, GLES passes (see `quest-parity-roadmap.md`).
9. **Retire the plugin's own analysis:** its nightly work becomes coordinator backfill, and its
   routes pass through to the coordinator.
