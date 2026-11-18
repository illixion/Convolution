# Running image-to-3D generators on lower-end hardware (as of November 2026)

Scope: TRELLIS / TRELLIS.2, Hunyuan3D 2.x (incl. mini/turbo/FlashVDM), TripoSG, Step1X-3D, SAM 3D Objects, SF3D/SPAR3D/TripoSR, MV-Adapter, Direct3D-S2. Target hardware: RTX 3090 (24 GB) for prototyping, RTX 5080 (16 GB, Blackwell sm_120), 16/12/8 GB consumer cards, Apple Silicon Macs, eventually Vision Pro (M5, 16 GB) / iPhone.

Convention: "Cited Findings" are reported numbers with sources (official = repo README/model card; community = forks, blogs, Reddit, auto-generated wikis, flagged as such). "Inferences" are mine.

## 1. What is the smallest hardware each leading model runs on today, and at what quality cost?

### Takeaway
Shape-only generation is already within 6–8 GB VRAM for Hunyuan3D-2mini(-Turbo + FlashVDM), Hunyuan3D 2.0 and TripoSG, and TRELLIS.2 has a community GGUF route reported around 6.5–8 GB at 512³. The real memory peak is almost always the texture stage (multi-view diffusion + bake): Hunyuan3D 2.1 is 10 GB shape but 21 GB texture, and Step1X-3D / SAM 3D Objects officially want 27–32 GB. So on a 16 GB card (RTX 5080) the practical recipe is to load shape and texture models sequentially, never together, and to use the smaller texture variants.

### Cited Findings

**Hunyuan3D 2.0 / 2mini / 2.1 (Tencent)**
- Official: Hunyuan3D 2.0 "takes 6 GB VRAM for shape generation and 16 GB for shape and texture generation in total." — [Tencent/Hunyuan3D-2 README](https://github.com/Tencent/Hunyuan3D-2)
- Official model zoo sizes: 2mini / mini-Fast / mini-Turbo = 0.6B; 2.0 DiT / Fast / Turbo = 1.1B; 2mv (multi-view input) = 1.1B; Paint-v2-0 (+Turbo) = 1.3B; Delight-v2-0 = 1.3B; 2.1 DiT = 3.0B; Paint-v2-1 = 1.3B. — [Tencent/Hunyuan3D-2 README](https://github.com/Tencent/Hunyuan3D-2)
- Official: "Fast" variants are guidance-distilled and "could half the dit inference time" (Feb 2025). Turbo models (2-Turbo, 2mini-Turbo) and FlashVDM released Mar 19 2025; launch commands combine `--low_vram_mode` and `--enable_flashvdm`. The README does not explain what `--low_vram_mode` does and gives no per-variant VRAM numbers. — [Tencent/Hunyuan3D-2 README](https://github.com/Tencent/Hunyuan3D-2)
- Official Comfy docs: the mini model "requires only 5GB VRAM for shape generation." — [ComfyUI Hunyuan3D-2 tutorial](https://docs.comfy.org/tutorials/3d/hunyuan3D-2)
- Community (auto-generated DeepWiki, numbers disagree between its own pages): "Mini + Turbo + FlashVDM + Low VRAM" ≈ 6 GB as "minimum viable"; elsewhere 4–6 GB for "edge deployment"; Turbo + FlashVDM (full 1.1B) 10+ GB. — [DeepWiki deployment options](https://deepwiki.com/Tencent/Hunyuan3D-2/8.2-deployment-options), [DeepWiki performance optimization](https://deepwiki.com/Tencent/Hunyuan3D-2/7.1-performance-optimization)
- Official (2.1): "10 GB VRAM for shape generation, 21GB for texture generation and 29GB for shape and texture generation in total"; `--low_vram_mode` is supported. — [Hunyuan3D-2.1 README mirror](https://gh.ali360.cloudns.ch/Tencent-Hunyuan/Hunyuan3D-2.1), [HF Space README copy](https://huggingface.co/spaces/dylanebert/Hunyuan3D-2.1/blob/4ba9ccc49d39b296e82df14994f9999592b85c4c/README.md)
- Hunyuan3D 3.0: a secondary source describes it as available through ComfyUI partner (API) nodes, not as open weights; no official Tencent licensing statement found. — [Picassoia blog](https://blog.picassoia.com/hunyuan3d-image-to-3d-free-model-comfyui-and-api)

**TRELLIS.2 (Microsoft, 4B, MIT)**
- Official: NVIDIA GPU with ≥24 GB, verified only on A100/H100, Linux only, CUDA 12.4 recommended, default env PyTorch 2.6.0+cu124. Runtimes on H100: 512³ ~3 s (2 s shape + 1 s material); 1024³ ~17 s (10+7); 1536³ ~60 s (35+25). Only low-memory hint given: `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`. Paper arXiv 2512.14692. — [microsoft/TRELLIS.2](https://github.com/microsoft/TRELLIS.2), [HF model card](https://huggingface.co/microsoft/TRELLIS.2-4B/blob/main/README.md)
- Community GGUF route: Aero-Ex/ComfyUI-Trellis2-GGUF with weights from Aero-Ex/Trellis2-GGUF, ~2.5 GB at GGUF Q4 vs ~8 GB BF16; nodes Trellis2LoadModel_GGUF / Trellis2Remesh_GGUF / Trellis2MeshTexturing_GGUF; a reported bug 404s the BF16 safetensors option; install friction reported. — [toastmanAu/trellis-2-rocm-comfyui write-up](https://github.com/toastmanAu/trellis-2-rocm-comfyui), [JanskNeh/ComfyUI-Trellis2-GGUF](https://github.com/JanskNeh/ComfyUI-Trellis2-GGUF)
- Community, unverified SEO-style sites: "~6.5 GB at 512³ in low-VRAM mode on RTX 3060 8GB"; "peak 7.2 GB at 512 and 7.9 GB at 1024 without low-VRAM mode"; "minimum 8 GB at low resolution; 16 GB+ recommended for full-resolution textured output." Treat as weak. — [trellis2.app low VRAM](https://trellis2.app/blog/trellis-2-low-vram), [trellis2.app ComfyUI](https://trellis2.app/blog/trellis-2-comfyui)
- Main ComfyUI node pack for TRELLIS.2: visualbruno/ComfyUI-Trellis2 — [GitHub](https://github.com/visualbruno/ComfyUI-Trellis2). A "Remesh with Quad" node is reported to use less VRAM than the standard remesh. — [lilys.ai summary](https://lilys.ai/notes/pt/d5-render-20260219/comyui-trellis2-better-free-3d-ai) (secondary)

**TripoSG (VAST, rectified-flow shape model)**
- Official: CUDA GPU with >8 GB VRAM. — [VAST-AI/TripoSG HF card](https://huggingface.co/VAST-AI/TripoSG), [GitHub](https://github.com/VAST-AI-Research/TripoSG)
- Community: RTX 3060 Ti 8 GB ran the quick-start at ~7.4 GB peak, ~1 min 15 s. — [r/StableDiffusion thread](https://redlib.cypherpunktools.com/r/StableDiffusion/comments/1jpl4tm/open_sourcing_triposg_highfidelity_3d_generation/ml08a33/?context=3)
- Community: an RTX 3090 Ti 24 GB user OOM'd in the Gradio Space app; reply says shape works outside Gradio, texture mapping is the problem. — [HF Space discussion #6](https://huggingface.co/spaces/VAST-AI/TripoSG/discussions/6)

**Step1X-3D (StepFun)**
- Community (DeepWiki): full pipeline at default settings needs ≥27–29 GB; geometry+texture config listed at 27 GB / 152 s. A third-party write-up says min 24 GB, RTX 4090 recommended. No official number found. — [DeepWiki troubleshooting](https://deepwiki.com/stepfun-ai/Step1X-3D/7-troubleshooting-and-faq), [xugj520 write-up](https://www.xugj520.cn/en/archives/open-source-3d-asset-generation.html)
- Its texture stage uses an SDXL-based "ig2mv" (MV-Adapter-style) pipeline. — [Step1X-3D Space source](https://huggingface.co/spaces/ajsbsd/Step1X-3D/commits/main/step1x3d_texture/pipelines/ig2mv_sdxl_pipeline.py)

**SAM 3D Objects (Meta)**
- Official: NVIDIA GPU with ≥32 GB VRAM, linux-64 only. — [facebookresearch/sam-3d-objects docs](https://docsearch.algolia.com/mcp/docs/repo/facebookresearch/sam-3d-objects), [EmbodiedGen setup copy](https://huggingface.co/spaces/HorizonRobotics/EmbodiedGen-Texture-Gen/blob/main/thirdparty/sam3d/doc/setup.md)
- Community: A5000 (24 GB) mean ~37.0 s per single-object inference; a Japanese blog claims RTX 3060 12 GB works (10–12 GB comfortable, 6–8 GB minimum) without showing how — conflicts with the official 32 GB. — search-result summaries of [Skywork blog](https://skywork.ai/blog/ai-image/install-sam-3d-jp?lang=pt); fal's "6 GB geometry / 12 GB full" appears to describe its hosted service — [fal.ai comparison](https://fal.ai/learn/devs/sam-3d-vs-hunyuan3d-2)

**MV-Adapter (multi-view diffusion, used for texturing)**
- Official: image-to-multiview (SDXL) "requires about 14G GPU memory." Text+geometry: SDXL recommended above 12 GB, SD2.1 below 6 GB. Image+geometry: SDXL above 16 GB, SD2.1 below 10 GB. Texture generation: `--variant sd21` when under 10 GB. LCM variant (8 steps, `--scheduler lcm`) for speed. 6 views; 768 px with SDXL. Texture pipeline needs CV-CUDA, RealESRGAN_x2plus and big-lama (LaMa) checkpoints. — [huanngzh/MV-Adapter](https://github.com/huanngzh/MV-Adapter)

**Direct3D-S2 (sparse-voxel, spatial sparse attention)**
- Paper: SSA enables training at 1024³ on 8 GPUs vs 32+ GPUs typical even at 256³. — [arXiv 2505.17412](https://arxiv.org/abs/2505.17412v2)
- Third-party Replicate card: 512 res needs ≥10 GB, 1024 res >24 GB. — [Replicate hcl14/direct3d_s2](https://replicate.com/hcl14/direct3d_s2)

**SF3D / SPAR3D / TripoSR (feed-forward reconstruction, small)**
- SPAR3D code has a `SPAR3D_LOW_VRAM` environment flag (CUDA path). — [SPAR3D system.py copy](https://huggingface.co/spaces/klawdyoss/text-to-3d-2.0/blob/main/spar3d/system.py)
- (On-device numbers for these are in section 3.)

### Inferences
- Smallest-hardware ranking for shape (inferred from the above): Hunyuan3D-2mini(-Turbo/FlashVDM) ≈ 5–6 GB < Hunyuan3D 2.0 ≈ 6 GB < TripoSG ≈ 7.5–8 GB ≈ TRELLIS.2 GGUF Q4 at 512³ (community 6.5–8 GB) < Hunyuan3D 2.1 ≈ 10 GB ≈ Direct3D-S2 @512 < TRELLIS.2 full (24 GB official) < Step1X-3D / SAM 3D (27–32 GB).
- On a 16 GB RTX 5080: Hunyuan3D 2.0 shape+texture (16 GB official total) is at the edge; with sequential loading/`--low_vram_mode` it should fit. Hunyuan3D 2.1 texture (21 GB) will not fit without offload or a smaller paint config. TRELLIS.2 at 512³/1024³ likely fits with GGUF or bf16 + offload, but see the Blackwell CuMesh bug in section 4.
- On 8 GB: shape-only with Hunyuan3D-2mini / TripoSG / TRELLIS.2-GGUF-512 is realistic; texturing will need SD2.1-class multi-view (MV-Adapter sd21) or vertex colours, with a visible quality drop (lower res, fewer views).
- Quality cost of the small variants: mini (0.6B vs 1.1B) and Turbo/Fast trade detail and prompt adherence for speed/memory; no official quantitative quality deltas were found (see Gaps).

### Gaps
- No official per-variant VRAM for Hunyuan3D-2mini-Turbo + FlashVDM; only Comfy's 5 GB for plain mini and auto-generated DeepWiki figures.
- No official VRAM numbers for TRELLIS.2 at each resolution, nor any validated quality comparison for GGUF Q4/Q8 vs bf16.
- No official SF3D / SPAR3D VRAM figures were retrieved in this pass; no Step1X-3D official number.
- No FP8/NVFP4 quantized checkpoints for 3D DiTs were found from official sources (GGUF for TRELLIS.2 is the only quantization route found).
- No reliable measured quality deltas (e.g., Chamfer / user study) between Hunyuan3D 2.0 vs mini vs Turbo.

## 2. Step-distillation, acceleration, and where the real VRAM peak is (decode / texture bake)

### Takeaway
Step-distillation for 3D-native DiTs works: Hunyuan3D ships guidance-distilled "Fast" and step-distilled "Turbo" variants plus FlashVDM (claimed ~1 s/shape, >32× speedup), and MDT-dist cuts TRELLIS to 1–2 steps per flow transformer (0.68–0.94 s on A800). Sparse attention (Direct3D-S2) attacks the token-count problem at high resolution. But the dominant cost on small hardware is not the DiT — it's the VAE/mesh decode (dense volume query), remeshing/hole-filling and especially texture multi-view diffusion and baking.

### Cited Findings
- FlashVDM (ICCV 2025): reports >32× speedup, ~1 s per shape for Hunyuan3D-2 Turbo; it accelerates both diffusion sampling (progressive flow distillation) and the VAE decode (vecset decoding was the bottleneck). — [arXiv 2503.16302](https://arxiv.org/abs/2503.16302), [ICCV paper](https://openaccess.thecvf.com/content/ICCV2025/html/Lai_Unleashing_Vecset_Diffusion_Model_for_Fast_Shape_Generation_ICCV_2025_paper.html), [Tencent/FlashVDM](https://www.github.com/Tencent/FlashVDM)
- Hunyuan3D "Fast" = guidance distillation, halves DiT time. — [Tencent/Hunyuan3D-2 README](https://github.com/Tencent/Hunyuan3D-2)
- MDT-dist (arXiv 2509.04406): distils TRELLIS flow transformers from 25 steps to 1–2 each; 0.68 s (1 step) / 0.94 s (2 steps) on A800, 9.0× / 6.5× speedup; authors report beating CM/PCM/sCM baselines and non-distilled TRELLIS. — [arXiv](https://arxiv.org/abs/2509.04406), [project page](https://zanue.github.io/mdt-dist/)
- Turbo3D (arXiv 2412.04470): few-step distillation of a multi-view diffusion generator for text-to-3D (different approach: distils the 2D multi-view stage, not a 3D DiT). — [arXiv](https://arxiv.org/html/2412.04470v1)
- Direct3D-S2 spatial sparse attention: 1024³ training on 8 GPUs. — [arXiv 2505.17412](https://arxiv.org/abs/2505.17412v2)
- UltraShape 1.0 report: larger token counts at high resolution bring "significant computational and memory overhead" for sparse-voxel methods. — [arXiv 2512.21185](https://arxiv.org/html/2512.21185v1)
- Texture is the peak, evidence:
  - Hunyuan3D 2.1: 10 GB shape vs 21 GB texture. — [2.1 README](https://gh.ali360.cloudns.ch/Tencent-Hunyuan/Hunyuan3D-2.1)
  - Hunyuan3D 2.0: 6 GB shape vs 16 GB total. — [2.0 README](https://github.com/Tencent/Hunyuan3D-2)
  - TripoSG: shape fits 8 GB, texture OOMs a 24 GB card in Gradio. — [HF discussion](https://huggingface.co/spaces/VAST-AI/TripoSG/discussions/6)
  - MV-Adapter SDXL image-to-MV ~14 GB. — [MV-Adapter](https://github.com/huanngzh/MV-Adapter)
  - On Mac, Hunyuan3D 2.1 PBR texturing at only 256 px / 6 views took ~8.5 min and ran into swap on 24 GB, while shape was ~5.7 min; the paint model's attention matrix is 4.2 GiB at the "Safe" preset and 67.5 GiB / 607.5 GiB at "Low"/"Normal". — [hunyuan3d-2.1-mac README](https://raw.githubusercontent.com/VladimirTalyzin/hunyuan3d-2.1-mac/main/README.md)
  - TRELLIS.2 on Mac: shape SLat decoder ~20 s, texture decoder ~7 s, mesh extraction ~8 s, bake (1024²) ~15 s; hole filling disabled because the CuMesh Metal port segfaults on decoder-sized meshes; mesh pre-simplified to ~200K faces before baking. — [trellis-mac](https://github.com/shivampkumar/trellis-mac)
  - Hunyuan3D-2.1 shape on MLX: octree 384 uses ~56M voxels vs ~3M at 256 (decode query volume). — [hy3dmlx-shape-v2.1](https://huggingface.co/AgenticVibes/hy3dmlx-shape-v2.1)

### Inferences
- For a 16 GB/8 GB pipeline, the levers in order of payoff are: (1) never co-resident shape + texture models; (2) lower octree / grid resolution for decode (256 vs 384 is ~18× fewer query points per the MLX card); (3) chunked decode (FlashVDM's adaptive/hierarchical decode); (4) fewer, smaller multi-view texture views or SD2.1-class MV; (5) step-distilled DiT (Turbo / MDT-dist) — this mainly buys time, not memory.
- Distillation is directly relevant to on-device: a 1–2-step TRELLIS-class sampler removes the main time cost, leaving decode/bake as the target for Metal work.
- MDT-dist weights' public availability was not verified (see Gaps).

### Gaps
- Whether MDT-dist checkpoints/code are public, and whether any distillation exists for TRELLIS.2 (vs TRELLIS 1) or Hunyuan3D 2.1.
- No found sparse-attention or FP8 work aimed at consumer-GPU inference specifically (Direct3D-S2's gains are reported for training).
- No measured per-stage VRAM breakdown (DiT vs decode vs bake) on CUDA for any model; the Mac READMEs give time, not peak memory per stage.

## 3. Apple Silicon and on-device: what exists, runtimes, blockers, porting path

### Takeaway
Both TRELLIS.2 and Hunyuan3D 2.1 now run on Apple Silicon via community PyTorch-MPS ports that replace every CUDA extension (sparse conv → Metal `mtlgemm`, flash-attn → SDPA, nvdiffrast → `mtldiffrast`/pure-PyTorch rasterizer, CuMesh → skipped), and Hunyuan3D 2.1's shape stage has an MLX port peaking at 7.85 GB. They are slow (TRELLIS.2 512: ~3m20s on M4 Pro 24 GB; Hunyuan3D 2.1 shape+texture ~14 min) and need ≥24 GB in practice. On phones, only small feed-forward reconstructors (SF3D via ONNX Runtime on iPhone/iPad; TripoSR ~15 s on an unnamed phone CPU) run today — no generative 3D DiT has been shown on iPhone or Vision Pro.

### Cited Findings

**TRELLIS.2 on Mac (shivampkumar/trellis-mac, PyTorch MPS)**
- Replacements: `flex_gemm` (sparse 3D conv) → `mtlgemm` (Metal port by Pedro Naugusto) with `backends/conv_none.py` pure-PyTorch fallback; `o_voxel._C` hashmap → pure-Python `mesh_extract.py` (+ CPU fork of o_voxel for texture); `flash_attn` → padded PyTorch SDPA; `cumesh` → skipped (fast_simplification before baking); `nvdiffrast` → `mtldiffrast` (Metal) with Python fallback; `.cuda()` calls → active device. — [trellis-mac](https://github.com/shivampkumar/trellis-mac)
- Memory: 24 GB+ unified recommended, peak ~18 GB, ~15 GB weights on disk. — same
- M4 Pro 24 GB, pipeline 512: load 103 s; sparse structure sampling 80 s; shape SLat 22 s; texture SLat 12 s; shape decode ~20 s; texture decode ~7 s; mesh extraction ~8 s; simplification 858K→200K faces ~1 s; Metal bake 1024² ~15 s; cold total 5 m 13 s; generation+bake 3 m 20 s. Thermal throttling can be 6–10× slower. — same
- Biggest remaining bottleneck: un-fused sparse attention, ~80 s of the sparse-structure phase. Modes: `--pipeline-type 512|1024|1024_cascade`, `--texture-size 512|1024|2048`. Hole filling disabled; Metal BVH unstable on large meshes. — same
- MLX effort `lyonsno/trellis2mlx`: sparse-structure and shape-latent stages working, mesh decoder "coming next" (in progress). — [trellis2mlx](https://github.com/lyonsno/trellis2mlx)

**Hunyuan3D 2.1 on Mac (VladimirTalyzin/hunyuan3d-2.1-mac, PyTorch MPS)**
- Replacements: CUDA custom rasterizer → pure-PyTorch `torch_rasterizer.py` on MPS (C++ CPU build via `HY3D_RASTER=cpu`); xformers/flash-attn/bitsandbytes/cupy not needed for inference; attention via MPS SDPA with a size cap; Blender `bpy` → `mesh_io.py`; a `torch.isin` replacement (avoided a 111 GB buffer request) and float64 workarounds (Metal has no float64). — [README](https://raw.githubusercontent.com/VladimirTalyzin/hunyuan3d-2.1-mac/main/README.md)
- M4 Pro 24 GB, macOS 26: shape 30 steps, octree 192 ~5.7 min (7.6 s/step); PBR texturing "Safe" (6 views, 256 px) ~8.5 min, ~8 GB swap; requires `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0`; higher texture settings blocked by Metal max buffer size (12 GiB single allocation ok, 24 GiB not). Shape and paint models never co-resident. ~30 GB install. 16 GB min / 24 GB+ recommended per the port. — same; [search summary of port](https://raw.githubusercontent.com/VladimirTalyzin/hunyuan3d-2.1-mac/main/README.md)
- Upstream PR adds CPU custom-rasterizer builds and an Apple Silicon guide; segfaults may be from insufficient RAM. — [Hunyuan3D-2.1 PR #105](https://github.xiaohuzi123231346.workers.dev/Tencent-Hunyuan/Hunyuan3D-2.1/pull/105/files)
- Hunyuan3D 2.0 README claims macOS/Windows/Linux support, but does not mention MPS, and the texture extensions are CUDA-style builds. — [Hunyuan3D-2](https://github.com/Tencent/Hunyuan3D-2)
- A Japanese write-up ran Hunyuan3D from ComfyUI on a Mac GPU. — [Zenn article](https://zenn.dev/renue/articles/144cd47fbe9d7a)

**Hunyuan3D 2.1 shape on MLX (AgenticVibes/hy3dmlx-shape-v2.1)**
- Ports DiT (HunYuanDiT-Plain, 21 layers, hidden 2048, 16 heads, last 6 layers MoE 8 experts top-2, ~3.3B), shape VAE encoder and decoder; DINOv2-Large pulled from upstream. fp16, no quantization yet (Q8/Q4 listed as future). Peak 7.85 GB at octree 384; 50 steps CFG 5.0: DiT 646 s of 1112 s total (~18.5 min) on "M3 Ultra-class"; octree 256 ~5 min. Untextured mesh only; paint pipeline in a separate repo (AgenticVibes/hunyuan3d-2.1-mlx). — [HF card](https://huggingface.co/AgenticVibes/hy3dmlx-shape-v2.1)
- Also reported: an MLX-community discussion on 3D generative AI with MLX (point clouds, Gaussian splatting). — [HF discussion](https://huggingface.co/spaces/mlx-community/README/discussions/22)
- `ultrashape-mac` port exists (not read). — [199-biotechnologies/ultrashape-mac](https://github-users.yhajoa.workers.dev/199-biotechnologies/ultrashape-mac)

**On iPhone / iPad / phones**
- SF3D-iOS: Stable Fast 3D converted to ONNX (encoder fp16 weights / fp32 I/O, decoder fp32) running "entirely on an iPhone/iPad via ONNX Runtime": 512×512 input → triplane [1,3,40,384,384] → density/RGB decoder → marching cubes (iso 10.0). Vertex/point colours; no UV unwrap mentioned. No runtime or memory figures published. Single-view; multi-view encoder unvalidated. Stability AI Community License (free under $1M revenue, attribution required). — [jc-builds/sf3d-ios](https://huggingface.co/jc-builds/sf3d-ios)
- Arm blog: Unity + ONNX Runtime, CPU-first, TripoSR split into ONNX sub-models, MLP int8 dynamic quantization (triplane net left unquantized because quantization degraded reconstruction), marching cubes res 160. Image→3D 15.3 s (triplanes 9.7 s); with LCM text→image 8.2 s, end-to-end 23.5 s, measured with a mini-game running. Phone not named. — [Arm community blog](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/can-mobile-phones-generate-a-3d-object-at-game-runtime-in-unity-here-is-what-actually-happens)
- Apple's SHARP (single photo → 3D Gaussian parameters) has community Core ML conversions targeting CPU/GPU/ANE on macOS and iOS (splats, not meshes; a view-synthesis model, not a full-object generator). — [pearsonkyle/Sharp-coreml](https://huggingface.co/pearsonkyle/Sharp-coreml/blob/main/README.md)

### Inferences
- The CUDA-only blockers are the same across models and are now all solved at least once on Metal: sparse conv (spconv/flex_gemm → mtlgemm), flash-attn (→ SDPA, at a memory/time cost), rasterization (nvdiffrast / custom_rasterizer → mtldiffrast or PyTorch rasterizer), mesh ops (CuMesh, o-voxel hashmap → CPU/Python, with hole filling still missing). Remaining Mac gaps are performance (unfused sparse attention, no flash-attention for the paint model's huge attention matrices) and Metal's per-buffer size limit.
- Hunyuan3D-family vecset models (dense latent set + transformer, no sparse conv) are the easier on-device porting target than TRELLIS's sparse-voxel stack: hy3dmlx already fits 7.85 GB fp16 for a 3.3B model; Hunyuan3D-2mini (0.6B) at fp16 would be ~1.2 GB weights, and with Q8/Q4 + Turbo/FlashVDM steps is plausibly within an M5 Vision Pro's budget (inference, not measured). Core ML conversion of a plain transformer DiT + MLP geo-decoder is standard; marching cubes / octree decode would be a custom Metal kernel.
- TRELLIS.2 on-device would need: an MLX/Metal sparse-conv and sparse-attention (trellis2mlx is partway), CuMesh replacements, and distillation (MDT-dist-like) to make 4B params × few steps tolerable; 4B at Q4 ≈ 2–2.5 GB (consistent with GGUF Q4 ~2.5 GB), so memory is not the blocker; compute and kernel coverage are.
- Realistic near-term on-device for Vision Pro/iPhone: feed-forward SF3D/TripoSR/SPAR3D-class reconstructors (seconds, low fidelity, especially on the unseen back side), or SHARP-style splats; generative-quality "wraparound" assets should be generated on the Mac or a GPU server and streamed.
- Texture on device: skip multi-view diffusion; use vertex colours from the generator (as trellis-mac and SF3D do) or a single-view projection + inpaint. Multi-view SDXL texturing (14 GB+) is not a candidate for 16 GB unified memory shared with the OS and the app.

### Gaps
- No timings for trellis-mac or hunyuan3d-2.1-mac on M1/M2/M3 base chips, 16 GB Macs, or M5; no MLX numbers for Hunyuan3D-2mini.
- No published 3D generative DiT running on iPhone, iPad or Vision Pro (searches found none); SF3D-iOS gives no latency/memory.
- No Core ML conversion of any Hunyuan3D/TRELLIS/TripoSG component found.
- visionOS-specific memory limits for a foreground app on the 16 GB M5 Vision Pro not researched here.

## 4. Blackwell / RTX 50-series compatibility of the CUDA extension stack (late 2026)

### Takeaway
Blackwell (sm_120) is workable but not plug-and-play: use PyTorch cu128+ builds, build extensions from source with `TORCH_CUDA_ARCH_LIST=12.0`, take community spconv wheels, prefer SDPA over flash-attn, and — critically for TRELLIS.2 — CuMesh's remeshing produces fragmented meshes on all RTX 50-series GPUs (open issue, no official fix as of the page read; workaround is a CPU marching-cubes path). Prototype on the 3090 (sm_86), where the official environments work.

### Cited Findings
- PyTorch: cu128 builds work on RTX 5080 (e.g., torch 2.9.0.dev20250905+cu128 reported working); older stable builds lacking sm_120 give "no kernel image" errors; a guide notes cu128 was the answer for most of 2025 and to check the current index before pinning. — [PyTorch forum sm120 thread](https://discuss.pytorch.org/t/pytorch-support-for-sm120/216099), [localaimaster sm_120 fix](https://localaimaster.com/blog/no-kernel-image-available-rtx-50)
- If nvcc rejects `compute_120`, the toolkit predates Blackwell; set `TORCH_CUDA_ARCH_LIST=12.0`; reinstall source-built extensions (kaolin, nvdiffrast) rather than PyTorch. — [localaimaster](https://localaimaster.com/blog/no-kernel-image-available-rtx-50)
- CUDA 12.8/12.9 .run/.deb installers reportedly lack `libnvptxcompiler.so`, breaking runtime PTX JIT on RTX 5080; AOT builds unaffected. — [HF forum](https://discuss.huggingface.co/t/ptx-jit-broken-on-rtx-5080-blackwell-sm-120-missing-libnvptxcompiler-so-in-cuda-12-8-12-9/161827)
- spconv: community prebuilt spconv 2.3.8 + cumm 0.8.2 wheels for CUDA 12.8 / 13.0 with native sm_120 kernels; install spconv and cumm from the same flavor; building needs `CUMM_DISABLE_JIT=1` and `SPCONV_DISABLE_JIT=1`. — [fafraob/spconv-wheels](https://github.com/fafraob/spconv-wheels)
- flash-attn: building 2.x from source with `FLASH_ATTN_CUDA_ARCHS=120` reportedly crashes nvcc on backward kernels (RTX 5070 Ti, CUDA 12.8/12.9); flash-attn 2.8.3 with `TORCH_CUDA_ARCH_LIST=12.0` reported working on sm_121 (GB10); Windows 5090 flash-attn 2.8.3 wheels exist. — [flash-attention issue #2361](https://github.com/Dao-AILab/flash-attention/issues/2361), [Medium sm_121](https://medium.com/@rakshith.d26/flash-attention-on-sm-121-solving-pytorch-compatibility-on-blackwell-gb10-a83d9ff3cf9b), [HF wheels](https://huggingface.co/tylerh216/flash-attn-windows-5090)
- xformers: an RTX 5090 guide warns of an "xformers trap" (prebuilt xformers pulling a mismatched torch). — [dev.to RTX 5090 survival guide](https://dev.to/madcoolseed/rtx-5090-survival-guide-sm120-cuda-12-and-13-side-by-side-and-the-xformers-trap-25nh)
- TRELLIS (1): flash-attn not needed, set attention backend to sdpa; spconv and nvdiffrast install from source with `--no-build-isolation`; PyPI `utils3d` is the wrong package. Single unofficial guide. — [HF anvlo12345a/3d-models](https://huggingface.co/anvlo12345a/3d-models)
- TRELLIS.2 deps: Blackwell wheels for FlexGEMM, CuMesh, O-Voxel built for RTX PRO 6000 (sm_120); Windows wheel set for torch 2.7.0 + CUDA 12.8 with cumesh/flex_gemm. A ComfyUI RTX 50 guide notes Trellis 2 deps were built against CUDA ≤12.6, recommends Python 3.12 (not 3.13) and driver ≥570. — [PixWizardry wheels](https://huggingface.co/PixWizardry/AI_Trellis2-WHLs-RTX-PRO-6000), [trify3d RTX 50 guide](https://trify3d.com/blog/install-trellis-2-comfyui-windows-rtx50/)
- TRELLIS.2 bug: CuMesh issue #27 (opened 2026-02-19): `cumesh.remeshing.remesh_narrow_band_dc` yields fragmented, non-watertight output (e.g., 58,265 components) on RTX 5070/5070 Ti/5080/5090, breaking `to_glb()`; recompiling for sm_120 doesn't help; open, no maintainer response or linked PR on the page; workaround: CPU marching-cubes path in ThatButters/trellis2-blackwell-fix (unverified). — [CuMesh #27](https://github.com/JeffreyXiang/CuMesh/issues/27)
- Hunyuan3D custom_rasterizer: kijai's wrapper ships prebuilt wheels only for Windows 11 / Python 3.12 / CUDA 12.6 / torch 2.6.0; otherwise build from source. — [kijai/ComfyUI-Hunyuan3DWrapper](https://github.com/kijai/ComfyUI-Hunyuan3DWrapper)
- ComfyUI on Blackwell: setup steps and pitfalls documented (Japanese). — [lilting.ch](https://lilting.ch/en/articles/comfyui-blackwell-gpu-compatibility)

### Inferences
- On the RTX 5080, Hunyuan3D 2.x (dense vecset DiT + one custom rasterizer + a mesh_processor) is the lowest-risk stack: no spconv, no flash-attn requirement, only two small extensions to rebuild for sm_120.
- TRELLIS (1) needs spconv (community wheels exist) + nvdiffrast + diff-gaussian-rasterization/kaolin for some paths; TRELLIS.2 needs flex_gemm/CuMesh/O-Voxel and currently has a correctness bug in CuMesh remeshing on Blackwell — so generate TRELLIS.2 GLBs on the 3090 until CuMesh #27 is fixed, or substitute the CPU marching-cubes path.
- gsplat and kaolin sm_120 status was not confirmed; both are typically built from source with `TORCH_CUDA_ARCH_LIST="8.6;12.0"` to serve both cards from one env (inference).

### Gaps
- No primary-source confirmation of kaolin, nvdiffrast, gsplat, or diff-gaussian-rasterization sm_120 status (only generic "rebuild from source" advice).
- Whether CuMesh #27 has been fixed after the page was read (the fetch showed it open).
- No Blackwell-specific reports for Hunyuan3D, TripoSG, Step1X-3D or SAM 3D Objects found.
- No data on FP8 / NVFP4 speedups for 3D DiTs on Blackwell.

## 5. Practical serving: job server, batching, model swap memory, per-asset time

### Takeaway
Hunyuan3D 2.0 ships its own HTTP API (`api_server.py`, POST `/generate` with base64 image → GLB); TRELLIS/TRELLIS.2/TripoSG ship Gradio apps; ComfyUI (with its `/prompt` API) is the common way to host any of them behind one queue. Per-asset time ranges from ~1–3 s shape on datacenter GPUs (FlashVDM Turbo, TRELLIS.2 512³) to ~1–3 min textured on consumer cards and 3–15+ minutes on Macs. Sequential model loading (shape → unload → paint) is the standard memory pattern, and on Macs the model load itself is ~100 s, so a warm long-running server matters.

### Cited Findings
- Hunyuan3D 2.0 API server: `python api_server.py --host 0.0.0.0 --port 8080`; POST `/generate` with base64 image in JSON, returns GLB; supports image/text-to-3D and texturing an existing mesh. Gradio app launched with `--low_vram_mode` (and `--enable_flashvdm` for Turbo). ComfyUI is not an official feature; community ComfyUI-Hunyuan3DWrapper and ComfyUI-3D-Pack. — [Tencent/Hunyuan3D-2](https://github.com/Tencent/Hunyuan3D-2)
- Per-asset times (reported):
  - TRELLIS.2 H100: 3 s / 17 s / 60 s at 512³ / 1024³ / 1536³. — [microsoft/TRELLIS.2](https://github.com/microsoft/TRELLIS.2)
  - FlashVDM Hunyuan3D-2 Turbo: ~1 s/shape. — [arXiv 2503.16302](https://arxiv.org/abs/2503.16302)
  - MDT-dist TRELLIS: 0.68–0.94 s A800. — [arXiv 2509.04406](https://arxiv.org/abs/2509.04406)
  - Step1X-3D geometry+texture: 152 s at 27 GB (community). — [DeepWiki](https://deepwiki.com/stepfun-ai/Step1X-3D/7-troubleshooting-and-faq)
  - SAM 3D Objects A5000: ~37 s/object (community). — [Skywork blog](https://skywork.ai/blog/ai-image/install-sam-3d-jp?lang=pt)
  - TripoSG RTX 3060 Ti: ~75 s shape (community). — [Reddit](https://redlib.cypherpunktools.com/r/StableDiffusion/comments/1jpl4tm/open_sourcing_triposg_highfidelity_3d_generation/ml08a33/?context=3)
  - TRELLIS.2 M4 Pro: 3 m 20 s warm, 5 m 13 s cold (103 s load). — [trellis-mac](https://github.com/shivampkumar/trellis-mac)
  - Hunyuan3D 2.1 M4 Pro: ~5.7 min shape + ~8.5 min texture. — [hunyuan3d-2.1-mac](https://raw.githubusercontent.com/VladimirTalyzin/hunyuan3d-2.1-mac/main/README.md)
- Model-swap memory pattern: the Mac Hunyuan3D 2.1 port never loads shape and paint models together (DiT unloaded before paint loads); Hunyuan3D 2.1 total 29 GB vs 10/21 GB per stage implies co-residence is what breaks 24 GB cards. — [hunyuan3d-2.1-mac](https://raw.githubusercontent.com/VladimirTalyzin/hunyuan3d-2.1-mac/main/README.md), [2.1 README](https://gh.ali360.cloudns.ch/Tencent-Hunyuan/Hunyuan3D-2.1)
- Cloud guide for TRELLIS deployments exists (Clore). — [docs.clore.ai TRELLIS](https://docs.clore.ai/guides/3d-generation/trellis-3d)

### Inferences
- For this project's job server on the 3090/5080: a single-worker FIFO queue (ComfyUI API or a thin FastAPI around Hunyuan3D's `api_server.py`) with models kept warm, shape model resident and paint model swapped in per job (or batched: run N shapes, then swap, then N textures) avoids repeated loads. Batching multiple images in one DiT forward is not documented by any repo found; per-asset serial processing is the norm.
- Expected per-asset on a 3090 (inferred, not measured): Hunyuan3D-2 Turbo/FlashVDM shape in seconds, full texture tens of seconds to ~1–2 min; TRELLIS.2 1024³ likely in the tens of seconds to ~1 min (H100 17 s scaled for a slower card).
- A Mac Studio/M-series server is viable for overnight batch jobs but not interactive use at current port speeds.

### Gaps
- No official batching support or throughput numbers (assets/hour) for any model.
- No measured RTX 3090 or RTX 5080 timings for TRELLIS.2 or Hunyuan3D 2.1 with texture.
- No first-party ComfyUI nodes for TRELLIS.2 / Hunyuan3D 2.1 (all community); ComfyUI-3D-Pack status in late 2026 not checked.
