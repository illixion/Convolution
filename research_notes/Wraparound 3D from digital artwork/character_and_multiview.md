# Character-specialised single-image 3D reconstruction and the multi-view diffusion stage (state as of 2026-11-18)

Scope: methods that turn one image (or a few) of a character, especially anime / stylized / Blender-rendered CG, into a full wrap-around 3D character (mesh or gaussians), plus the multi-view (MV) diffusion generators used as their first stage. Judged for viewing digital artwork on Apple Vision Pro.

Method note: this pass used ~18 search/fetch calls. Items verified this session carry a source link. Items marked **[prior knowledge, unverified this session]** come from the researcher's training data (cutoff mid-2026) and are listed only under Inferences or Gaps so the report writer can decide whether to re-check them.

---

## Which approaches handle stylized/anime/CG characters well, and which fail (trained only on realistic humans)?

### Takeaway
The anime-capable family is the VRoid-trained line: CharacterGen (SIGGRAPH 2024), StdGEN (CVPR 2025), StdGEN++ (arXiv, Jan 2026), Anime-Ready (ICLR 2026), SeparateGen (IEEE TVCG, Jul 2026) and NOVA-3D (2024). The human-reconstruction line (PSHuman, LHM/LHM++, AniGS, SAM 3D Body, ICON/SIFU-style) is trained and evaluated on real people, with no anime evaluation published. Every anime method shares one data bias: VRoid Hub avatars, so it learns "VRoid-shaped humanoid", not arbitrary CG characters.

### Cited Findings

**Anime / stylized-specific (current)**
- **StdGEN** (Yuze He et al., arXiv 2411.05738, submitted 8 Nov 2024, v2 5 Mar 2025, CVPR 2025): it generates detailed 3D characters with separate semantic parts (body, clothes, hair) from a single image "in three minutes" — [stdgen.github.io](https://stdgen.github.io); [arXiv](https://arxiv.org/abs/2411.05738).
  - It is built from a semantic-aware Large Reconstruction Model (S-LRM), an efficient multi-view diffusion model and iterative multi-layer mesh refinement — [arXiv](https://arxiv.org/html/2411.05738v2).
  - The pipeline (from the repo) runs in stages: 1.1 reference image to an A-pose image, which the user can edit before going on; 1.2 multi-view generation, decomposed by default; 2 S-LRM reconstruction to OBJ; 3 multi-layer refinement — [GitHub hyz317/StdGEN](https://github.com/hyz317/StdGEN).
  - Training data is Anime3D++, full-body anime characters with finely annotated multi-view, multi-pose semantic parts — [arXiv](https://arxiv.org/html/2411.05738v2). It comes from about 10.8k VRoid-Hub models — [search summary of arXiv PDF](https://arxiv.org/pdf/2411.05738).
  - The README says its background remover `rm_anime_bg` is tuned for anime, and that other styles (2.5D, real photos) may need other tools. Half-body inputs may give suboptimal results — [GitHub](https://github.com/hyz317/StdGEN).
  - Timeline: inference code, dataset and checkpoints released 2025-03-04; Hugging Face Gradio demo 2025-03-17 — [GitHub](https://github.com/hyz317/StdGEN).
- **StdGEN++** (arXiv 2601.07660, January 2026): it takes a single image or a text prompt, canonicalizes it to A-pose, generates 6 orthographic RGB and normal views, then reconstructs with a Dual-Branch S-LRM (a full-body LoRA branch plus a facial LoRA branch on cropped head views). Semantic surface extraction follows, with a coarse-to-fine proposal so that only active voxels are evaluated densely — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
  - Its grid is 256×256×384, up from StdGEN's 100×100×150 — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
  - Training and evaluation use only anime data (Anime3D-EX, from VRoid assets). Non-anime input is not addressed — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
  - Reported holistic A-pose metrics (Table I):

    | Method | SSIM | LPIPS | FID | CLIP |
    |---|---|---|---|---|
    | StdGEN++ | 0.938 | 0.064 | 0.011 | 0.941 |
    | StdGEN | 0.937 | 0.066 | 0.010 | 0.941 |
    | CharacterGen (3D) | 0.880 | 0.124 | 0.081 | 0.905 |

    Source: [arXiv HTML](https://arxiv.org/html/2601.07660v1).
  - Reported arbitrary-pose metrics: StdGEN++ 0.916 / 0.084 / 0.011 / 0.937, CharacterGen 0.869 / 0.134 / 0.119 / 0.901 — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
  - The gain over StdGEN is mainly in geometry. Hair F-score rises from 0.642 to 0.725 and hair IoU from 0.466 to 0.546; whole-character F-score goes from 0.594 to 0.628 (Table II) — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
- **CharacterGen** (SIGGRAPH 2024 / ACM TOG): it generates a 3D character from one image with "multi-view pose canonicalization". It has a 2D_Stage (MV) and a 3D_Stage, is built on Tune-A-Video and TripoSR, and its pretrained weights are on Hugging Face. Code is Apache-2.0 — [GitHub zjp-shadow/CharacterGen](https://github.com/zjp-shadow/CharacterGen); [ACM DL](https://dl.acm.org/doi/abs/10.1145/3658217).
  - Its Anime3D data is VRoid VRMs that cannot be redistributed: users must fetch them via PAniC-3D's instructions and render them, which takes about 1 day with two threads — [GitHub](https://github.com/zjp-shadow/CharacterGen).
  - It is superseded by StdGEN/StdGEN++ on the metrics above — [StdGEN++ arXiv](https://arxiv.org/html/2601.07660v1).
- **Anime-Ready** (ICLR 2026): it takes text or a single image and generates an animatable anime character with body-aligned, component-wise garment modeling. It introduces **Anime-SMPL**, a body template designed for anime proportions. Code was listed as "TBD" in the notes found — [paper notes](https://en.papernotes.org/ICLR2026/3d_vision/anime-ready_controllable_3d_anime_character_generation_with_body-aligned_compone/) (the page now redirects; the content came from the search snippet); [ICLR 2026 proceedings PDF](https://proceedings.iclr.cc/paper_files/paper/2026/file/60fb8cf8000f0386063fb24ead366330-Paper-Conference.pdf) (the search tied this PDF to the topic, but it was not opened, so whether it is the Anime-Ready paper is unconfirmed).
- **SeparateGen** (IEEE TVCG vol. 32 no. 7, July 2026): it generates a character as separate semantic parts (body, clothing, hair, shoes), aimed at rigging. It introduces the SC-Anime dataset of 7,580 annotated anime characters, "to be released" — [DOI 10.1109/tvcg.2026.3652452](https://doi.org/10.1109/tvcg.2026.3652452) (from a search snippet; a second search could not find any other page about it).
- **NOVA-3D** (arXiv 2405.12505, 2024): it reconstructs anime characters from front and back views (two images, not one) and was extended to the full body. Official PyTorch code and the NOVA-Human dataset (10.2k VroidHub models) are on the project page. The authors are from Zhejiang University, Zhejiang Lab and Gameday — [arXiv](https://arxiv.org/pdf/2405.12505); [project](https://wanghongsheng01.github.io/NOVA-3D).
- **PAniC-3D** (CVPR 2023): it reconstructs stylized 3D heads only, from anime portraits. It is old and covers heads only, but it is the source of the VRoid dataset tooling that later works reuse — [arXiv 2303.14587](https://arxiv.org/pdf/2303.14587); [CharacterGen README](https://github.com/zjp-shadow/CharacterGen).
- **See-through** (arXiv 2602.03749, 3 Feb 2026; SIGGRAPH 2026 per a search snippet): this is single-image layer decomposition of anime illustrations into fully inpainted semantic layers with drawing order. It produces **2.5D, not 3D**, but it is relevant for parallax and layered presentation of artwork — [arXiv](https://arxiv.org/abs/2602.03749).
- **DrawingSpinUp** (arXiv 2409.08615): this is 3D animation from single character drawings. The search returned only fragments of its reference list, so its details were not confirmed — [arXiv](https://arxiv.org/pdf/2409.08615).

**Tools, not papers (VRM output)**
- **Charakuru**: a free kit that turns one full-body illustration into a rigged VRM 1.0 avatar using Codex and Tripo. Release 1.0.3 is dated October 2026 — [artrealmai article](https://artrealmai.com/article/charakuru-illustration-to-vrm-avatar-codex-tripo).
- **Neural4D AnimeArt** (commercial): it generates pre-rigged VRM characters with 55 bones and 52 facial blendshapes. Its docs say it targets VRM 0.x — [Neural4D](https://www.neural4d.com/features/animeart); [Neural4D blog](https://blog.neural4d.com/anime-art-generation/how-to-make-a-vrchat-avatar/).

**Realistic-human-trained (no published anime evaluation)**
- **PSHuman** (arXiv 2409.10141, CVPR 2025): it generates multiview colour and normal maps with body-face cross-scale diffusion, then carves a mesh initialised from SMPL-X. Evaluation is on CAPE and THuman2.1 (real scans) — [arXiv](https://arxiv.org/html/2409.10141v2); [CVPR OA](https://openaccess.thecvf.com/content/CVPR2025/html/Li_PSHuman_Photorealistic_Single-image_3D_Human_Reconstruction_using_Cross-Scale_Multiview_Diffusion_CVPR_2025_paper.html).
  - The checkpoint is "PSHuman_Unclip_768_6views", run with 7 views at inference. An SMPL-free version was released 2024-11-30. Code is MIT — [GitHub pengHTYX/PSHuman](https://github.com/pengHTYX/PSHuman).
- **LHM** (Alibaba Tongyi, arXiv 2503.10625, ICCV 2025): it builds an animatable human from one image in seconds and is driven by SMPL-X parameters. Training data is 300K videos plus 5K synthetic samples, so real people. The README says nothing about stylized input. Code is Apache-2.0 — [GitHub aigc3d/LHM](https://github.com/aigc3d/LHM).
- **AniGS** (Qiu et al., CVPR 2025; "Ani" means animatable, not anime): a reference-guided video diffusion model generates multi-view canonical-pose images and normals, then a 4D-gaussian-splatting reconstruction is robust to inconsistent views. Output is an animatable gaussian avatar in canonical pose, targeting in-the-wild photos — [arXiv 2412.02684](https://arxiv.org/html/2412.02684v1); [CVPR OA](https://openaccess.thecvf.com/content/CVPR2025/html/Qiu_AniGS_Animatable_Gaussian_Avatar_from_a_Single_Image_with_Inconsistent_CVPR_2025_paper.html); [project](https://lingtengqiu.github.io/2024/AniGS).
- **SAM 3D Body** (Meta, checkpoints released 2025-11-19; paper arXiv 2602.15989): promptable full-body human mesh recovery, including hands and feet, on the Momentum Human Rig (MHR). The repo claims in-the-wild generalisation but has no stylized or anime evaluation — [GitHub facebookresearch/sam-3d-body](https://github.com/facebookresearch/sam-3d-body).
  - It treats each person separately, and hands are weaker than in specialised hand models — [mer.vin summary](https://mer.vin/2026/06/sam-3d-body-promptable-full-body-3d-mesh-from-one-image-cvpr-2026-mhr/).
- **2026 human-realistic works seen but not studied**: DiGS-Avatar (UV-space diffusion, arXiv 2608.20759) and Any3DAvatar (full-head, arXiv 2604.13856) are photoreal human or portrait methods — [DiGS-Avatar](https://arxiv.org/html/2608.20759); [Any3DAvatar](https://arxiv.org/pdf/2604.13856).

### Inferences
- For anime and VRoid-like CG characters, StdGEN is the strongest open, runnable option (code, weights, demo). StdGEN++ is better on paper but showed no code or runtime in the version read. Anime-Ready and SeparateGen are 2026 alternatives without confirmed public code.
- For Blender renders of non-VRoid characters (realistic proportions, PBR shading), all anime-trained methods are out of distribution, and so are human methods for non-human proportions. A generic object pipeline (covered by other researchers: Hunyuan3D 2.x/3, TRELLIS, etc.) may be the safer default. The character-specialised methods are then a branch for humanoid inputs.
- SAM 3D Body outputs a body-shape mesh (MHR). The page shows no clothing or hair modelling, so it is a pose and shape prior, not a viewing-quality reconstruction of artwork.
- **[prior knowledge, unverified this session]** ICON (CVPR 2022), ECON (CVPR 2023), SIFU (CVPR 2024) and SiTH (CVPR 2024) are SMPL-X-guided clothed-human reconstructors trained on real scans (THuman, RenderPeople). They are superseded by PSHuman/LHM-class methods and are poor on anime proportions (large heads and eyes, stylized hair) because the SMPL-X fit fails. PSHuman's README borrows SMPL-X models from ECON and SIFU — [PSHuman GitHub](https://github.com/pengHTYX/PSHuman).

### Gaps
- None of the human methods (PSHuman, LHM, AniGS, SAM 3D Body) publishes anime or cartoon quantitative results. Community anime results were not found this session.
- DrawingSpinUp's details (it is a drawing-to-animation method, reportedly using contour removal plus a skeleton-based thinning deformation) are **[prior knowledge, unverified]**.
- No "AniCharacter"-named 2025-2026 paper was found. "Make-A-Character" (Alibaba, 2023, text to realistic head avatar) is **[prior knowledge, unverified]** and is not anime-specific.
- No 2026 code release was found for StdGEN++, Anime-Ready or SeparateGen.

---

## Do any keep the input view's pixels exactly on the visible side, and how do they handle hair, loose clothing, accessories, weapons, non-human characters?

### Takeaway
No surveyed method guarantees that the input pixels survive on the visible side. All the anime methods first re-render the character into an A-pose or orthographic canonical view, which by construction regenerates the front view, and they measure fidelity only by CLIP similarity (~0.94). Exact front-view fidelity has to be added afterwards by re-projecting the input image onto the mesh. Hair and clothing are handled as separate layers in StdGEN/StdGEN++/SeparateGen/Anime-Ready. Weapons, accessories and non-humanoid characters are outside every character method's training distribution.

### Cited Findings
- StdGEN's Stage 1.1 converts the input into an A-pose image before multi-view generation, so the views come from that synthesized A-pose, not from the input pixels — [GitHub](https://github.com/hyz317/StdGEN).
- StdGEN++ also canonicalizes to A-pose. Input-view fidelity is measured only indirectly, by CLIP similarity between the reference and generated views (~0.94). The paper claims A-pose canonicalization preserves identity but gives no direct pixel-fidelity metric — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
- Era3D regenerates outputs in a canonical orthogonal camera, so they are not pixel-identical to the input. It predicts elevation and focal length (the EFReg module) to avoid distortion on perspective inputs — [Era3D arXiv](https://arxiv.org/html/2405.11616v3).
- Wonder3D takes the input as the canonical view and generates 6 images plus normals. Its orthographic-camera training makes it distort on perspective inputs, as reported by Era3D and One-2-3-45++ — [Era3D PDF](https://arxiv.org/pdf/2405.11616); [One-2-3-45++](https://arxiv.org/pdf/2311.07885).
- Zero123++ tiles 6 views in one frame and needs the input view's elevation to fix the relative poses — [Zero123++](https://ar5iv.labs.arxiv.org/html/2310.15110); [One-2-3-45++ discussion](https://arxiv.org/pdf/2311.07885).
- The MV-Adapter README says nothing about exact preservation of the reference in the front view — [GitHub huanngzh/MV-Adapter](https://github.com/huanngzh/MV-Adapter).
- Hair is a separate mesh layer in StdGEN and StdGEN++. StdGEN's hair refinement depends on a hair mask (`--outside_ratio`, default 0.20, may need tuning) — [StdGEN GitHub](https://github.com/hyz317/StdGEN).
- StdGEN++ outputs structurally independent body, hollow-clothing and hair meshes, plus a three-layer face texture (brows and lashes / skin with eye whites / iris) that allows gaze motion. Refinement "can slightly hurt thin structures like hair" and cannot repair topological holes — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
- Era3D notes that generating only 6 views limits thin structures — [Era3D arXiv](https://arxiv.org/html/2405.11616v3).
- StdGEN fails visibly on background residue and half-body inputs, and results vary by seed — [GitHub](https://github.com/hyz317/StdGEN).
- PSHuman results vary by case and need tuning of `crop_size` and `seed`. It runs at 768 px with 7 views — [GitHub](https://github.com/pengHTYX/PSHuman).
- SAM 3D Body predicts a watertight body mesh from a single-person crop. The page does not discuss clothing or hair — [mer.vin](https://mer.vin/2026/06/sam-3d-body-promptable-full-body-3d-mesh-from-one-image-cvpr-2026-mhr/); [GitHub](https://github.com/facebookresearch/sam-3d-body).

### Inferences
- For Vision Pro viewing of artwork, where the user expects the "front" to look exactly like the picture, the practical recipe is: (a) reconstruct with any method, (b) back-project the original image onto the front-facing faces of the mesh, using the input camera (estimated, e.g. with Era3D-style focal and elevation) and visibility masks, and (c) blend generated texture only where the input is unseen. A-pose canonicalization breaks this, because the mesh is no longer in the input pose. An A-pose method would need its result re-posed into the input pose (via its rig or the MHR/SMPL-X fit) before projection. That is an engineering inference, not a published pipeline in these sources.
- Methods that keep the input pose (Era3D, PSHuman-style human recon, MV-Adapter i2mv with the input as the front view) are easier to texture-project than the A-pose methods.
- Weapons, staffs, wings, tails, mascots and creatures: the VRoid-based datasets (Anime3D++, Anime3D-EX, NOVA-Human, SC-Anime) are humanoid avatars, and the human methods all assume an SMPL-X / MHR humanoid. Expect such parts to be dropped, fused into the body or hallucinated. A generic object model is the better bet for non-humanoids.

### Gaps
- No quantitative "front-view PSNR vs input" was found for any MV model this session.
- No community reports (Reddit, X) on how these methods handle weapons, accessories or creatures were retrieved.

---

## Which produce rig-ready or part-decomposed output that would be useful later?

### Takeaway
Part-decomposed: StdGEN (body/clothes/hair), StdGEN++ (body/hollow clothes/hair plus layered face textures), SeparateGen (body/clothing/hair/shoes) and Anime-Ready (component-wise garments on an Anime-SMPL body). Rig-ready or animatable: Anime-Ready (Anime-SMPL), LHM/LHM++ and AniGS (SMPL-X-driven gaussians, realistic humans), SAM 3D Body (MHR parametric rig, body only), and the commercial VRM tools (Charakuru, Neural4D AnimeArt). CharacterGen's A-pose output is "rig-friendly" but carries no rig.

### Cited Findings
- StdGEN outputs separated body, clothes and hair meshes as OBJ — [stdgen.github.io](https://stdgen.github.io); [GitHub](https://github.com/hyz317/StdGEN).
- StdGEN++ shows rigging and animation comparisons against CharacterGen and physics-style cloth and hair motion demos, but describes no rigging procedure of its own — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
- SeparateGen states explicitly that it targets rigging, since entangled meshes get in the way — [DOI](https://doi.org/10.1109/tvcg.2026.3652452).
- Anime-Ready uses an Anime-SMPL template so the output can be animated — [paper notes](https://en.papernotes.org/ICLR2026/3d_vision/anime-ready_controllable_3d_anime_character_generation_with_body-aligned_compone/).
- LHM ships an `inference_mesh.sh` mesh-export script and SMPL-X motion driving, with ComfyUI motion-extraction and animation nodes (10 s of animation in about 20 s from pre-extracted motion) — [GitHub](https://github.com/aigc3d/LHM).
- AniGS produces a canonical-pose gaussian avatar for real-time animation — [arXiv](https://arxiv.org/html/2412.02684v1).
- SAM 3D Body's MHR "decouples skeletal structure and surface shape" — [GitHub](https://github.com/facebookresearch/sam-3d-body).
- Charakuru produces a rigged VRM 1.0 — [artrealmai](https://artrealmai.com/article/charakuru-illustration-to-vrm-avatar-codex-tripo). Neural4D AnimeArt produces VRM 0.x with 55 bones and 52 blendshapes — [Neural4D](https://www.neural4d.com/features/animeart).

### Inferences
- For later animation on Vision Pro (RealityKit skeletal meshes), StdGEN-family part meshes plus an auto-rigger, or a VRM pipeline, are the most reusable outputs. Gaussian avatars (LHM, AniGS) need a gaussian renderer and SMPL-X driving, which RealityKit does not provide natively.
- **[prior knowledge, unverified this session]** Generic auto-riggers (UniRig, RigAnything, Mixamo-style) could rig a StdGEN mesh. This was not researched here.

### Gaps
- Whether StdGEN outputs carry consistent topology or UVs usable for skinning was not verified.

---

## Multi-view diffusion first stages: how each works and how well it preserves the input view

### Takeaway
The MV generators are mostly SD2.1- or SDXL-based, produce 6 (sometimes 4 to 10) views at 256 to 768 px, and all regenerate the input view rather than copying it. MV-Adapter (SDXL, 768 px, Apache-2.0, ICCV 2025) is the most flexible and best maintained, with geometry-guided texturing (ig2mv) that can paint an existing mesh from a reference image. Era3D (512 px, camera-aware) underpins human pipelines like PSHuman. CharacterGen's and StdGEN's MV stages are specialised for A-pose anime.

### Cited Findings
- **MV-Adapter** (ICCV 2025, Apache-2.0) — [GitHub](https://github.com/huanngzh/MV-Adapter):
  - Modes: t2mv, i2mv, tg2mv and ig2mv (geometry-guided, intended for texture generation, including a partial-image variant usable with MIDI), a ControlNet scribble mode, a full text- and image-to-texture pipeline that outputs a textured `.glb`, and image-to-arbitrary-views.
  - Base models: SDXL (768 px, higher quality) or SD2.1 (cheaper). It trains 6-view, plus 2/3/4/6-view variants for single-image input.
  - VRAM: i2mv about 14 GB. tg2mv SDXL above 12 GB (SD2.1 under 6 GB). ig2mv SDXL above 16 GB (SD2.1 under 10 GB). Use sd21 for texturing below 10 GB.
  - Timeline: initial weights and ComfyUI support 2024-12-27; geometry-guided weights 2025-03-07; texture pipeline 2025-05-15; low-VRAM SD2.1 geometry adapters 2025-06-13; ICCV acceptance 2025-06-26. A separate ComfyUI-MVAdapter repo provides the nodes.
- **Era3D** — [arXiv HTML](https://arxiv.org/html/2405.11616v3):
  - Built on SD2.1-unclip; 6 views at elevation 0° and azimuths β, β±45°, β±90°, β+180°; 512×512, with 1024 px only in texture refinement; generates normal maps too.
  - Runtime: about 13 s of diffusion, 3 min of NeuS and 10 s of texture refinement, about 4 min in total. Training took 16× H800 for about 30 h.
  - Regenerates in a canonical orthogonal camera.
- **PSHuman's MV stage**: a 768 px, 6-view unCLIP model ("PSHuman_Unclip_768_6views") with an additional face-scale branch. It needs more than 40 GB of VRAM at 768 px; a 512 px model for the RTX 4090 was "planned" — [GitHub](https://github.com/pengHTYX/PSHuman).
- **Wonder3D**: 6 views plus normals in orthographic cameras, the input treated as the canonical front view. It distorts on perspective inputs — [Era3D PDF](https://arxiv.org/pdf/2405.11616); [One-2-3-45++](https://arxiv.org/pdf/2311.07885).
- **Zero123++**: 6 views tiled into one image, needing the input elevation to fix relative poses — [ar5iv](https://ar5iv.labs.arxiv.org/html/2310.15110); [One-2-3-45++](https://arxiv.org/pdf/2311.07885).
- **CharacterGen's MV stage**: a separate 2D_Stage built on Tune-A-Video that performs "multi-view pose calibration" to a canonical pose; the 3D stage is TripoSR-based — [GitHub](https://github.com/zjp-shadow/CharacterGen).
- **StdGEN's MV stage**: an A-pose image first, then decomposed multi-view generation feeding S-LRM — [GitHub](https://github.com/hyz317/StdGEN). StdGEN++ uses 6 orthographic RGB plus normal views — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
- **AniGS's MV stage**: a reference-guided *video* diffusion model producing canonical-pose multi-view images and normals — [arXiv](https://arxiv.org/html/2412.02684v1).

### Inferences
- Pixel-exact front view: none of the sources claims it. Diffusion through a VAE at 512 to 768 px, after re-centring and resizing, cannot return the input exactly. Wonder3D, Era3D and MV-Adapter i2mv at least keep the input viewpoint as view 0. CharacterGen and StdGEN change the pose. Zero123++ v1.2 views are offset from the input azimuth **[prior knowledge, unverified]**.
- MV-Adapter's ig2mv/texture mode is the most relevant tool for "keep my artwork's look": given a mesh (from any reconstructor) and the reference image, it generates view-consistent textures aligned to that geometry. The final front texture can then be overwritten by projecting the original image.
- **[prior knowledge, unverified this session]**
  - SV3D (Stability AI, March 2024) is an orbit-video model (21 frames, 576 px) released under Stability's non-commercial / community licence, and is superseded.
  - Hunyuan3D-1.0 (Tencent, November 2024) has an MV stage producing 6 views in a 3×2 grid, then a feed-forward LRM. Tencent Hunyuan community licences have excluded the EU, UK and South Korea from their licensed territory, which matters for an EU user.
  - Wonder3D++ (2025, journal extension) adds cross-domain MV generation and a cascaded mesh-extraction stage.
  - Zero123++ code is Apache-2.0, but weight-licence terms should be checked.

### Gaps
- Exact licences of the Zero123++, Era3D, Wonder3D/Wonder3D++, SV3D and Hunyuan3D-1 weights were not verified this session (Era3D's paper is CC BY 4.0; its code licence is not stated in the paper).
- Wonder3D++ was not found by search.
- No benchmark comparing these MV models on anime input was found.

---

## VRAM / runtime and licences (commercial use; EU user)

### Takeaway
Code licences are permissive (Apache-2.0 for StdGEN, CharacterGen, MV-Adapter and LHM; MIT for PSHuman), but **StdGEN's checkpoints are research-only**. SAM 3D Body uses Meta's SAM License, with MHR licensed separately and sources disagreeing on its commercial terms. Every anime method's training data is VRoid Hub avatars whose redistribution is restricted. VRAM ranges from about 8 GB (LHM++ 8-view) to more than 40 GB (PSHuman at 768 px).

### Cited Findings
- **StdGEN**: Apache-2.0 code; checkpoints "for research purposes only"; a `--low_vram` offload option; no VRAM or runtime figures beyond "three minutes" — [GitHub](https://github.com/hyz317/StdGEN); [project](https://stdgen.github.io).
- **CharacterGen**: Apache-2.0; no VRAM figure — [GitHub](https://github.com/zjp-shadow/CharacterGen).
- **MV-Adapter**: Apache-2.0. VRAM figures are under the multi-view section above (about 14 GB for i2mv, below 10 GB with the SD2.1 variants) — [GitHub](https://github.com/huanngzh/MV-Adapter).
- **PSHuman**: MIT; more than 40 GB of VRAM at 768 px; about 1 minute per reconstruction (claimed) — [GitHub](https://github.com/pengHTYX/PSHuman).
- **LHM**: Apache-2.0. Reported inference times: MINI 1.41 s, 500M 2.01 s, 1B 6.57 s.
  - VRAM: MINI fits 16 GB; the memory-saving pipeline fits 14 GB; the motion Gradio app needs 24 GB for 500M.
  - LHM++ (open-sourced March 2026) takes arbitrary-view input and runs 8-view input in 8 GB.
  - Source: [GitHub](https://github.com/aigc3d/LHM).
- **SAM 3D Body**: SAM License on code and checkpoints. Two checkpoints (DINOv3-H+ 840M and ViT-H). Community ComfyUI and GGUF ports exist — [GitHub](https://github.com/facebookresearch/sam-3d-body); [mer.vin](https://mer.vin/2026/06/sam-3d-body-promptable-full-body-3d-mesh-from-one-image-cvpr-2026-mhr/); [comfyui-wiki](https://comfyui-wiki.com/en/models/sam/sam-3d-body).
  - MHR's licensing is reported inconsistently: one blog advises reading the separate MHR licence before commercial use, another calls MHR openly commercial — [mer.vin](https://mer.vin/2026/06/sam-3d-body-promptable-full-body-3d-mesh-from-one-image-cvpr-2026-mhr/); [hermes-ai](https://hermes-ai.net/news/meta-s-sam-3d-body-turns-a-single-photo-into-a-riggable-human-mesh/).
- **Era3D**: about 4 min end-to-end, of which about 13 s is MV diffusion — [arXiv](https://arxiv.org/html/2405.11616v3).
- **StdGEN++**: no runtime, VRAM or code reported — [arXiv HTML](https://arxiv.org/html/2601.07660v1).
- **VRoid data**: the raw VRM data cannot be redistributed, for both CharacterGen and StdGEN — [CharacterGen GitHub](https://github.com/zjp-shadow/CharacterGen); [StdGEN GitHub](https://github.com/hyz317/StdGEN).

### Inferences
- For a product shipped to EU users, StdGEN's research-only weights rule it out commercially without permission. CharacterGen (Apache-2.0 per the repo; weight terms on Hugging Face not checked) and MV-Adapter (Apache-2.0) look the most permissive, but both inherit base-model licences (SD2.1 / SDXL: CreativeML OpenRAIL-M / OpenRAIL++, **[prior knowledge]**).
- None of these run on the Vision Pro itself. They need a server GPU: a 24 GB card (RTX 3090/4090) covers StdGEN with low-VRAM mode (likely), MV-Adapter, LHM and Era3D, but not PSHuman at 768 px. The user's `ai` host (RTX 3090, 24 GB) would fit everything except PSHuman-768.

### Gaps
- No per-stage VRAM figure for StdGEN, CharacterGen, AniGS, SAM 3D Body or Anime-Ready.
- The licence text of the CharacterGen weights on Hugging Face and of MHR was not checked.
- The SAM License terms (permitted uses, EU restrictions) were not read directly.
