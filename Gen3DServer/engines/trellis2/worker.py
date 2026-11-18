"""TRELLIS.2 engine worker.

Speaks the gen3d worker protocol (see ../../README.md): one JSON object per
line on stdin is a job, one JSON object per line on stdout is an event. The
model loads once at start and stays resident until the gateway stops this
process. Everything the library prints goes to stderr so stdout stays clean.
"""
import json
import os
import sys
import time
import traceback

os.environ.setdefault("OPENCV_IO_ENABLE_OPENEXR", "1")
os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

PROTO = sys.stdout
sys.stdout = sys.stderr

ROOT = os.environ.get("GEN3D_ROOT", "/opt/gen3d")
SRC = os.path.join(ROOT, "engines", "trellis2")
MODEL_DIR = os.path.join(ROOT, "models", "TRELLIS.2-4B")
sys.path.insert(0, SRC)


def emit(**event):
    PROTO.write(json.dumps(event) + "\n")
    PROTO.flush()


def load():
    import torch
    from trellis2.pipelines import Trellis2ImageTo3DPipeline
    t = time.time()
    pipeline = Trellis2ImageTo3DPipeline.from_pretrained(MODEL_DIR)
    pipeline.cuda()
    _release_cache_before_cumesh()
    return pipeline, time.time() - t


def _release_cache_before_cumesh():
    """CuMesh allocates with cudaMalloc, outside torch's caching allocator, so the
    blocks torch holds after decoding the latents (most of a 24 GB card on a
    detailed model) are invisible to it and its first allocation fails with
    `out of memory`. Hand them back before each CuMesh step (hole filling,
    BVH, remeshing, simplification), and retry once if one still fails."""
    import functools
    import gc
    import torch
    import cumesh
    from trellis2.representations.mesh.base import Mesh

    def release():
        gc.collect()
        torch.cuda.empty_cache()

    def guarded(original):
        @functools.wraps(original)
        def call(*args, **kwargs):
            release()
            try:
                return original(*args, **kwargs)
            except RuntimeError as e:
                if "out of memory" not in str(e):
                    raise
                release()
                return original(*args, **kwargs)
        return call

    Mesh.fill_holes = guarded(Mesh.fill_holes)
    cumesh.CuMesh.simplify = guarded(cumesh.CuMesh.simplify)
    cumesh.CuMesh.init = guarded(cumesh.CuMesh.init)
    cumesh.remeshing.remesh_narrow_band_dc = guarded(cumesh.remeshing.remesh_narrow_band_dc)
    cumesh.cuBVH.__init__ = guarded(cumesh.cuBVH.__init__)


def render_preview(mesh, path):
    """A PBR turntable under one of upstream's HDRIs (needs opencv < 5 for EXR)."""
    import cv2
    import imageio
    import torch
    from trellis2.renderers import EnvMap
    from trellis2.utils import render_utils
    hdri = cv2.imread(os.path.join(SRC, "assets/hdri/forest.exr"), cv2.IMREAD_UNCHANGED)
    envmap = EnvMap(torch.tensor(cv2.cvtColor(hdri, cv2.COLOR_BGR2RGB), dtype=torch.float32, device="cuda"))
    frames = render_utils.make_pbr_vis_frames(render_utils.render_video(mesh, envmap=envmap))
    imageio.mimsave(path, frames, fps=15)


def run_job(pipeline, job):
    import numpy as np
    import torch
    import o_voxel
    from PIL import Image

    job_dir = job["dir"]
    opts = job.get("options") or {}
    pipeline_type = opts.get("pipeline_type", "1024_cascade")
    seed = int(opts.get("seed", 42))
    decimation = int(opts.get("decimation_target", 500_000))
    texture_size = int(opts.get("texture_size", 2048))
    torch.cuda.reset_peak_memory_stats()
    timings = {}

    image = Image.open(os.path.join(job_dir, "image.png"))
    mask_path = os.path.join(job_dir, "mask.png")
    if os.path.exists(mask_path):
        mask = Image.open(mask_path).convert("L").resize(image.size)
        image = image.convert("RGB")
        image.putalpha(mask)
    if job.get("views"):
        emit(id=job["id"], event="warning", message="trellis2 is single-image; extra views ignored")

    emit(id=job["id"], event="progress", stage="generate", fraction=0.05)
    t = time.time()
    mesh = pipeline.run(image, seed=seed, pipeline_type=pipeline_type)[0]
    timings["generate"] = time.time() - t
    mesh.simplify(16777216)  # nvdiffrast limit

    emit(id=job["id"], event="progress", stage="export", fraction=0.7)
    t = time.time()
    glb = o_voxel.postprocess.to_glb(
        vertices=mesh.vertices, faces=mesh.faces, attr_volume=mesh.attrs,
        coords=mesh.coords, attr_layout=mesh.layout, voxel_size=mesh.voxel_size,
        aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]],
        decimation_target=decimation, texture_size=texture_size,
        remesh=True, remesh_band=1, remesh_project=0, verbose=False,
    )
    out = os.path.join(job_dir, "out")
    os.makedirs(out, exist_ok=True)
    glb.export(os.path.join(out, "model.glb"), extension_webp=False)
    timings["export"] = time.time() - t

    files = ["model.glb"]
    if opts.get("preview"):
        t = time.time()
        try:
            render_preview(mesh, os.path.join(out, "preview.mp4"))
            files.append("preview.mp4")
            timings["preview"] = time.time() - t
        except Exception as e:  # the asset is the result; a preview is optional
            emit(id=job["id"], event="warning", message=f"preview failed: {e}")

    peak = torch.cuda.max_memory_reserved() // (1 << 20)
    del mesh, glb
    torch.cuda.empty_cache()
    return {
        "files": files,
        "timings": timings,
        "peak_vram_mb": int(peak),
        # Where the input camera sits relative to the asset is not reported by
        # TRELLIS.2; the projection bake has to fit it from the silhouette.
        "camera": None,
        "engine_options": {"pipeline_type": pipeline_type, "seed": seed,
                           "decimation_target": decimation, "texture_size": texture_size},
    }


def main():
    try:
        pipeline, seconds = load()
    except Exception:
        emit(event="fatal", message=traceback.format_exc())
        return 1
    emit(event="ready", engine="trellis2", load_seconds=round(seconds, 1))
    for line in sys.stdin:
        if not line.strip():
            continue
        job = json.loads(line)
        try:
            result = run_job(pipeline, job)
            emit(id=job["id"], event="done", **result)
        except Exception:
            emit(id=job["id"], event="error", message=traceback.format_exc())
            try:
                import torch
                torch.cuda.empty_cache()
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
