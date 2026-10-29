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
