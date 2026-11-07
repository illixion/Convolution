# Analysis workers and the Vergence desktop app

Status: steps 1–6, 8 (not yet run on a headset) and 9 built on 2026-11-07 (see "Progress"); 7 built for the Mac worker and the Vision Pro (not yet on a headset). Plan revised 2026-11-07. It started on 2026-11-01 as "a Mac helping the headset", agreed then
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
  - Core ML and ONNX Runtime running "the same" model can share a profile only once their
    chunks agree within a tolerance set from the in-family noise (`scripts/check-onnx-workload.sh`,
    question 3). AI 3D depth does: Depth Anything V2 Small and Base have one profile name on the
    Mac and the PC worker (family, input size, licence, pipeline version, context; no engine), so
    the two split a title. Smooth Motion's flow and AI HDR keep a profile per engine family.

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
- **Transport:** the chunk and worker API runs over the paired TLS-PSK channel (below). rustls has
  no external-PSK support, so the Rust side uses OpenSSL (`openssl` + `tokio-openssl`). The Windows
  Companion hit the same wall in .NET and uses BouncyCastle. Plain HTTP with a bearer token stays for
  scripts, workers set up by hand and the Jellyfin plugin.
- **Remote workers** reach a home coordinator over the user's VPN; nothing is exposed publicly.

### The paired channel (built 2026-11-07)

What a paired device speaks to a coordinator (`vergenced`, or the desktop app's). Exact, so a client
can be written from it; the reference is vergence `coordinator/src/paired.rs`, and
`coordinator/tests/paired.rs` drives it with a raw client.

1. **Pairing** is RAVECompanion's, in Vergence's namespace: service stem `vergence`, label prefix
   `Vergence`, link scheme `vergence://pair?…`, direct pairing port **4869** (open only while
   pairing: `vergenced pair`, or Pair a Headset in the desktop app). A headset asks for `play`. The
   grant's `token` is the device's pairing token; keep it in the platform's secret store. The
   device id is the `headsetID` the device sent in its commit.
2. **Connect** TCP to the coordinator on port **8421** (the desktop app's `pairedPort`, vergenced's
   `pairedListen`), at the address the pairing ran over first, then the grant's `addresses`.
3. **TLS 1.2 only**, one cipher suite: `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8; OpenSSL
   `PSK-AES128-GCM-SHA256`). No certificate, no SNI needed, no identity hint from the server.
   - **PSK identity:** the UTF-8 bytes of `VergenceAPI/v1/<device id>`. The bare `VergenceAPI/v1`
     (a shared token) is refused.
   - **PSK:** `HKDF-SHA256(ikm = pairing token as UTF-8, salt = "Vergence-API-PSK-v1",
     info = "psk")`, 32 bytes. That is `RAVECompanionChannel(identityBase: "VergenceAPI/v1",
     salt: "Vergence-API-PSK-v1")`.
   - An unknown device, a wrong key or a forgotten device fails the handshake.
4. **Then plain HTTP/1.1** on the TLS stream, straight away: no identify message, no
   `Authorization` header (one sent is ignored). The handshake's identity is the device; its grants
   are the ones it was paired with, read again for every request.
   - Requests carry `Content-Length` (0 for none). One request at a time per connection,
     keep-alive; the server closes a connection idle for 60 s, so a client reconnects and resends
     a request that got no byte back.
   - Responses carry `Content-Length` (a client should still accept `chunked`).
   - Routes are the HTTP port's (vergence `coordinator/src/api.rs`): `POST /v1/playing`,
     `GET /v1/titles/{server}/{id}/{workload}`, `GET …/chunks/{n}` with `Vergence-Chunk-Complete`
     and `Vergence-Pieces`, and the worker routes for a device paired with `work`. A device's
     player names are `device-<device id>/<player>`.
   - `403` means the device is no longer paired or lacks the grant: pair again.
5. **The derived HTTP token** lets the same device use the plain port (8420) instead:
   `hex(HKDF-SHA256(ikm = pairing token, salt = "Vergence-HTTP-Token-v1", info = device id))`,
   lowercase, as `Authorization: Bearer <token>`. The coordinator recognises it from its paired
   devices.

Built: vergence 8f23a62 (coordinator, vergenced `pair` and `devices`, the desktop app), RAVESDK 2c052d6
`RAVECompanionHTTPClient` (the Swift client), Convolution's Settings pairing and `AnalysisPairing` (9a719c4).
`companion/interop/run.sh` pairs the Swift client with `vergenced pair` and calls the API over the
channel.

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

#### Upscaling (built 2026-11-07)

Asked for with a real case: a full side-by-side 3D film at 720×400 per eye (H.264, 7.8 Mbps, AC-3
5.1, MKV) to watch on a headset. `convert --upscale 2x` in both converters (same flags and lines),
and "Upscale 2×" plus a "2D (upscale only)" layout in the desktop app:
- **2D source:** upscaled, then AI 3D as before (depth still at the source's size), or upscaled only
  (`--layout 2d`, `VIDEO.2x.mp4`).
- **Side-by-side / top-and-bottom source** (declared, named, or on the Mac seen in its picture;
  `--input-layout` says it): each eye upscaled, no depth, packed in any output layout
  (`VIDEO.2x.3D.FSBS.mp4`).
- **Model:** Real-ESRGAN's compact `realesr-general-x4v3` (BSD-3), run at 4× and averaged to 2×.
  Vergence ships no weights: `--download-model` fetches the authors' `.pth` (pinned SHA-256), and
  each converter writes the network itself from it, no Python (Core ML spec on the Mac, compiled
  once per size, batch split between the Neural Engine and the GPU; an ONNX graph on the PC).
- **Stereo-consistent:** the eyes' fine detail is pulled halfway together where block-matched
  disparity (SAD, left-right check) is sure, held to ±10 code values.
- **Measured** on two 10 s clips of that film against Lanczos (detail = high-pass energy;
  disagreement = detail difference after warping right onto left by an independent optical flow;
  flicker = along temporal flow): the general network adds 36–48 % detail with 23–29 % more L/R
  disagreement and 23–36 % more flicker; fused, disagreement drops to 0.92–1.20× Lanczos for 2–4 %
  less detail. `animevideov3` (BSD-3): +13–26 % detail, no more disagreement or flicker than
  Lanczos, twice as fast. RRDB x2plus/x4plus: slower (4–12×), more flicker. RealBasicVSR (Apache-2.0
  code, video model): most detail but up to 2× the disagreement and flicker, 10× slower.
- **Speed:** M2 Max 9.4 fps for a 720×400 3D pair: the whole 81-minute film (121,493 frames after
  the repeats were dropped) in 3 h 36 min, audio in sync to the end. RTX 3080 PC 6.9 fps (DirectML),
  the CPU fusion setting the pace.
- **Repeated frames:** that film repeats one frame in five (NTSC pulldown retimed to 31.24 fps to
  fit PAL audio). Every `convert` now detects this and drops one in five (the Mac's own picker,
  ffmpeg `decimate` on the PC), writing 24.99 fps in sync with the audio; `--keep-repeated-frames`
  keeps them.
- **Watched on the Vision Pro (2026-11-07):** eyes fine (the title sequence's eyes really differ in
  the source); diagonals aliased: the source's stair steps (SD CG, NTSC deinterlacing) came out
  sharpened. Added (vergence eaf98c7, 26085b0):
  - `--antialias` (both converters): each field's missing lines re-made by ffmpeg's `estdif`
    (edge-slope tracing, no weights), both fields averaged, kept along edges (blurred Sobel mask).
    Edge raggedness on the bed edge after upscaling 0.0655 → 0.0564, detail elsewhere −7 %; NNEDI3
    the same way (GPL weights) 0.0612, both directions 0.0592 with more detail lost. ~73 fps.
  - `--ai-hdr` (Mac only so far): the `ai-hdr` worker's producer makes the grids (left eye of a 3D
    source), `GainGridPass` applies them (cap 2.5×), 10-bit BT.2020 PQ, SDR white 203 nits, HDR10
    metadata (P3 1,000 nits mastering, MaxCLL 1015, MaxFALL 507). Grids ~34 fps; baking is free.
  - A 10-minute piece (20:00–30:00) with both and `--upscale 2x`: 40.6 min on the M2 Max; on the
    headset for the user to judge (ledger).
- **Not done:** temporal stabilisation (a flow-warped detail blend cut flicker by a third in the
  experiment but needs flow per frame); the fusion on the PC's GPU (it is CPU-bound); a stereo SR
  network (NAFSSR is trained on clean bicubic downscaling, not compressed video); upscaling MV-HEVC
  sources.

### AI HDR for video, in short (proposed 2026-11-07; built from workers, not yet on a headset)

It is meant to work on a Vision Pro alone too, with workers as a quality upgrade.
- **The grid as built** (Vergence `GainGrid`, the `gainMap` record): eye mono, float16, 8 channels
  (luma bins) of 16×9 cells, each the log2 of the linear gain for pixels in that cell whose
  non-linear luma (BT.709 weights on full-range R′G′B′) falls in that bin. Cells and bins are
  sampled at their centres, trilinearly, clamped to the edges: a 16×9×8 3D texture read at
  (u, v, Y′). HDR = SDR linear × 2^g. About 1 KB a frame.
- **The players as built:** Settings › Viewing › AI HDR for Videos (off by default) asks an analysis
  server for an SDR Library title's `ai-hdr` track. Vergence's `GainGridPlayback` picks each frame's
  grid, ramps it in over a second of media time after engaging and after every seek, holds the last
  grid while a piece is missing (strength 0 until the first one after a seek arrives), and while the
  device is short of time refreshes it only every half second, still snapping at once to a grid
  that jumps (a cut, which the worker snapped). The frame's average gain is held to 2.5× on the GPU
  (`GainGridPass.encodeMean`, every fourth pixel).
  - Flat video: `aiHDRImageFragmentShader`, `imageFragmentShader`'s resolve and tone in SDR plus the
    lookup, into an EDR `rgba16Float` drawable in extended linear BT.709 (no extra pass; tvOS not,
    as it has no EDR switch).
  - AI 3D: the pump warps in SDR into its half-float eyes, then one pass per eye (after every warp
    variant, so none of their shaders changed) writes BT.2020 PQ, SDR white at 203 nits, into the
    10-bit `xf20` eyes, tagged PQ with HDR10 static metadata; subtitles then draw as PQ.
  - Step-down: interpolation backs off first; grid updates step down only while it is backed off;
    depth is never touched. HDR never switches off mid-shot.
  - Not done: the photo path's GMNet on the headset alone (no worker), the film player's AI 3D, and
    a 3D title's own picture.
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

## Progress (2026-11-07)

| Step | State | Where |
| --- | --- | --- |
| 1. Coordinator | Built. Jellyfin and Stash adapters, pieces, leases, priorities, profiles, upload checks, partial and whole chunks, the plugin's routes, bearer tokens. Tested against both dev servers | vergence `coordinator/` (3b85410) |
| 2. Mac worker | Built. Same records as `vergence analyze` over the whole file (disparity identical, flow within Core ML noise); about 37 fps, seeks included | vergence `worker` mode (289a191), `scripts/check-worker.sh` |
| 3. Vision Pro | Client built: reports the playhead, reads partial chunks. **The lead after open and seek is not measured yet** (device QA) | Hypnos 65e6851, vergence e01ad52 |
| 4. Pairing | Rust port matches every golden vector; pairs with the Swift code both ways. The chunk and worker API runs over the paired TLS-PSK channel ("The paired channel"); `vergenced pair` and the desktop app pair, the Vision Pro pairs in Settings and uses it. HTTP + token stays for scripts and the plugin. Not yet on a headset | vergence `companion/` (cf954fa), 8f23a62; RAVESDK `RAVECompanionHTTPClient` |
| 5. Desktop app | Mac build runs: coordinator, settings, pairing, worker sidecar, convert queue, the paired TLS-PSK port. Windows x64 builds (cross-compiled, `desktop/scripts/package-windows.sh`, a zip as Apparition ships) and ran on a Windows PC: window, coordinator, paired channel (an OpenSSL client exchange through it), worker found; it runs `vergence-worker.exe` and `vergence-convert.exe` there, and announces pairing over mDNS (`DnsServiceRegister`, seen from a Mac with `dns-sd`). Tray and a conversion not tried on Windows. Updater pins the release keys (Apparition's two), no release site yet | vergence `desktop/` (181599a), 0867eef, db4af4a, b7d8f28 |
| 5. `vergence convert` | Built: all layouts, HDR kept, audio copied, resume, depth track. No subtitles, no Smooth Motion bake | vergence 0607bc0 |
| 6. ONNX worker | Built and run on a Windows PC with an RTX 3080 against a coordinator on the Mac: CUDA, TensorRT and DirectML each made a whole title, 47–55 fps for 1080p 3D pieces, records matching Core ML's (Question 3). It yields for real there: a game, an app launched through Sunshine, SteamVR or another program keeping the GPU busy makes it give back its piece and unload its models; a desktop stream alone doesn't (the user's call). The 2D workloads too (2D flow, AI 3D depth through the converter's Rust depth pipeline, AI HDR with GMNet exported to ONNX), 2D flow and AI HDR under their own ONNX profiles, depth under one shared with the Mac worker (Small and Base; a Mac and the PC split a title): on the 3080, 2D flow 58 fps (TensorRT), depth 13 fps of title (CUDA), AI HDR 59 fps (CUDA), matching the Core ML worker's chunks (Question 3) | vergence `worker/` (2a7892b), ab2ffbc, 5f870d3, 44c3b73, 79d3dff, 0822638, 8c92b4b |
| 6. Windows converter | Built: `vergence-convert`, the same flags, names, output lines and progress as `vergence convert` (so the desktop app runs either), ONNX depth, the refinement ported to Rust, a wgpu warp, NVENC. Within 49 dB PSNR, SSIM 0.985 of the Mac's output per eye (tolerance 40 dB, 0.97). No spatial video, no HDR10 mastering metadata through NVENC (x265 keeps it) | vergence `convert/` (99539a1), 876a7bd, 03cd136 |
| 5/6. Upscaling in convert | Built on both converters: `--upscale 2x` (Real-ESRGAN compact, weights fetched, network written without Python), 3D sources eye by eye with the eyes' detail fused, `--layout 2d`, pulldown repeats dropped; desktop app option. Checked against PyTorch on a fixture net (Core ML and ONNX), Mac vs PC copies at 40–43 dB. Not watched on a headset yet | vergence afe0b10, e54c438, 2986334, e3bc32b, 3c36aeb |
| 7. More kinds | Built on the Mac, three workloads, each checked end to end against the dev Jellyfin (a coordinator's chunks against the worker's own whole-file run). **`smooth-motion-2d`**: RIFE 4.25 lite 960×576 on the GPU, flow stored at 240×144; chunks identical to the whole-file run; the Vision Pro reads it for 2D Library titles (flat and AI 3D, film player AI 3D too) through a fields-first mono pass that leaves uncovered pairs to the device's interpolator. **`ai-3d-depth`**: the offline depth pipeline per piece (a second of context before it) with Depth Anything V2 Small at 770×574; chunks within 0.005 mean, 0.05 max (shot-space units) of a whole-file conversion; the Vision Pro warps it in real-time AI 3D and runs its own model only for frames it lacks. **`ai-hdr`**: GMNet on keyframes (0.5 s and cuts) fitted to the pinned grid, eased within shots; chunks identical; used in the players behind Settings › AI HDR for Videos: the flat player's final pass into EDR and AI 3D's eyes as BT.2020 PQ, ramped in, capped, stepped down after interpolation, snapped at cuts (checked through the pump on the visionOS simulator). The ONNX worker makes all three too (row 6). Not done: any headset run | vergence 352dd73, 3e20c96, 308f15e, 39c4240; Hypnos 9ec9b9d, 2178727, 964a8b5; RAVESDK b6ab5e6, a4e89b4, 9ea391e |
| 8. Quest | Built, not run on a headset. Pairs by the six-digit code (NSD, a typed address or link) and keeps the token in the Keystore, or takes an HTTP address and token; talks over the paired TLS-PSK channel (Bouncy Castle) or HTTP; reports the playhead per workload, reads partial chunks (VGAT in C++). GLES 3 passes: the shared field at the display's rate for 3D titles and its mono form for 2D ones (`smooth-motion-2d`); the gain-grid lookup with the cap into a BT.2020 PQ window, asked for (`ai-hdr`) only when the display reports HDR; the AI 3D mesh warp, built but not wired, as the Quest has no AI 3D presentation yet (so no `ai-3d-depth` requests). Tested off the headset against VergenceCore and vergence-worker tracks, the Mac worker's 2D-flow, depth and gain tracks, vergence-companion's vectors and a real `vergenced` over TLS-PSK. The desktop app announces `_vergence-pair._tcp` while pairing on macOS, Linux and Windows | Hypnos 1cc42b1, 857297a; vergence 6a80077 (b7d8f28 on Windows); Controller Bridge 4ed9722 |
| 9. Plugin | Routes pass through to a coordinator; the nightly task queues there | Hypnos 16640ed |

A paired headset uses the TLS-PSK channel; its HTTP token, for the plain port, is derived from its
pairing token, not sent as is: HKDF-SHA256 with salt `Vergence-HTTP-Token-v1` and the device id as
info (`coordinator/src/paired.rs`). The Vision Pro and Quest clients compute the same.

Answers so far:
- **Question 3 (Core ML vs ONNX):** NeuFlow agrees within noise; RIFE does not, because the Core ML
  conversion runs in float16 (up to about 1 px of flow, mean 0.004). So ONNX titles get their own
  profile, unless RIFE gets a float32 Core ML conversion. On the RTX 3080 (same title, whole):
  CUDA, TensorRT (fp32) and DirectML agree with each other within 0.06 px of flow and 0.03 px of
  disparity (one or two storage steps), and with Core ML's disparity within 0.03 px (mean 0.0005);
  their flow is as far from Core ML's as the Mac's ONNX CPU run (max 1 px, p99 0.06). So every
  ONNX provider shares one profile, Core ML another. The 2D kinds against the Core ML worker, same
  720p title, RTX 3080: RIFE 960×576 flow p99 0.06 px, mean 0.003, up to 3 px where Core ML's
  float16 run drifts (TensorRT and CUDA within 0.2 px of each other); depth (Depth Anything V2
  Small 770×574 through the Rust port of the offline pipeline) mean 0.012, max 0.09 in shot-space
  units, from float16 against float32 and the odd threshold flip; GMNet's gain grids within 0.01 in
  log2 gain. So 2D flow and AI HDR keep an ONNX profile of their own.
  **Depth is shared** (the user's call, 2026-11-07, once measured): chunk records after the offline
  refinement, one 720p title, against the Core ML worker's pieces. In-family noise: Core ML is
  deterministic run to run; ONNX providers (CUDA, DirectML, the Mac's CPU) agree within mean
  0.0004, p99 0.004; Core ML's pieces against its own whole-file run differ by mean 0.005, p99 0.023,
  max 0.05. Across families: Small (770×574) mean 0.012, p99 0.041, max 0.089; Base (518×392) mean
  0.006, p99 0.025, max 0.069; the same against the Mac's ONNX CPU run as against the 3080's CUDA.
  Tolerance: mean 0.015 and p99 0.05 in shot-space depth, about twice the in-family piece noise and,
  at Convolution's Subtle strength (0.008 of the width), 0.2 px of parallax on average and 0.8 px at
  p99 on a 1920-wide eye; most of the difference is a per-shot scale (anchor fits accepted on one
  side and not the other), correlation 0.99 per frame. Both pass, so Small and Base share one name;
  Large and other models keep a per-engine one until checked. A Mac worker and the PC worker split a
  title through one `vergenced`: pieces from both, mean 0.010 from a Core ML whole-file run. Speed
  on that 9-piece title: the 3080 alone 35 s (3.6 s a piece), the M2 Max alone 95–113 s, together
  45 s, because the Mac's first piece (45 s, its model loading) came last; on long titles the two
  rates add (about 13 + 5 fps of title). Two problems the split run found, both fixed
  (vergence 4a68244): the Mac worker's `ai-3d-depth` lost frames on Matroska titles ("the depth pass
  gave 57 of 74 frames": the ProRes intermediate kept the source's millisecond timestamps, uneven,
  and the depth pass reads by time; frame k now sits at k / rate), and the coordinator took a title's
  length from the container, so the 4K demo (109.8 s of container, 2548 frames of picture) had pieces
  no worker could make. A worker whose decode ends cleanly inside a piece now says `videoEndFrame` in
  its track header; within 10 s (or 2 %) of the title's end the coordinator takes the short piece,
  ends the title there and stores the pieces past it empty. On the 4K demo every piece was made and
  the title went ready; against a whole-file run its depth then differed by 0.012 on average but
  0.12 at p99 (0.55 at most). That turned out to be the converter's static-frame gate, not the
  anchoring: which frames it skips (reusing the last map) depends on where a run started. Workers
  now infer every frame, and a second of context then matches a whole-file run (p99 0.0067).
  **Sticky runs** (vergence a781746, the user's request): a worker claims with `continues`
  {title, frame} and the coordinator gives it the next piece when that is free and no less urgent
  than its own choice (live pieces still come first); a second worker in backfill starts halfway
  along the longest pending stretch. The Mac worker's depth then seeds Stable Depth's anchoring
  with where the last piece put the overlap frame in shot space and decodes 2 frames of context
  instead of 24. On the 4K demo, sticky pieces against one decode of the whole title: mean 0.0009,
  p99 0.0064, max 0.094 (through the fade, frames 1473–1485: p99 0.004), in 496 s against 713 s
  with a second of context. AI HDR keeps its keyframes on both workers (identical records, less
  decoding). Smooth Motion's flow isn't sticky (it decodes one frame past a piece; nothing to
  save). The Rust worker's depth is sticky too (vergence 135d56b, the converter crate's depth pass seeded the same way): on the dev Jellyfin's 18 s title on a Mac CPU, 8 of 9 pieces carried on, 809 s against 1120 s with a second of context, the two within mean 0.0028, p99 0.011. Both workers on one Mac don't add up: on a 600 s 640×360 title over 240 s each, the Core ML
  worker alone made 164 depth pieces (about 33 fps of title), the ONNX worker on the CPU alone 19
  (about 4), and the two together 85 (72 + 13): the CPU worker takes the cores the Core ML worker's
  decoding and refinement need. Rates add across machines (the M2 Max and the 3080 above), not
  between engines on one; a Mac should run only `vergence worker`.
- **Question 4 (throughput):** the M2 Max's Core ML worker does 1080p 3D Smooth Motion at about
  37 fps; ONNX Runtime on the same Mac 16–17 fps. On an RTX 3080, whole pieces from a coordinator
  (decode and seek included): TensorRT 55 fps, DirectML 52, CUDA 47, for 0.45–0.9 GB of GPU memory;
  the models alone run at 103–111, 94 and 81 fps. TensorRT builds its engines for about 100 s the
  first time, then loads from its cache. The 2D kinds on the 3080, a 720p title's pieces: RIFE
  960×576 flow 58 fps on TensorRT (the model alone 89; CUDA 60, DirectML 71), depth 13 fps of title
  on CUDA with each piece's second of context (DirectML about a third of that; 2 GB of GPU memory),
  AI HDR 59 fps on CUDA. TensorRT builds an engine per input size, so the free-size depth and GMNet
  models run on CUDA when it is chosen. By kind on the M2 Max (whole
  files, model load included, the Mac busy with other work):
  - 2D flow, RIFE 4.25 lite 960×576: about 40 fps for 720p on the GPU (16–17 on the Neural Engine
    or with Core ML choosing, so the worker puts it on the GPU), 24–40 fps for 1080p; about 30 KB a
    frame. The full RIFE 4.25 at that size runs as fast on the GPU.
  - AI 3D depth, Depth Anything V2 Small 770×574 through the offline pipeline: about 9 fps (13.5 at
    Apple's 518×392), and each piece also converts a second of context, so a worker makes about a
    third of real time: ahead and backfill work, not a live lead, on one M2 Max. 43 KB a frame.
  - AI HDR, GMNet on keyframes every 0.5 s: about 30 fps for 1080p, 1 KB a frame.
- **Question 5 (TLS-PSK in Rust):** OpenSSL, through the `openssl` and `tokio-openssl` crates: the
  server's PSK callback picks each device's key by the identity it presents, so the coordinator knows
  the device from the handshake and needs no identify message. Windows builds OpenSSL in
  (`vendored-openssl`); macOS and Linux link the system's.
- **Question 6 (Quest passes):** GLES 3.0, not Vulkan. The passes are a few texture reads per pixel;
  the Quest's video surfaces are Android ones (Home's SurfaceView, Spatial SDK's video panel), which
  EGL renders into directly, and the decoder feeds a SurfaceTexture as an external texture with no
  copy through Vulkan interop. Vulkan would only pay if the passes grew into compute work. Frame time
  on a Quest 3 is unmeasured (the renderer logs it).
- **Question 10 (depth model licences):** answered by the user on 2026-11-07: offer the larger
  models, sideload only, behind build flags. Depth Anything V2 Base and Large, and Video Depth
  Anything Base and Large, are CC-BY-NC-4.0 by their model cards (Video Depth Anything Small is
  Apache-2.0); Depth Pro's weights are research-only. So:
  - **Convolution:** with `NC_MODELS_CONDITION=HYPNOS_NC_MODELS` (sideload builds only, like
    `HYPNOS_YOUTUBE`), Settings › AI Models offers Depth Anything V2 Base and Large as downloads
    after showing the licence and "non-commercial use only"; a submission build has no name, address
    or UI of them. The Core ML conversions are a third party's on Hugging Face (`.tar.gz`, checked
    against the repo's SHA-256, unpacked on the device); nothing is re-hosted.
  - **Vergence:** `vergence convert` and `vergence worker` take such a model only when built with
    `-Xswiftc -DVERGENCE_NONCOMMERCIAL_MODELS`, and say its licence; a worker's profile names the
    licence, so its titles never mix with Small's. No weights in the repo.
  - **Measured on the M2 Max** (offline pipeline, 1080p, warm, Mac shared with other work): Small
    23–35 fps, Base 5–16 fps (our own `convert-depth-model.py --variant base` at 518×392) and 9–12
    fps (the third-party all-float16 518×518 archive). Base resolves fine structure Small misses
    (dandelion fibres, thin stems); our conversion was sharper and haloed less than the archive's,
    and can be dropped into Documents instead of downloaded.
  - **Not offered:** Video Depth Anything (reads 32-frame clips, not one frame: not a drop-in for the
    per-frame pipeline) and Depth Pro (1536×1536 input at seconds a frame, an image output the
    provider doesn't read).
  - **The Rust side** (vergence 0822638): `vergence-convert` and the ONNX worker take Base/Large
    only with the cargo feature `noncommercial-models`, off by default, by the same name rule and
    licence line; such a converter downloads them (`--download-model --variant base|large`,
    `onnx-community/depth-anything-v2-base` / `-large`, pinned and checked), and the desktop app,
    built with its own feature, offers them on Windows only after showing the licence. Base on the
    RTX 3080 (CUDA, 518×392, the worker's pieces of a 720p title): 3.0 s a piece against Small's 3.6
    at 770×574; under 1 fps on a Mac through ONNX Runtime (CPU or Core ML provider), so a Mac runs it on
    Core ML.
- **Question 8 (the Windows converter's depth maths):** a Rust port. The GPU kernels had to be
  rewritten anyway (Metal to WGSL); VergenceCore's part is about 400 lines of plain maths, ported and
  tested against fixtures VergenceCore writes (`scripts/make-convert-fixtures.sh`), all passing.
  Building VergenceCore for Windows would have meant shipping the Swift runtime and a C ABI for the
  smaller half. The two differ only where a threshold flips (a shot's anchor fit accepted on one,
  rejected on the other), which shifts pixels by at most the strength.
- **Question 9 (spatial video on Windows):** nothing usable yet. NVIDIA's Video Codec SDK 13 can
  encode two-view MV-HEVC through its own API, but ffmpeg 8.1's `hevc_nvenc` doesn't expose it (and
  whether an RTX 3080 supports it is unverified); x265 4's `--multiview-config` needs a separate GPL
  x265 plus a muxer writing Apple's spatial metadata. Either is new work, so spatial stays Mac only.
- **Question 11 (conversion speed):** 1080p at about 30 fps on the M2 Max, a two-hour film in about
  100 minutes. On an RTX 3080 (CUDA depth, NVENC): 1080p SDR at about 42 fps steady (depth 68,
  picture 110), a two-hour film in about 70 minutes; 1080p HDR10 28–33 fps; 4K SDR 18 fps; 4K HDR10
  12 fps, about 3.6 hours a film. 1.0–2.7 GB of GPU memory.

## Open questions

1. **Lead after open and seek.** The first second or two runs without workers. Check on the Vision
   Pro that the switch to a worker's larger fields doesn't show. On a Quest, it plays without
   enhancement until pieces arrive.
2. **Mapping a transcode to media time,** for Jellyfin HLS and Stash's live transcode, to within a
   frame.
3. **Core ML vs ONNX Runtime parity** for each model. If they don't agree within tolerance, each
   backend family gets its own profile, and a title sticks to one family. Answered for the 3D
   Smooth Motion models and the 2D flow, depth and GMNet kinds (see "Answers so far"): every kind
   gets its own ONNX profile.
4. **Worker throughput by kind:** measured on the M2 Max for every kind and on an RTX 3080 for 3D
   Smooth Motion and the three 2D kinds (see "Answers so far").
5. **TLS-PSK in Rust:** answered: OpenSSL (see "Answers so far").
6. **Quest player passes:** GLES vs Vulkan in the Quest port's renderer (Spatial SDK, Media3
   surfaces); see `quest-parity-roadmap.md`.
7. **Stash stereo layout:** detection only, or a tag convention as well.
8. **The Windows converter's depth maths:** answered: a Rust port (see "Answers so far").
9. **Spatial video on Windows:** answered: no usable MV-HEVC encoder through ffmpeg yet, so spatial
   output stays Mac only (see "Answers so far").
10. **Depth model licences:** answered (see "Answers so far"): sideload and opt-in builds only.
11. **Conversion speed** on the M2 Max and on CUDA per model and resolution: answered for Depth
    Anything V2 Small (see "Answers so far"): an evening's job at 1080p on either, a night's at 4K
    HDR on the 3080.

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
