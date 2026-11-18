# Extra signal from Blender renders and digital artwork: few-view, passes, CG traits, preprocessing (as of 2026-11-18)

Scope: what extra inputs (2-8 views, alpha, depth/normal passes, intrinsics) a CG/stylized source can give an image-to-3D pipeline, which open methods accept them, preprocessing for artwork, and licences. Target: wrap-around assets on Apple Vision Pro, prototyping on an RTX 3090 (24 GB).

## How much better are results with 2-4 views or depth/normal passes vs a single image, and which models accept them?

### Takeaway
Multi-view input is now accepted by the main open generators: TRELLIS (training-free multi-image), Hunyuan3D-2mv (named front/left/back views), TRELLIS.2 via ComfyUI multi-view nodes, and Pixal3D's multi-view model (a turnaround sheet). The best evidence that it helps is qualitative. Extra views recover the specific asymmetric detail, back-side design, hair volume and raised relief that a single image "averages out". No source supplied a controlled quantitative gain for stylized inputs. No open generator was found that takes a user-supplied *rendered* normal or depth pass directly. Hi3DGen uses normals as an intermediate, but estimates them itself. Hunyuan3D-Omni takes a point cloud, which a depth pass plus known intrinsics could provide; that route is an inference, not a documented workflow.

### Cited Findings
**Multi-image conditioning in generators**
- TRELLIS (image model) added multi-image conditioning on 2024-12-18 as a "tuning-free algorithm without training a specialized model". The README warns it "may not give the best results for all input images". It needs an NVIDIA GPU with at least 16 GB and has `example_multi_image.py`. Models and most code are MIT — [TRELLIS README](https://github.com/microsoft/TRELLIS)
- TRELLIS's hosted multi-image endpoint exposes `multiimage_algo` with values `stochastic` (default) and `multidiffusion`; the docs found do not explain the difference — [fal TRELLIS multi](https://fal.ai/models/fal-ai/trellis/multi/api)
- TRELLIS.2's official README shows only single-image `pipeline.run(image)` and no multi-view option. It needs ≥24 GB VRAM (verified on A100/H100). It exports PBR GLB (base colour, roughness, metallic, opacity; exported OPAQUE by default, so transparency must be enabled manually). Code and model are MIT; the nvdiffrast/nvdiffrec dependencies have their own terms — [TRELLIS.2 README](https://github.com/microsoft/TRELLIS.2)
- Third-party ComfyAI docs list TRELLIS.2 "Multi-View Image to Shape" (optional back/left/right inputs), "Mesh Refiner Multi-View" and "Mesh Texturing Multi-View" nodes. These are unofficial, so verify the names against the installed version — [ComfyAI Trellis2MultiViewImageToShape](https://comfyai.run/documentation/Trellis2MultiViewImageToShape), [Trellis2MultiViewTexturing](https://comfyai.run/documentation/Trellis2MultiViewTexturing)
- Hunyuan3D-2mv is a 1.1B "Multiview Image to Shape" model. The repo-wide VRAM figure is 6 GB for shape and 16 GB for shape plus texture — [Hunyuan3D-2 README](https://github.com/Tencent-Hunyuan/Hunyuan3D-2)
- The Hunyuan3D-2mv model-card example passes a dict of views `"front"`, `"left"`, `"back"` (with `num_inference_steps=30`, `octree_resolution=380`). The card does not say whether a right view is accepted or which views are optional — [HF tencent/Hunyuan3D-2mv](https://huggingface.co/tencent/Hunyuan3D-2mv)
- Pixal3D (Li et al., arXiv 2605.10922, Tsinghua + Tencent ARC, SIGGRAPH 2026) is built on the TRELLIS.2 backbone, VAEs and DINOv3 conditioning. It does "pixel-aligned generation" with "near-reconstruction-level fidelity to the input view", and generally beats TRELLIS.2 on alignment with the input. The authors still say closed generators (Hunyuan 3D, Tripo, Rodin) give better results and that its textures are not perfect. ComfyUI made TRELLIS.2 and Pixal3D native on 2026-08-31, with the non-commercial NVIDIA dependencies removed, and says the outputs are commercially usable — [Comfy blog](https://blog.comfy.org/p/trellis2-and-pixal3d-are-now-native)
- The ComfyUI "Pixal3D: Multi Views to 3D" workflow takes one character turnaround sheet (front, side, back; the example is a 4-view sheet). "The multiview model uses the extra viewpoints to reconstruct geometry the single-image pipeline cannot see." Its models are the Pixal3D multiview UNet (int8), shape and texture VAEs, DINOv3 and BiRefNet. The docs advise separating the subject from the background, and offer a "Character Turnaround Sheet Generator" template that uses Nano Banana 2 to make the sheet — [ComfyUI docs Pixal3D](https://docs.comfy.org/tutorials/3d/pixal3d)
- The same workflow accepts separate view images or a mixed sheet. "It works with fewer views, but geometry becomes more ambiguous"; best results come from front, back, left and right "with consistent scale and pose" — [ComfyUI Pixal3D workflow page](https://comfy.org/workflows/25c14ca59910-25c14ca59910/) (via search summary)
- Step1X-3D (StepFun, arXiv 2505.07747) conditions geometry on a single image (point-cloud VAE, TSDF, marching cubes). Its multi-view step is *internal*: an MV-Adapter/SDXL-based generator is conditioned on the input image plus rendered normal and position maps of the generated geometry, then baked to UV at 2048² and inpainted. It is listed as Apache-2.0 — [Step1X-3D arXiv](https://arxiv.org/pdf/2505.07747), [SourcePulse](https://www.sourcepulse.org/projects/2445154)
- Hunyuan3D-Omni (arXiv 2509.21245, 3.3B, built on Hunyuan3D 2.1) adds controls beside the image: point cloud, voxel, bounding box (8 vertices, controls aspect ratio and avoids thin degenerate geometry) and skeleton pose. Incomplete or noisy point clouds are reported to improve alignment and detail. Inference takes `--control_type point|voxel|bbox|pose`. No multi-view conditioning was found — [arXiv](https://arxiv.org/abs/2509.21245v1), [EmergentMind](https://www.emergentmind.com/papers/2509.21245), [HF mirror card](https://huggingface.co/Antided/Hunyuan3D-Omni)

**Evidence on the gain from extra views (stylized)**
- A vendor-side test (Meshy designer, 2026-08-17) ran one anime character through single-image versus 3-view Multiview (front, left and back concept art); both meshes are about 1.95M faces. At gallery size the front views look the same. With a single image, appliques flatten into printed-looking shapes, black keylines "thin, break, and soften into the cloth", hair highlights stay painted-on horizontal streaks, the ponytail collapses, a two-tone hair split reverts to one colour, the back is generic (with fake lettering), and asymmetric leg warmers get symmetrized. The conclusion is that single-image generation fails by "averaging out specific details", and extra views recover them only for the surfaces they show. A conflict of interest applies (the author works for the vendor) — [HackerNoon](https://hackernoon.com/i-ran-the-same-anime-character-through-meshy-multiview-and-single-image-3d)
- StdGEN (CVPR 2025, Tencent AI Lab + Tsinghua) is anime-specific. It takes one image in any pose, runs multi-view diffusion that produces A-pose RGB and normals, then a semantic LRM (S-LRM) that predicts geometry, colour and part labels for body, clothes and hair, then mesh refinement, in about 3 min. It claims to beat CharacterGen, Unique3D and InstantMesh, and is trained on Anime3D++ — [arXiv 2411.05738](https://arxiv.org/html/2411.05738v1), [project](https://stdgen.github.io)

**Normal/depth as conditioning**
- Hi3DGen (ICCV 2025) runs image → normal (NiRNE) → geometry (NoRLD), on its DetailVerse synthetic data. It argues normals from "strong 2D priors" alleviate the synthetic-to-real domain gap, and that RGB is ambiguous due to "lighting, shading, or complex object textures". The paper does **not** describe a user-supplied normal-map input: the estimated normal map, with a white background, is what feeds NoRLD. Its only quantitative table compares normal estimators (NiRNE NE 21.837 / SNE 26.628 against GeoWizard, StableNormal, Lotus and GenPercept); the 3D comparisons are qualitative plus a user study. Stylized inputs are not evaluated. The authors note some details don't align with the input — [arXiv html v2](https://arxiv.org/html/2503.22236v2), [arXiv pdf](https://arxiv.org/pdf/2503.22236)
- Stable3DGen (the Hi3DGen code) is MIT. It is adapted from TRELLIS with the kaolin, nvdiffrast and flexicube dependencies removed "to make it usable commercially" — [Stable-X/Hi3DGen](https://github.com/Stable-X/Hi3DGen)

**Pose-free feed-forward reconstruction (sparse, unposed)**
- FreeSplatter (TencentARC, arXiv 2412.09573) predicts pixel-wise Gaussians and camera parameters from uncalibrated sparse views. It ships object-centric and scene variants, and the HF model card says Apache-2.0 — [arXiv](https://arxiv.org/abs/2412.09573), [HF README](https://huggingface.co/TencentARC/FreeSplatter/blame/main/README.md)
- AnySplat (arXiv 2505.23716) predicts 3D Gaussians plus intrinsics and extrinsics in one pass from uncalibrated views, distilled from VGGT (pose pseudo-labels). With sparse views (up to 16) it reportedly beats NoPoSplat and FLARE on novel-view synthesis. Its range runs from object-centric setups to large scenes — [HF paper page](https://huggingface.co/papers/2505.23716.md), [EmergentMind](https://www.emergentmind.com/papers/2505.23716), [project](https://city-super.github.io/anysplat)

### Inferences
- With 2-4 consistent views of a CG character, a generative model with multi-view conditioning (Hunyuan3D-2mv, TRELLIS multi-image, or Pixal3D/TRELLIS.2 multi-view in ComfyUI) is likely a better fit than pose-free splatting (FreeSplatter, AnySplat). The splatting methods reconstruct only what is seen: the unseen regions stay empty for a 360° asset, and they output Gaussians, not a mesh. Generators hallucinate the remainder and give a mesh.
- A render's depth pass plus known intrinsics can be back-projected to a partial point cloud and fed to Hunyuan3D-Omni's `point` control. This is the closest open route found to "depth-conditioned shape generation". It is untested here, and Omni carries the Hunyuan EU-exclusion licence (see the licence question).
- A Blender normal pass could replace NiRNE's estimate in the Hi3DGen pipeline, but it would need converting to the camera-space convention and white background the model was trained on. That would be a code change, not a documented feature.
- Most of these models are trained on CG renders (Objaverse-style), so clean Blender renders are probably *closer* to the training distribution than photos are. The weakness is flat-shaded art, which lacks shading cues (next point).
- Turnaround sheets map directly onto Pixal3D's documented input and Hunyuan3D-2mv's named views. View consistency (scale, pose, A/T-pose) is what the docs stress.

### Gaps
- No controlled, quantitative single-view versus 2/4-view comparison on stylized or anime inputs was found for any open model.
- What TRELLIS's `stochastic` versus `multidiffusion` modes do, and which works better for turnarounds, is undocumented in the sources fetched.
- Whether Hunyuan3D-2mv accepts a `right` view or arbitrary subsets was not confirmed.
- GS-LRM, Long-LRM and InstantMesh were not researched in this pass (time budget). Also unchecked: the DUSt3R/MASt3R/VGGT licences and how they behave on flat-shaded CG. As background knowledge, not verified here: DUSt3R/MASt3R are CC BY-NC-SA and InstantMesh is Apache-2.0.
- The VRAM use and licence of Pixal3D itself are not stated in the ComfyUI sources.
- Use of known camera intrinsics: no generator found accepts them. Only the pose-free reconstructors estimate them, and the docs found don't say whether supplied intrinsics can be fixed.

## What preprocessing is essential for artwork input? (segmentation, CG traits, normalisation)

### Takeaway
The essentials are a clean alpha (use the render's own alpha when there is one, otherwise an anime-tuned matting model such as ToonOut/BiRefNet), a single centred subject, and consistent views when there are several. Flat or toon shading is the most significant CG-specific failure: models produce thin, flat geometry from flat-coloured art, and painted highlights and keylines get baked in or broken. There is little evidence on delighting for stylized art.

### Cited Findings
- Art3D (arXiv 2504.10466) finds that large pre-trained image-to-3D models "struggle with flat-colored images because they lack a 3D illusion". It builds the Flat-2D benchmark (100+ samples) and proposes a training-free fix that uses 2D generator features plus a VLM realism check to strengthen the 3D illusion before lifting — [arXiv abs](https://arxiv.org/abs/2504.10466)
- Per a search summary, Art3D reports that existing models produce "an abnormally thin structure" from flat inputs. REVIVE 3D (arXiv 2604.27504, April 2026) targets cartoons, line drawings and flat-shaded art, with Compactness and Normal Anisotropy metrics for volume and surface flatness on the same flat dataset. Neither full text was read — [Art3D pdf](https://arxiv.org/pdf/2504.10466), [REVIVE 3D](https://www.alphaxiv.org/abs/2604.27504)
- Stylized single-image failures observed (vendor test): keylines thin and break, painted specular highlights get transferred as hard streaks, and the unseen side is symmetrized — [HackerNoon](https://hackernoon.com/i-ran-the-same-anime-character-through-meshy-multiview-and-single-image-3d)
- Hi3DGen's rationale: RGB is ambiguous under "lighting, shading, or complex object textures", so normals give clearer cues — [arXiv](https://arxiv.org/html/2503.22236v2)
- ToonOut (arXiv 2509.06839, Sep 2025) fine-tunes BiRefNet on 1,228 annotated anime images. Pixel accuracy rises from 95.3% to 99.5% on the authors' own test split (about 126 images, with a self-defined metric). Error falls from 4.7% (BiRefNet) and 2.2% (RMBG-2.0) to 0.5%, and Boundary-IoU error from 11.5% and 7.6% to 4%. It reportedly beats Photoroom too, except slightly in the "items" category. The "action" category jumps from 76.8% to 99.0%. Weights MIT, data CC-BY 4.0 — [arXiv](https://arxiv.org/html/2509.06839v1), [HF weights](https://huggingface.co/joelseytre/toonout)
- BiRefNet is MIT, with a default input of 1024²; BiRefNet_HR and HR-matting are trained at 2048², BiRefNet_dynamic at 256-2304, and lite-2K takes up to 2560×1440. The README links ToonOut as a third-party anime fine-tune — [BiRefNet README](https://github.com/ZhengPeng7/BiRefNet)
- BEN2 (Prama) is MIT and claims better hair matting, 4K and edge refinement. Its claim that RMBG-2.0 did not preserve the DIS5k validation set is self-reported — [BEN2 card](https://huggingface.co/PramaLLC/BEN2/raw/main/README.md)
- RMBG-2.0 (Bria) is CC BY-NC 4.0, with commercial use by agreement with Bria — [Bria RMBG-2.0](https://github.com/Bria-AI/RMBG-2.0)
- The Pixal3D ComfyUI workflow bundles BiRefNet and tells users to separate the subject from the background for their own sheets — [ComfyUI docs](https://docs.comfy.org/tutorials/3d/pixal3d)
- StdGEN canonicalises any-pose input to A-pose multi-views before reconstruction (pose normalisation built in) — [arXiv](https://arxiv.org/html/2411.05738v1)

### Inferences
- When a Blender render's alpha exists, use it directly: it is exact, including on thin hair strands, which matting models soften. Fall back to ToonOut for anime art, and to BiRefNet-HR or BEN2 for CG and painted art. Avoid RMBG-2.0 for anything commercial.
- For toon or flat-shaded inputs, run a normal-bridging pipeline (Hi3DGen) or a 3D-illusion-boost step (Art3D) to counter thin geometry. For Blender work, a better option may be to re-render the same model with plain Lambert or soft lighting, or to export the normal pass. That restores the shading cues the models rely on.
- Outlines: keylines will probably bake into the texture as painted lines and may break across the mesh (the vendor test supports this). Rendering without the Freestyle/outline pass, then re-adding outlines in RealityKit (inverted-hull or a shader), would likely give cleaner assets. This is untested.
- Delighting matters less for stylized art than for photos (the lighting is part of the style), but painted specular highlights become hard streaks. Remove them, or rely on extra views.
- Multi-subject images: crop each subject and matte it on its own before generation (no source tested this). SAM 2/3 with a point or box prompt is a reasonable picker, but it was not researched here.

### Gaps
- No independent benchmark of BiRefNet, BEN2, RMBG-2.0 and SAM 2/3 on anime or CG matting was found, apart from ToonOut's self-reported numbers.
- No source measured the effect of upscaling inputs before generation. DINOv2/v3 conditioning typically works at about 518 px, so the gain is probably small, but that is unverified.
- Transparency and glass in input art: no source found. TRELLIS.2 outputs an opacity map, but its GLB exports OPAQUE by default ([README](https://github.com/microsoft/TRELLIS.2)).
- Glossy materials and delighting on stylized inputs: no direct evidence found. The Hunyuan3D 2.1 delight/PBR stage was not researched.
- SAM 2/3 specifics and licences were not checked in this pass.

## Licences of the key tools (commercial use; user in the EU)

### Takeaway
The MIT and Apache-licensed stack (TRELLIS, TRELLIS.2, Stable3DGen/Hi3DGen, Step1X-3D, FreeSplatter, BiRefNet, ToonOut, BEN2) is usable commercially in the EU. Every Tencent Hunyuan3D 2.x licence checked (2mv, 2.1, and Omni, which is built on 2.1) **excludes the EU, UK and South Korea**, so it is not licensed for an EU user at all. RMBG-2.0 is non-commercial.

### Cited Findings
- Hunyuan3D-2mv licence §1(l): Territory is "the worldwide territory, excluding the territory of the European Union, United Kingdom and South Korea". §5(c) makes use outside the Territory "unlicensed and unauthorized". Above 1M MAU you need a licence from Tencent (§4). §5(b) bars using outputs to improve other AI models. AUP item 12 requires public machine-generated content to be labelled conspicuously. Tencent claims no rights in outputs (§6(d)) — [HF LICENSE](https://huggingface.co/tencent/Hunyuan3D-2mv/blob/main/LICENSE)
- The Hunyuan3D-2.1 licence has the same territory exclusion, and its preamble says it "DOES NOT APPLY IN THE EUROPEAN UNION, UNITED KINGDOM AND SOUTH KOREA"; the 1M MAU threshold also applies — [GitHub LICENSE](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1/blob/main/LICENSE)
- TRELLIS: models and most code MIT; the diffoctreerast and modified FlexiCubes submodules may differ — [README](https://github.com/microsoft/TRELLIS)
- TRELLIS.2: MIT; nvdiffrast and nvdiffrec have their own (NVIDIA) terms — [README](https://github.com/microsoft/TRELLIS.2). ComfyUI's native integration removed those non-commercial dependencies, so the outputs are commercially usable — [Comfy blog](https://blog.comfy.org/p/trellis2-and-pixal3d-are-now-native)
- Stable3DGen/Hi3DGen: MIT, with NVIDIA dependencies removed for commercial use — [GitHub](https://github.com/Stable-X/Hi3DGen)
- Step1X-3D: Apache-2.0 per listings; whether the MV-Adapter base weights carry the same terms is unverified — [SourcePulse](https://www.sourcepulse.org/projects/2445154), [SourceForge mirror](https://sourceforge.net/projects/step1x-3d.mirror/)
- FreeSplatter: Apache-2.0 on the HF card — [HF](https://huggingface.co/TencentARC/FreeSplatter/blame/main/README.md)
- BiRefNet MIT ([GitHub](https://github.com/ZhengPeng7/BiRefNet)); ToonOut weights MIT and data CC-BY 4.0 ([arXiv](https://arxiv.org/html/2509.06839v1)); BEN2 MIT ([HF](https://huggingface.co/PramaLLC/BEN2/raw/main/README.md)); RMBG-2.0 CC BY-NC 4.0 ([GitHub](https://github.com/Bria-AI/RMBG-2.0))

### Inferences
- For an EU user, Hunyuan3D-2mv, the most direct "named multi-view" model, is out. The licensed multi-view routes are TRELLIS multi-image (MIT, 16 GB, fits the 3090) and TRELLIS.2/Pixal3D multi-view through ComfyUI native. TRELLIS.2 officially states ≥24 GB, which is borderline on a 3090, though the int8 Pixal3D checkpoint suggests lower use. Pixal3D's own licence is unconfirmed.
- The ComfyUI Pixal3D turnaround-sheet template uses Nano Banana 2 (a Google API) to *generate* missing views. That is a separate service with its own terms, and it hallucinates views rather than using real ones.

### Gaps
- Pixal3D's licence was not found in the fetched sources.
- Not checked: Hunyuan3D 3.x (whether open weights exist and what licence they carry), the SAM 2/3 licences, and the DUSt3R/MASt3R/VGGT licences (VGGT's commercial terms in particular).
- Whether the MV-Adapter weights used by Step1X-3D are Apache-licensed is unverified.
