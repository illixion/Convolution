#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#     "torch==2.7.0",
#     "coremltools==9.0",
#     "numpy==1.26.4",
#     "pillow",
# ]
# ///
"""
Convert GMNet (Liao et al., "Learning Gain Map for Inverse Tone Mapping",
ICLR 2025, MIT, github.com/qtlark/GMNet) to the Core ML model Convolution's
AI HDR uses to give an SDR photo a gain map.

    git clone --depth 1 https://github.com/qtlark/GMNet.git /tmp/GMNet
    uv run scripts/convert-gainmap-model.py --repo /tmp/GMNet [--check photo.jpg]

Writes Hypnos/Hypnos/Resources/GainMapGMNet.mlpackage (bundled; Xcode compiles it).

What the model does, baked in so the app only multiplies:
  inputs  "image"     RGB, one of the enumerated sizes below, 0...1 (scale 1/255)
          "thumbnail" RGB 256x256, the whole photo squeezed (the paper's global input)
  outputs "gain"      1x1xHxW float16: the linear multiplier for each pixel,
                      1 (SDR) up to the checkpoint's peak (5x for real-world).
                      HDR linear = SDR linear x gain.
          "headroom"  1: the largest gain (the picture's content headroom)

The real-world checkpoint was trained on phone photos at 2048x1536 (203-nit
SDR white, 1015-nit peak), its second output normalized by log2(5). GMNet's
attention predicts a per-image 3x3 depthwise kernel and applies it with a
grouped conv whose weights are a tensor; that is rewritten here as nine
shifted multiply-adds (identical maths) so it converts with constant weights
and stays on the Neural Engine.
"""

import argparse
import math
import os
import sys
import types

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

SIZES = [(1024, 768), (768, 1024), (1024, 576), (576, 1024), (896, 896)]  # (w, h)
PEAK = {"realworld": 5.0, "synthetic": 8.0}


def load_gmnet(repo: str):
    sys.path.insert(0, os.path.join(repo, "codes"))
    # GMNet.py imports a GPU memory logger it never calls.
    stub = types.ModuleType("utils.gpu_memory_log")
    stub.gpu_memory_log = lambda *a, **k: None
    sys.modules.setdefault("utils", types.ModuleType("utils"))
    sys.modules["utils.gpu_memory_log"] = stub
    from models.modules.GMNet import GMNet  # noqa: E402
    return GMNet


class Exported(nn.Module):
    """GMNet's forward with the dynamic depthwise conv unrolled and the gain
    decoded to a linear multiplier."""

    def __init__(self, net, peak: float):
        super().__init__()
        self.net = net
        self.log2_peak = math.log2(peak)

    def forward(self, image, thumbnail):
        n = self.net
        y = n.res_y(n.down2(n.down1(thumbnail)))
        kernel = n.sq_ker(y)          # 1 x C x 3 x 3
        cse = n.sq_chn(y)             # 1 x C x 1 x 1
        qmax = n.sq_qmax(y)           # 1 x 1 x 1 x 1

        x = n.res1(n.down_x(image))
        h, w = x.shape[2], x.shape[3]
        xp = F.pad(x, (1, 1, 1, 1))
        mask = None
        for i in range(3):
            for j in range(3):
                term = xp[:, :, i:i + h, j:j + w] * kernel[:, :, i:i + 1, j:j + 1]
                mask = term if mask is None else mask + term
        x = x * n.mask_est(mask)
        x = n.res2(x)
        x = x * n.att_est(cse)
        x = n.res3(x)
        out = n.act(n.upsampler(n.upconv(x)))
        out = n.conv_last(n.act(n.HRconv(out)))
        q = torch.clamp(qmax * out, min=0.0, max=1.0)
        gain = torch.exp2(q * self.log2_peak)
        headroom = torch.amax(gain, dim=(1, 2, 3))
        return gain, headroom


def reference(net, image, thumbnail, peak):
    """The repository's own forward, for checking the export."""
    with torch.no_grad():
        _, q = net((image, thumbnail))
    return torch.exp2(torch.clamp(q, 0, 1) * math.log2(peak))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="a checkout of github.com/qtlark/GMNet")
    ap.add_argument("--checkpoint", choices=PEAK.keys(), default="realworld")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..",
                                                  "Hypnos/Hypnos/Resources/GainMapGMNet.mlpackage"))
    ap.add_argument("--check", help="an SDR photo to compare PyTorch and Core ML on")
    args = ap.parse_args()

    import coremltools as ct
    from PIL import Image

    GMNet = load_gmnet(args.repo)
    net = GMNet(in_nc=3, out_nc=1, nf=64, nb=16, act_type="relu").eval()
    state = torch.load(os.path.join(args.repo, "checkpoints", f"G_{args.checkpoint}.pth"), map_location="cpu")
    missing, unexpected = net.load_state_dict(state, strict=False)
    if missing or unexpected:
        sys.exit(f"checkpoint mismatch: missing {missing}, unexpected {unexpected}")
    peak = PEAK[args.checkpoint]
    model = Exported(net, peak).eval()

    w0, h0 = SIZES[0]
    ex_image = torch.rand(1, 3, h0, w0)
    ex_thumb = torch.rand(1, 3, 256, 256)
    with torch.no_grad():
        ours = model(ex_image, ex_thumb)[0]
    theirs = reference(net, ex_image, ex_thumb, peak)
    print(f"unrolled vs original forward: max |diff| {float((ours - theirs).abs().max()):.2e}")

    traced = torch.jit.trace(model, (ex_image, ex_thumb))
    shapes = ct.EnumeratedShapes(shapes=[[1, 3, h, w] for (w, h) in SIZES], default=[1, 3, h0, w0])
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(name="image", shape=shapes, scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
            ct.ImageType(name="thumbnail", shape=(1, 3, 256, 256), scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
        ],
        outputs=[ct.TensorType(name="gain", dtype=np.float16), ct.TensorType(name="headroom", dtype=np.float16)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
    mlmodel.short_description = ("GMNet (Liao et al., ICLR 2025, MIT): a gain map for an SDR photo, "
                                 f"as a linear multiplier up to {peak:g}x ({args.checkpoint} checkpoint).")
    mlmodel.author = "Yinuo Liao et al.; converted for Convolution"
    mlmodel.license = "MIT"
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    mlmodel.save(args.out)
    print("saved", os.path.abspath(args.out))

    if args.check:
        photo = Image.open(args.check).convert("RGB")
        pw, ph = photo.size
        w, h = min(SIZES, key=lambda s: abs(math.log((s[0] / s[1]) / (pw / ph))))
        img = photo.resize((w, h), Image.BICUBIC)
        thumb = photo.resize((256, 256), Image.BICUBIC)
        t_img = torch.from_numpy(np.asarray(img, dtype=np.float32) / 255).permute(2, 0, 1)[None]
        t_thumb = torch.from_numpy(np.asarray(thumb, dtype=np.float32) / 255).permute(2, 0, 1)[None]
        ref = reference(net, t_img, t_thumb, peak)[0, 0].numpy()
        pred = mlmodel.predict({"image": img, "thumbnail": thumb})
        gain = np.asarray(pred["gain"], dtype=np.float32)[0, 0]
        print(f"check {w}x{h}: torch gain {ref.min():.3f}...{ref.max():.3f} mean {ref.mean():.3f}; "
              f"core ml {gain.min():.3f}...{gain.max():.3f} mean {gain.mean():.3f}; "
              f"max |diff| {np.abs(gain - ref).max():.3f}, mean |diff| {np.abs(gain - ref).mean():.4f}; "
              f"headroom {float(np.asarray(pred['headroom']).ravel()[0]):.3f}")
        vis = np.clip(np.log2(gain) / math.log2(peak) * 255, 0, 255).astype(np.uint8)
        out = os.path.splitext(args.check)[0] + "-gain.png"
        Image.fromarray(vis).save(out)
        print("gain map (log2, 0 = black, peak = white):", out)


if __name__ == "__main__":
    main()
