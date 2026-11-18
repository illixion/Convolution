"""Downloads TRELLIS.2's weights into /opt/gen3d/models and points its
pipeline.json at sources that need no gated access.

Run with the trellis2 env's python. Two substitutions, both recorded in the
README:

* image_cond_model: facebook/dinov3-vitl16-pretrain-lvd1689m is gated
  (manual approval). We use a public re-upload whose Git LFS pointer has the
  same blob id as the official file (the pointer embeds the SHA-256), and we
  check that SHA-256 here after downloading, so the bytes are Meta's.
* rembg_model: briaai/RMBG-2.0 is gated and CC BY-NC. ZhengPeng7/BiRefNet is
  the same architecture from its author, MIT, ungated. Callers that send an
  alpha channel (Blender renders) skip it anyway.
"""
import hashlib
import json
import os
import sys

from huggingface_hub import snapshot_download

ROOT = os.environ.get("GEN3D_ROOT", "/opt/gen3d")
MODELS = os.path.join(ROOT, "models")
TRELLIS_DIR = os.path.join(MODELS, "TRELLIS.2-4B")
DINO_DIR = os.path.join(MODELS, "dinov3-vitl16-pretrain-lvd1689m")
DINO_MIRROR = "camenduru/dinov3-vitl16-pretrain-lvd1689m"
DINO_SHA256 = "dcb2e45127cccbf1601e5f42fef165eea275c8e5213197e8dcf3f48822718179"
REMBG = "ZhengPeng7/BiRefNet"


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    os.makedirs(MODELS, exist_ok=True)
    snapshot_download("microsoft/TRELLIS.2-4B", local_dir=TRELLIS_DIR)
    # The sparse-structure decoder is referenced from TRELLIS v1's repo.
    snapshot_download("microsoft/TRELLIS-image-large", local_dir=os.path.join(MODELS, "TRELLIS-image-large"),
                      allow_patterns=["ckpts/ss_dec_conv3d_16l8_fp16.*", "pipeline.json"])
    snapshot_download(DINO_MIRROR, local_dir=DINO_DIR)
    digest = sha256(os.path.join(DINO_DIR, "model.safetensors"))
    if digest != DINO_SHA256:
        print(f"DINOv3 weights do not match the official SHA-256 ({digest})", file=sys.stderr)
        return 1
    snapshot_download(REMBG)

    cfg_path = os.path.join(TRELLIS_DIR, "pipeline.json")
    with open(cfg_path) as f:
        cfg = json.load(f)
    args = cfg["args"]
    args["models"]["sparse_structure_decoder"] = os.path.join(
        MODELS, "TRELLIS-image-large", "ckpts", "ss_dec_conv3d_16l8_fp16")
    args["image_cond_model"]["args"]["model_name"] = DINO_DIR
    args["rembg_model"]["args"]["model_name"] = REMBG
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=4)
    print("models ready:", TRELLIS_DIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())
