# Smooth Motion for 3D Blu-ray (true stereo)

Status: plan (2026-11-01). Direction revised the same day: **option E (neural flow, one shared
motion field) is the recommendation**; B is the VideoToolbox-only fallback. Phases E0 (convert and
time the models on the headset) and E1 (quality on real 3D Blu-ray footage) are done: RIFE 4.25 lite
at 480×288 is the flow model, and VideoToolbox's interpolator turned out at least as good per eye, so
E's case rests on binocular consistency and 4×, not on picture quality. E2 (the right eye from the left eye's field, on the Mac) confirms it: a
third of per-eye rivalry, real-pair level on the slow pan, the most faithful depth; fire and smoke stay open.
E3 built the Mac producer (`vergence analyze`): it matches PyTorch, runs faster than real time, and
stores about 25 KB a frame. E4 built the player's half (`SharedFieldInterpolator`, one Metal pass,
~2 ms a pair on an M2 Max, identical to the reference) and wired it into the film player's 3D
picture through a track file. On the headset (Bumblebee's disc, 2026-11-01) it made ~23 in-between
pairs a second at 3–9 ms each; the user liked the result. The video window's live 3D (a Jellyfin
SBS/TAB title, half or full) takes a track the same way since then. Smooth Motion also covers flat 2D
in the video window (`NativeMetalVideoPlayerView`, SDR, visionOS) and AI 3D (the stereo pump, mono
frames before depth). A packed pair without a track still passes through unchanged.

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
4. **Right eye from the shared field.** The right eye's motion is the left eye's motion read across
   by disparity, `F_R(x) = F_L(x + D_t(x))`, with `D_t` the right→left disparity mixed in place between
   the real pairs. R(t) warps the *real right eyes* along that field (with RIFE's mask read the same
   way), so right-eye-only content comes from right-eye pixels, and any motion error is the same
   error in both eyes: one slightly wrong object in 3D, not rivalry. Do **not** add the change in
   disparity over the span: that means reading disparity a second time at the moved position, and
   near a silhouette either read lands on the other depth layer (measured in E2: 7 dB lost and a
   doubled outline).
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

**E1. Quality at the working sizes** (done 2026-11-01). `scripts/interp-quality.py` (with
`scripts/vt-interp-helper.swift` for VideoToolbox) on six 3-second clips of the Bumblebee 3D
Blu-ray, decoded losslessly with `vergence decode` (both eyes): two slow pans (a crowd behind two
people; a face against fire), a car interior, a dark garage with a car body sliding past the
camera (occlusion), a handheld junkyard shot with a hand moving, and a dark robot fight with motion
blur. For each frame i+1 we predicted it from i and i+2 and compared it with the real one, at
1920×1080. The small runs mirror the planned shader: the frames are scaled to the working size, the
model's flow and mask are scaled back up, and the warp and blend run at 1080p. PyTorch on the Mac;
the Core ML fp16 models from E0 give the same pictures (within 0.1 dB on spot checks).

2×, t = ½, 210 held-out frames, left eye (PSNR on luma in dB, higher is better; "moving" is the
pixels moving at least 4 px per 24 fps frame):

| Candidate | PSNR | SSIM | Moving PSNR | Headset cost |
| --- | --- | --- | --- | --- |
| Repeat the frame (no interpolation) | 27.6 | 0.886 | 23.9 | – |
| 50/50 blend | 31.0 | 0.910 | 26.7 | – |
| `VTLowLatencyFrameInterpolation`, 1080p | **37.1** | **0.957** | **31.5** | an eye: 15 ms on the Mac, 17–34 ms on the headset beside AI 3D |
| RIFE 4.25 lite, 480×288 | 36.5 | 0.948 | 31.3 | 12 ms a pair |
| RIFE 4.25 lite, 640×384 | 36.8 | 0.950 | 31.4 | 22 ms |
| RIFE 4.25 lite, full 1920×1088 (ceiling) | 36.7 | 0.949 | 31.2 | doesn't fit |
| NeuFlow v2, 512×288, 4 iterations, flow reversal | 36.0 | 0.951 | 30.7 | 14 ms |
| the same with a forward/backward occlusion weighting | 34.6 | 0.948 | 29.6 | |

Per clip, PSNR: the pans 38.5–40.2 (crowd) and 36.2–36.3 (fire), the car 42–44, the garage 38.8–40.2,
handheld 31.7–34.5 and the robot fight 27.6–28.6 for every flow method; blend sits 7–9 dB below the
best elsewhere, and only 3 dB on the fire and the fight, where nothing does well. VT leads on the pans and the fight, RIFE on the garage occlusion and the
handheld shot, NeuFlow on the car interior.

4× stress test, from (i, i+4) predict i+1, i+2, i+3 (PSNR at t = ¼ / ½ / ¾). Four frames apart is
far more motion than 24→96 really asks for, so only the ranking means anything:

| Candidate | t = ¼ | t = ½ | t = ¾ |
| --- | --- | --- | --- |
| Nearest real frame | 27.6 | 24.3 | 27.7 |
| VT (one call, 3 phases; 44 ms on the Mac) | **33.8** | **32.5** | **33.9** |
| RIFE 480×288 once at ½, other t by flow reversal | 33.5 | 32.3 | 33.3 |
| RIFE 480×288 run at each t (3× the cost) | 33.4 | 32.3 | 33.5 |
| RIFE 640×384 once, reversal | 33.5 | 32.5 | 33.2 |
| NeuFlow 512×288, reversal | 32.9 | 31.5 | 33.2 |

Stereo: left and right eyes interpolated separately (option A), the in-between pair's disparity
measured with NeuFlow at full size, on the pixels where the real pair's left→right and right→left
matches agree within 1 px. A rectified Blu-ray pair has no vertical disparity, so vertical disparity
in an in-between pair is pure rivalry, and it is the cleanest measure here (the real pairs show it
on 0.1–1.2% of pixels, which is the estimator's own noise):

| Clips | Real pair | VT per eye | RIFE 480 per eye | NeuFlow 512 per eye (with occlusion weighting) |
| --- | --- | --- | --- | --- |
| Crowd pan, car, garage, handheld: pixels with vertical disparity > 1 px | 0.1–1.0% | 0.8–10.6% | 2.6–17.6% | 0.6–9.5% |
| the same: horizontal disparity off the real pair's by > 1 px | – | 2.5–14% | 7–22% | 2.4–13% |
| Fire pan and robot fight: vertical > 1 px | 0.6–1.2% | 25–29% | 35–40% | 22–23% |

What this means for option E:
- **Quarter size is good enough.** RIFE at the full 1920×1088 is no better than at 480×288
  (36.7 against 36.5 dB, and worse on the occlusion clip), so the working size is not what limits
  quality; the model is. **RIFE 4.25 lite at 480×288 is the flow model.**
- **640×384 is not worth its 22 ms**: +0.3 dB overall, +0.1 dB on moving pixels, nothing visible in
  the crops. Spend the ANE time on the disparity run instead.
- **RIFE once per pair covers 4×.** Flows derived from the t = ½ run lose at most 0.25 dB against a
  run per t, and only at ¾. NeuFlow's bidirectional output is up to 0.9 dB worse, so it has
  no edge left; keep it in mind only as the disparity estimator.
- **The surprise: VideoToolbox's low-latency interpolator is at least as good per eye** (+0.6 dB
  over RIFE 480 at 2×, though only +0.1 dB on moving pixels; best at 4× too), and its independently interpolated eyes disagree less than
  RIFE's. So option E cannot be sold on picture quality. What it buys is one motion field for both
  eyes, arbitrary t for 4× at one model run, and 12 ms on the ANE instead of 2×16 ms.
- **Per-eye interpolation is not safe on hard scenes, whichever model does it.** On calm shots the
  eyes disagree vertically by more than a pixel on 1–18% of pixels; on fire and fast motion on
  25–40%. That is the rivalry the plan's opening section predicted, now measured, and it is why the
  shared field (E step 4) or B's disparity transfer matters. Option A alone would only be acceptable
  on slow pans, and even there VT is the better per-eye engine.
- Failure modes look different in the worst-region crops (`build/interp-quality/crops/`): VT smears
  into blocky mush where it gives up, RIFE fades the moving object into a ghost, NeuFlow tears it into
  sharp broken pieces. RIFE's soft failure is the kindest of the three to show for 10 ms.
- The occlusion weighting from NeuFlow's forward/backward check made things worse in both readings
  of it (down-weighting or preferring the unmatched side). At 512×288 the check fails too widely to
  steer the blend; RIFE's learned mask does that job better.
- Caveats: one film, six clips, 210 frames; the photometric left/right residual turned out useless
  as a rivalry measure because blur lowers it (VT's in-between pairs scored *better* than the real
  ones); the disparity estimator itself is unreliable in fire, smoke and dark motion blur.

### E2: the right eye from the left eye's field (Mac, 2026-11-01)

`scripts/stereo-shared-field.py`, the same six clips, every 4th triplet (100 in-between pairs at
t = ½). The left eye is RIFE 4.25 lite at 480×288 throughout. Disparity is NeuFlow 512×288, run once
in both directions per real pair (14 ms on the headset), and only its horizontal part is used,
because a Blu-ray pair is rectified. The measurement is E1's: NeuFlow at full size, on pixels where
the real pair's two directions agree. It is also counted on **detailed pixels only** (local luma
standard deviation ≥ 4 of 255). Black sky, smoke and night tarmac otherwise dominate the vertical
count with the estimator's own guesses: every clip's worst E1 "rivalry" region turned out to be one
of those, flat in all candidates. Rivalry can't be seen there anyway.

| Method | Vertical disparity > 1 px (detailed pixels) | Horizontal off the real pair's by > 1 px | Median horizontal error | Right-eye PSNR (dB) |
| --- | --- | --- | --- | --- |
| Real pair (the estimator's noise) | 0.6% | – | – | – |
| A: VideoToolbox per eye | 9.3% | 16.6% | 1.51 px | **37.0** |
| A: RIFE per eye | 13.0% | 23.0% | 1.13 px | 36.4 |
| **E: shared field** | **4.1%** | **12.3%** | **0.43 px** | 36.0 |
| B: VT's left eye moved across by disparity | 4.1% | 21.2% | 0.47 px | 32.9 |
| B: RIFE's left eye moved across | **2.8%** | 20.7% | 0.46 px | 32.9 |

Per clip, vertical > 1 px on detailed pixels:

| Method | Car | Garage | Handheld | Crowd pan | Fire pan | Robot fight |
| --- | --- | --- | --- | --- | --- | --- |
| Real | 1.1% | 0.2% | 0.3% | 0.1% | 1.0% | 0.7% |
| A: VT | 2.2% | 5.3% | 8.4% | 0.5% | 14.2% | 25.3% |
| E | 1.7% | 2.0% | 3.7% | 0.3% | 12.2% | 4.6% |
| B: RIFE | 1.3% | 1.4% | 7.3% | 0.4% | 2.5% | 3.8% |

What this means:
- **E is the design.** It reaches the real pairs' level on the slow pan (the actual use case: 0.3%
  against 0.1%) and on the car shot. On everything else it is a half to a fifth of per-eye
  interpolation's rivalry. Its depth is the most faithful of all (0.43 px median, a third of per-eye).
  The right eye costs 0.4 dB against its own RIFE run, and it needs one RIFE run plus one disparity
  run per pair, not two RIFE runs.
- **B is the most consistent pair and the worst picture.** It is a horizontally shifted copy of the
  left eye, so the eyes can't disagree vertically, but the right eye is 3 dB worse (left-eye pixels
  where only the right eye can see, and the picture edge), and its depth is off by more than a pixel
  on a fifth of pixels. It wins on fire (2.5% against E's 12%), where flow is meaningless.
- **None of these extras earns its cost:**
  - sharpening the quarter-size disparity per pixel (a 25-tap best-match pick): +0.1 dB;
  - a second RIFE run for content only the right eye sees: +0.2 dB, rivalry unchanged;
  - the right eye's own horizontal motion with the left's vertical: rivalry back up to 7.5%;
  - blending the real right eyes where the eyes don't match: −0.9 dB;
  - switching to B wherever E's and B's right eyes disagree: −2.6 dB, because they disagree where B
    is the broken one.
  The quarter-size disparity is enough.
- **Open: fire, smoke, non-rigid motion.** There, E's shared field is a wrong field for both eyes,
  and warping two different real right frames along it doesn't stay consistent. The candidate is a
  per-scene switch to B (or to no interpolation) when the flow's confidence drops. RIFE's
  forward/backward agreement or the left eye's own error against the next real frame could drive
  it, and the governor already has the shape for it. To be measured, not designed blind.
- One film, six clips, 100 pairs. The detail-only count is the one to trust for "is it visible";
  the all-pixels count is in the script's output.

### E3: the producer on the Mac (2026-11-01)

`vergence analyze` (Vergence `Sources/VergenceCLI/Analyze.swift`, with `SharedFieldAnalysis` in
VergenceCore and `StereoFlowAnalyzer` in VergenceApple) writes an analysis track: per real frame
pair, the left eye's RIFE flow and mask (`flowPair`); per real frame, the right→left NeuFlow
disparity (`disparity`, right eye, horizontal only). It reads a disc, a clip pair, or raw packed
frames from ffmpeg (`--raw 1920x1080`), so a server can feed it any stereo file.

- **Storage.** Stored at a quarter of the model's size (flow 120×72, disparity 128×72): the
  fields are smooth, and the in-between frames came out *better* (+0.05 dB left, +0.1 dB right, on
  four clips). Int16 in steps of 1/32 of a stored pixel (half a pixel at 1080p), each row
  delta-coded, then raw DEFLATE (the record format's 0x80 flag, so a Linux or Quest-side reader
  only needs zlib). That comes to about 25 KB a frame: 6 Mbit/s live, 4 GB for a two-hour film.
  Steps measured: 1/64 px ~31 KB and lossless, 1/16 ~20 KB and −0.15 dB on the slow pan, 1/4
  ~12 KB and −0.9 dB.
- **Checked against PyTorch** (`scripts/check-analysis-track.py`, a track made from every other
  frame so each in-between has a real frame to score against). On the crowd pan the track renders
  38.57 / 38.33 dB (left / right) against PyTorch's 38.51 / 38.00, and on the robot fight 27.81 /
  27.71 against 27.80 / 27.69. The two renders agree to 41–47 dB, and the median flow difference is
  0.3–1 px at 1080p. The Core ML fp16 conversions, the Swift resize (bilinear like
  `F.interpolate`, straight from 4:2:0) and the storage cost nothing measurable.
- **Speed on an M2 Max: 35–39 frames a second**, faster than the film, with RIFE on the Neural
  Engine (13 ms) and NeuFlow on the GPU (10 ms) running side by side. Two conversion findings:
  - The fp16 NeuFlow takes 100 ms on this Mac's Neural Engine (14 ms on the headset's) and
    overflows to NaN on its GPU.
  - The producer therefore uses a one-way **fp32** NeuFlow (`--one-way --precision fp32`) on the
    GPU. One direction is all E reads.
  - A model's NaN is stored as 0 rather than crashing the encoder.

### E4: the player's pass (2026-11-01)

`SharedFieldInterpolator` (Vergence `Sources/VergenceApple/Stereo/`) makes both in-between eyes
of a packed pair in one compute pass: the stored fields sampled bilinearly (as
`F.interpolate(align_corners=False)`), the left eye RIFE's own result at ½, the right eye the left
eye's field read across by the mixed disparity, each frame read clamped to its own eye. It is a
`MidFrameInterpolator`, so `InterpolatingFrameSource` drives it unchanged (cuts, gaps, the
governor), now passing the frames' times so `AnalysisTrackFieldProvider` can find the pair's
records (within a quarter frame; binary search, so a film's 340,000 records stay fast).

- **Checked against the reference.** `vergence interpolate` runs the same pass on a Mac from
  packed BGRA; `scripts/check-analysis-track.py --metal` scores it. On the crowd pan and the robot
  fight the Metal frames agree with the script's own track render to 68 dB (8-bit rounding), so
  they score the same against the real frames: 38.64 / 38.39 and 27.85 / 27.75 dB.
- **Speed: ~1.7 ms a 1080p pair on an M2 Max**, lookup, upload and pass together. On the headset
  it shares the GPU with the pump, not the Neural Engine with anything.
- The check script scaled the vertical flow by the width ratio (16 instead of 15 at 120×72);
  fixed, the track's own render gained ~0.05 dB.
- Only t = ½ (the doubling `InterpolatingFrameSource` does). 4× needs flow reversal and a mask
  for other phases, not measured.

In Convolution: a disc's track is a file in Documents/Smooth Motion named after the film or its
Jellyfin item id (`SmoothMotionTracks`). `FilmSession` indexes it when the film loads, the film
player's 3D picture passes it to the stereo engine (`Pseudo3DStereoEngine.sharedFields`), and the
Smooth Motion toggle appears for a 3D disc only when a track exists. `vergence analyze` now times
a disc's records on the playlist's own clock, the film player's.

On the headset (2026-11-01): a disc's packed pump paused for "reserve low" under the depth
pump's thresholds, though no depth model runs and the pump takes frames only 40–80 ms ahead; a
packed pair now uses `.flat`. Then ~23 in-between pairs a second, 3–9 ms median, 13 ms worst.

Since then:
- **Half-resolution packing** (half SBS/TAB) is interpolated too: the fields scale to each
  eye's stored size, and the track is made from those eyes (crop the halves, stack them, `--raw`
  at the half eye's size; see the README's `analyze` section).
- **The video window** looks for a Library 3D title's track (by item id, else name) and hands it
  to live 3D, which rebuilds its pump when the track arrives (`VideoWindowModel.sharedFields`).
- **Cuts no longer read as dropped frames.** With the doubled spacing learned, every real frame
  passed through without its in-between frame counted as a drop ("3D picture dropping frames: 73%
  of 48 fps"), which could step the picture down. Such frames are marked
  (`PumpFrame.standsInForMidFrame`) and the delivery report counts each as both.
- **96 Hz.** The stereo engine publishes doubled display criteria while it interpolates and the
  video window's 3D picture states them; the film player doubles its own criteria in 3D.
- **A miss says how far off the clock is**: the track's first miss (and every 240th) logs the
  distance to the nearest pair, which is the `timeOffset` a player's clock would need.
- **`analyze` held every input frame** (autoreleased reads, never drained): a whole film ran out of
  memory 38,000 frames in. It now stays at ~195 MB.
- A half-SBS MKV with an H.264 frame-packing SEI (and Matroska's StereoMode) made Homebrew's
  ffmpeg 8.1.2 fail every filter graph with "File exists" (-17). Stripping the SEI in a copy remux
  first (`-bsf:v filter_units=remove_types=6 -c:v copy -f matroska -`, piped into the decoding
  ffmpeg) works around it.

Next: a whole film on the headset (Ready Player One 3D, half SBS, analysed on the M2 Max at
~35 fps), then the per-scene fallback for fire and smoke, then getting tracks to the headset
without the Files app (served by the plugin, or a paired Mac).

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
   - Display criteria for 47.952 fps (96 Hz) on the stereo window: done for live 3D and the
     film player (2026-11-01); whether visionOS honours them for a RealityKit video plane is not
     yet seen on the headset.
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
