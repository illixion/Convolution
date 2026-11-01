#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#     "torch==2.7.0",
#     "numpy==1.26.4",
#     "pillow",
#     "huggingface_hub",
# ]
# ///
"""
Interpolation quality at the headset's working sizes, for the Smooth Motion plan
(docs/plans/blu-ray-3d-smooth-motion.md, option E / phase E1).

    swiftc -O -parse-as-library scripts/vt-interp-helper.swift -o build/interp-quality/vt-interp-helper
    uv run scripts/interp-quality.py build/interp-quality/*.mkv [--stride 2] [--limit N]

Clips are 1080p stereo, both eyes stacked top (left) and bottom (right), lossless
(FFV1), e.g. from a 3D Blu-ray through Vergence:
    vergence decode DISC --seek 6480 --frames 72 --threads -1 --output - \\
      | ffmpeg -f rawvideo -pix_fmt yuv420p -s 1920x2160 -r 24000/1001 -i - -c:v ffv1 clip.mkv

What it measures, each against the real frame it leaves out:
- 2×, t = ½: from frames (i, i+2) predict i+1. Candidates:
    repeat        frame i again (what no interpolation shows)
    blend         50/50 mix of i and i+2
    vt            VTLowLatencyFrameInterpolation at 1080p, '420v' (vt-interp-helper)
    rife480       RIFE 4.25 lite run at 480×288, scales 8 4 2 1 1 (12 ms on the headset ANE)
    rife640       RIFE 4.25 lite at 640×384, same scales (22 ms)
    rife1088      RIFE 4.25 lite at the full 1920×1088, Practical-RIFE's scales 32 16 8 4 1
                  (the ceiling: what going small loses; not runnable on the headset)
    neuflow512    NeuFlow v2 at 512×288, 4 iterations, both directions (14 ms), flow reversal
    neuflow512occ the same, with each side weighted down where its forward/backward check fails
    neuflow512vis the same check read the other way: a sample its own frame alone sees is preferred
  For the small runs the frames are resized to the working size (not letterboxed), the flow
  and mask are scaled back up to 1080p, and the warp and blend run at 1080p: a mirror of the
  planned Metal shader.
- 4× stress test: from (i, i+4) predict i+1, i+2, i+3 (t = ¼, ½, ¾). RIFE runs once at t = ½;
  F0→1 ≈ 2·F½→1 and F1→0 ≈ 2·F½→0 feed the flow reversal (`-derived`), next to a RIFE run per t
  (`-direct`). A 4-frame gap is far more motion than the real 24→96 case.
- Stereo: left and right eyes interpolated independently at t = ½. NeuFlow v2 at full
  1920×1088 measures the left→right disparity of the real pairs i, i+1, i+2 and of the
  in-between pair, only where the real i+1 pair's L→R and R→L agree within 1 px. Reports how
  far the in-between pair's horizontal disparity strays from the mean of its neighbours (the
  real i+1 pair's own stray is the control) and its vertical disparity.

Scores: PSNR and SSIM (11-tap Gaussian) on luma (BT.709, 0–255) at 1920×1080; "moving" is
PSNR over pixels moving ≥ 4 px per 24 fps frame (per RIFE at full size). The worst 256×256
region of each clip (by rife480's error) is saved under --out/crops as a strip, real first.

Weights and code: RIFE's IFNet and NeuFlow's loader come from scripts/convert-interp-model.py
(RIFE re-implemented, weights loaded with weights_only=True; NeuFlow's package imported from
the clone). Defaults point at build/interp-spike as E0 left it.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("convert_interp_model", HERE / "convert-interp-model.py")
conv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(conv)


def _backwarp(img, flow):
    """The converter's backwarp (RIFE's warplayer), with its grid on the flow's device."""
    b, _, h, w = flow.shape
    xs = torch.linspace(-1.0, 1.0, w, dtype=flow.dtype, device=flow.device).view(1, 1, 1, w).expand(b, 1, h, w)
    ys = torch.linspace(-1.0, 1.0, h, dtype=flow.dtype, device=flow.device).view(1, 1, h, 1).expand(b, 1, h, w)
    grid = torch.cat([xs + flow[:, 0:1] / ((w - 1.0) / 2.0),
                      ys + flow[:, 1:2] / ((h - 1.0) / 2.0)], 1).permute(0, 2, 3, 1)
    # MPS has no "border" padding; with align_corners, clamping the grid is the same thing.
    return F.grid_sample(img, grid.clamp(-1.0, 1.0), mode="bilinear", padding_mode="zeros", align_corners=True)


conv.backwarp = _backwarp  # IFNet.forward looks it up in the converter's module at call time

W, H = 1920, 1080
SCALE_FLAGS = "scale=in_range=tv:out_range=pc:in_color_matrix=bt709:flags=accurate_rnd+full_chroma_int"

# ---------------------------------------------------------------- frames


def read_clip(path):
    """(rgb [N,2,H,W,3] uint8 via ffmpeg, i420 [N,2,H*W*3/2] uint8 per eye)."""
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo",
                          "-pix_fmt", "yuv420p", "-"], check=True, capture_output=True).stdout
    full = np.frombuffer(raw, np.uint8).reshape(-1, W * 2 * H * 3 // 2)
    n = full.shape[0]
    y = full[:, :W * 2 * H].reshape(n, 2 * H, W)
    u = full[:, W * 2 * H:W * 2 * H + W * H // 2].reshape(n, H, W // 2)
    v = full[:, W * 2 * H + W * H // 2:].reshape(n, H, W // 2)
    eyes = []
    for e in range(2):
        ye = y[:, e * H:(e + 1) * H].reshape(n, -1)
        ue = u[:, e * H // 2:(e + 1) * H // 2].reshape(n, -1)
        ve = v[:, e * H // 2:(e + 1) * H // 2].reshape(n, -1)
        eyes.append(np.concatenate([ye, ue, ve], 1))
    i420 = np.stack(eyes, 1)
    rgb = i420_to_rgb(i420.reshape(-1, W * H * 3 // 2)).reshape(n, 2, H, W, 3)
    return rgb, i420


def i420_to_rgb(frames):
    """ffmpeg's BT.709 limited → full-range RGB, so every candidate goes through the same path."""
    out = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p",
                          "-s", f"{W}x{H}", "-i", "-", "-vf", SCALE_FLAGS, "-f", "rawvideo",
                          "-pix_fmt", "rgb24", "-"], input=frames.tobytes(), check=True,
                         capture_output=True).stdout
    return np.frombuffer(out, np.uint8).reshape(-1, H, W, 3)


def vt_interpolate(helper, pairs, phases, scratch):
    """pairs: list of (i420 a, i420 b). Returns rgb [len(pairs), len(phases), H, W, 3]."""
    src, dst = scratch / "vt-pairs.yuv", scratch / "vt-out.yuv"
    with open(src, "wb") as f:
        for a, b in pairs:
            f.write(a.tobytes())
            f.write(b.tobytes())
    r = subprocess.run([str(helper), str(src), str(dst), str(W), str(H), ",".join(map(str, phases))],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"vt-interp-helper failed: {r.stderr}")
    print("   ", r.stderr.strip())
    out = np.frombuffer(dst.read_bytes(), np.uint8).reshape(-1, W * H * 3 // 2)
    return i420_to_rgb(out).reshape(len(pairs), len(phases), H, W, 3)


# ---------------------------------------------------------------- metrics


def tensor(rgb, dev):
    return torch.from_numpy(np.array(rgb)).to(dev).permute(2, 0, 1)[None].float() / 255.0


def luma(x):
    """[1,3,H,W] in 0…1 → [H,W] BT.709 luma in 0…255, after 8-bit rounding (like any real output)."""
    q = (x.clamp(0, 1) * 255).round()
    return 0.2126 * q[0, 0] + 0.7152 * q[0, 1] + 0.0722 * q[0, 2]


_gauss = {}


def ssim_map(a, b):
    dev = a.device
    if dev not in _gauss:
        g = torch.exp(-((torch.arange(11, dtype=torch.float32) - 5) ** 2) / (2 * 1.5 ** 2))
        _gauss[dev] = (g / g.sum()).to(dev)
    g = _gauss[dev]

    def blur(x):
        x = F.pad(x[None, None], (5, 5, 5, 5), mode="reflect")
        x = F.conv2d(x, g.view(1, 1, 1, 11))
        return F.conv2d(x, g.view(1, 1, 11, 1))[0, 0]
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    ma, mb = blur(a), blur(b)
    va, vb, cov = blur(a * a) - ma * ma, blur(b * b) - mb * mb, blur(a * b) - ma * mb
    return ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))


def psnr(mse):
    return 10 * np.log10(255.0 ** 2 / max(mse, 1e-10))


# ---------------------------------------------------------------- models


def up_flow(flow, size):
    """Scale a [B,2k,h,w] pixel flow to size (H,W) and to its pixel units."""
    h, w = flow.shape[2:]
    out = F.interpolate(flow, size=size, mode="bilinear", align_corners=False)
    sx, sy = size[1] / w, size[0] / h
    scale = torch.tensor([sx, sy] * (flow.shape[1] // 2), device=flow.device).view(1, -1, 1, 1)
    return out * scale


def run_rife(net, a, b, t, size):
    """RIFE at working size (h,w) → (F t→0, F t→1, mask) at 1080p. size (1088,1920) pads instead."""
    h, w = size
    if (h, w) == (1088, 1920):
        a0, b0 = F.pad(a, (0, 0, 0, 8), mode="replicate"), F.pad(b, (0, 0, 0, 8), mode="replicate")
    else:
        a0, b0 = conv.resize(a, (h, w)), conv.resize(b, (h, w))
    ts = torch.full((1, 1, 1, 1), float(t), device=a.device)
    flow, mask = net(a0, b0, ts)
    if (h, w) == (1088, 1920):
        return flow[:, :2, :H], flow[:, 2:, :H], mask[:, :, :H]
    flow = up_flow(flow, (H, W))
    mask = F.interpolate(mask, size=(H, W), mode="bilinear", align_corners=False)
    return flow[:, :2], flow[:, 2:], mask


def run_neuflow(net, a, b, size, bidirectional=True):
    """NeuFlow at (h,w) → (F0→1, F1→0) at the input's size (F1→0 None one-way)."""
    h, w = size
    ih, iw = a.shape[2:]
    pad = (h, w) != (ih, iw) and (h - ih, w - iw) == (8, 0)
    if pad:
        a0, b0 = F.pad(a, (0, 0, 0, 8), mode="replicate"), F.pad(b, (0, 0, 0, 8), mode="replicate")
    else:
        a0, b0 = conv.resize(a, (h, w)), conv.resize(b, (h, w))
    a0, b0 = a0 * 255.0, b0 * 255.0
    if bidirectional:
        flow = net(torch.cat([a0, b0]), torch.cat([b0, a0]), iters_s8=net._iters)[-1]
    else:
        flow = net(a0, b0, iters_s8=net._iters)[-1]
    if pad:
        flow = flow[:, :, :ih]
    elif (h, w) != (ih, iw):
        flow = up_flow(flow, (ih, iw))
    return (flow[0:1], flow[1:2]) if bidirectional else (flow[0:1], None)


def reversal(f01, f10, t):
    """Super SloMo's flow reversal: flows from time t back to frame 0 and on to frame 1."""
    ft0 = -(1 - t) * t * f01 + t * t * f10
    ft1 = (1 - t) ** 2 * f01 - t * (1 - t) * f10
    return ft0, ft1


def warp_blend(a, b, ft0, ft1, w0):
    return conv.backwarp(a, ft0) * w0 + conv.backwarp(b, ft1) * (1 - w0)


def occlusion_weights(f01, f10, ft0, ft1, t, unit=1920 / 512, prefer_unmatched=False):
    """Down-weight a side whose sampled pixel fails the forward/backward check (UnFlow's test,
    |f + b|² < 0.01(|f|² + |b|²) + 0.5 px², in working-size pixels, `unit` 1080p px each), softly."""
    def check(fwd_at, back):
        e = (fwd_at + back).pow(2).sum(1, keepdim=True)
        tol = 0.01 * (fwd_at.pow(2).sum(1, keepdim=True) + back.pow(2).sum(1, keepdim=True)) + 0.5 * unit ** 2
        return torch.exp(-torch.relu(e - tol) / tol)
    # Pixel p0 = x + Ft→0 in frame 0: does F0→1 there come back via F1→0? Likewise for frame 1.
    # prefer_unmatched flips the rule: a sample only its own frame sees (covered in the other)
    # can only come from that frame, so weight it up instead of down.
    f01_at = conv.backwarp(f01, ft0)
    c0 = check(f01_at, conv.backwarp(f10, ft0 + f01_at))
    f10_at = conv.backwarp(f10, ft1)
    c1 = check(f10_at, conv.backwarp(f01, ft1 + f10_at))
    if prefer_unmatched:
        c0, c1 = 1 + 4 * (1 - c0), 1 + 4 * (1 - c1)
    v0, v1 = (1 - t) * c0, t * c1
    return (v0 + 1e-3 * (1 - t)) / (v0 + v1 + 1e-3)


class Models:
    def __init__(self, args, dev):
        self.dev = dev
        lite = Path(args.rife)
        self.rife_small = conv.load_rife(lite, [8, 4, 2, 1, 1]).to(dev)
        self.rife_full = conv.load_rife(lite, [32, 16, 8, 4, 1]).to(dev)
        self.nf512 = self._neuflow(args.neuflow, 2, 288, 512, 4)
        self.nf_disp = self._neuflow(args.neuflow, 1, 1088, 1920, 8)

    def _neuflow(self, repo, batch, h, w, iters):
        net, _ = conv.load_neuflow(repo, h, w)
        from NeuFlow import matching  # imported from the clone by load_neuflow

        def global_correlation_softmax(self, feature0, feature1):
            # MPS's scaled_dot_product_attention mishandles a 2-wide value; same maths, spelled out.
            b, c, hh, ww = feature0.shape
            q = feature0.flatten(-2).permute(0, 2, 1)
            k = feature1.flatten(-2)
            attn = torch.softmax(torch.bmm(q, k) / (c ** 0.5), dim=-1)
            corr = torch.bmm(attn, self.flatten_grid).view(b, hh, ww, 2).permute(0, 3, 1, 2)
            return corr - self.grid
        matching.Matching.global_correlation_softmax = global_correlation_softmax
        net = net.to(self.dev)
        net.init_bhwd(batch, h, w, self.dev, amp=False)
        net._iters = iters
        return net

    @torch.no_grad()
    def midframes(self, a, b, t, which):
        """Every candidate for moment t between a and b (1080p tensors). Returns {name: tensor}, extras."""
        out, extra = {}, {}
        if "rife480" in which:
            f0, f1, m = run_rife(self.rife_small, a, b, t, (288, 480))
            out["rife480"] = warp_blend(a, b, f0, f1, m)
        if "rife640" in which:
            f0, f1, m = run_rife(self.rife_small, a, b, t, (384, 640))
            out["rife640"] = warp_blend(a, b, f0, f1, m)
        if "rife1088" in which:
            f0, f1, m = run_rife(self.rife_full, a, b, t, (1088, 1920))
            out["rife1088"] = warp_blend(a, b, f0, f1, m)
            extra["motion"] = f0.norm(dim=1)[0] / max(t, 1e-3)  # motion across the whole gap
        if "neuflow512" in which or "neuflow512occ" in which:
            f01, f10 = run_neuflow(self.nf512, a, b, (288, 512))
            ft0, ft1 = reversal(f01, f10, t)
            out["neuflow512"] = warp_blend(a, b, ft0, ft1, torch.full_like(ft0[:, :1], 1 - t))
            if "neuflow512occ" in which:
                out["neuflow512occ"] = warp_blend(a, b, ft0, ft1, occlusion_weights(f01, f10, ft0, ft1, t))
            if "neuflow512vis" in which:
                out["neuflow512vis"] = warp_blend(a, b, ft0, ft1, occlusion_weights(f01, f10, ft0, ft1, t, prefer_unmatched=True))
        return out, extra

    @torch.no_grad()
    def quarter(self, a, b, ts):
        """4× from one pair: {name: [frame per t]}."""
        res = {}
        for name, size, net in (("rife480", (288, 480), self.rife_small), ("rife640", (384, 640), self.rife_small)):
            f0, f1, m = run_rife(net, a, b, 0.5, size)
            f01, f10 = 2 * f1, 2 * f0  # F½→1 ≈ ½·F0→1, F½→0 ≈ ½·F1→0 for linear motion
            frames = []
            for t in ts:
                if t == 0.5:
                    frames.append(warp_blend(a, b, f0, f1, m))
                else:
                    ft0, ft1 = reversal(f01, f10, t)
                    frames.append(warp_blend(a, b, ft0, ft1, torch.full_like(ft0[:, :1], 1 - t)))
            res[f"{name}-derived"] = frames
        res["rife480-direct"] = []
        res["rife1088-direct"] = []
        for t in ts:
            f0, f1, m = run_rife(self.rife_small, a, b, t, (288, 480))
            res["rife480-direct"].append(warp_blend(a, b, f0, f1, m))
            f0, f1, m = run_rife(self.rife_full, a, b, t, (1088, 1920))
            res["rife1088-direct"].append(warp_blend(a, b, f0, f1, m))
        f01, f10 = run_neuflow(self.nf512, a, b, (288, 512))
        res["neuflow512"], res["neuflow512occ"], res["neuflow512vis"] = [], [], []
        for t in ts:
            ft0, ft1 = reversal(f01, f10, t)
            res["neuflow512"].append(warp_blend(a, b, ft0, ft1, torch.full_like(ft0[:, :1], 1 - t)))
            res["neuflow512occ"].append(warp_blend(a, b, ft0, ft1, occlusion_weights(f01, f10, ft0, ft1, t)))
            res["neuflow512vis"].append(warp_blend(a, b, ft0, ft1, occlusion_weights(f01, f10, ft0, ft1, t, prefer_unmatched=True)))
        return res

    @torch.no_grad()
    def disparity(self, left, right):
        """Left→right flow at full size (x: horizontal disparity, y: vertical)."""
        d, _ = run_neuflow(self.nf_disp, left, right, (1088, 1920), bidirectional=False)
        return d


# ---------------------------------------------------------------- accumulation


class Score:
    def __init__(self):
        self.psnr, self.ssim, self.mse_mov, self.n_mov, self.ssim_mov = [], [], 0.0, 0, 0.0

    def add(self, ref_y, y, moving):
        se = (ref_y - y) ** 2
        self.psnr.append(psnr(se.mean().item()))
        sm = ssim_map(ref_y, y)
        self.ssim.append(sm.mean().item())
        if moving is not None:
            k = int(moving.sum().item())
            self.mse_mov += se[moving].sum().item()
            self.ssim_mov += sm[moving].sum().item()
            self.n_mov += k
        return se

    def row(self):
        return {"psnr": float(np.mean(self.psnr)), "ssim": float(np.mean(self.ssim)),
                "psnr_moving": psnr(self.mse_mov / self.n_mov) if self.n_mov else None,
                "ssim_moving": self.ssim_mov / self.n_mov if self.n_mov else None, "n": len(self.psnr)}


def save_strip(path, tiles, labels):
    from PIL import Image, ImageDraw
    th, tw = tiles[0].shape[:2]
    pad = 18
    img = Image.new("RGB", (tw * len(tiles), th + pad), (0, 0, 0))
    d = ImageDraw.Draw(img)
    for i, (t, lab) in enumerate(zip(tiles, labels)):
        img.paste(Image.fromarray(t), (i * tw, pad))
        d.text((i * tw + 4, 3), lab, fill=(255, 255, 255))
    img.save(path)


def to_u8(x):
    return (x.clamp(0, 1)[0].permute(1, 2, 0) * 255).round().byte().cpu().numpy()


def worst_window(se, k=256):
    """Top-left (y, x) of the k×k window with the highest mean squared error."""
    pooled = F.avg_pool2d(se[None, None], k // 4, stride=k // 8)[0, 0]
    # windows of k from k/4 pools: average 4×4 neighbourhood of pools (stride k/8 → 7 steps)
    pooled = F.avg_pool2d(pooled[None, None], 7, stride=1)[0, 0]
    iy, ix = divmod(int(pooled.argmax()), pooled.shape[1])
    return min(iy * k // 8, H - k), min(ix * k // 8, W - k), pooled.max().item()


# ---------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--rife", default="build/interp-spike/dl/rife425lite/train_log")
    ap.add_argument("--neuflow", default="build/interp-spike/NeuFlow_v2")
    ap.add_argument("--vt-helper", default="build/interp-quality/vt-interp-helper")
    ap.add_argument("--out", default="build/interp-quality")
    ap.add_argument("--stride", type=int, default=2, help="step between 2× test triplets")
    ap.add_argument("--stereo-every", type=int, default=4, help="stereo check on every Nth 2× triplet")
    ap.add_argument("--limit", type=int, default=0, help="max 2× triplets per clip (0 = all)")
    ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    args = ap.parse_args()

    dev = torch.device(args.device)
    out = Path(args.out)
    (out / "crops").mkdir(parents=True, exist_ok=True)
    scratch = out / "scratch"
    scratch.mkdir(exist_ok=True)
    models = Models(args, dev)
    helper = Path(args.vt_helper)

    half_names = ["repeat", "blend", "vt", "rife480", "rife640", "rife1088", "neuflow512", "neuflow512occ",
                  "neuflow512vis"]
    quarter_names = ["repeat", "blend", "vt", "rife480-derived", "rife640-derived", "rife480-direct",
                     "rife1088-direct", "neuflow512", "neuflow512occ", "neuflow512vis"]
    stereo_names = ["vt", "rife480", "rife640", "neuflow512occ"]
    results = {"half": {}, "quarter": {}, "stereo": {}, "crops": []}
    tot_half = {n: Score() for n in half_names}
    tot_q = {(n, t): Score() for n in quarter_names for t in (0.25, 0.5, 0.75)}
    stereo_acc = {n: {} for n in stereo_names + ["real"]}

    for clip in args.clips:
        name = Path(clip).stem
        print(f"== {name}", flush=True)
        rgb, i420 = read_clip(clip)
        n = rgb.shape[0]
        # cut guard: skip a triplet whose ends differ far more than usual
        ly = rgb[:, 0, ::8, ::8].astype(np.float32).mean(-1)
        d2 = np.array([np.abs(ly[i + 2] - ly[i]).mean() for i in range(n - 2)])
        cut = d2 > max(4 * np.median(d2), 25)
        idx = [i for i in range(0, n - 2, args.stride) if not cut[i]]
        if args.limit:
            idx = idx[:args.limit]
        stereo_idx = set(idx[::args.stereo_every])
        qidx = [i for i in range(0, n - 4, 4) if not (cut[i] or cut[i + 2])]
        if args.limit:
            qidx = qidx[:max(1, args.limit // 2)]

        # VideoToolbox in one batch per clip and eye
        vt_half = {e: vt_interpolate(helper, [(i420[i, e], i420[i + 2, e]) for i in idx], [0.5], scratch)
                   for e in (0, 1)}
        vt_q = vt_interpolate(helper, [(i420[i, 0], i420[i + 4, 0]) for i in qidx], [0.25, 0.5, 0.75], scratch)

        clip_half = {k: Score() for k in half_names}
        worst = (-1, None)
        for k, i in enumerate(idx):
            eyes = (0, 1) if i in stereo_idx else (0,)
            mids = {}
            for e in eyes:
                a, real, b = (tensor(rgb[j, e], dev) for j in (i, i + 1, i + 2))
                which = half_names if e == 0 else stereo_names
                cand, extra = models.midframes(a, b, 0.5, which)
                cand["vt"] = tensor(vt_half[e][k, 0], dev)
                if e == 0:
                    cand["repeat"], cand["blend"] = a, 0.5 * (a + b)
                    ry = luma(real)
                    moving = (extra["motion"] / 2) >= 4.0  # per-frame motion over a 2-frame gap
                    errs = {}
                    for cn in half_names:
                        se = clip_half[cn].add(ry, luma(cand[cn]), moving)
                        tot_half[cn].add(ry, luma(cand[cn]), moving)
                        errs[cn] = se
                    y0, x0, score = worst_window(errs["rife480"])
                    if score > worst[0]:
                        worst = (score, (i, y0, x0, {cn: to_u8(cand[cn][:, :, y0:y0 + 256, x0:x0 + 256])
                                                     for cn in ["blend", "vt", "rife480", "rife640", "rife1088",
                                                                "neuflow512occ"]},
                                         to_u8(real[:, :, y0:y0 + 256, x0:x0 + 256])))
                mids[e] = cand
            if i in stereo_idx:
                L = [tensor(rgb[j, 0], dev) for j in (i, i + 1, i + 2)]
                R = [tensor(rgb[j, 1], dev) for j in (i, i + 1, i + 2)]
                d0, dm, d2_ = (models.disparity(L[j], R[j]) for j in range(3))
                drl, _ = run_neuflow(models.nf_disp, R[1], L[1], (1088, 1920), bidirectional=False)
                back = conv.backwarp(drl, dm)
                valid = ((dm + back).norm(dim=1)[0] < 1.0)
                avg_h = 0.5 * (d0[0, 0] + d2_[0, 0])
                for sn in ["real"] + stereo_names:
                    if sn == "real":
                        d, lp, rp = dm, L[1], R[1]
                    else:
                        lp, rp = mids[0][sn], mids[1][sn]
                        d = models.disparity(lp, rp)
                    dev_h = (d[0, 0] - avg_h).abs()[valid]
                    err_h = (d[0, 0] - dm[0, 0]).abs()[valid]
                    v_abs = d[0, 1].abs()[valid]
                    # Rivalry, photometrically: the right eye carried onto the left by the *real*
                    # in-between pair's disparity. An error both eyes share cancels here.
                    lr = (luma(lp) - luma(conv.backwarp(rp, dm)))[valid].abs()
                    row = {"dev": dev_h.median().item(), "err": err_h.median().item(),
                           "over1": (err_h > 1.0).float().mean().item(),
                           "over4": (err_h > 4.0).float().mean().item(),
                           "vabs": v_abs.median().item(), "v_over1": (v_abs > 1.0).float().mean().item(),
                           "lr": lr.mean().item(), "lr_over10": (lr > 10).float().mean().item()}
                    for key, val in row.items():
                        stereo_acc[sn].setdefault(key, []).append(val)
                    results["stereo"].setdefault(name, {}).setdefault(sn, []).append(row)
            print(f"   t=½ {k + 1}/{len(idx)} (frame {i})", end="\r", flush=True)
        print()
        results["half"][name] = {cn: s.row() for cn, s in clip_half.items()}

        # 4× stress test
        clip_q = {(cn, t): Score() for cn in quarter_names for t in (0.25, 0.5, 0.75)}
        for k, i in enumerate(qidx):
            a, b = tensor(rgb[i, 0], dev), tensor(rgb[i + 4, 0], dev)
            res = models.quarter(a, b, (0.25, 0.5, 0.75))
            _, extra = models.midframes(a, b, 0.5, ["rife1088"])
            moving = (extra["motion"] / 4) >= 4.0  # per-frame motion over a 4-frame gap
            for j, t in enumerate((0.25, 0.5, 0.75)):
                ry = luma(tensor(rgb[i + 1 + j, 0], dev))
                res["vt"] = res.get("vt", []) + [tensor(vt_q[k, j], dev)]
                res["repeat"] = res.get("repeat", []) + [a if t < 0.5 else (b if t > 0.5 else a)]
                res["blend"] = res.get("blend", []) + [(1 - t) * a + t * b]
                for cn in quarter_names:
                    y = luma(res[cn][j])
                    clip_q[(cn, t)].add(ry, y, moving)
                    tot_q[(cn, t)].add(ry, y, moving)
            print(f"   4× {k + 1}/{len(qidx)}", end="\r", flush=True)
        print()
        results["quarter"][name] = {f"{cn}@{t}": s.row() for (cn, t), s in clip_q.items()}

        if worst[1]:
            i, y0, x0, tiles, real = worst[1]
            p = out / "crops" / f"{name}-f{i + 1:03d}-y{y0}-x{x0}.png"
            labels = ["real"] + list(tiles)
            save_strip(p, [real] + list(tiles.values()), labels)
            results["crops"].append(str(p))
            print(f"   worst region: {p}")

        # per-clip summary
        for cn in half_names:
            r = results["half"][name][cn]
            print(f"   {cn:14s} PSNR {r['psnr']:6.2f}  SSIM {r['ssim']:.4f}  moving PSNR "
                  f"{(r['psnr_moving'] or float('nan')):6.2f}")

    results["half"]["ALL"] = {cn: s.row() for cn, s in tot_half.items()}
    results["quarter"]["ALL"] = {f"{cn}@{t}": s.row() for (cn, t), s in tot_q.items()}
    results["stereo"]["ALL"] = {sn: {k: float(np.mean(v)) for k, v in acc.items()} for sn, acc in stereo_acc.items()
                                if acc}
    (out / "results.json").write_text(json.dumps(results, indent=1))

    print("\n## 2×, t = ½, all clips (left eye)")
    print("| candidate | PSNR | SSIM | moving PSNR | moving SSIM |")
    print("| --- | --- | --- | --- | --- |")
    for cn, r in results["half"]["ALL"].items():
        print(f"| {cn} | {r['psnr']:.2f} | {r['ssim']:.4f} | {r['psnr_moving'] or float('nan'):.2f} | "
              f"{r['ssim_moving'] or float('nan'):.4f} |")
    print("\n## per clip, PSNR (moving PSNR)")
    clips = [c for c in results["half"] if c != "ALL"]
    print("| candidate | " + " | ".join(clips) + " |")
    print("| --- |" + " --- |" * len(clips))
    for cn in half_names:
        cells = [f"{results['half'][c][cn]['psnr']:.2f} ({results['half'][c][cn]['psnr_moving'] or float('nan'):.2f})"
                 for c in clips]
        print(f"| {cn} | " + " | ".join(cells) + " |")
    print("\n## 4× stress test (i, i+4), PSNR at t = ¼ / ½ / ¾ (moving PSNR)")
    for cn in quarter_names:
        cells = []
        for t in (0.25, 0.5, 0.75):
            r = results["quarter"]["ALL"][f"{cn}@{t}"]
            cells.append(f"{r['psnr']:.2f} ({r['psnr_moving'] or float('nan'):.2f})")
        print(f"| {cn} | " + " | ".join(cells) + " |")
    print("\n## stereo, t = ½, eyes interpolated independently (px; real = the real i+1 pair, the control)")
    print("| candidate | median |Dh − neighbours' mean| | median |Dh − real| | > 1 px | > 4 px "
          "| median |Dv| | |Dv| > 1 px | L−R residual | residual > 10 |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for sn, r in results["stereo"]["ALL"].items():
        print(f"| {sn} | {r['dev']:.2f} | {r['err']:.2f} | {r['over1'] * 100:.1f}% | {r['over4'] * 100:.1f}% | "
              f"{r['vabs']:.2f} | {r['v_over1'] * 100:.1f}% | {r['lr']:.2f} | {r['lr_over10'] * 100:.1f}% |")
    print("\ncrops:\n" + "\n".join(results["crops"]))


if __name__ == "__main__":
    main()
