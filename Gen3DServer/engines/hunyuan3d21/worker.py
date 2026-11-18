"""Hunyuan3D-2.1 engine worker (shape DiT + PBR paint pipeline).

Same worker protocol as the other engines (see ../../README.md). The two stages
do not fit a 24 GB card together (~29 GB), so they take turns on the GPU: the
shape model and the paint multiview model each live in host RAM and are moved
to the GPU only while they run.
"""
import json
import os
import sys
import time
import traceback
import types

PROTO = sys.stdout
sys.stdout = sys.stderr

ROOT = os.environ.get("GEN3D_ROOT", "/opt/gen3d")
SRC = os.path.join(ROOT, "engines", "hunyuan3d21")
os.chdir(SRC)  # upstream resolves its configs and checkpoints relative to the repo root
for p in ("./hy3dshape", "./hy3dpaint"):
    sys.path.insert(0, p)

# Upstream converts the painted OBJ to GLB with bpy 4.0, which has no wheel for
# python 3.10. We never call that path (save_glb=False); the stub only lets the
# module import.
sys.modules.setdefault("bpy", types.ModuleType("bpy"))


def emit(**event):
    PROTO.write(json.dumps(event) + "\n")
    PROTO.flush()


class Engine:
    def __init__(self):
        import torch
        self.torch = torch
        from hy3dshape import Hunyuan3DDiTFlowMatchingPipeline
        self.shape = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
            "tencent/Hunyuan3D-2.1", subfolder="hunyuan3d-dit-v2-1",
            use_safetensors=False, device="cpu")
        self.paint = {}  # keyed by (views, resolution)
        self.rmbg = None

    # MARK: GPU turn-taking

    def _free_gpu(self):
        gc_collect()
        self.torch.cuda.empty_cache()

    def shape_to(self, device):
        self.shape.to(device)
        if device == "cpu":
            self._free_gpu()

    def paint_pipeline(self, views, resolution):
        key = (views, resolution)
        if key not in self.paint:
            for old in self.paint.values():
                self.paint_to(old, "cpu")
            try:
                from utils.torchvision_fix import apply_fix
                apply_fix()
            except Exception as e:
                print("torchvision fix:", e)
            from textureGenPipeline import Hunyuan3DPaintConfig, Hunyuan3DPaintPipeline
            conf = Hunyuan3DPaintConfig(max_num_view=views, resolution=resolution)
            conf.realesrgan_ckpt_path = "hy3dpaint/ckpt/RealESRGAN_x4plus.pth"
            conf.multiview_cfg_path = "hy3dpaint/cfgs/hunyuan-paint-pbr.yaml"
            conf.custom_pipeline = "hy3dpaint/hunyuanpaintpbr"
            self.paint[key] = Hunyuan3DPaintPipeline(conf)
        return self.paint[key]

    def paint_to(self, pipe, device):
        mv = pipe.models["multiview_model"]
        mv.pipeline.to(device)
        if hasattr(mv, "dino_v2"):
            mv.dino_v2.to(device)
        if device == "cpu":
            self._free_gpu()

    def remove_background(self, image):
        from PIL import Image
        if self.rmbg is None:
            from transformers import AutoModelForImageSegmentation
            self.rmbg = AutoModelForImageSegmentation.from_pretrained("ZhengPeng7/BiRefNet", trust_remote_code=True).eval()
        from torchvision import transforms
        tf = transforms.Compose([transforms.Resize((1024, 1024)), transforms.ToTensor(),
                                 transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])])
        self.rmbg.to("cuda")
        with self.torch.no_grad():
            pred = self.rmbg(tf(image.convert("RGB")).unsqueeze(0).to("cuda"))[-1].sigmoid().cpu()[0].squeeze()
        self.rmbg.to("cpu")
        mask = transforms.ToPILImage()(pred).resize(image.size)
        image = image.convert("RGB")
        image.putalpha(mask)
        return image


def gc_collect():
    import gc
    gc.collect()


def obj_to_glb(obj_path, glb_path):
    """Textured OBJ (+ albedo / metallic / roughness maps) to a PBR GLB, without Blender."""
    import numpy as np
    import trimesh
    from PIL import Image
    base = os.path.splitext(obj_path)[0]
    mesh = trimesh.load(obj_path, process=False, maintain_order=True)
    if isinstance(mesh, trimesh.Scene):
        mesh = trimesh.util.concatenate(list(mesh.geometry.values()))
    albedo = Image.open(base + ".jpg" if os.path.exists(base + ".jpg") else base + ".png").convert("RGB")
    mr = None
    metal_p, rough_p = base + "_metallic.jpg", base + "_roughness.jpg"
    if os.path.exists(metal_p) and os.path.exists(rough_p):
        metal = Image.open(metal_p).convert("L").resize(albedo.size)
        rough = Image.open(rough_p).convert("L").resize(albedo.size)
        zero = Image.new("L", albedo.size, 0)
        mr = Image.merge("RGB", (zero, rough, metal))  # glTF: G = roughness, B = metallic
    material = trimesh.visual.material.PBRMaterial(
        baseColorTexture=albedo, metallicRoughnessTexture=mr,
        metallicFactor=1.0 if mr else 0.0, roughnessFactor=1.0 if mr else 0.8)
    mesh.visual = trimesh.visual.TextureVisuals(uv=mesh.visual.uv, material=material)
    mesh.export(glb_path)


def run_job(engine, job):
    import torch
    from PIL import Image
    from hy3dshape.pipelines import export_to_trimesh
    from hy3dshape import FaceReducer

    job_dir = job["dir"]
    opts = job.get("options") or {}
    steps = int(opts.get("steps", 50))
    guidance = float(opts.get("guidance_scale", 7.5))
    octree = int(opts.get("octree_resolution", 256))
    seed = int(opts.get("seed", 1234))
    views = int(opts.get("paint_views", 6))
    resolution = int(opts.get("paint_resolution", 512))
    target_faces = int(opts.get("target_faces", 40000))
    shape_only = bool(opts.get("shape_only", False))
    torch.cuda.reset_peak_memory_stats()
    timings = {}
    out = os.path.join(job_dir, "out")
    os.makedirs(out, exist_ok=True)

    image = Image.open(os.path.join(job_dir, "image.png"))
    mask_path = os.path.join(job_dir, "mask.png")
    if os.path.exists(mask_path):
        image = image.convert("RGB")
        image.putalpha(Image.open(mask_path).convert("L").resize(image.size))
    if image.mode != "RGBA" or min(image.getchannel("A").getextrema()) == 255:
        emit(id=job["id"], event="progress", stage="background", fraction=0.02)
        image = engine.remove_background(image)
    if job.get("views"):
        emit(id=job["id"], event="warning", message="hunyuan3d21 is single-image; extra views ignored")

    emit(id=job["id"], event="progress", stage="shape", fraction=0.05)
    t = time.time()
    engine.shape_to("cuda")
    gen = torch.Generator().manual_seed(seed)
    outputs = engine.shape(image=image, num_inference_steps=steps, guidance_scale=guidance,
                           generator=gen, octree_resolution=octree, num_chunks=200000, output_type="mesh")
    mesh = export_to_trimesh(outputs)[0]
    engine.shape_to("cpu")
    mesh = FaceReducer()(mesh, max_facenum=target_faces)
    white = os.path.join(out, "white_mesh.obj")
    mesh.export(white)
    timings["shape"] = time.time() - t
    shape_peak = torch.cuda.max_memory_reserved() // (1 << 20)

    files = []
    if shape_only:
        mesh.export(os.path.join(out, "model.glb"))
        files.append("model.glb")
    else:
        emit(id=job["id"], event="progress", stage="paint", fraction=0.4)
        t = time.time()
        pipe = engine.paint_pipeline(views, resolution)
        engine.paint_to(pipe, "cuda")
        textured = os.path.join(out, "textured_mesh.obj")
        pipe(mesh_path=white, image_path=image, output_mesh_path=textured, save_glb=False)
        engine.paint_to(pipe, "cpu")
        timings["paint"] = time.time() - t
        t = time.time()
        obj_to_glb(textured, os.path.join(out, "model.glb"))
        timings["glb"] = time.time() - t
        files.append("model.glb")

    peak = torch.cuda.max_memory_reserved() // (1 << 20)
    return {
        "files": files,
        "timings": timings,
        "peak_vram_mb": int(peak),
        "shape_peak_vram_mb": int(shape_peak),
        "camera": None,
        "engine_options": {"steps": steps, "guidance_scale": guidance, "octree_resolution": octree,
                           "seed": seed, "paint_views": views, "paint_resolution": resolution,
                           "target_faces": target_faces, "shape_only": shape_only},
    }


def main():
    try:
        t = time.time()
        engine = Engine()
        seconds = time.time() - t
    except Exception:
        emit(event="fatal", message=traceback.format_exc())
        return 1
    emit(event="ready", engine="hunyuan3d21", load_seconds=round(seconds, 1))
    for line in sys.stdin:
        if not line.strip():
            continue
        job = json.loads(line)
        try:
            emit(id=job["id"], event="done", **run_job(engine, job))
        except Exception:
            emit(id=job["id"], event="error", message=traceback.format_exc())
            try:
                engine.shape_to("cpu")
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
