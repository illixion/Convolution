#!/usr/bin/env bash
# Builds the TRELLIS.2 engine environment under /opt/gen3d on the GPU host.
#
# Mirrors TRELLIS.2's own setup.sh (torch 2.6 / cu124, the same extension
# pins), but inside a micromamba env that carries its own CUDA 12.4 toolkit, so
# nothing is installed system-wide (the host has no CUDA toolkit, only the
# driver). Idempotent: re-running skips what is already importable.
set -euo pipefail

ROOT=${GEN3D_ROOT:-/opt/gen3d}
ENV=$ROOT/envs/trellis2
SRC=$ROOT/engines/trellis2
EXT=$ROOT/build/trellis2-ext
MM=$ROOT/bin/micromamba
export MAMBA_ROOT_PREFIX=$ROOT/mamba

[ -d "$SRC/.git" ] || git clone -b main --recursive https://github.com/microsoft/TRELLIS.2.git "$SRC"

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
# Extensions that link -lcuda find the toolkit's stub at build time; at run
# time the driver's own libcuda.so.1 is used.
export LIBRARY_PATH=$ENV/lib/stubs${LIBRARY_PATH:+:$LIBRARY_PATH}
# The env's conda gcc 12 is inside CUDA 12.4's supported host-compiler range.
export CC=$ENV/bin/x86_64-conda-linux-gnu-gcc CXX=$ENV/bin/x86_64-conda-linux-gnu-g++

has torch || pip install torch==2.6.0 torchvision==0.21.0 --index-url https://download.pytorch.org/whl/cu124

pip install imageio imageio-ffmpeg tqdm easydict 'opencv-python-headless<5' trimesh \
  'transformers>=4.56,<5' tensorboard pandas lpips zstandard kornia timm pillow \
  fastapi 'uvicorn[standard]' python-multipart
has utils3d || pip install git+https://github.com/EasternJournalist/utils3d.git@9a4eb15e4021b67b12c460c7057d642626897ec8

# Prebuilt wheel matching torch 2.6 / cu12 / py3.10 (building it takes an hour).
has flash_attn || pip install \
  "https://github.com/Dao-AILab/flash-attention/releases/download/v2.7.3/flash_attn-2.7.3+cu12torch2.6cxx11abiFALSE-cp310-cp310-linux_x86_64.whl"

mkdir -p "$EXT"
build() { # name importname git-url [branch]
  local name=$1 mod=$2 url=$3 branch=${4:-}
  has "$mod" && return 0
  [ -d "$EXT/$name" ] || git clone ${branch:+-b $branch} --recursive "$url" "$EXT/$name"
  pip install "$EXT/$name" --no-build-isolation
}
build nvdiffrast nvdiffrast https://github.com/NVlabs/nvdiffrast.git v0.4.0
build nvdiffrec nvdiffrec_render https://github.com/JeffreyXiang/nvdiffrec.git renderutils
build CuMesh cumesh https://github.com/JeffreyXiang/CuMesh.git
build FlexGEMM flex_gemm https://github.com/JeffreyXiang/FlexGEMM.git
if ! has o_voxel; then
  rm -rf "$EXT/o-voxel" && cp -r "$SRC/o-voxel" "$EXT/o-voxel"
  pip install "$EXT/o-voxel" --no-build-isolation
fi

run python - <<'PY'
import torch, flash_attn, nvdiffrast.torch, cumesh, o_voxel
print("torch", torch.__version__, "cuda", torch.version.cuda, torch.cuda.get_device_name(0))
PY
echo "trellis2 env ready: $ENV"
