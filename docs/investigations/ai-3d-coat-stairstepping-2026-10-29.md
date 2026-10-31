# AI 3D coat silhouette: compression, stretch and residual aliasing

## Finding

The yellow garment against the blue background has a smooth decoded source edge. The captured left-eye image makes that edge narrower and visibly toothed; the right-eye image makes it wider and fringed. Both defects are already present in the GPU eye buffers, before their RGB-to-YCbCr conversion and RealityKit presentation. This is a stereo-warp defect, not just AVP window scaling or source compression.

There are two contributions: raster/texture sampling, which additional sampling can improve, and the depth-displaced connected surface, which compresses/folds on one side of a depth discontinuity and stretches on the other. Antialiasing alone does not correct that surface or reconstruct the exposed background. No renderer defaults were changed, and no fix was deployed during this investigation.

## Device evidence

Convolution build `36391d6`, AVP, visionOS 27.2. Captured through the existing `stereoEyes` and `stereoCaptureInfo` endpoints used in the earlier film investigation. The selected frame is at **745.1198222222222 s**, 1920×1080; depth is 896×504; strength is 0.008 per eye and convergence is 1. Snap, fill, separated boundaries and hole visualization are off; gap compression is on. Thus the old edge-snap/background-fill heuristics are not causing this instance.

An initial capture returned a different close-up frame at 731.439488888889 s. It is not comparison evidence. After the user selected the coat shot, a normal fresh capture timed out; `recompute=true` succeeded. That request recomputes depth as a first frame of a shot, so the retained coat capture is **not a record of the previous temporal depth state**. Source/left/right/depth were subsequently exported from the same retained capture with `fresh=false`; no playback advance occurred between those views.

Local, ignored artifacts:

- `build/edge-comparison/coat-2026-10-29/{source,left,right,depth}.png`
- `capture.json`: timestamp, dimensions, strength and convergence.
- `report/captured-coat.png`: unfiltered 2× crop of the three captured RGB images.
- `report/metrics.json`: input SHA-256 hashes and repeatable measurements.
- `lab/`: approximate offline shader replays, metrics and comparison sheets.

The device capture hook in `StereoPump.draw` copies the RGB eye buffers after the GPU command completes, **before** `VTPixelTransferSessionTransferImage`. `StereoEyeImages` converts them to PNG. This isolates the problem upstream of chroma subsampling, presentation and the headset display; it does not exclude additional downstream artifacts.

Over source rows 570–670, measuring the yellow-to-blue contrast along the coat silhouette:

| Captured image | Median 90–10% transition width | High-frequency contour RMS |
| --- | ---: | ---: |
| Source | 7.87 px | 0.192 px |
| Left eye | 2.53 px | 0.322 px |
| Right eye | 15.95 px | 0.702 px |

These are shot-specific diagnostics, not general perceptual scores. Local source colors normalize each row's R−B contrast; the subpixel 50% crossing measures the contour. RMS is the residual after subtracting a Gaussian-smoothed contour (sigma 3 rows). The foreground/background sampling bands and search range are deliberately limited to this particular unobstructed edge. A different shot needs its own measurement region; these color thresholds must never become a renderer heuristic.

## Rendering mechanism

Relevant production code is in `vergence/Sources/VergenceApple/Stereo/`:

- `VergenceMetal.swift`: the connected mesh already uses 4× MSAA. Refined realtime depth and cached depth request a 769×433 grid; unrefined realtime depth uses 193×109. `RealtimeDepthSource.prefersDenseWarpGrid` depends on successful refinement setup. The device capture does not export that flag, so dense-grid selection in this exact running instance is inferred from the normal refined path, not directly measured.
- `StereoShaders.metal`, `videoStereoMeshVertex`: normalized source position x becomes `x + eyeSign * strength * (depth − convergence)` (apart from the window-edge feather).
- Its local horizontal scale is therefore `1 + eyeSign * strength * d(depth)/dx`. A steep foreground-to-background drop compresses the surface in one eye, possibly folding it so depth testing selects overlapping triangles. The opposite eye stretches the same source band into the newly exposed strip. This predicts the observed narrow/toothed versus wide/fringed asymmetry.
- `videoStereoMeshFragment` samples color bilinearly at interpolated source coordinates. The connected mesh has no explicit foreground coverage or separate background surface. More samples can integrate its output better, but cannot supply the missing background or repair the depth contour.
- The normal mesh fragment uses pixel interpolation and no `sample_id`. Four coverage/depth samples do not by themselves provide four independently shaded source-color samples. An experimental variant used both `[[sample_perspective]]` and `[[sample_id]]` to test that distinction.

The captured depth PNG is a display visualization: min/max normalized, 8-bit and color transformed. It lacks raw floating-point values, their range and all warp mapping fields. It is useful for visualizing and approximately replaying the contour, but is not an exact replay format.

## Offline experiments

`scripts/stereo-edge-lab.swift` compiles the actual production shader at runtime and changes its source **in memory only** for the sampling experiments. It does not edit Vergence or the running app. Investigation-time Vergence HEAD was `6bf6050`.

The replay decodes the normalized depth PNG through a gamma-2.2 grayscale context and inverts that gamma. It assumes identity depth UV/value mapping, a 0–1 budget, strength 0.008 and convergence 1. The coat replay resembles the device's narrow left and fringed right edges, but normalization, quantization, shot mapping, GPU platform and color conversion prevent a pixel-exact comparison to the device. All candidate comparisons below use the same reconstructed depth.

| Experiment | Observation | Interpretation |
| --- | --- | --- |
| Disable MSAA | Stronger left-edge aliasing. | Existing MSAA helps; it is not absent. |
| 4× sample-frequency shading | Modest improvement on the coat; fringed right outline remains. | Coverage and color sampling are separate; shading more samples addresses only part of the defect. |
| Render at 2× width/height, then box-average to native size | Better integration of the left edge; right-side stretch remains. | Useful sampling reference, not a complete silhouette fix. |
| Render at 4× width/height and downsample | Residual contour shape remains even with much finer sampling. | This is a reference for integrating the **same geometry**, not correct scene geometry. |
| Increase grid to 1537×865 | Changes the contour; does not remove the asymmetric defect. | A denser connected surface is not sufficient. Its changed geometry makes error against the baseline-grid reference an unsuitable standalone quality score. |
| Reduce grid to 193×109 | More obvious contour approximation and displacement changes. | Coarsening is not a quality fix. |
| Four source taps over the interpolated pixel footprint | Small numerical improvement, still fringed. | Filtering cannot fix the wrong surface or missing background; not adopted. |
| 8× MSAA | Unsupported on the test Mac; skipped. | No result. |

For the coat ROI x=600–834, y=550–1049, RGB RMSE against the 4×-resolution same-grid reference was:

| Variant | Left | Right |
| --- | ---: | ---: |
| Production-style 4× coverage MSAA | 0.671 | 0.396 |
| No MSAA | 1.771 | 0.379 |
| 4× sample-frequency shading | 0.613 | 0.299 |
| 2× resolution + box resolve | 0.392 | 0.336 |
| Four footprint taps | 0.604 | 0.283 |

Units are 8-bit RGB code values over that ROI. The region includes interior/background pixels, so these small averages are **not** estimates of visible outline error. A slightly lower right-eye score without MSAA does not establish that disabling MSAA improves quality. The finer reference shares the same geometric defect.

A second fixture used an analytically antialiased straight yellow/blue diagonal at 1080p with a binary 896×504 depth map. Even a perfectly straight source contour developed asymmetric displacement and ripple through the connected mesh. Sample-frequency shading and supersampling reduced integration error, but the low-resolution depth transition and connected geometry still changed the contour. This separates the failure mechanism from movie grain, motion, codecs and model inference. It is intentionally not evidence that a binary synthetic depth map matches the real model's error distribution.

GPU timings were collected only as exploratory Mac measurements, with too few repetitions and variable scheduling. They do not establish an AVP frame budget; no performance claim or default is based on them. The device's earlier continuous-play logs showed approximately 24 fps, 25–36 ms depth, 5–8 ms warp and 1–2 ms transfer. Those logs cover surrounding playback, not a controlled candidate benchmark.

## Relationship to the previous investigation

Read `ai-3d-edge-artifacts-2026-10-13.md` before changing silhouette handling. That work already found that color-based snapping and background fill could improve a frame while damaging ears, hair, clothing or railings elsewhere. This investigation does not reverse those findings.

The experimental disconnected renderer has since gained antialiasing, but still uses depth-texel classification and explicit background filling. It was not enabled on the headset here. Its existence does not establish that it fixes the coat or the old film scenes. The old local reference captures were absent from this checkout; they were not silently substituted or claimed as re-tested.

## Recommended implementation direction

1. For a small, isolated experiment, test sample-frequency shading in the normal mesh behind a diagnostic switch. This has measurable sampling benefit but must be described as partial. Measure AVP warp time and both eyes, in motion as well as paused; do not spend a 60 fps budget based on Mac timings.
2. For the actual contour fix, separate foreground coverage from the connected surface bridging a depth jump. Preserve a continuous subpixel silhouette and reconstruct exposed **background-only** pixels without stretching foreground color into the strip. Revisit the existing boundary renderer as a research baseline, not a default toggle. Do not restart per-shot color-rule tuning.
3. Add an exact, screen-capture-gated export of raw float depth plus UV mapping, value scale/bias, budget, grid choice and source/eye buffers. That is needed before claiming exact on-device candidate regressions or selecting a production fix. A source PNG plus normalized depth PNG is insufficient.
4. Recheck this coat, the earlier horse/corral, face, low-contrast clothing, thin rails and hair, plus motion/cuts. Source identity, depth, mapping and playhead must match in each A/B. Antialiasing success alone does not prove silhouette fidelity or stereo comfort.

## Reproduce the local replay

Keep capture files outside version control. On macOS with Xcode command-line tools:

```sh
swiftc -O scripts/stereo-edge-lab.swift -o /tmp/stereo-edge-lab
/tmp/stereo-edge-lab build/edge-comparison/coat-2026-10-29 \
  build/edge-comparison/coat-2026-10-29/replay-new
```

The default shader path expects the normal sibling `../vergence` checkout. An optional third argument supplies a different `StereoShaders.metal`. Existing output directories are refused. Unsupported sample counts are skipped.

For the coat measurements, use a Python environment with numpy, Pillow and scipy:

```sh
python scripts/analyze-stereo-coat.py \
  build/edge-comparison/coat-2026-10-29 \
  build/edge-comparison/coat-2026-10-29/replay-new \
  build/edge-comparison/coat-2026-10-29/report-new
```

Validation: the standalone Swift tool compiled and completed every supported variant on the captured frame, then was compiled and run again from its committed-path source; the analysis tool completed on both replay runs. No app source or shared-package source was modified, so app platform builds were not needed. No shipping fix or headset candidate validation is claimed.

## Follow-up: original MKV, 12:22, floating-point video replay

The user supplied the original episode file and identified 12:22. This permits a materially stronger investigation than the display-depth replay above. The right-eye fringe is a failure in its own right; improving the left-eye teeth does not constitute a fix.

### Source and model verification

The local source is 1920×1080 HEVC, 24000/1001 fps, BT.709. An accurate output seek, after decoding from 730 s, extracted the frame at 742 s. A direct input seek near the target initially emitted missing-reference decoder errors; the warm-up seek avoids carrying those startup errors into the selected frame. A timestamped 740–748 s scan separately matched the earlier retained device source most closely to local PTS 745.224 s. The retained device capture reported 745.119822 s, and the user's 12:22 frame is another pose in the same shot. **These are not claimed to be the same frame.** All new renderer variants use the one extracted 12:22 frame.

The AVP's public model-load log identifies `DepthAnythingV2Small560x252.mlpackage`, the custom cinema model from the earlier investigation. It was copied from the app's model store for local inference. Letterboxing this 16:9 source leaves approximately 448×252 usable depth samples; refinement produces 896×504, matching the captured device dimensions. This is less useful horizontal detail than the stock Small model's 518×291 content crop, but it is not the sole defect.

### Reproduction with the actual realtime path

Vergence's new opt-in `VideoStereoFrameLabTests/exportFrame` (commit `8909115`) loads the source PNG into a BT.709-tagged BGRA pixel buffer, calls the real `CoreMLDepthProvider.refinedDepth`, and renders both eyes through the production mesh. It explicitly requires refinement to be available, rather than silently passing a fallback path. It exports the actual half-float plane losslessly as float32, plus UV mapping, affine values, studio budget, strength and convergence. All shader variants within a run share that one frozen depth texture and source.

This is a **fresh first-frame inference on a Mac**, not a dump of the AVP's prior temporal/ANE state. The tagged PNG input also differs from the original decoder's YCbCr input. Nevertheless, it directly reproduces the teeth and right-eye fringe with the production realtime refiner, without reconstructing depth from a display PNG.

`scripts/stereo-edge-lab.swift` now accepts `depth.f32` + `depth.json` and applies the recorded mapping/budget. The PNG fallback remains explicitly approximate. Replaying the exported floating-point case through the standalone mesh tool differed from the package renderer by only **0.086 left / 0.049 right RGB-code RMS** in the coat ROI x=620–759, y=550–799. Those small differences include format/color/interpolation rounding; the local reproduction no longer depends on an unknown min/max depth range.

### The mesh really folds

At source row y=600, sample the recorded depth at the production dense grid's vertices, apply the studio budget, and compute the horizontal source-to-eye scale in each grid cell:

`scale = 1 + eyeSign × 1920 × 0.008 × Δdepth / ΔsourcePixels`

For the 769-column grid, adjacent vertices are 2.5 source pixels apart. A negative scale reverses the cell in the left eye; the corresponding right-eye cell stretches by more than 2×. These are actual depth-driven cell scales, not estimates from a PNG edge-width measurement.

| Model | Refined depth | Minimum left-eye scale | Maximum right-eye scale |
| --- | --- | ---: | ---: |
| Custom Small 560×252 | 896×504 | −1.090 | 3.090 |
| Stock Small F16 | 1036×582 | −0.835 | 2.835 |
| Stock Base F16 | 1036×582 | −0.606 | 2.606 |
| Local Small 770×574 | 1540×866 | −1.484 | 3.484 |

All four reproduce the geometric failure at this reference cross-section. More model pixels do not guarantee a better contour; a sharper depth step can make the connected mesh fold more strongly. Sampling the continuous interpolated field at native-pixel spacing gives a still steeper local peak (about 3.95× right-eye scale for the 560 model); the table uses the actual coarser mesh-cell calculation and is the better description of this renderer.

With the real floating-point plane, sample-frequency shading and supersampling again reduce sampling error but leave the right-eye stretch. Over this coat ROI, 4× sample-frequency shading reduces RMS against the same-geometry 4×-resolution integration reference from 1.017 to 0.897 left, and 0.599 to 0.332 right. This does **not** mean that the visible fringe is fixed: the reference also integrates the stretched surface.

### Why the separated prototype is also unsuitable

The existing `StereoBoundaryWarp` is worse in the right eye on this frame: it breaks the edge into small fragments. Its crossing triangles independently choose their own near/far extrema and midpoint depth classifier. Adjacent triangles can therefore disagree about which surface a source pixel belongs to, and also displace their local surfaces by different amounts.

The harness tested these alternatives **only in in-memory shader strings**, never as package defaults:

| Variant | Result on both eyes |
| --- | --- |
| Bilinear depth classification in place of point-sampled depth | Did not remove the fragmented right outline. |
| Bilinear color for the near surface, then for both surfaces | Did not resolve the fragmentation/contamination. |
| Consistent local near/far layers with a shared source-coordinate mask | Much smoother coat contour, but left a detached yellow outline in the right-eye background. The left background also developed visible reconstruction artifacts. Rejected. |
| Shift the shared depth-mask cutoff to 25% or 10% | Moved the defect instead of eliminating it. Rejected; these are measurements of a failed design, not proposed presets. |
| Render the far layer before hole filling | The displaced yellow edge is already present in that layer. The filler is not the sole source of the duplicate. |
| Restrict the far layer to a more confidently background depth band | Removed some contaminated samples but produced conspicuous horizontal reconstruction stripes. Rejected. |

The shared-layer experiment uses depth extrema over a ±6-texel horizontal neighborhood. It is a research construction, not a physically correct layer decomposition. Its rejected cutoff variants should not be shipped or tuned to this episode.

The duplicate identifies a second requirement beyond consistent geometry: the source's soft silhouette contains **mixed foreground/background color**. Some of those yellow-tinted samples enter the far surface and are displaced with the background. A smooth binary depth contour and more MSAA do not separate those colors. The current filler can also copy unsuitable surface colors into an exposed strip; expanding the rejected band just makes that reconstruction problem larger.

A viable layered renderer therefore needs subpixel foreground coverage **and** an uncontaminated background representation, with premultiplied/matted boundary handling. A stable binary threshold alone is insufficient. Background gathered from valid neighboring frames or a separately reconstructed background is worth investigating; neither is implemented or validated by this work. No new color-classification heuristic, model preference, strength reduction or boundary renderer was enabled on the AVP.

### Artifacts and rerun

New local artifacts live under `build/edge-comparison/house-local-2026-10-29/`:

- `t742.png`: extracted local source frame.
- `t742-both-eyes.png`: source and production-mesh eyes, enlarged without filtering.
- `video560-background-mask/`: source, floating-point depth, exact mapping, all rejected shader experiments, and the far-only pre-fill diagnostic.
- `video-stock-small/`, `video-stock-base/`, `video770/`: independent fresh-inference model comparisons; their model/depth differences are intentional, not renderer A/Bs.
- `float-sampling/`: sampling variants sharing the 560 model's recorded float plane.
- `mesh-scales.json`, `source-replay-manifest.json`: numeric cell scales and input/output hashes.
- `background-mask-comparison.png`: several explicitly **failed** variants, including the far-layer contamination and striped reconstruction. It is not a before/after success image.

To reproduce the video path after extracting a source frame and placing the desired model locally:

```sh
VERGENCE_VIDEO_FRAME=/absolute/path/frame.png \
VERGENCE_VIDEO_MODEL=/absolute/path/model.mlpackage \
VERGENCE_VIDEO_OUTPUT=/absolute/path/new-output \
swift test --package-path ../vergence --filter VideoStereoFrameLabTests/exportFrame
```

Then pass that output directory directly to `stereo-edge-lab`; it detects the floating-point files. The diagnostic model/source/output are explicit environment inputs, so ordinary package tests do not run personal-video inference or export pictures. Prototype code is confined to the opt-in test harness. The tool and harness do not install, launch or change the app.

Validation: original-file runs completed with all four models; the final float-export harness run passed; the standalone tool compiled and completed all supported sampling variants with the recorded float plane. The complete Vergence test run passed **211 tests across four test bundles**. No production source/public API changed, so no app platform build or headset deployment was necessary. There is still **no acceptable production fix** among these variants.

## Follow-up: preserve coverage, then move the two contributions

There is now a **visibly better offline candidate for both coat edges**, in
`scripts/stereo-matte-lab.py`. It is not enabled in the app. The candidate separates
foreground coverage and radiance from a background estimate, moves each layer
using its own depth, and composites the results. Strength remains **0.008** and
convergence **1**. No coat color or crop coordinates enter that renderer; the
crop and R−B measurements below are evaluation fixtures only.

The controlled hypothesis is two depth layers, partitioned at budgeted depth
0.5. Eroding each side by 16 source pixels supplies confident foreground and
background seeds. Normalized Gaussian convolution extends their colors and
depths into the boundary band. A local RGB color-line projection estimates
coverage `a`. The background estimate transitions continuously to the actual
source as coverage approaches zero. The foreground's premultiplied contribution
is the residual `P = C − (1 − a) B`, so recomposition at zero disparity preserves
the source. These are **experimental parameters and a two-layer assumption**,
not a generally validated segmentation method.

Two intermediate mistakes were instructive:

- Clipping `P` into a legal premultiplied range before moving it created a second
  contour in the right eye. A hard `a == 0` switch between estimated and original
  background also introduced a discontinuity. Keeping floating-point residuals
  and a continuous transition removes those particular defects, but does not
  make an underdetermined foreground/background estimate physically exact.
- Fixed-point inverse warping failed to converge at thousands of pixels elsewhere
  in the full image. The final experiment instead intersects each output ray with
  the forward-warped horizontal segments and selects the nearest surface when
  segments overlap. Across the twelve frames, no ray's forward-equation residual
  exceeded 0.25 pixel; the maximum was **0.0163 pixel**. This is a numerical check,
  not proof that the estimated scene geometry is correct.

### Evidence and limits

The frame harness now accepts a consecutive PNG directory and retains **one
CoreMLDepthProvider across the sequence**, exercising temporal refinement and
shot anchoring. Twelve consecutive original-file frames were extracted at the
24,000/1,001 fps cadence, starting near 12:22. Harness metadata uses a caller-
supplied nominal start of 742 seconds, not decoded MKV timestamps. The first
frame is cold; the remaining eleven share provider state. An additional frame
near 12:25 also shows the coat-edge improvement. Partitions at 0.4 and 0.6 retain
it on the first frame without retuning the color calculation.

`scripts/measure-stereo-matte.py` measures rows 580–670. These are means of the
per-frame median 90–10% R−B transition widths and per-frame contour residual RMS
(Gaussian sigma 3 rows). Do not compare their absolute RMS directly with the
older paused-frame table: the source poses and row range differ.

| Image | Transition width | Contour residual RMS |
| --- | ---: | ---: |
| Source | 7.95 px | 0.478 px |
| Production left | 2.31 px | 0.321 px |
| Prototype left | 6.10 px | 0.359 px |
| Production right | 15.73 px | 1.245 px |
| Prototype right | 6.15 px | 0.343 px |

The important improvement is balanced edge width and much less right-eye
fringing. **The left-eye RMS is not lower**; its less conspicuous teeth accompany
a broader edge, closer to the source's softness. There is no ground-truth second
camera view here, and this is not a general perceptual score.

A comparison with [PyMatting's closed-form alpha and multi-level foreground
estimation](https://pymatting.github.io/examples.html), using the same automatic
trimap, also recovered a soft silhouette but left a dark contour in the estimated
background. Substituting an extended clean-background estimate improved that
result. This independently reinforces the need to check both the matte and the
revealed background; an attractive cutout alone is insufficient. PyMatting is an
optional dependency of the offline tool only.

Remaining barriers to a player change:

- A single global depth partition cannot represent arbitrary overlapping objects,
  fine structures and multiple depth discontinuities. Similar foreground and
  background colors also leave coverage ambiguous.
- The new background is extrapolated, not observed behind the coat. It can smear
  structure and still produces a faint displaced background band in places.
- The residual method produces 5,074–6,448 premultiplied channel values outside the
  physical `[0, alpha]` interval by more than one 8-bit code value per frame
  (about 0.08–0.10% of all RGB channels). They remain floating point until final
  image export; this is explicitly measured, not silently called valid matting.
- This operates on SDR PNG code values, not a validated linear-light HDR pipeline.
- The CPU reference takes roughly **4 seconds per 1080p frame**, including two-eye
  rendering and output, with about **1.5 seconds** in separation. It is a quality
  experiment, not a realtime implementation or AVP performance measurement.
- Twelve frames cover only half a second. Broader motion, cuts, hair, low-contrast
  boundaries and other scenes still need coverage before a production choice.

The next implementation step is a confidence-aware, multiple-layer formulation
with uncontaminated background reconstruction and a GPU implementation. The
existing snap/fill switches and separated-boundary renderer are still not a
substitute for that. No renderer defaults, app settings or device installation
were changed in this follow-up.

### Reproduction and validation

Local artifacts are under `build/edge-comparison/matte-lab/`:

- `motion-depth/frame-01` … `frame-12`: source, production eyes and lossless depth,
  generated with one retained depth provider.
- `motion-raycast/frame-*/comparison.png`: unfiltered 2×, source / production left /
  prototype left / production right / prototype right; full eye images and
  diagnostic `report.json` beside each.
- `coat-comparison-motion.mp4`: the twelve-frame comparison, lossy review copy;
  PNGs remain the pixel reference.
- `later-result/`, `threshold-04-raycast/`, `threshold-06-raycast/`: additional checks.
- `edge-metrics-final.json`: per-frame measurements; input hashes are in each
  renderer report. Maximum zero-disparity reconstruction RMSE was below
  `3e-7` 8-bit code values before export.

Example, with dependencies installed in an isolated local Python environment:

```sh
VERGENCE_VIDEO_FRAME=/path/to/consecutive-pngs \
VERGENCE_VIDEO_FPS=23.976023976 VERGENCE_VIDEO_START=742 \
VERGENCE_VIDEO_MODEL=/path/to/DepthAnythingV2Small560x252.mlpackage \
VERGENCE_VIDEO_OUTPUT=/path/to/new-captures VERGENCE_VIDEO_VARIANTS=connected \
swift test --package-path ../vergence --filter VideoStereoFrameLabTests/exportFrame

python scripts/stereo-matte-lab.py /path/to/new-captures /path/to/new-render \
  --sequence --crop 620,550,760,800
python scripts/measure-stereo-matte.py /path/to/new-captures /path/to/new-render \
  /path/to/new-metrics.json
python scripts/stereo-matte-lab.py --self-test
```

The synthetic self-test checks zero disparity, both eye shifts against analytic
separate-layer translations, numerical inversion and source recomposition. The
real sequence and single-frame harness runs pass. The ordinary suite initially
hung in simultaneous `SampleBufferFrameSourceTests` fixture reads; sampling
located the wait in `AVAssetReaderOutput.copyNextSampleBuffer`, outside changed
code. The other **204 tests pass** with that suite excluded, and its seven tests
are checked separately. No production code or public API changed, so no app
rebuild or deployment was needed for these diagnostic changes.

### Broader scenes and GPU ray-warp spike (2026-10-29)

The layer hypothesis and ray map were checked on four additional 1920×1080
frames from the supplied episode, sampled at nominal 10:00, 15:00, 25:00 and
30:00: overlapping pale coats, a face/hair edge against curtains, fine hair and
medical leads against a dark room, and hair/skin/fabric against bedding. Each
used the same local Small model and a fresh first-frame inference; these are
single-frame scene checks, not temporal captures. The broad comparison sheet is
`build/edge-comparison/broad-scenes/edge-crops.png`.

Those comparisons do **not** establish a general visible improvement. The
layered results are close to the connected mesh at full-frame scale, and the
hair and overlapping-fabric cases show no dependable edge-quality win. The
coat remains the clearest positive case. The decomposition still reports
3,290–8,887 premultiplied RGB channels outside the physical range by more than
one code value across these scenes. It remains an approximate layer guess.

An eight-frame sequence at nominal 24 fps around 25:00 retained one depth
provider across the frames. The experimental GPU raycaster in
`scripts/stereo-matte-gpu-warp.swift` intersects output rays with the two
pre-separated horizontal depth surfaces, chooses the nearest valid surface,
and combines premultiplied foreground coverage with the background sample. It
is intentionally a standalone offline spike; the matte/depth layer preparation
is still CPU-side, and it is not wired into Vergence or the app. On this Mac,
the Metal kernel took 5–8 ms per 1080p eye. Across all four stills and eight
sequence frames (24 eye renders), it produced no uncovered pixels. Compared
with the CPU raycaster using the same quantized layer inputs, RGB MAE was
0.03–0.07 code values and the 99th-percentile channel difference was one code
value. The timing excludes matting, video decode, model inference, pixel-buffer
transfer and visionOS compositor work; it is not an AVP frame-budget result.

The spike shows that per-eye layer raycasting itself can run on Metal while
matching the slow reference. It does not solve the still-open problem: producing
stable, physically plausible foreground coverage and uncontaminated background
layers on the GPU across hair, thin structures, overlapping subjects, motion
and cuts. No production renderer, setting, build or device was changed.

## GPU candidate: confidence-aware layered silhouettes (2026-10-31)

The follow-up implements `StereoLayeredWarp` in Vergence and connects it to the
visionOS video pump behind **`DepthRefinement.layersSilhouettes = false`**.
Convolution's `stereoEdges` debug endpoint accepts `layered=true` to opt in and
`layered=false` to return to the mesh. The disconnected-boundary switch takes
precedence, so use `separated=false` for this comparison. No default or persisted
setting changes, and no device deployment or headset validation is claimed.

### Method

The renderer replaces the CPU prototype's global depth partition with a local
near/far pair. A quarter-resolution table finds local depth extrema and seeds
inside each side of a discontinuity. Normalized Gaussian convolution extends
their colours and depth plateaus. Trust combines seed support, colour contrast,
within-layer depth variance and differential disparity. This is a local
two-layer hypothesis, not an arbitrary multilayer scene reconstruction.

Colour-line projection estimates coverage. The near contribution remains the
unclipped premultiplied residual `P = C - (1 - alpha) B`, while clean background
pixels transition back to the source. Per-eye ray/segment intersection chooses
the nearest hit in each layer, composites them, and blends the patch over the
mesh in the same MSAA pass. Where trust is zero the mesh remains the result.
Mirroring reverses both source coordinates and the patch's displacement sign.

Composition is capped at 2048 pixels wide and sampled up for larger sources;
the seed table is a quarter of that size in each dimension. Maximum shifts
below two composition pixels skip the split. The default seed margin is two
table texels, Gaussian sigma 1.25 texels, cutoff four sigmas, and support gate
`2e-6` to `2e-5`. These are experimental parameters, not validated segmentation
constants. No coat colour or evaluation crop enters the renderer.

### Evidence

The final defaults were replayed on all twelve retained floating-point captures
with the real Metal shaders. Strength is 0.008 and convergence is 1. The existing
measurement script uses the same rows 580–670 and normalization as the CPU table
above; values below are means of per-frame measurements.

| Image | Transition width | Contour residual RMS |
| --- | ---: | ---: |
| Source | 7.95 px | 0.478 px |
| Connected mesh left | 2.31 px | 0.321 px |
| GPU layered left | 6.98 px | 0.342 px |
| Connected mesh right | 15.73 px | 1.245 px |
| GPU layered right | 7.79 px | 0.414 px |

Both eyes recover source-like softness, and the right-eye fringe is reduced.
Left-eye contour RMS is slightly higher than the mesh's; the improvement is
balanced width and appearance, not a lower value in every metric. The earlier
CPU prototype's corresponding widths were 6.10/6.15 px. Neither prototype has a
ground-truth second camera view, and these are shot-specific diagnostics.

The replay can also export the connected mesh, checking that candidate and
baseline use identical inputs. Across the twelve frames and both eyes, that
mesh replay has mean code-value RMS 0.038 and maximum 0.052 against the retained
eyes (including the PNG alpha channel). Synthetic tests use a soft diagonal
foreground
against a striped background with a softer, low-resolution depth transition.
They check width and position in both eyes and foreground orientations, source
sizes above the composition cap (2304 and 3840 pixels), flat depth, low contrast,
a thin bar and mirror symmetry. Removing the mirror displacement reversal was
confirmed to fail the mirror test during implementation.

Four additional episode captures (nominal 10:00, 15:00, 25:00 and 30:00) were
replayed and visually reviewed during implementation, covering pale clothing,
faces, hair, medical leads and bedding. Changes are localized around outlines;
this small sample does not establish general quality. A short streak near the
end of a trusted band in capture 0900 remains; it was also present in the mesh.

### Limits and rejected alternatives

- A narrow far strip can borrow the next surface's colour when the seed margin
  extends beyond it. Thin structures without clean interior seeds retain the
  mesh's defects. A confidence gate reduces uncertainty; it does not guarantee
  a physically correct matte or hidden background.
- Twice the normal stereo strength moves content beyond the trusted band's
  useful reach. The uncovered strip then partly retains the connected mesh.
  The composition cap is not the cause of this strength limit.
- Wider seed margins, broader Gaussian tails and smaller support thresholds
  exposed notches or neighbouring-surface contamination. Narrower trusted bands
  ended before the exposed background strip. A row-wise colour extension gave
  no useful improvement and was removed. No per-shot colour tuning was adopted.
- All reviewed captures are SDR. HDR, wide gamut, long motion, cuts, low-contrast
  outlines and the older horse/corral footage remain unvalidated. Twelve frames
  cover only half a second. There is no AVP cost or memory measurement yet.

### Reproduction and validation

From the worktree's Hypnos directory, with the sibling Vergence clone:

```sh
swift test --package-path ../vergence --filter StereoLayeredWarpTests
VERGENCE_LAYER_LAB=/path/to/lossless-captures \
VERGENCE_LAYER_OUTPUT=/path/to/new-render VERGENCE_LAYER_MESH=1 \
swift test --package-path ../vergence \
  --filter StereoLayeredLabTests/replayCaptures
python scripts/measure-stereo-matte.py /path/to/lossless-captures \
  /path/to/new-render /path/to/new-metrics.json
```

Each capture needs `source.png`, `depth.f32` and `depth.json`; a directory of
captures is accepted. Output must not exist. `VERGENCE_LAYER_DEBUG=1` exports
decomposition planes. Optional `VERGENCE_LAYER_TUNING` accepts semicolon-joined
`seed`, `support`, `contrast`, `spread`, `separation` low/high pairs and scalar
`radius`, `sigma`, `kernel` values. The normal grid is dense; use
`VERGENCE_LAYER_GRID=moderate` only for a deliberate coarse-grid comparison.

The new GPU regression cases pass. The prior complete-suite runs excluding
the known hang-prone `SampleBufferFrameSourceTests` found one unrelated failure:
`SpatialVideoMakerTests.streamSegmentsFromTwoRunsJoinIntoTheWholeVideo` expects
fixed keyframe positions that fail under concurrent load. It also failed in an
unchanged baseline copy and passed alone. This is retained as a validation
limitation rather than attributed to the silhouette change.

The continuation reran the suite with parallel execution disabled: **209 tests
pass across four bundles**, excluding `SampleBufferFrameSourceTests`; the
keyframe test passes in this run. The new GPU tests and twelve-frame replay
also pass independently, and the measured edge table above is reproduced.
Hypnos builds pass for visionOS, iOS Simulator, macOS and tvOS, both with and
without `YOUTUBE_CONDITION=HYPNOS_YOUTUBE`. All builds use the worktree's local
package clones. No app was installed on a device.

Before considering a default, compare identical source/depth/playhead states on
the headset, both paused and moving, and measure warp cost and memory there.
Test stronger disparity, scene cuts, thin structures, ambiguous backgrounds and
HDR. Adaptive reach and a colour-variance gate are possible follow-ups, not
implemented fixes for these remaining limits.

### First headset check and paused-capture regression (2026-10-31)

The merged candidate was installed on the AVP in an optimized Release build.
The user reports a faint translucent warp outside the coat and selected 12:15
as a clearer demonstration. Captures at **735.4430416666667 s**, 1920×1080,
depth 896×504, strength 0.008 and convergence 1 retain that residual band.
The layered renderer remains a candidate with a visible defect, not a completed
silhouette fix.

Local evidence is in `build/edge-comparison/coat-1215-2026-10-31/`: both eyes,
source and depth for layered and original mesh, `capture.json`, and
`coat-edge-comparison.png`. The A/B has identical timestamps, disparity settings,
source PNG hashes and depth PNG hashes. Depth was retained, not recomputed.
Layering was restored and the paused frame redrawn after comparison. These
display-depth exports do not replace a lossless raw-depth fixture.

Capturing initially timed out even with the existing paused-redraw endpoint.
The pump's capture guard required every buffered frame to have rendered eyes;
the depth-lookahead reserve now deliberately leaves future eyes unrendered
until they approach presentation. A paused clock never brings those frames
into the rendering window. The guard now checks for paused playback instead
of requiring an empty rendering backlog. After deployment, fresh paused
captures, the exact-frame A/B and restoration redraw all completed without
advancing playback. The capture remains gated by screen-capture approval.

### Outer silhouettes and the shade regression case (2026-10-31)

The user's corrected eye/edge report at **740.3229166666666 s** is: left eye,
left edge of the yellow garment; right eye, right edge of the yellow garment
and right edge of the beige jacket. This supersedes the earlier focus on only
the inner yellow edge. Lossless device inputs and both eyes are retained under
`build/edge-comparison/coat-whole-740-lossless-2026-10-31/`. The mesh-only fixture
in `coat-whole-740-mesh-2026-10-31/` has identical source/depth hashes and time.

A clearer second regression is `/Users/ixion/Downloads/House_S03E06.mkv`, at
15:09. The paused device capture is **909.325 s**, 1920×1080, depth 896×504,
strength 0.008, convergence 1, layered on and experimental corrected matte off.
The user sees halos around the heads, with the window shade bending behind
them. `build/edge-comparison/heads-1509-lossless-2026-10-31/` retains raw BGRA,
float32 depth, mapping and both eye PNGs. The shade provides a structured
background test in addition to the soft coat edge.

The `stereoFrame` endpoint exports the retained capture without recomputing
depth or advancing playback, under the usual screen-capture grant. Export it
after a fresh `stereoEyes` capture:

```sh
python scripts/export-stereo-frame.py --out /path/to/new-capture
```

The replay harness prefers `source.bgra` when present and reads mirror, tone
and grid metadata. This avoids an image decode or a fresh depth inference
changing the experiment's inputs.

Rejected experiments remain rejected: covariance-based local colour fitting
and guided coverage changed the faint band into a distinct line on the
headset; the user did not accept that as a fix. Those production experiments
were removed. Isolated lab trials of physically bounded radiance, BT.709
linear-light matting, confidence changes and opaque patch composition also
leave visible shade distortion. Widening the local seed margin introduces
additional shade discontinuities. None of these is a validated replacement.

Further offline research separates three problems: locating actual coverage,
preserving source radiance, and obtaining background hidden by the subject.
Image-guided and Vision-assisted mattes improve parts of the head silhouettes
but do not by themselves recover the shade's hidden stripes. Local inpainting
still leaves errors. Registered neighbouring frames supply observed background
for some exposed strips; a visible-background agreement check rejects other
shots. This is research evidence, not a general renderer, a realtime budget,
or headset acceptance. The original layered candidate remains on the device.

An offline stereo review is now in the device's `Documents/Videos/` as
`Heads-halo-review.spatial.mov`: A (0–10 s) is the current layered renderer;
B (10–20 s) uses a narrow image-guided matte and registered observations;
C (20–30 s) adds LaMa completion for unobserved background. Both candidates
preserve the source through a bounded premultiplied decomposition and blend
back to the original renderer outside the experimental boundary region. The
user's result: **C looks best, but warping remains visible, less than B**.
This is improvement evidence, not acceptance of a suitable solution.

The review is a 30-second still-frame MV-HEVC clip (two labelled 1920×1080
views, BT.709, 24 fps), not a moving-video or realtime implementation. Local
files live in `build/edge-comparison/stereo-review-2026-10-31/`; preserved
research scripts/results are under `build/edge-comparison/research-2026-10-31/`.
Raw replay fixtures remain the authoritative inputs.

A broad local affine background-depth fit was also rejected: measured median
horizontal deviation from straight visible background lines in the head frame
rose from 0.012 px with C's background depth to 0.032 px with the fit (33 source
segments). The two qualifying coat segments worsened too. This diagnostic
does not measure hidden pixels and is not a ground-truth stereo benchmark.

Model experiments run locally. The compact palettized LaMa Core ML conversion
produced purple masked regions and was rejected. A full-precision conversion
runs at 800×800 and returns RGB in **0–255**, unlike the 512×512 Torch model's
0–1 output; treating it as 0–1 makes the preview white. Mac timings and model
conversion success are not evidence of a realtime AVP budget. Current work
tests completion constrained by observed background first, rather than pasting
observations over an independently generated background afterward.
