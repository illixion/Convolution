#!/usr/bin/env bash
# Builds the Hunyuan3D-2.1 engine environment under /opt/gen3d.
#
# Follows upstream's README (torch 2.5.1 / cu124, py3.10, custom_rasterizer and
# the mesh painter compiled from source) inside a micromamba env that carries
# its own CUDA 12.4 toolkit. Upstream's requirements.txt is installed minus what
# the engine never imports (gradio, deepspeed, cupy, open3d, tb_nightly, the
# pythreejs viewer) and minus its Tencent/Aliyun mirror index lines.
# Licence note: Tencent's licence excludes the EU, UK and South Korea; this
# engine is a private test on a US host (decision recorded in README.md).
set -euo pipefail

ROOT=${GEN3D_ROOT:-/opt/gen3d}
ENV=$ROOT/envs/hunyuan3d21
SRC=$ROOT/engines/hunyuan3d21
MM=$ROOT/bin/micromamba
export MAMBA_ROOT_PREFIX=$ROOT/mamba

[ -d "$SRC/.git" ] || git clone https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1.git "$SRC"

if [ ! -x "$ENV/bin/python" ]; then
  "$MM" create -y -p "$ENV" -c nvidia/label/cuda-12.4.1 -c conda-forge \
    python=3.10 cuda-toolkit=12.4 gxx_linux-64=12 ninja git
fi

run() { "$MM" run -p "$ENV" "$@"; }
pip() { run python -m pip "$@"; }
has() { run python -c "import $1" >/dev/null 2>&1; }

export CUDA_HOME=$ENV
export TORCH_CUDA_ARCH_LIST="8.6"   # RTX 3090; add 12.0 for the 5080 later
export MAX_JOBS=${MAX_JOBS:-16}
export LIBRARY_PATH=$ENV/lib/stubs${LIBRARY_PATH:+:$LIBRARY_PATH}
export CC=$ENV/bin/x86_64-conda-linux-gnu-gcc CXX=$ENV/bin/x86_64-conda-linux-gnu-g++

has torch || pip install torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 \
  --index-url https://download.pytorch.org/whl/cu124

# Filtered upstream requirements.
grep -v -E '^(--extra-index-url|#|$)|^(gradio|deepspeed|cupy|open3d|tb_nightly|pythreejs|bpy)' \
  "$SRC/requirements.txt" > "$ROOT/build/hunyuan3d21-requirements.txt"
pip install -r "$ROOT/build/hunyuan3d21-requirements.txt"
pip install 'fastapi' 'uvicorn[standard]' python-multipart 'setuptools<81'  # pytorch-lightning 1.9 imports pkg_resources

# Upstream converts the painted OBJ to GLB with bpy 4.0, which has no wheel for
# py3.10. The worker stubs the module and builds the GLB itself (worker.py).

cd "$SRC/hy3dpaint/custom_rasterizer" && pip install -e . --no-build-isolation
cd "$SRC/hy3dpaint/DifferentiableRenderer"
run bash -c 'c++ -O3 -Wall -shared -std=c++11 -fPIC $(python -m pybind11 --includes) mesh_inpaint_processor.cpp -o mesh_inpaint_processor$(python3-config --extension-suffix)'

run python - <<'PY'
import torch, custom_rasterizer
print("torch", torch.__version__, "cuda", torch.version.cuda, torch.cuda.get_device_name(0))
PY
echo "hunyuan3d21 env ready: $ENV"
