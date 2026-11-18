"""Pre-downloads Hunyuan3D-2.1's weights into the HF cache (HF_HOME=/opt/gen3d/hf).

Run with the hunyuan3d21 env's python. The engine loads them by repo id, so
the cache is all it needs:

* tencent/Hunyuan3D-2.1 — shape DiT (3.3B), VAE and the PBR paint model (2B)
* facebook/dinov2-giant — the paint model's image encoder (public)
* ZhengPeng7/BiRefNet   — background removal for inputs without alpha (MIT;
  already cached by the trellis2 engine, shared through the same HF_HOME)

RealESRGAN_x4plus.pth is a GitHub release asset, which this host can't
download (TLS fails); it is copied to hy3dpaint/ckpt/ from the Mac instead.
"""
import os

from huggingface_hub import snapshot_download

os.environ.setdefault("HF_HOME", "/opt/gen3d/hf")
for repo in ("tencent/Hunyuan3D-2.1", "facebook/dinov2-giant", "ZhengPeng7/BiRefNet"):
    snapshot_download(repo)
    print("cached", repo)
