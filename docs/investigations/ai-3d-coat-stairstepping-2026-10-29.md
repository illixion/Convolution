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
