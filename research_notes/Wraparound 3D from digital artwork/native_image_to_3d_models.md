# Native single-image-to-3D generative models (state as of November 2026)

Scope: general image-to-3D models that output a full 360° textured mesh or 3D gaussians, judged for turning one piece of digital artwork or a Blender render (stylized/CG/anime, clean or transparent background) into a wrap-around asset for Apple Vision Pro (so a GLB/USDZ mesh with baked colour is the practical target; gaussians need a splat renderer).

Source-quality warning: a large share of web material on this topic in 2026 is SEO/affiliate sites (trellis2.app, triposr.org, supavoxel, freeapihub, etc.). Primary sources (GitHub READMEs, HF model cards, LICENSE files, arXiv) are used wherever possible; aggregator claims are labelled as such.

## Model-by-model comparison (summary table)

| Model | Release | Architecture (one line) | Output | Texture approach | Peak VRAM (reported) | Licence (code / weights) | Status Nov 2026 |
|---|---|---|---|---|---|---|---|
| **TRELLIS.2-4B** (Microsoft) | 2025-12-16 | "O-Voxel" field-free sparse voxel; sparse 3D VAE (16× downsample) + vanilla DiTs, 4B params | GLB with PBR (base colour, roughness, metallic, opacity), 4096 textures | Native: PBR attributes generated in the voxel latent (re-synthesized); also has a separate "texture a given shape" pipeline | ≥24 GB official (A100/H100 verified); community claims 8–16 GB with low-VRAM (unverified) | MIT / MIT; nvdiffrast & nvdiffrec under NVIDIA's own (non-commercial) licences | Leading open model |
| **TRELLIS** (v1) | Dec 2024 | Structured 3D latent (SLAT) on sparse grid + rectified-flow DiT | Gaussians, radiance field, mesh (GLB, baked) | Native latent appearance, baked to mesh | ~16 GB (prior knowledge, not re-verified) | MIT | Superseded by TRELLIS.2 |
| **Pixal3D** (Tsinghua + Tencent ARC) | Code May 2026; multiview Sep 2026; SIGGRAPH 2026 | Pixel back-projection conditioner lifting image features into a 3D volume + pixel-aligned sparse-SDF VAE; main branch on TRELLIS.2 backbone (paper branch on Direct3D-S2) | GLB; "detailed geometry and PBR textures" | Generated, but explicitly pixel-aligned to the input view | Not stated; `--low_vram` (1024 res, on-demand loading) vs default 1536 | MIT code; weights licence not stated on README | Newest notable open release |
| **Hunyuan3D 2.1** (Tencent) | 2025-06-13 | Shape: flow DiT on ShapeVAE latent (3.3B); Paint: multiview PBR diffusion (2B) + bake | Mesh + PBR textures | Multiview diffusion conditioned on input, baked onto mesh; can texture any mesh | Shape ~10 GB, Paint ~21 GB, both ~29 GB | Tencent Hunyuan 3D 2.1 Community License: **excludes EU, UK, South Korea** | Last open-weight Hunyuan3D |
| **Hunyuan3D 2.0 / 2mini / 2mv / Turbo / Fast** | Jan–Apr 2025 | Flow DiT shape (1.1B; mini 0.6B) + Paint v2.0 (1.3B) + Delight | Mesh + RGB texture | Multiview + bake; Delight removes lighting from input | 6 GB shape, 16 GB shape+texture; `--low_vram_mode` | Tencent community licence, same territory exclusion | Superseded by 2.1 for texture |
| **Hunyuan3D 2.5 / 3.0 / 3.1** | Apr 2025 / Sep 2025 / Jan 2026 | 2.5: 10B "LATTICE" shape; 3.0: 1536³ geometry | Hosted | — | — | **No open weights** (hosted only) | Closed |
| **SAM 3D Objects** (Meta) | 2025-11-19; encoder weights 2026-06-01 | Not described in README (progressive training + human-feedback data engine) | Gaussian splat .ply (mesh also per third parties) | Native, reconstruction-oriented, includes pose/layout | **≥32 GB** (official setup doc) | SAM License (custom) | Open, real-photo/scene oriented |
| **Step1X-3D** (StepFun) | 2025-05-13 | Hybrid VAE-DiT geometry (TSDF, perceiver latent, 1.3B) + SD-XL multiview texture with sync module | Watertight mesh + texture | Multiview + bake (Hunyuan3D-2.0 baker); can texture a mesh | 27–29 GB (geometry+texture), 152 s/50 steps (GPU unstated) | Apache 2.0 | Open, not updated since mid-2025 |
| **Direct3D-S2** (DreamTech) | 2025-05-30 (NeurIPS 2025) | Sparse SDF volume + Spatial Sparse Attention DiT | Untextured mesh (OBJ) | None | ≥10 GB @512, ~24 GB @1024 | MIT | Geometry-only |
| **TripoSG** (VAST) | 2025-03 | 1.5B rectified-flow transformer on SDF VAE | Untextured GLB | None (VAST pairs it with separate texturing) | ≥8 GB | MIT (repo) | Geometry-only |
| **TripoSR** | Mar 2024 | LRM (feed-forward transformer, triplane) | Mesh, vertex colours | Feed-forward reconstruction | ~6 GB (aggregator) | MIT | Superseded/legacy |
| **SPAR3D** (Stability) | Jan 2025 | Point diffusion → point cloud → SF3D-style mesh stage | UV mesh + texture | Feed-forward, ~0.7 s | 10.5 GB default, ~7 GB with `SPAR3D_LOW_VRAM=1` | Stability AI Community Licence (free < $1M revenue) | Fast, lower fidelity |
| **SF3D** (Stability) | Aug 2024 | LRM-style with UV unwrapping + illumination disentanglement | UV-textured mesh | Feed-forward | ~6 GB (aggregator) | Stability Community Licence | Superseded by SPAR3D |
| **Hi3D v1.0** (formerly Sparc3D) | 2026-10-23 open weights | Sparse deformable-marching-cubes refinement up to 1536³ | Geometry (refines coarse mesh from reference image) | None | Vendor tested only on 96 GB; ~10 GB third-party estimate | Hi3D Open License (commercial OK under 200k MAU / $1M monthly revenue, "Powered by Hi3D 1.0" attribution) | Geometry refiner |
| **UniLat3D** | Sep 2025 | Single unified latent for geometry + appearance, single-stage | (not verified) | Native | Not found | Apache 2.0 (original code) | Research |

## Which models give the best geometry and which the most faithful visible-side texture, especially for stylized/CG/anime input?

### Takeaway
Among open weights, TRELLIS.2 (MIT) is the consensus best all-round open model in 2026, and Pixal3D (built on TRELLIS.2, pixel-aligned conditioning, SIGGRAPH 2026) is the one explicitly designed to fix input-image fidelity. No major native model reprojects the input pixels directly onto the mesh: TRELLIS.2/UniLat3D/SAM 3D synthesize appearance in a latent, and Hunyuan3D/Step1X-3D resynthesize via multiview diffusion then bake, so all drift to some degree from the input on the visible side. Independent, quantitative evidence on stylized/anime input specifically was not found.

### Cited Findings
- TRELLIS.2 is a 4B model using a "field-free" sparse voxel (O-Voxel) structure with a sparse 3D VAE (16× spatial downsampling) and vanilla DiTs; it handles open surfaces, non-manifold geometry and internal structures; outputs GLB with Base Color, Roughness, Metallic and Opacity; example uses 4096 textures — [TRELLIS.2 GitHub](https://github.com/microsoft/TRELLIS.2)
- TRELLIS.2 runtime on H100: 512³ ~3 s (2 s shape + 1 s material), 1024³ ~17 s (10+7), 1536³ ~60 s (35+25) — [TRELLIS.2 GitHub](https://github.com/microsoft/TRELLIS.2)
- TRELLIS.2 GLB exports as OPAQUE by default; alpha is kept in the texture but must be wired manually for transparency — [TRELLIS.2 GitHub](https://github.com/microsoft/TRELLIS.2)
- TRELLIS.2 tech report: arXiv 2512.14692; repo released 2025-12-16 — [TRELLIS.2 GitHub](https://github.com/microsoft/TRELLIS.2); [Cinevva timeline](https://app.cinevva.com/guides/ai-3d-model-generation-timeline-2026)
- An aggregator cites a 3D Arena ranking (May 2026) placing TRELLIS.2 at #2 overall, Elo 1306, and #1 open-source (aggregator claim, live board not verified) — [BuilderAI/aggregator summaries via search](https://builderai.tools/blog/single-image-to-3d-model-pipeline-2026)
- 3D Arena methodology: pairwise human votes, Elo starting at 1200; textured models get a 144.1 Elo advantage over untextured, gaussian splats a 16.6 Elo advantage over meshes — [3D Arena paper, arXiv 2506.18787](https://arxiv.org/html/2506.18787)
- Pixal3D attributes low fidelity in other 3D-native generators to an "implicit 2D-3D correspondence issue" (image cues enter via attention, pixel-to-3D association ambiguous); its pixel back-projection conditioner "explicitly lifts multi-scale image features into a 3D feature volume", generates the asset in the input-view alignment rather than canonical pose, and claims fidelity "approaching the fidelity level of reconstruction" — [Pixal3D project page](https://ldyang694.github.io/projects/pixal3d/)
- Pixal3D compares visually (no metrics) against TRELLIS 2 and HY3D V3.1, whose meshes were manually rotated/scaled to match the input view — [Pixal3D project page](https://ldyang694.github.io/projects/pixal3d/)
- Pixal3D main branch is rebuilt on the TRELLIS.2 backbone; paper branch on Direct3D-S2; three-stage cascade (sparse structure, shape, texture); May 2026 code release, Sep 2026 multiview inference (needs camera `transforms.json`, first frame canonical front view) — [Pixal3D GitHub](https://github.com/TencentARC/Pixal3D)
- One aggregator claims Pixal3D has the highest geometric accuracy (93.57% IoU) among open tools — single unverified source — [pixazo/aggregator via search](https://www.pixazo.ai/blog/best-open-source-3d-model-generation-apis)
- Hunyuan3D 2.1: shape model 3.3B, Paint 2B, PBR pipeline replacing the earlier RGB texture model; released 2025-06-13 — [Hunyuan3D-2.1 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1)
- Aggregators call Hunyuan3D "the strongest open PBR pipeline, if you are not in the EU, UK, or South Korea" — [BuilderAI guide](https://builderai.tools/blog/single-image-to-3d-model-pipeline-2026)
- Hunyuan3D 2.5 (10B LATTICE shape), 3.0 (Sep 2025, 1536³ geometry) and 3.1 (28 Jan 2026, up to 8 views) are hosted only, no open weights; 2.1 is the last open one — [triposr.org versions guide (vendor blog)](https://triposr.org/blog/hunyuan3d-versions); consistent with [Cinevva timeline](https://app.cinevva.com/guides/ai-3d-model-generation-timeline-2026) ("hosted versions; do not establish open checkpoints")
- Hunyuan3D-2.0 ships a Delight model (1.3B) for removing lighting from the input image — [Hunyuan3D-2 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2)
- Step1X-3D: hybrid VAE-DiT geometry producing watertight TSDF (perceiver latent, sharp-edge sampling), and SD-XL-based multiview texture with geometric conditioning and latent-space synchronisation, baked with the Hunyuan3D 2.0 baker — [Step1X-3D GitHub](https://github.com/stepfun-ai/Step1X-3D)
- SAM 3D Objects reconstructs "full 3D shape geometry, texture, and layout from a single image"; quick-start exports Gaussian splat .ply; checkpoints 2025-11-19; 3D Artist Object Set and HF leaderboard released 2026-06-02 — [SAM 3D Objects GitHub](https://github.com/facebookresearch/sam-3d-objects)
- Direct3D-S2: sparse volumes + Spatial Sparse Attention in a DiT; v1.1 ~2× faster than v1.0; a v1.2 "enhanced character generation" was announced as in preparation (2025-06-03); no texture — [Direct3D-S2 GitHub](https://github.com/DreamTechAI/Direct3D-S2)
- TripoSG: 1.5B rectified flow transformer, SDF VAE with SDF/normal/eikonal supervision, trained on 2M image-SDF pairs; mesh GLB output, texture not mentioned — [TripoSG GitHub](https://github.com/VAST-AI-Research/TripoSG)
- SPAR3D: point diffusion → sparse point cloud → mesh; ~0.7 s per reconstruction — [SPAR3D arXiv](https://arxiv.org/html/2501.04689v1); [The Decoder](https://the-decoder.com/stability-ais-new-3d-model-aims-for-real-time-generation/)
- SF3D described by aggregators as the "speed king" with lower fidelity than Hunyuan3D or TRELLIS; TripoSR as "runs anywhere, fast, MIT, and you can live with vertex colors" — [BuilderAI guide](https://builderai.tools/blog/single-image-to-3d-model-pipeline-2026)
- Hi3D v1.0 (formerly Sparc3D), open weights 2026-10-23: refines an existing coarse mesh from a reference image up to 1536³; geometry only, no training code — [Cinevva timeline](https://app.cinevva.com/guides/ai-3d-model-generation-timeline-2026); [Tokenstrom](https://tokenstrom.com/posts/hi3d-v1-0-formerly-sparc3d-goes-open-source-with-mesh-refinement-up-to/)
- UniLat3D encodes geometry and appearance in one latent for single-stage generation from a single image — [arXiv 2509.25079](https://arxiv.org/abs/2509.25079)
- Other 2026 releases are closed/hosted or not released: Meshy 6/7/7.1, Meshy T2 (research, no weights), Meshy N1 (texturing, Nov 2026), Tripo P1.0/H3.1/P2.0, Rodin Gen-2.5, Hunyuan3D-Buffalo 1.0 (no weights) — [Cinevva timeline](https://app.cinevva.com/guides/ai-3d-model-generation-timeline-2026)
- Commercial "Top 3D AI" arena (different from 3D Arena, vendor source, 2026-08-03): Tripo AI v3.1 at 1042 Elo, Meshy 6 at 1004 — [Sloyd blog](https://www.sloyd.ai/blog/ai-3d-model-generator-rankings)

### Inferences
- **Best open geometry (Nov 2026):** TRELLIS.2 at 1024³–1536³ and Pixal3D (which inherits TRELLIS.2 and adds pixel alignment). Hi3D v1.0 and Direct3D-S2 are geometry-only alternatives/refiners; Hunyuan3D 2.1 shape is a step below the hosted Hunyuan 3.x.
- **Most faithful visible side:** Pixal3D is the only open model whose stated design goal is input-view alignment, so for "the front must look exactly like my artwork" it is the first to try. TRELLIS.2 generates colour in its own latent, so flat-shaded anime colours, linework and small decals tend to soften or shift; multiview-diffusion painters (Hunyuan3D-Paint, Step1X-3D) keep the front close to the input because the input conditions the front view, but the views are still resynthesized and baked, so linework can blur and colours shift (Hunyuan's Delight stage is designed for photos and can wash out deliberately painted shading on stylized art — inference, not measured).
- **Canonical-pose models** (TRELLIS.2, Hunyuan3D) output an object in their own frame; for an artwork you then have to match the camera manually, which is exactly what Pixal3D's authors did for their comparison. Pixal3D's view-aligned output is directly useful for a "pop the painting into 3D" presentation.
- **Gaussian-output models** (SAM 3D, TRELLIS v1) are viewable on Vision Pro only with a splat renderer; for RealityKit/USDZ a mesh+baked texture (TRELLIS.2, Hunyuan3D 2.1, Pixal3D GLB) is the practical route.
- SAM 3D Objects is trained for real-world photos and scene layout; it is not the natural choice for clean-background CG art (inference from its stated purpose).
- TripoSR/SF3D/SPAR3D/TRELLIS v1 are superseded for quality; they remain only as fast/low-VRAM fallbacks.

### Gaps
- No independent quantitative benchmark on stylized/anime/CG input specifically was found; 3D Arena live standings for Nov 2026 were not retrieved (the HF space is at huggingface.co/spaces/dylanebert/3d-arena).
- Reddit r/StableDiffusion / r/comfyui practical-experience threads did not surface in searches.
- TripoSF (VAST, SparseFlex) and Hi3DGen (normal-bridging geometry) primary READMEs were not fetched; their details (release, VRAM, licence) are unverified here. Hi3DGen MIT only via an aggregator.
- UniLat3D output formats, VRAM and weight availability not verified.
- SAM 3D Objects architecture and mesh-export path not described in the README.

## Which models support texturing an existing mesh from the input image (texture back-projection)?

### Takeaway
Hunyuan3D-Paint (2.0 and 2.1), Step1X-3D's texture stage and TRELLIS.2's separate texturing pipeline all texture a supplied mesh from an image. All three generate the texture (multiview diffusion + bake, or latent PBR generation) rather than projecting the input pixels verbatim, so a pure back-projection of the input view onto the visible side has to be added as a separate bake step.

### Cited Findings
- TRELLIS.2 provides PBR texture generation "for a given 3D shape" via `example_texturing.py` and `app_texturing.py` — [TRELLIS.2 GitHub](https://github.com/microsoft/TRELLIS.2)
- Hunyuan3D-2.1 paint pipeline takes a mesh path and an image: `paint_pipeline(mesh_path, image_path='assets/demo.png')` — [Hunyuan3D-2.1 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1)
- Hunyuan3D-Paint 2.0 produces texture maps "for generated or hand-crafted meshes"; Paint-v2-0-Turbo (2025-04-01) is a distilled multiview texture model — [Hunyuan3D-2 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2)
- Step1X-3D texture pipeline takes an input image and an untextured mesh (loaded via trimesh), with mesh cleanup (`remove_degenerate_face`, `reduce_face`) before texturing; multiview generation then baking — [Step1X-3D GitHub](https://github.com/stepfun-ai/Step1X-3D)
- Hi3D v1.0 refines an existing coarse mesh's geometry from a reference image, but does not texture — [Cinevva timeline](https://app.cinevva.com/guides/ai-3d-model-generation-timeline-2026)
- Meshy N1 (2026-11-03) is a hosted texturing release, not open — [Cinevva timeline](https://app.cinevva.com/guides/ai-3d-model-generation-timeline-2026)

### Inferences
- For a Blender render, the user already has the original mesh: the highest-fidelity path is to skip generation and bake the render itself (camera projection in Blender), then use Hunyuan3D-Paint / TRELLIS.2 texturing only to fill the occluded back. For digital artwork without a mesh: generate geometry (TRELLIS.2 / Pixal3D / Direct3D-S2 / Hi3D), then texture with a painter, then overwrite the front-facing texels with a direct camera projection of the input. That last step is what guarantees visible-side fidelity; none of the models above does it by itself.
- The UV-unwrap + bake code in Hunyuan3D (custom rasterizer, differentiable renderer, also reused by Step1X-3D) is the obvious open component to adapt for a front-view projection bake.

### Gaps
- Not verified whether any ComfyUI node pack ships an explicit "project input view onto mesh" node; ComfyUI-3D-Pack is a likely candidate but its node list was not checked.

## Peak VRAM at default settings and with low-VRAM options; fit for 24 / 16 / 12 / 8 GB?

### Takeaway
At official defaults only Hunyuan3D 2.0 (16 GB full pipeline), SPAR3D, TripoSG and Direct3D-S2 @512 fit 16 GB. TRELLIS.2 officially needs 24 GB; Hunyuan3D 2.1 full pipeline (~29 GB), Step1X-3D (27–29 GB) and SAM 3D (≥32 GB) exceed 24 GB unless stages are run separately or offloaded. Sub-16 GB TRELLIS.2/Pixal3D runs are community-reported and unverified.

### Cited Findings
- TRELLIS.2: NVIDIA GPU with at least 24 GB, verified on A100 and H100, Linux-only tested, CUDA 12.4 — [TRELLIS.2 GitHub](https://github.com/microsoft/TRELLIS.2)
- TRELLIS.2 community claims: 8 GB minimum with low-VRAM mode at 512³, 16 GB+ recommended for 1024³ (third-party site) — [trellis2.app low VRAM](https://trellis2.app/blog/trellis-2-low-vram); a user on a 4070 Super 12 GB reported ~30 minutes per GLB and ~40 GB install — [Godot forums](https://godotforums.org/d/43783-img-to-3d-locally-6gb-vram-nvida); a TRELLIS-Studio maintainer ran a "validated low-VRAM runtime" on a 12 GB RTX 4070 Ti (Windows preview) — [TRELLIS-Studio](https://github.com/yoslo59/TRELLIS-Studio); a video creator uses an RTX 5080 16 GB — [lilys.ai notes](https://lilys.ai/notes/pt/d5-render-20260219/comyui-trellis2-better-free-3d-ai)
- No GGUF/quantised TRELLIS.2 release was found — search result above (negative finding)
- Pixal3D: default 1536 resolution; `--low_vram` defaults to 1024 and loads models on demand; no numbers given — [Pixal3D GitHub](https://github.com/TencentARC/Pixal3D)
- Hunyuan3D 2.1: shape ~10 GB, texture ~21 GB, both ~29 GB — [Hunyuan3D-2.1 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1)
- Hunyuan3D 2.0: 6 GB shape, 16 GB shape+texture; `--low_vram_mode` flag exists (undocumented); FlashVDM (`--enable_flashvdm`) for Turbo; Fast variant "could half the dit inference time"; 2mini shape model 0.6B — [Hunyuan3D-2 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2)
- Step1X-3D: 27 GB (geometry-1300m + texture) / 29 GB (label variant), 152 s for 50 steps, GPU unstated — [Step1X-3D GitHub](https://github.com/stepfun-ai/Step1X-3D); a local guide recommends 32 GB GPU + 64 GB RAM — [localclaw](https://localclaw.io/3d/step1x-3d)
- SAM 3D Objects: NVIDIA GPU with "at least 32 Gb of VRAM", Linux 64-bit — [SAM 3D setup.md](https://github.com/facebookresearch/sam-3d-objects/blob/main/doc/setup.md); a blog claims 16 GB minimum (conflicts with official) — [search summary of third-party blog](https://www.adwaitx.com/meta-sam-3d-models-guide/)
- Direct3D-S2: ≥10 GB @512 (not recommended, lower quality), ~24 GB @1024 — [Direct3D-S2 GitHub](https://github.com/DreamTechAI/Direct3D-S2)
- TripoSG: ≥8 GB — [TripoSG GitHub](https://github.com/VAST-AI-Research/TripoSG)
- SPAR3D: 10.5 GB default, ~7 GB with `SPAR3D_LOW_VRAM=1` (same README also says ~6 GB per image — inconsistent) — [SPAR3D README mirror](https://gitee.com/cctvteam/stable-point-aware-3d)
- Hi3D v1.0: vendor tested only on 96 GB; ~10 GB third-party estimate (calculated, not measured) — [Tokenstrom](https://tokenstrom.com/posts/hi3d-v1-0-formerly-sparc3d-goes-open-source-with-mesh-refinement-up-to/)

### Inferences (fit table; "official" = README number, "?" = community/unverified)
| Model | 24 GB (3090/4090) | 16 GB (5080/4080) | 12 GB | 8 GB |
|---|---|---|---|---|
| TRELLIS.2 | Yes (official) | ? (community, low-VRAM/ComfyUI) | ? (slow, reported) | ? (512³ only, claimed) |
| Pixal3D | Probably at `--low_vram` 1024 (inherits TRELLIS.2) | ? | ? | No evidence |
| Hunyuan3D 2.1 | Yes if shape and paint run sequentially with unload (10 + 21 GB); not both resident (29 GB) | Shape only | Shape only | No |
| Hunyuan3D 2.0/2mini | Yes | Yes (16 GB official) | Shape (+ maybe texture with low_vram_mode, unverified) | Shape only (6 GB) |
| Step1X-3D | Marginal/no at default (27 GB); likely with stage offload | No | No | No |
| SAM 3D Objects | No (official ≥32 GB) | No | No | No |
| Direct3D-S2 | Yes @1024 (~24 GB, tight) | @512 only | @512 only | No |
| TripoSG | Yes | Yes | Yes | Yes (official 8 GB) |
| SPAR3D | Yes | Yes | Yes | Yes with low-VRAM (~7 GB) |
- Apple Silicon/macOS: Hunyuan3D 2.1 README says it supports macOS, Windows and Linux ([Hunyuan3D-2.1 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1)); TRELLIS.2 is CUDA/Linux-tested only. So TRELLIS.2/Pixal3D realistically need an NVIDIA box (e.g. the user's gaming PC RTX 3080 10 GB would be under the official floor).

### Gaps
- No measured peak-VRAM numbers on RTX 3090/4090/5080 for TRELLIS.2 or Pixal3D from a primary source; H100 runtimes only for TRELLIS.2.
- Runtime for Hunyuan3D 2.1 and Pixal3D not reported in READMEs.

## Licence and commercial/territorial restrictions (user in the EU)

### Takeaway
For an EU user, MIT/Apache models (TRELLIS.2, Pixal3D code, Step1X-3D, Direct3D-S2, TripoSG, TripoSR, UniLat3D code) are clean; Hunyuan3D 2.0/2.1 (and Hunyuan-derived Omni/Part) are **not licensed for use in the EU at all**; SAM 3D uses Meta's custom SAM License; Stability (SF3D/SPAR3D) is free under $1M revenue; Hi3D v1.0 has MAU/revenue thresholds and mandatory attribution.

### Cited Findings
- TRELLIS.2 code and weights: MIT; nvdiffrast and nvdiffrec governed by NVIDIA licences — [TRELLIS.2 GitHub](https://github.com/microsoft/TRELLIS.2); third-party guide notes those NVIDIA dependencies carry non-commercial terms — [search summary, freeapihub](https://freeapihub.com/ai-models/trellis-2); TRELLIS-Studio notes DINOv3 (used as image encoder) has its own licence — [TRELLIS-Studio](https://github.com/yoslo59/TRELLIS-Studio)
- Hunyuan3D 2.1 licence, Section 1.l: Territory is "excluding the territory of the European Union, United Kingdom and South Korea"; Section 4: >1M MAU requires a Tencent licence; Section 5(b): may not use Works or Outputs "to improve any other AI model" — [Hunyuan3D-2.1 LICENSE](https://huggingface.co/tencent/Hunyuan3D-2.1/blob/main/LICENSE)
- Hunyuan3D 2.0, Omni and Part are under community licences with the same exclusions (aggregator) — [triposr.org](https://triposr.org/blog/hunyuan3d-versions)
- Claims that Hunyuan3D is "Apache 2.0" (e.g. hokai.io) are wrong per the licence file — [hokai.io (incorrect claim)](https://hokai.io/hub/tools/hunyuan-3d) vs [Hunyuan3D-2.1 LICENSE](https://huggingface.co/tencent/Hunyuan3D-2.1/blob/main/LICENSE)
- Pixal3D code MIT; weights licence not stated in README; third-party components keep their terms (NOTICE) — [Pixal3D GitHub](https://github.com/TencentARC/Pixal3D); Cinevva lists Pixal3D as MIT — [Cinevva](https://app.cinevva.com/guides/ai-3d-model-generation-timeline-2026)
- SAM 3D Objects checkpoints and code: SAM License (gated HF download); grant is non-exclusive, worldwide, royalty-free, with prohibitions on military/warfare/nuclear/espionage uses (per secondary summary) — [SAM 3D GitHub](https://github.com/facebookresearch/sam-3d-objects); [Roboflow playground](https://playground.roboflow.com/models/meta/sam-3d-objects)
- Step1X-3D: Apache 2.0 — [Step1X-3D GitHub](https://github.com/stepfun-ai/Step1X-3D)
- Direct3D-S2: MIT — [Direct3D-S2 GitHub](https://github.com/DreamTechAI/Direct3D-S2)
- TripoSG repo: MIT (weights and RMBG-1.4 licences not stated; note BRIA RMBG-1.4 is itself non-commercial — prior knowledge, not re-verified) — [TripoSG GitHub](https://github.com/VAST-AI-Research/TripoSG)
- SPAR3D/SF3D: Stability AI Community License, free for orgs/individuals under US$1M annual revenue, Enterprise licence above; gated download — [SPAR3D HF](https://huggingface.co/stabilityai/stable-point-aware-3d); [Stability blog](https://stability.ai/news/stable-point-aware-3d)
- Hi3D v1.0: Hi3D Open License; commercial use allowed but separate licence above 200k MAU or $1M monthly revenue; integrations must display "Powered by Hi3D 1.0"; not OSI-approved — [Tokenstrom](https://tokenstrom.com/posts/hi3d-v1-0-formerly-sparc3d-goes-open-source-with-mesh-refinement-up-to/)
- UniLat3D: Apache 2.0 for original code; third-party components keep their licences — [UniLat3D GitHub org](https://github.com/UniLat3D)

### Inferences
- For a feature that ships in Convolution (EU developer, App Store/sideload), Hunyuan3D in any open version is off the table; even running it as a personal tool in the EU is outside the licensed Territory.
- TRELLIS.2 is MIT but its mesh/texture post-processing depends on nvdiffrast (NVIDIA Source Code License, non-commercial); a commercial or server-side deployment would need to replace or license that piece. Pixal3D inherits the same dependency stack.
- Running a model server-side (e.g. on the gaming PC) and returning a GLB to the app keeps the weights out of the app bundle; the licence of the weights still governs that use.

### Gaps
- Pixal3D HF weight licence file not checked directly.
- Exact SAM License commercial terms not read from the primary text.

## ComfyUI integration (supplementary)
- TRELLIS.2: covered by ComfyUI-Wiki on release (2025-12-18), with community ComfyUI workflows and low-VRAM workflows in 2026 — [ComfyUI-Wiki](https://comfyui-wiki.com/en/news/2025-12-18-microsoft-trellis2-3d-generation); [lilys.ai notes on "Comfy Trellis 2 update"](https://lilys.ai/notes/pt/d5-render-20260219/comyui-trellis2-better-free-3d-ai)
- Hunyuan3D 2.0: ComfyUI-Hunyuan3DWrapper (kijai) and ComfyUI-3D-Pack listed as community extensions — [Hunyuan3D-2 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2); 2.1: ComfyUI-Hunyuan3d-2-1 by visualbruno — [Hunyuan3D-2.1 GitHub](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1)
- Pixal3D: community Pixal3D-ComfyUI by Saganaki22 — [Pixal3D GitHub](https://github.com/TencentARC/Pixal3D)
- Step1X-3D: ComfyUI listed as an undelivered plan item — [Step1X-3D GitHub](https://github.com/stepfun-ai/Step1X-3D)
- Direct3D-S2, TripoSG: no ComfyUI mention in READMEs (community nodes may exist; not verified).
