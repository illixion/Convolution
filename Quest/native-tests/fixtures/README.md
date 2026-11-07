# VGAT fixtures for the Quest's native tests

- `vergencecore-fields.vgat`: written by VergenceCore itself (`swift/`, `swift run MakeFixtures <out>`):
  known flow pairs and disparities as int16, plus a float16 depth map and a uint8 gain map.
- `worker-fields.vgat`: the same values written by vergence-worker's Rust record code (`rust/`).
- `worker-2d-flow.vgat`, `worker-depth.vgat`, `worker-gain.vgat`: the Mac worker's own output for the
  `smooth-motion-2d`, `ai-3d-depth` and `ai-hdr` workloads over 8 frames of a synthetic 1280×720
  23.976 fps clip (ffmpeg `testsrc2` blended with `mandelbrot`, H.264), made with vergence b4c9a1e:
  `vergence worker --config CFG --reference clip.mp4 --workload NAME --frames 8 --output NAME.vgat`
  (RIFE 4.25 lite 960×576, Depth Anything V2 Small, Convolution's GainMapGMNet).
- `worker-expected.txt`: what VergenceCore reads in those three (`swift run MakeFixtures --expect ..`),
  which `test_analysis.cpp` matches.
