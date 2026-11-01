#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#     "torch==2.7.0",
#     "coremltools==9.0",
#     "numpy==1.26.4",
#     "pillow",
#     "huggingface_hub",
# ]
# ///
"""
Convert frame-interpolation flow networks to Core ML, for the Smooth Motion
spike (docs/plans/blu-ray-3d-smooth-motion.md, option E / phase E0).

    uv run scripts/convert-interp-model.py rife --weights <train_log dir> [--name RIFE425]
    uv run scripts/convert-interp-model.py neuflow --repo <NeuFlow_v2 clone>

Then copy each .mlpackage to Documents/InterpModels on the headset, where the
`interpModelBench` debug endpoint times them:
    xcrun devicectl device copy to --device AVP --domain-type appDataContainer \
        --domain-identifier com.illixion.spatialstash \
        --source "$PWD/build/interp-models/<name>.mlpackage" \
        --destination "Documents/InterpModels/<name>.mlpackage"

Sizes that fit the headset's budget (E0 results in the plan): RIFE lite at
--size 480x288 --scales 8 4 2 1 1, NeuFlow at --size 512x288 --iters 4.

RIFE (hzwer/Practical-RIFE, MIT). Weights are a Google Drive zip per version
(train_log/flownet.pkl + IFNet_HDv3.py). The IFNet here is a re-implementation
of 4.25's inference path, so no downloaded Python runs; flownet.pkl is loaded
with `weights_only=True`. The `c` of block4 is read from the weights (32 in
4.25, 24 in 4.25 lite).
  inputs  img0, img1: [1,3,H,W] float16, RGB in 0…1
          timestep:   [1,1,1,1] float16, 0…1 (the in-between moment)
  outputs flow: [1,4,H,W] — channels 0-1 the flow from t back to img0, 2-3 from
                t on to img1, in pixels of the input size
          mask: [1,1,H,W] — weight of img0's warp (sigmoid applied)
The final warp + blend is left to a Metal shader at display resolution, so the
model can run at a reduced size. W and H must be multiples of 16 × the
coarsest scale's stride (64 for the default --scales 16 8 4 2 1).

NeuFlow v2 (neufieldrobotics/NeuFlow_v2, Apache-2.0). Its package code is
imported from the clone (read before use). Converted bidirectional: one run is
batch 2, (a→b, b→a), so any timestep is a flow reversal in a shader.
  inputs  img0, img1: [1,3,H,W] float16, RGB in 0…255 (the model divides)
  outputs flow: [2,2,H,W] — [0] img0→img1, [1] img1→img0, in pixels
          ([1,2,H,W] img0→img1 with --one-way)
The 7-D convex upsample is rewritten as 5-D + pixel shuffle (Core ML caps rank
at 5); the result is checked against the original.
"""
import argparse
import math
import os
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

# ---------------------------------------------------------------- shared


def backwarp(img, flow):
    """Sample img at (x + flow). Pixel-unit flow, align_corners=True, border pad
    (RIFE's warplayer)."""
    b, _, h, w = flow.shape
    xs = torch.linspace(-1.0, 1.0, w, dtype=flow.dtype).view(1, 1, 1, w).expand(b, 1, h, w)
    ys = torch.linspace(-1.0, 1.0, h, dtype=flow.dtype).view(1, 1, h, 1).expand(b, 1, h, w)
    grid = torch.cat([xs + flow[:, 0:1] / ((w - 1.0) / 2.0),
                      ys + flow[:, 1:2] / ((h - 1.0) / 2.0)], 1).permute(0, 2, 3, 1)
    return F.grid_sample(img, grid, mode="bilinear", padding_mode="border", align_corners=True)


def resize(x, size):
    return F.interpolate(x, size=size, mode="bilinear", align_corners=False)


# ---------------------------------------------------------------- RIFE 4.25


def conv(i, o, k=3, s=1, p=1):
    return nn.Sequential(nn.Conv2d(i, o, k, s, p, bias=True), nn.LeakyReLU(0.2, True))


class Head(nn.Module):
    def __init__(self):
        super().__init__()
        self.cnn0 = nn.Conv2d(3, 16, 3, 2, 1)
        self.cnn1 = nn.Conv2d(16, 16, 3, 1, 1)
        self.cnn2 = nn.Conv2d(16, 16, 3, 1, 1)
        self.cnn3 = nn.ConvTranspose2d(16, 4, 4, 2, 1)
        self.relu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        x = self.relu(self.cnn0(x))
        x = self.relu(self.cnn1(x))
        x = self.relu(self.cnn2(x))
        return self.cnn3(x)


class ResConv(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.conv = nn.Conv2d(c, c, 3, 1, 1)
        self.beta = nn.Parameter(torch.ones((1, c, 1, 1)))
        self.relu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        return self.relu(self.conv(x) * self.beta + x)


class IFBlock(nn.Module):
    def __init__(self, in_planes, c):
        super().__init__()
        self.conv0 = nn.Sequential(conv(in_planes, c // 2, 3, 2, 1), conv(c // 2, c, 3, 2, 1))
        self.convblock = nn.Sequential(*[ResConv(c) for _ in range(8)])
        self.lastconv = nn.Sequential(nn.ConvTranspose2d(c, 4 * 13, 4, 2, 1), nn.PixelShuffle(2))

    def forward(self, x, flow, scale, full):
        h, w = full
        small = (int(h // scale), int(w // scale))
        x = resize(x, small)
        if flow is not None:
            x = torch.cat((x, resize(flow, small) * (1.0 / scale)), 1)
        feat = self.convblock(self.conv0(x))
        tmp = resize(self.lastconv(feat), (h, w))
        return tmp[:, :4] * scale, tmp[:, 4:5], tmp[:, 5:]


class IFNet(nn.Module):
    def __init__(self, c4, scales):
        super().__init__()
        self.block0 = IFBlock(7 + 8, 192)
        self.block1 = IFBlock(8 + 4 + 8 + 8, 128)
        self.block2 = IFBlock(8 + 4 + 8 + 8, 96)
        self.block3 = IFBlock(8 + 4 + 8 + 8, 64)
        self.block4 = IFBlock(8 + 4 + 8 + 8, c4)
        self.encode = Head()
        self.scales = scales

    def forward(self, img0, img1, timestep):
        h, w = img0.shape[2], img0.shape[3]
        t = timestep.expand(1, 1, h, w)
        f0 = self.encode(img0)
        f1 = self.encode(img1)
        blocks = [self.block0, self.block1, self.block2, self.block3, self.block4]
        flow = mask = feat = None
        wi0, wi1 = img0, img1
        for i, blk in enumerate(blocks):
            if flow is None:
                flow, mask, feat = blk(torch.cat((img0, img1, f0, f1, t), 1), None, self.scales[i], (h, w))
            else:
                wf0 = backwarp(f0, flow[:, :2])
                wf1 = backwarp(f1, flow[:, 2:4])
                fd, mask, feat = blk(torch.cat((wi0, wi1, wf0, wf1, t, mask, feat), 1), flow,
                                     self.scales[i], (h, w))
                flow = flow + fd
            if i < len(blocks) - 1:
                wi0 = backwarp(img0, flow[:, :2])
                wi1 = backwarp(img1, flow[:, 2:4])
        return flow, torch.sigmoid(mask)


def load_rife(weights_dir, scales):
    sd = torch.load(Path(weights_dir) / "flownet.pkl", map_location="cpu", weights_only=True)
    sd = {k.replace("module.", ""): v for k, v in sd.items() if "teacher" not in k and "caltime" not in k}
    c4 = sd["block4.conv0.0.0.weight"].shape[0] * 2
    net = IFNet(c4, scales)
    net.load_state_dict(sd, strict=True)
    print(f"RIFE: block4 c={c4}, {sum(p.numel() for p in net.parameters()) / 1e6:.2f} M parameters")
    return net.eval()


# ---------------------------------------------------------------- NeuFlow v2


def load_neuflow(repo, h, w):
    sys.path.insert(0, str(Path(repo).resolve()))
    from NeuFlow.neuflow import NeuFlow  # noqa: E402
    from NeuFlow.backbone_v7 import ConvBlock  # noqa: E402
    from NeuFlow import upsample as up_mod  # noqa: E402

    net = NeuFlow()
    ckpt = torch.load(Path(repo) / "neuflow_mixed.pth", map_location="cpu", weights_only=True)
    net.load_state_dict(ckpt["model"], strict=True)

    def fuse(conv, bn):
        fused = nn.Conv2d(conv.in_channels, conv.out_channels, conv.kernel_size, conv.stride, conv.padding,
                          groups=conv.groups, bias=True).requires_grad_(False)
        w_conv = conv.weight.clone().view(conv.out_channels, -1)
        w_bn = torch.diag(bn.weight.div(torch.sqrt(bn.eps + bn.running_var)))
        fused.weight.copy_(torch.mm(w_bn, w_conv).view(fused.weight.shape))
        b_conv = torch.zeros(conv.weight.shape[0]) if conv.bias is None else conv.bias
        b_bn = bn.bias - bn.weight.mul(bn.running_mean).div(torch.sqrt(bn.running_var + bn.eps))
        fused.bias.copy_(torch.mm(w_bn, b_conv.reshape(-1, 1)).reshape(-1) + b_bn)
        return fused

    for m in net.modules():
        if type(m) is ConvBlock:
            m.conv1 = fuse(m.conv1, m.norm1)
            m.conv2 = fuse(m.conv2, m.norm2)
            del m.norm1, m.norm2
            m.forward = m.forward_fuse
    net.eval()
    return net, up_mod


def rank5_upsample_forward(self, feature, flow):
    """NeuFlow's convex upsample without 7-D tensors."""
    k = self.upsample_factor
    concat = torch.cat((flow, feature), dim=1)
    mask = self.conv3(self.relu(self.conv2(self.relu(self.conv1(concat)))))
    b, _, h, w = flow.shape
    mask = torch.softmax(mask.view(b, 9, k * k, h, w), dim=1)          # [B,9,KK,H,W]
    unf = F.unfold(flow, [3, 3], padding=1).view(b, 2, 9, h, w)          # [B,2,9,H,W]
    outs = []
    for c in range(2):
        u = unf[:, c].unsqueeze(2)                                        # [B,9,1,H,W]
        outs.append(torch.sum(mask * u, dim=1))                           # [B,KK,H,W]
    return F.pixel_shuffle(torch.cat(outs, 1), k)                          # [B,2,KH,KW]


class NeuFlowBidirectional(nn.Module):
    """Both directions as batch 2, or (one_way) img0→img1 only as batch 1."""

    def __init__(self, net, iters, one_way):
        super().__init__()
        self.net = net
        self.iters = iters
        self.one_way = one_way

    def forward(self, img0, img1):
        if self.one_way:
            return self.net(img0, img1, iters_s8=self.iters)[-1]
        a = torch.cat([img0, img1], 0)
        b = torch.cat([img1, img0], 0)
        return self.net(a, b, iters_s8=self.iters)[-1]


# ---------------------------------------------------------------- conversion


def test_pair(h, w, scale255):
    """Two frames of a textured scene; the second is the first moved (−12, +5) px — a pan."""
    rng = np.random.default_rng(7)
    big = rng.random((3, h + 64, w + 64)).astype(np.float32)
    k = np.ones((9, 9), np.float32) / 81  # smooth the noise so flow is learnable
    t = torch.from_numpy(big)[None]
    t = F.conv2d(t, torch.from_numpy(k)[None, None].repeat(3, 1, 1, 1), padding=4, groups=3)
    t = (t - t.min()) / (t.max() - t.min())
    a = t[:, :, 32:32 + h, 32:32 + w]
    b = t[:, :, 32 - 5:32 - 5 + h, 32 + 12:32 + 12 + w]
    if scale255:
        a, b = a * 255, b * 255
    return a.contiguous(), b.contiguous()


def convert(module, example, input_names, output_names, out_path, precision):
    import coremltools as ct

    with torch.no_grad():
        traced = torch.jit.trace(module, example, check_trace=False)
    inputs = [ct.TensorType(name=n, shape=e.shape, dtype=np.float16) for n, e in zip(input_names, example)]
    outputs = [ct.TensorType(name=n, dtype=np.float16) for n in output_names]
    mlmodel = ct.convert(
        traced, inputs=inputs, outputs=outputs, convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.save(str(out_path))
    print(f"saved {out_path}")
    return mlmodel


def compare(mlmodel, example, input_names, reference, output_names):
    if sys.platform != "darwin":
        return
    feed = {n: e.numpy().astype(np.float16) for n, e in zip(input_names, example)}
    got = mlmodel.predict(feed)
    for name, ref in zip(output_names, reference):
        g = np.asarray(got[name], dtype=np.float32)
        r = ref.numpy().astype(np.float32)
        err = np.abs(g - r)
        print(f"  {name}: mean |Δ| {err.mean():.4f}, p99 {np.percentile(err, 99):.4f}, "
              f"ref range {r.min():.2f}…{r.max():.2f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model", choices=["rife", "neuflow"])
    ap.add_argument("--weights", help="RIFE train_log dir (flownet.pkl)")
    ap.add_argument("--repo", help="NeuFlow_v2 clone")
    ap.add_argument("--size", default="960x576", help="WxH the model runs at")
    ap.add_argument("--scales", type=float, nargs=5, default=[16, 8, 4, 2, 1],
                    help="RIFE per-block downscale (Practical-RIFE uses 32 16 8 4 1 at scale 1)")
    ap.add_argument("--iters", type=int, default=8, help="NeuFlow refinement iterations at 1/8 (default 8)")
    ap.add_argument("--one-way", action="store_true", help="NeuFlow: img0→img1 only (batch 1)")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    ap.add_argument("--name", help="output basename")
    ap.add_argument("--out", default="build/interp-models")
    args = ap.parse_args()

    w, h = (int(v) for v in args.size.lower().split("x"))
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.model == "rife":
        stride = int(max(args.scales) * 4)
        if w % stride or h % stride:
            sys.exit(f"--size must be a multiple of {stride} for scales {args.scales}")
        net = load_rife(args.weights, args.scales)
        a, b = test_pair(h, w, scale255=False)
        ts = torch.full((1, 1, 1, 1), 0.5)
        example = (a, b, ts)
        names_in, names_out = ["img0", "img1", "timestep"], ["flow", "mask"]
        with torch.no_grad():
            ref = net(*example)
            f = ref[0]
            # img1 is img0 moved (−12, +5): at t=0.5 the flow back to img0
            # is about (6, −2.5) and on to img1 about (−6, 2.5).
            c = f[:, :, h // 4:3 * h // 4, w // 4:3 * w // 4].mean((2, 3)).squeeze().tolist()
            print(f"  PyTorch centre flow t→0 ({c[0]:.2f}, {c[1]:.2f})  t→1 ({c[2]:.2f}, {c[3]:.2f}); "
                  f"expected about (6, −2.5) and (−6, 2.5)")
        name = args.name or f"RIFE_{w}x{h}"
    else:
        net, up_mod = load_neuflow(args.repo, h, w)
        if w % 16 or h % 16:
            sys.exit("--size must be a multiple of 16 for NeuFlow")
        a, b = test_pair(h, w, scale255=True)
        batch = 1 if args.one_way else 2
        net.init_bhwd(batch, h, w, "cpu", amp=False)
        with torch.no_grad():
            if args.one_way:
                original = net(a.clone(), b.clone(), iters_s8=args.iters)[-1]
            else:
                original = net(torch.cat([a, b]), torch.cat([b, a]), iters_s8=args.iters)[-1]
        up_mod.UpSample.forward = rank5_upsample_forward
        model = NeuFlowBidirectional(net, args.iters, args.one_way)
        with torch.no_grad():
            patched = model(a.clone(), b.clone())
        print(f"  rank-5 upsample vs original: max |Δ| {(patched - original).abs().max():.5f}")
        c = patched[:, :, h // 4:3 * h // 4, w // 4:3 * w // 4].mean((2, 3)).tolist()
        print(f"  PyTorch centre flow a→b {c[0][0]:.2f},{c[0][1]:.2f}"
              + ("" if args.one_way else f"  b→a {c[1][0]:.2f},{c[1][1]:.2f}")
              + "; expected about (−12, 5) and (12, −5)")
        net = model
        example = (a, b)
        ref = (patched,)
        names_in, names_out = ["img0", "img1"], ["flow"]
        name = args.name or (f"NeuFlowV2_{w}x{h}" + ("_1way" if args.one_way else "")
                             + (f"_i{args.iters}" if args.iters != 8 else ""))

        # NeuFlow divides its inputs in place; trace on copies.
        class Copying(nn.Module):
            def __init__(self, m):
                super().__init__()
                self.m = m

            def forward(self, x, y):
                return self.m(x * 1.0, y * 1.0)
        net = Copying(model)

    if args.precision != "fp16":
        name += f"_{args.precision}"
    path = out_dir / f"{name}.mlpackage"
    ml = convert(net, example, names_in, names_out, path, args.precision)
    compare(ml, example, names_in, ref if isinstance(ref, tuple) else (ref,), names_out)


if __name__ == "__main__":
    main()
