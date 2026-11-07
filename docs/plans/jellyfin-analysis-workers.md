# Analysis workers for Jellyfin titles

Status: plan, revised 2026-11-07. It started on 2026-11-01 as "a Mac helping the headset", agreed then
and kept as a short note in `blu-ray-3d-smooth-motion.md`. On 2026-11-07 the user scoped it down
and widened it:
- **Jellyfin only.** Stash, Local and shared files are out of scope.
- **Each node connects to Jellyfin on its own.**
- **CUDA PCs as an optional tier:** one on the LAN and one remote, joining only if the M2 Max and the
  M5 headset prove insufficient. Which machines these are is kept out of this public repo.

## Goal

The headset's own compute, not its displays, sets the picture quality today:
- **Smooth Motion:** flow runs at a quarter of the eye's size, because RIFE at 960×576 takes 48 ms on
  the headset's ANE.
- **AI 3D real-time:** uses the small depth model (~28 ms a map, 38–45 ms beside the interpolator),
  holds depth for up to a frame, and steps quality down when warm.
- **AI HDR for video:** would have to share the same Neural Engine.

Other machines run the networks at full working size, ahead of the playhead, and the headset only
presents: warps, blends, gain lookups and the compositor. The aim is to use what the displays can
show:
- in-between frames at the display's rate (96 Hz for 24 fps, 100/120 for 50/60);
- the pre-processed depth quality without waiting for a conversion;
- HDR highlights within the measured 2.5–3× headroom.

## Shape: the plugin coordinates, every node talks only to Jellyfin

```
               headset (M5)                      workers
        plays, fetches chunks,            M2 Max · servo M1 · [LAN GPU] · [remote GPU]
        falls back to its own work        each with its own Jellyfin API key
                   │                                │  ▲
   GET chunks ─────┤                 claim jobs ────┤  │ read the media
   playback reports│                 PUT results ───┤  │ (original or proxy)
                   ▼                                ▼  │
             Jellyfin on servo + the Atmos Objects plugin (SmoothMotionService)
             job queue · chunk store · the existing SmoothMotion/ routes
```

- **The headset doesn't change transport.** It already streams tracks from the plugin in 10 s chunks
  (`StreamingAnalysisTrack` + `SmoothMotionTracks`). What's new is that a chunk can now exist because
  a worker made it moments ago, not only because the nightly task did.
- **Workers are Jellyfin clients.** Each logs in with its own API key, reads the media through
  Jellyfin and posts results back to the plugin.
  - Nothing pairs with anything, and no device hands another a credential or a URL.
  - `RAVECompanion` isn't needed for this. Its other consumers are unaffected.
- **servo's own analysis becomes worker 0.** Today's nightly `vergence analyze` runs through the same
  queue, so there is one scheduling path, not two.
- **Fallback is unchanged.** A chunk that isn't there means the headset's own quarter-size work or a
  pass-through. Playback never waits for a worker.

## What is built

| Piece | Where | State |
| --- | --- | --- |
| Analysis track format | Vergence `AnalysisTrack` (6abe4b0) | Used. Kinds `flowPair`, `disparity`, `depth`, `gainMap`. Flow + disparity ≈ 25 KB a frame |
| Producer | `vergence analyze` (VergenceCLI, Core ML) | Mac only. Fed raw frames by ffmpeg. 35–39 fps on the M2 Max, 16.3 on servo's M1 (flow + disparity, 1080p 3D) |
| Server analysis + chunk routes | Plugin `SmoothMotionService`, `SmoothMotion/` routes (README "Smooth Motion tracks") | Nightly, one title at a time, 3D titles only, local process only |
| Chunked consumer | `StreamingAnalysisTrack` + `SmoothMotionTracks` | Plays server tracks around the playhead |
| Player passes | Vergence `SharedFieldInterpolator` | 3D discs and live 3D Library titles |

## Workloads

| Workload | Headset alone (M5) | On a worker | Record kind | Headset's part |
| --- | --- | --- | --- | --- |
| Smooth Motion, 3D titles | NeuFlow 512×288, 14 ms | Today's track, made live for titles the nightly hasn't reached | `flowPair`, `disparity` | `SharedFieldInterpolator`, ~2 ms |
| Smooth Motion, 2D and AI 3D | VideoToolbox (≤1080p, 15–19 ms on the ANE) or GPU flow | RIFE at 960×576 (13.5 ms on the M2 Max GPU) or larger | `flowPair` (one eye) | A mono shared-field pass (new; the stereo one is the template) |
| AI 3D depth | Real-time model, ~28 ms, ≤1-frame hold | A larger depth model at a larger size, with the pre-processed refinement (bilateral, ±2-frame lookahead, cut-aware range) | `depth` | Warp only; the ANE is left idle |
| AI HDR for video | GMNet keyframes competing for the ANE | GMNet every few frames or every frame, fitted to a gain grid | `gainMap` (grid layout to pin) | One 3D-texture lookup in the warp or draw shader |

With every workload covered by workers, the headset's Neural Engine is idle and its GPU runs only the
presentation shaders.

## The plugin's job queue

- **Unit of work:** a 2 s **piece** of a title's chunk, for one set of kinds and one profile.
  - A 10 s chunk still exists for storage and downloads; it's assembled from its pieces.
  - `GET …/Chunks/{n}` serves the pieces that are ready so far. The headset already copes with a
    chunk that has no records for some frames: they pass through.
  - Ten-second units would make the first chunk after a seek about 7 s late even on the M2 Max.
- **Demand:**
  - The headset already reports playback progress to Jellyfin. The plugin listens to the session
    manager's progress and seek events, and to the chunk requests themselves.
  - From these it knows each session's title, media time and rate, with no new route on the
    headset.
- **Priority:**
  1. **Live:** pieces within ~30 s of an active session's playhead.
  2. **Ahead:** the rest of that title.
  3. **Backfill:** the nightly library work.
- **Placement by distance from the playhead:**
  - The nearest pieces go to the lowest-latency worker that keeps up: the M2 Max, or the GPU PC on
    the LAN.
  - Pieces minutes ahead and backfill can go anywhere, including a remote worker, where a slow link
    and latency don't matter.
- **Leases:** a worker claims a piece with a lease of about twice its measured time, and an expired
  lease goes back to the queue. A seek re-prioritises: pieces behind the new playhead drop to
  backfill rather than being cancelled, so work done is kept.
- **Profiles:**
  - A profile is one model, working size and precision per kind, e.g. `flow:rife425lite@960x576/fp16`.
    Workers advertise the profiles they can run.
  - **One title uses one profile per kind**, so neighbouring chunks never come from numerically
    different networks.
  - A better profile can replace a title's chunks later (backfill on a GPU at a larger size), whole
    title at a time.
  - Core ML on a Mac and CUDA on a PC running "the same" model differ numerically. Each pair is
    checked against the reference with `scripts/check-analysis-track.py`'s tolerances before both
    may share a profile name.
- **Worker routes:** register (name, profiles, measured throughput), long-poll for the next piece,
  upload a piece's records. Authorised by the worker's own API key, with admin rights.
  - The upload is checked against the title's frame index before it's stored: frame count, times,
    profile and kinds.

## Reading the media

- **Keyed by media time.** Records are keyed by the original file's presentation time. The headset
  maps what it plays, including a transcode, to media time, as it already does for resume and
  progress.
- **LAN workers** (the M2 Max, the GPU PC on the LAN) read the **original** with a static,
  byte-ranged stream and decode it themselves. That costs servo no transcode, and frames match
  exactly.
- **Remote workers** read a **proxy at the working size**. The models never look at
  more than about 960×576, so the proxy only has to keep every frame and its timestamps, with no
  frame-rate conversion and no dropped or doubled frames:
  - a high-quality HEVC or H.264 transcode, a few Mbit/s instead of a remux's 25–100;
  - made on servo with VideoToolbox, cached per title, so many pieces share one transcode;
  - checked against the original's frame index like any upload.
- **3D titles:** packed frames keep their packing, and discs go through vergence's own MVC decoder,
  which only the Mac and servo have. PCs take packed 3D files and 2D only.

## Workers

| Worker | Runs | Role | Notes |
| --- | --- | --- | --- |
| **M5 headset** | its own fallback | always | Not a queue worker |
| **servo M1** | `vergence` (Core ML) | backfill (worker 0) | 16.3 fps: too slow for live; keeps the nightly |
| **M2 Max** | `vergence worker` (Core ML), a launch agent | live and ahead | The first live worker. Works only while the Mac is awake and on the network; no waking it |
| **GPU PC on the LAN** | Python + PyTorch CUDA producer | live and ahead, if needed | See below |
| **Remote GPU PC** | the same producer | ahead and backfill, if needed | See below |

- **`vergence worker`** is a new CLI mode: register, long-poll, decode a piece with ffmpeg (as
  `analyze` is fed today), run the models, upload. It's the same binary as `analyze`, so there's no
  Convolution app worker mode.
- **The PC producer** is Python. RIFE, NeuFlow, Depth Anything and GMNet are all PyTorch originals,
  and the E2 scripts already run them. It writes `AnalysisTrack` records, and a golden test checks
  that VergenceCore reads its output exactly.
- **A GPU PC shares its machine.** A worker there runs at low priority. It stops claiming pieces, and
  gives up held leases, whenever the GPU or its memory is wanted by anything else. The models need
  little VRAM.
- **A LAN PC that sleeps** can be woken by servo with Wake-on-LAN when live demand needs it. The
  plugin treats it as optional, never as required.
- **A remote PC** is too far for live pieces, and servo's upload speed sets how far ahead it can get.
  The proxy's frames are decoded there; results are all that come back.

**Gate for the PCs:** they join only if the M2 Max can't stay ahead with margin, about 1.3× real
time, for the kinds and profile a title needs. Measure that first (Order, step 4).

### AI HDR for video, in short (proposed 2026-11-07, not started)

It is meant to work on the headset alone too, with the workers as a quality upgrade.
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

## Open questions

1. **Lead after open and seek.** The first second or two is headset-only, then pieces arrive. Check
   that the switch from the headset's quarter-size fields to a worker's larger ones doesn't show.
2. **Mapping a transcode to media time.** Jellyfin HLS transcodes start at an offset. Confirm on
   device that the player's media time matches the original's presentation times to within a frame.
3. **Mixed backends in one profile.** Is Core ML vs CUDA close enough for one profile, or does each
   backend need a profile of its own? If so, a title sticks to one kind of worker.
4. **Worker throughput by kind** (unmeasured): M2 Max for mono flow at 960×576, depth at a larger
   size and GMNet; and every model on the CUDA GPUs.
5. **servo's upload** for a remote worker's proxies, and its VideoToolbox budget for making them while it
   also serves the headset's own stream.

## Order

1. **Queue in the plugin.** Pieces, leases, priorities from playback sessions, worker routes, upload
   checks. servo's nightly analysis becomes worker 0 through it. Use `scripts/dev-jellyfin.sh` for the
   tests, not the live server.
2. **`vergence worker` on the M2 Max**, with its own API key and today's 3D profile (flow +
   disparity). The player side exists and the quality is known, so this tests the live path end to
   end.
3. **Headset:** partial chunks around the playhead, and the measured lead after open and seek.
4. **Mono flow, depth and gain grids** on the Mac, one at a time, each with its headset pass.
   Measure the M2 Max's real-time factor for each combination.
5. **Only if step 4 falls short:** the Python CUDA producer, then the GPU PC on the LAN (yielding,
   woken on demand), then the remote one for ahead and backfill with working-size proxies.
6. **Measure on the headset** throughout: the share of frames on worker results, the handover after
   a seek, the headset's ANE and GPU load, and thermals over a film.
