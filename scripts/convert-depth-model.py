#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#     "torch==2.7.0",
#     "transformers==4.51.3",
#     "coremltools==9.0",
#     "numpy==1.26.4",
#     "pillow",
# ]
# ///
"""
Convert Depth Anything V2 (Small / Base / Large) to Core ML for Hypnos,
matching Apple's official Small model I/O so CoreMLDepthProvider uses the
result unchanged.

Run with uv (resolves the dependencies above automatically):
    uv run scripts/convert-depth-model.py --variant base
or in a plain venv:
    python3.12 -m venv .venv
    .venv/bin/pip install torch==2.7.0 transformers==4.51.3 coremltools==9.0 numpy==1.26.4 pillow
    .venv/bin/python scripts/convert-depth-model.py --variant base

Get the result onto the device either way:
    ./scripts/push-depth-model.sh DepthAnythingV2Base518x392.mlpackage   # dev cable
or copy the .mlpackage into the app's Documents folder with the Files app —
DepthModelStore imports anything dropped there on next launch.

Why the precision ladder: DINOv2 (the backbone) produces activations that
overflow float16's max (65504) in its LayerNorm/attention layers on the Base
and Large variants. A naive all-FP16 conversion then shows a wave/grid pattern
across the whole depth map (the ViT patch grid bleeding through). Small happens
to stay in range, which is why Apple's F16 Small is clean. `--precision auto`
converts at each rung and validates against the PyTorch reference on a test
image, keeping the first rung that passes:
    fp16   — everything float16 (fastest, full ANE)
    mixed  — float16 except layer_norm/softmax (they fall back to GPU in fp32)
    mixed+ — additionally keeps matmul (attention scores) in fp32
    fp32   — everything float32 (no ANE; slow but always correct)

Resolution: width/height must be multiples of 14 (DINOv2 patch size). The
default 518x392 matches Apple's Small. Larger inputs sharpen depth edges at a
roughly quadratic inference cost — try 686x392 for mostly-16:9 libraries or
630x476 / 770x574 for more detail. Very large inputs (>~900px) can degrade
global depth coherence (the model was trained at 518) — validate on real
content before committing to one.

Aspect-matched A/B inputs at approximately the default's pixel count:
    --aspect-preset tv        # 602x336 (~16:9)
    --aspect-preset cinema22  # 686x308 (~2.2:1)
    --aspect-preset cinema239 # 700x294 (~2.39:1)
Use the same variant and precision for comparisons. Similar pixel count is
not a promise of similar ANE time; measure on device. No preset is automatic.
The converter dependencies are pinned: newer NumPy scalar conversion and
Python 3.14 tracing broke this export path in the widescreen-model check.

Target I/O (mirrors apple/coreml-depth-anything-v2-small):
  input  "image": color RGB image, W x H
  output "depth": relative inverse depth, min-max normalized to [0,1] in-model
                  (near = high; the normalization runs in the final ops)
"""
import argparse
import sys

import numpy as np
import torch
import torch.nn.functional as F

# coremltools has no upsample_bicubic2d op; the DepthAnything head upsamples
# bicubic. Apple's Small conversion used bilinear (its op histogram shows
# upsampleBilinear), so force bilinear here too — visually negligible for depth,
# and we re-refine with a joint-bilateral pass on-device anyway. Patched before
# both tracing AND the reference forward pass, so validation compares like with
# like.
_orig_interpolate = F.interpolate


def _interpolate_bilinear(input, size=None, scale_factor=None, mode="nearest",
                          align_corners=None, **kwargs):
    if mode == "bicubic":
        mode = "bilinear"
    return _orig_interpolate(input, size=size, scale_factor=scale_factor,
                             mode=mode, align_corners=align_corners, **kwargs)


F.interpolate = _interpolate_bilinear

VARIANTS = {
    "small": "depth-anything/Depth-Anything-V2-Small-hf",
    "base": "depth-anything/Depth-Anything-V2-Base-hf",
    "large": "depth-anything/Depth-Anything-V2-Large-hf",
}

# Ops kept in fp32 per rung. Overflow lives in the DINOv2 LayerNorms and the
# q@k attention scores; softmax is included with layer_norm because it's cheap
# and shares the overflow-prone activations.
PRECISION_LADDER = [
    ("fp16", None),
    ("mixed", {"layer_norm", "softmax"}),
    ("mixed+", {"layer_norm", "softmax", "matmul"}),
    ("fp32", "all"),
]


class DepthWrapper(torch.nn.Module):
    """Bakes ImageNet normalization + per-frame min-max into the graph, so the
    Core ML ImageType just feeds pixels in [0,1] via scale=1/255."""

    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, x):
        x = (x - self.mean) / self.std
        out = self.m(pixel_values=x).predicted_depth        # (1,H,W) inverse depth
        if out.dim() == 3:
            out = out.unsqueeze(1)                           # (1,1,H,W)
        # Per-frame min-max to [0,1] so float16 output keeps precision; near = high.
        mn = out.amin(dim=[2, 3], keepdim=True)
        mx = out.amax(dim=[2, 3], keepdim=True)
        out = (out - mn) / (mx - mn + 1e-6)
        return out


def make_test_image(width, height, path=None):
    """A structured scene (gradient + occluding shapes), or a user-supplied
    photo. Overflow corruption is global, so either exposes it clearly."""
    from PIL import Image, ImageDraw
    if path:
        return Image.open(path).convert("RGB").resize((width, height), Image.BILINEAR)
    img = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(img)
    for y in range(height):  # sky-to-ground gradient
        v = int(90 + 140 * y / height)
        draw.line([(0, y), (width, y)], fill=(v, v, min(255, v + 30)))
    # Occluding shapes at different scales ~ different depths.
    draw.rectangle([width * 0.08, height * 0.45, width * 0.38, height * 0.98], fill=(60, 90, 60))
    draw.ellipse([width * 0.45, height * 0.25, width * 0.75, height * 0.6], fill=(150, 80, 70))
    draw.rectangle([width * 0.7, height * 0.55, width * 0.95, height * 0.95], fill=(40, 45, 55))
    draw.ellipse([width * 0.25, height * 0.08, width * 0.42, height * 0.28], fill=(210, 200, 180))
    return img


def convert(traced, width, height, rung_fp32_ops):
    import coremltools as ct
    if rung_fp32_ops == "all":
        precision = ct.precision.FLOAT32
    elif rung_fp32_ops is None:
        precision = ct.precision.FLOAT16
    else:
        fp32_ops = rung_fp32_ops
        precision = ct.transform.FP16ComputePrecision(
            op_selector=lambda op: op.op_type not in fp32_ops
        )
    return ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, height, width),
                             scale=1 / 255.0, bias=[0, 0, 0],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="depth")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=precision,
        compute_units=ct.ComputeUnit.ALL,
    )


def validate(mlmodel, wrapper, test_image, width, height):
    """Pearson correlation between the PyTorch reference and the Core ML output
    on the test image. Legit fp16 rounding stays >0.995; fp16 overflow (the
    wave artifact) collapses it. Prediction runs with ComputeUnit.ALL, so on
    Apple Silicon this exercises the ANE's fp16 behavior — a good proxy for the
    device, though the final say is on-device."""
    x = torch.from_numpy(np.asarray(test_image, dtype=np.float32) / 255.0)
    x = x.permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        ref = wrapper(x).numpy().reshape(-1)
    out = mlmodel.predict({"image": test_image})["depth"]
    out = np.asarray(out, dtype=np.float32).reshape(-1)
    if out.shape != ref.shape:
        return 0.0, float("inf")
    if not np.isfinite(out).all():
        return 0.0, float("inf")
    corr = float(np.corrcoef(ref, out)[0, 1])
    max_diff = float(np.abs(ref - out).max())
    return corr, max_diff


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", choices=list(VARIANTS), default="base")
    parser.add_argument("--width", type=int, help="input width, multiple of 14 (default 518)")
    parser.add_argument("--height", type=int, help="input height, multiple of 14 (default 392)")
    parser.add_argument("--aspect-preset", choices=["tv", "cinema22", "cinema239"],
                        help="aspect-matched input at roughly the default pixel count; conflicts with width/height")
    parser.add_argument("--precision", choices=["auto", "fp16", "mixed", "mixed+", "fp32"], default="auto",
                        help="auto walks the ladder and keeps the first rung that validates")
    parser.add_argument("--test-image", help="photo to validate against (default: synthetic scene)")
    parser.add_argument("--threshold", type=float, default=0.98, help="min Pearson correlation to pass (default 0.98)")
    parser.add_argument("--out", help="output .mlpackage path (default: auto-named)")
    args = parser.parse_args()

    if args.aspect_preset:
        if args.width is not None or args.height is not None:
            parser.error("--aspect-preset cannot be combined with --width/--height")
        args.width, args.height = {"tv": (602, 336), "cinema22": (686, 308),
                                   "cinema239": (700, 294)}[args.aspect_preset]
    else:
        args.width = 518 if args.width is None else args.width
        args.height = 392 if args.height is None else args.height

    if args.width <= 0 or args.height <= 0 or args.width % 14 or args.height % 14:
        parser.error(f"width/height must be multiples of 14 (got {args.width}x{args.height})")

    ckpt = VARIANTS[args.variant]
    out_path = args.out or f"DepthAnythingV2{args.variant.capitalize()}{args.width}x{args.height}.mlpackage"

    print(f"Loading {ckpt} ...")
    from transformers import AutoModelForDepthEstimation
    model = AutoModelForDepthEstimation.from_pretrained(ckpt)
    model.eval()
    wrapper = DepthWrapper(model).eval()

    example = torch.rand(1, 3, args.height, args.width)
    with torch.no_grad():
        ref = wrapper(example)
    print(f"wrapper output shape: {tuple(ref.shape)}  range: {float(ref.min()):.3f}..{float(ref.max()):.3f}")

    print("Tracing ...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)

    test_image = make_test_image(args.width, args.height, args.test_image)
    ladder = PRECISION_LADDER if args.precision == "auto" else \
        [r for r in PRECISION_LADDER if r[0] == args.precision]

    mlmodel = None
    for name, fp32_ops in ladder:
        print(f"Converting to Core ML ({name}) ...")
        candidate = convert(traced, args.width, args.height, fp32_ops)
        corr, max_diff = validate(candidate, wrapper, test_image, args.width, args.height)
        print(f"  validation: correlation={corr:.4f}  max|diff|={max_diff:.4f}  (threshold {args.threshold})")
        if corr >= args.threshold:
            mlmodel = candidate
            print(f"  -> {name} passes")
            break
        print(f"  -> {name} FAILS validation" +
              (" — this is the fp16-overflow wave artifact; trying the next rung"
               if args.precision == "auto" else ""))
    if mlmodel is None:
        print("ERROR: no precision rung passed validation", file=sys.stderr)
        sys.exit(1)

    mlmodel.short_description = (
        f"Depth Anything V2 {args.variant.capitalize()} {args.width}x{args.height} — "
        "monocular relative depth (Core ML)."
    )
    mlmodel.author = "Original Paper: Lihe Yang et al. (Depth Anything V2)"
    mlmodel.license = "Apache 2"
    mlmodel.save(out_path)
    print(f"Saved {out_path}")

    spec = mlmodel.get_spec()
    print("=== inputs ===")
    for i in spec.description.input:
        print(" ", i.name, i.type.WhichOneof("Type"))
    print("=== outputs ===")
    for o in spec.description.output:
        print(" ", o.name, o.type.WhichOneof("Type"))
    print("DONE — push with ./scripts/push-depth-model.sh", out_path)


if __name__ == "__main__":
    main()
