# Smooth Motion for 3D Blu-ray (true stereo)

Status: plan (2026-11-01). Direction revised the same day: **option E (neural flow, one shared
motion field) is the recommendation**; B is the VideoToolbox-only fallback. Phase E0 (convert and
time the models on the headset) is done; E1 (quality) is next. Smooth Motion today covers flat 2D in the video window
(`NativeMetalVideoPlayerView`, SDR, visionOS) and AI 3D (the stereo pump, mono frames before depth).
A packed stereo pair (`PackedStereoLayout`: 3D Blu-ray, SBS/TAB files) is deliberately passed through
unchanged. This is the plan for changing that.

## Why stereo is not "interpolate each eye"

An interpolated frame is a guess: the model estimates motion between two frames and invents the
pixels in between. Run separately on each eye, the two guesses are made from different pictures, so
they differ, most of all where the guess is hard (occlusions, thin objects, repeating texture, motion
blur). In mono that shows as a brief smear. In stereo the two eyes then disagree about *where* a
thing is, which the brain reads as a depth error or as rivalry (shimmer, a "doubled" edge), every
other frame, at 24 Hz. That flicker is more likely to cause the discomfort Smooth Motion is meant to
remove than the judder it replaces.

So the requirement is **binocular consistency**: the in-between right eye must be the in-between left
eye seen from the right eye's position, with a disparity between the disparities of the two real
pairs it sits between. Per-eye quality matters less than that.

AI 3D gets this for free, because both eyes are warped from one interpolated mono picture. True
stereo has two real pictures and no depth map, so it has to be earned.

## What the platform offers (visionOS 26/27 SDK, checked 2026-11-01)

| API | visionOS | Use here |
| --- | --- | --- |
| `VTLowLatencyFrameInterpolation` | yes | One eye's in-between frame. `420v` only, at most 1920 per side and 2,073,600 pixels: one 1080p eye fits; a packed 1920×2160 pair does not. About 16 ms per frame on an M2 Max; 17–34 ms on the headset beside AI 3D's depth model, so less alone. |
| `VTMotionEstimationSession` | yes | Block motion vectors between two frames, with configurable block size and multi-pass "true motion" search. Fed the left and right eye of one instant, its vectors are a coarse disparity map. Not measured yet. |
| `VTOpticalFlow`, `VTFrameRateConversion` | **macOS/iOS only** | Dense flow and high-quality conversion. Only usable offline (Mac or servo), see option D. |
| Stereo-aware interpolation of any kind | **none** | Nothing takes a stereo pair, MV-HEVC layers or tagged buffers. |

Nothing native does this. The parts are: one interpolator for one eye, a block-motion estimator, and
our own Metal code.

Vergence already has two relevant pieces:
- `StereoSubtitleCompositor`'s `stereoSubtitleMatch` kernel matches the two eyes of a packed pair
  (sparse: 16×4 patches behind a subtitle cue, 128 disparity candidates). That kernel is a dense
  disparity estimator in waiting.
- The fake-3D warps (`StereoMeshWarp`, `StereoLayeredWarp`, `StereoBoundaryWarp`) synthesise a view
  from a picture and a per-pixel disparity, including hole handling. Those are view synthesis in
  waiting.

## How a 3D Blu-ray plays now

`MVCPictureSource` (Hypnos) reads the disc image over HTTP and decodes both MVC views with edge264 on
the CPU. It hands over the left eye as one pixel buffer for the film player's own layer (2D), and
both eyes stacked top and bottom (`StereoPixelBufferMaker(layout: .packed(.topAndBottom))`, 1920×2160)
for the stereo tap. In 3D the film player feeds that tap through a `SampleBufferFrameSource` into the
stereo pump with `packedStereo: .topAndBottom`. The pump crops each eye out and runs no depth model,
so **the Neural Engine is idle during 3D Blu-ray playback**. That differs from AI 3D, where
interpolation fought the depth model and lost (device, 2026-10-31). The frame rate is 23.976. The
budget per real frame is 41.7 ms.

## Options

**A. Each eye independently.** Split the pair, interpolate L and R (two low-latency calls, ~2×16–20 ms
on an idle ANE, tight against 41.7 ms), and repack. Little new code: `InterpolatingFrameSource` with
a split/repack step and two `VTMidFrameInterpolator` sessions. It does nothing for consistency (see
above). Worth building first only as a baseline, to learn whether the disagreement is visible in
practice with this model on real Blu-ray content. It may be mild on slow pans, which are the actual
use case.

**B. Interpolate the left eye; make the right eye from it (VideoToolbox-only fallback to E).**
1. For every *real* pair, estimate disparity D(t), from left to right. Each pair is estimated once and
   reused for both in-between frames that touch it.
2. Interpolate the left eye: L(t+½) with one low-latency call.
3. D(t+½) = the average of D(t) and D(t+1), each sampled along the left eye's motion. A first version
   can sample in place, since a slow pan moves little.
4. R(t+½) = L(t+½) forward-warped by D(t+½), with a z-test so nearer content wins: a one-sided
   version of the existing warp.
5. Holes, meaning what only the right eye sees (disocclusions at the right edges of near objects),
   are filled from the real right eyes R(t) and R(t+1) at the same place, blended by phase. A slow
   pan moves a hole only a few pixels in half a frame, so this is close to exact.
6. Where the left-to-right and right-to-left disparities disagree by more than ~1 px (unreliable
   match), use option A's right-eye pixels there, or hold the nearer real right eye. The fallback is
   local, never the whole frame.

Cost: one interpolation (~16–20 ms, ANE), one disparity map per real pair (GPU or ME session, to be
measured), and a warp (~1–2 ms GPU, judging from the fake-3D warps). It fits the budget with room to
spare, and the ANE does half of option A's work.

What it guarantees: both eyes carry the left eye's motion, so they cannot disagree about motion.
The in-between frame's depth lies between the real neighbours' depth by construction.

**C. Interpolate both eyes as one frame.** Pack L|R at half width into 1920×1080 and interpolate
once, so one model pass sees both. This is rejected: the in-between frames would have half the
horizontal resolution of the real ones, which shows as a 24 Hz soft/sharp shimmer, and the model
still estimates each half's motion independently near the seam.

**D. Offline, best quality (optional, later).** A `vergence` command on the Mac or servo would decode
the MVC, run the macOS-only `VTFrameRateConversion` per eye with `VTOpticalFlow` between eyes for the
consistency step (B's steps 3–6 with dense flow), and write a 48 fps MV-HEVC file the film player
plays like a pre-processed AI 3D video. Measured on an M2 Max at 1080p: 33–46 ms a frame, so ~3–4
hours for a two-hour film. It belongs with "AI 3D (Pre-Processed)" as a conversion, not with live
playback.

**E. Neural flow once per real pair, one motion field for both eyes (recommended, revised
2026-11-01).** A small flow network runs once per pair of real frames; every in-between frame after
that is a cheap shader. Both eyes take their motion from the same field.
1. **Flow.** For each real pair (L0, L1), a network estimates motion. Two candidates, both converted
   to Core ML by `scripts/convert-interp-model.py` and timed on the headset (phase E0):
   - **RIFE 4.25 / 4.25 lite** (MIT): the de facto standard for video interpolation (SVP,
     Flowframes). It is timestep-conditioned: it predicts the flows from time t back to L0 and on to
     L1, plus a blend mask, so each in-between moment is a full run. Quality reference.
   - **NeuFlow v2** (Apache-2.0): flow only, built for edge devices. One batched run gives F0→1 and
     F1→0; any t is then a flow reversal in a shader (Super SloMo's
     `Ft→0 = −(1−t)t·F0→1 + t²·F1→0`, `Ft→1 = (1−t)²·F0→1 − t(1−t)·F1→0`), so 4× costs the same as 2×.
   Flow runs at about a quarter of the eye's size (480×288–512×288, see E0); warp and blend run at full resolution.
2. **Any number of in-between frames.** Arbitrary t gives 4× for 96 Hz on the Vision Pro, and a
   "smoothness" strength (squeeze the in-between moments towards the real frames, like a TV's dejudder
   level) for people who find full smoothing looks like video.
3. **Disparity is sideways flow.** The same network, run on (L, R) of a real pair, gives the dense
   disparity B needed, without a separate stereo matcher. One estimate per real pair, reused by both
   in-between spans that touch it.
4. **Right eye from the shared field.** The right eye's motion is the left eye's motion carried across
   by disparity (`F_R(x) ≈ F_L(x − D(x))`, plus the change in D between the real pairs). R(t) warps
   the *real right eyes* along that field, so right-eye-only content comes from right-eye pixels, and
   any motion error is the same error in both eyes: one slightly wrong object in 3D, not rivalry.
5. **Fallback.** Where L→R and R→L disagree by more than ~1 px, or the flow's forward/backward check
   fails, blend the real frames by phase there. VideoToolbox (`VTMidFrameInterpolator`) stays the
   2D default until E beats it on the headset.

Cost per real pair (to be measured): flow L0→L1 both ways, plus disparity on the new pair, all on the
otherwise idle Neural Engine within 41.7 ms; shaders per in-between frame on the GPU.

It also helps AI 3D later: the same flow can warp the depth map to the in-between moment (no depth
inference for in-between frames) and steady depth from frame to frame.

**Other platforms (Quest and other VR headsets): the ML runs off the headset** (the user's call,
2026-11-01). A desktop companion or the Jellyfin server runs the same models (PyTorch / ONNX on a GPU)
and streams the result already interpolated, so a headset's own NPU doesn't matter. Only the Apple
path runs on-device. What stays shared is the algorithm (flow reversal, disparity transfer,
consistency fallback, governor) in VergenceCore, and the model files.

Rejected: AMD FSR 3 frame generation. It is built around a game engine's motion vectors and depth,
falls back to its own optical flow on video, assumes ≥60 fps input (24 fps moves 2.5× further per
frame) and makes one frame (2×). FSR 2's temporal part is upscaling, and FSR 4's ML is AMD-GPU only.

## Phases

**E0. Convert and time the models on the headset** (done 2026-11-01):
- `scripts/convert-interp-model.py` converts RIFE 4.25, 4.25 lite and NeuFlow v2 to Core ML at fixed
  sizes and checks each against PyTorch.
- Vergence's `InterpolationModelBenchmark` times every model in `Documents/InterpModels` on each
  compute-unit choice and reports which ops land on the Neural Engine (`grid_sample` may not).
- Go ahead if a pair's work fits in ~25 ms on the headset, leaving room for the disparity pass.

Results (Vision Pro M5, visionOS 27, idle app, fp16, 2026-11-01; median ms per prediction):

| Model, working size | CPU+ANE | CPU+GPU | Notes |
| --- | --- | --- | --- |
| RIFE 4.25 lite 480×288 | **12.1** | 7.4 | all 294 ops on the ANE, warps included |
| RIFE 4.25 lite 640×384 | 22.0 | 12.9 | |
| RIFE 4.25 lite 960×576 | 47.7 | 20.5 | full 4.25 is the same (47.8 / 23.3) |
| RIFE 4.25 lite 1280×768 | 91.3 | 42.3 | |
| RIFE 4.25 lite 1920×1088 | 936 (CPU) | 89.7 | the ANE refuses it; Core ML falls back to the CPU |
| NeuFlow v2 512×288, 4 iterations, both ways | **14.0** | 20.3 | |
| NeuFlow v2 768×432, one way | 32.1 | 33.4 | |
| NeuFlow v2 768×432, 4 iterations, both ways | 41.8 | 46.6 | |
| NeuFlow v2 768×432, both ways | 56.9 | 59.6 | |
| NeuFlow v2 960×544, both ways | 125.5 | 103.8 | its 1/16 all-pairs match grows with the square of the pixel count |

What this means:
- The headset's ANE is no faster than an M2 Max's on these (RIFE 960×576: 48 ms on both); the
  M2 Max GPU is about 1.5× the headset's. Cost grows faster than the pixel count, so the working size
  is the lever.
- **Flow has to run at about a quarter of the eye's size (480×288 to 512×288).** There, one RIFE run
  (12 ms) or one bidirectional NeuFlow run (14 ms) plus a one-way disparity run fits a 41.7 ms pair on
  the ANE with the GPU left to the renderer. 640×384 RIFE (22 ms) is the next step up if quality needs
  it.
- RIFE's per-timestep cost rules out one run per in-between frame at 4×. Run it once at t=½ per pair
  and derive F0→1 ≈ 2·F½→1 (and F1→0 likewise) for flow reversal at other t; a slow pan is close to
  linear motion, which is the assumption this makes.
- Not measured yet: the same runs while the pump renders and edge264 decodes (contention), and
  quality. **Next (E1): quality on real footage at these sizes**: hold out every other frame of a
  24 fps clip, predict it from its neighbours, and compare RIFE ½-size, NeuFlow ½-size and
  `VTLowLatencyFrameInterpolation` against the real frame (PSNR/SSIM, plus a look at pans and
  occlusion edges); for stereo, the in-between pair's left/right residual against the real pairs'.

The phases below were written for option B; under E, phase 3 becomes "flow, disparity transfer, warp
and fallback shaders" and phase 0's disparity work is the flow network's.

0. **Measure on the headset** (no UI):
   - Low-latency interpolation at 1920×1080 while edge264 decodes MVC. CPU decode plus ANE plus the
     pump may contend on memory bandwidth, not on the ANE.
   - `VTMotionEstimationSession` between L and R: time per pair, vector block size, how much vertical
     noise there is (a rectified Blu-ray pair should be ~0 vertically), and whether the vectors hold
     up on low texture.
   - The same with a dense version of `stereoSubtitleMatch` (8×8 blocks, horizontal search only,
     ±128 px) on the GPU. Pick the cheaper of the two that gives a usable map.
   - Use the lossless paused-frame fixtures (`Export paused stereo frames as lossless replay
     fixtures`) to do this on the Mac first, then confirm on device.
1. **Plumbing.**
   - A `StereoMidFrameInterpolator` protocol: `(L0, R0, L1, R1) → (Lm, Rm)`.
   - `InterpolatingFrameSource` gains a packed mode that splits the pair (a crop through
     `VTPixelTransferSession`, since the interpolator needs separate buffers anyway), checks for cuts
     on the left eye, and repacks into the pump's packed layout, so the pump and renderer need no
     changes.
   - The flag on `Pseudo3DStereoEngine` stops excluding `packedStereo`. The film player passes Smooth
     Motion for discs as it does for AI 3D.
2. **Option A behind a developer toggle.** It is the baseline and the fallback pixels for step B.6.
   Look at slow pans on the headset; if no rivalry is visible, A may be enough for discs and B is a
   quality step.
3. **Option B:** disparity map, one-sided warp, hole fill, consistency fallback. Test it:
   - On synthetic pairs (a known disparity ramp moving sideways): the in-between pair's measured
     disparity must lie between the neighbours', with no vertical disparity.
   - On fixtures: the left/right residual of the in-between pair must be no worse than the real pairs'.
4. **Presentation.**
   - Display criteria for 47.952 fps (96 Hz) on the stereo window. Neither the AI 3D window nor the
     film player's stereo plane sets it yet; the flat video window now does.
   - Governor thresholds for a packed pump: no depth model, so the pump's reserve fills faster; start
     from `.depthPump` and tune from the `interp` log line.
5. **2D Blu-ray (cheap, independent).** The film player's 2D picture of a disc is the decoded left eye
   (`FilmPictureFrame.picture`). An interpolation stage over `MVCPictureSource`'s frames before they
   are enqueued gives discs Smooth Motion in 2D with no stereo question at all. A film's own
   (non-disc) 2D picture goes compressed to an `AVSampleBufferDisplayLayer` and is usually HDR or
   Dolby Vision, which the 8-bit interpolator can't take, so that is out of scope.

## Later: a Mac helping the headset (idea, 2026-11-01)

Proposed, not agreed or started. A paired Mac (Convolution's own macOS build, in a background worker
mode) computes flow, disparity, depth and gain maps **ahead of the playhead** and sends only the
results; it opens the same Jellyfin/Stash/disc URL and decodes the video itself, so no frames cross.
- Results are small: a 512×288 flow field or a 518×392 depth map is 0.4–0.6 MB raw, likely 50–150 KB
  quantised and zstd-compressed, a few MB/s at 24 pairs a second.
- One **analysis track** format (kind, presentation timestamp, model id and version, size, payload) in
  VergenceCore, written by every producer: a live Mac, servo or the Jellyfin server offline, the
  AI 3D (Pre-Processed) cache, and the server path for Quest. Keyed by media id + model + timestamp.
- The headset asks for "range [t, t+N] at quality Q", keeps doing its own quarter-size work near the
  playhead and whenever results are late, and re-asks on a seek. The Mac can afford bigger working
  sizes (M2 Max GPU: RIFE 960×576 in 13.5 ms) and bigger depth models.
- Transport: Longwave's pairing and encrypted channel are app-local (`Longwave/Shared/
  CompanionPairing.swift` and its crypto); a second consumer means moving them into RAVENet first.
- Open: the Mac's access to the media (prefer a short-lived authorised URL from the headset), both
  sides playing the same stream variant, the lead time after open/seek, keeping the Mac awake.
- Order: E1 quality first; then a Mac writes an analysis track to a file and the headset plays it
  back (proves format and frame matching, no network); then the live channel.

## Risks and open questions

- **Memory.** A packed 1080p pair in BGRA is 16.6 MB. In-between frames double what the pump holds;
  check the pump's reserve size at 48 fps.
- **CPU.** edge264 MVC decoding already runs on the CPU. If the headset can't decode 2× views plus
  the split/repack transfers in time, the governor will keep interpolation paused. That's safe, but
  it would mean the feature never runs.
- **Cut detection** on the left eye only. A cut is the same in both eyes, so this is fine.
- **Subtitles** are drawn by the pump after the frame source, so they aren't interpolated. Their depth
  matching (`stereoSubtitleMatch`) then sees in-between pairs, which have consistent disparity under
  option B.
- **HDR discs** (UHD Blu-ray has no 3D, so 3D discs are SDR). Not an issue for this path.
