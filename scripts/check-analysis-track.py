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
Checks an analysis track from `vergence analyze` (Vergence's Swift + Core ML producer) against the
PyTorch reference of scripts/stereo-shared-field.py, on frames left out of the track.

    ffmpeg -i CLIP.mkv -vf "select=not(mod(n\\,2))" -f rawvideo -pix_fmt yuv420p - \\
      | vergence analyze --raw 1920x1080 - --models build/interp-models -o CLIP.vgat
    uv run scripts/check-analysis-track.py CLIP.mkv CLIP.vgat [--requantize 16] [--metal MID.bgra]

The track then holds every other frame, so each of its flow pairs (2k, 2k+2) has a real frame
2k+1 in between. For each, the in-between pair is made the way the headset will (option E): the
left eye from the stored flow and mask, the right eye from the left eye's flow read across by the
stored right→left disparity. It is scored against the real frame (PSNR, left and right) next to
the same pipeline run in PyTorch at full precision (RIFE 480 and NeuFlow 512 run here), and the
two renders against each other: how much the Core ML conversion, the Swift resize, the 4× smaller
storage and the quantisation cost together.

--requantize N rounds the stored fields to 1/N of a stored pixel before rendering and reports the
deflated size that would have, to choose the producer's step.

--metal MID.bgra scores the player's own render too: Vergence's `SharedFieldInterpolator` (the
Metal pass the headset runs), as `vergence interpolate` writes it from the same even frames:

    ffmpeg -i CLIP.mkv -vf "select=not(mod(n\\,2)),SCALE" -fps_mode passthrough -f rawvideo -pix_fmt bgra - \\
      | vergence interpolate --raw 1920x1080 - --fields CLIP.vgat -o MID.bgra

(SCALE as `interp-quality.py`'s SCALE_FLAGS, so its frames are this script's.)
"""
import argparse
import importlib.util
import json
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("stereo_shared_field", HERE / "stereo-shared-field.py")
ssf = importlib.util.module_from_spec(_spec)
sys.modules["stereo_shared_field"] = ssf
_spec.loader.exec_module(ssf)
iq, np, torch, F = ssf.iq, ssf.np, ssf.torch, ssf.F
H, W = iq.H, iq.W

KINDS = {1: "flowPair", 2: "disparity", 3: "depth", 4: "gainMap"}


def read_track(path):
    """VGAT (Vergence `AnalysisTrack.swift`) → header, [record dict with float values [c,h,w]]."""
    data = Path(path).read_bytes()
    assert data[:4] == b"VGAT" and data[4] == 1, "not a version 1 analysis track"
    (hlen,) = struct.unpack_from("<I", data, 5)
    header = json.loads(data[9:9 + hlen])
    pos, records = 9 + hlen, []
    while pos < len(data):
        (length,) = struct.unpack_from("<I", data, pos)
        body = data[pos + 4:pos + 4 + length]
        pos += 4 + length
        kind, eye, enc, ch, w, h = struct.unpack_from("<BBBBHH", body, 0)
        value, end, scale_ts = struct.unpack_from("<qqi", body, 8)
        scale, offset = struct.unpack_from("<ff", body, 28)
        payload = body[36:]
        deflated, enc = bool(enc & 0x80), enc & 0x7F
        dtype = {1: np.float16, 2: np.int16, 3: np.uint8}[enc]
        if deflated:
            payload = zlib.decompress(payload, -15)
        raw = np.frombuffer(payload, dtype=dtype).reshape(ch * h, w)
        if deflated:  # row deltas, wrapping in the raw integer type
            view = raw.view(np.uint16 if raw.itemsize == 2 else np.uint8)
            raw = np.cumsum(view, axis=1, dtype=view.dtype).view(dtype)
        values = raw.astype(np.float32).reshape(ch, h, w) * scale + offset
        records.append({"kind": KINDS[kind], "eye": eye, "time": value / scale_ts, "end": end / scale_ts,
                        "values": values, "bytes": 4 + length})
    return header, records


def up(field, dev, units=True):
    """[c,h,w] stored field → [1,c,1080,1920] tensor; units: (x, y) pixel pairs scaled to 1080p."""
    t = torch.from_numpy(np.ascontiguousarray(field))[None].to(dev)
    out = F.interpolate(t, size=(H, W), mode="bilinear", align_corners=False)
    if not units:
        return out
    scale = torch.tensor([W / field.shape[2], H / field.shape[1]] * (field.shape[0] // 2) + [W / field.shape[2]]
                         * (field.shape[0] % 2), device=dev, dtype=out.dtype).view(1, -1, 1, 1)
    return out * scale


def deflated_size(values, step):
    q = np.round(values / step).astype(np.int16)
    d = np.diff(q.reshape(-1, q.shape[-1]), axis=1, prepend=0).astype(np.int16)
    return len(zlib.compress(d.tobytes(), 6))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clip")
    ap.add_argument("track")
    ap.add_argument("--rife", default="build/interp-spike/dl/rife425lite/train_log")
    ap.add_argument("--neuflow", default="build/interp-spike/NeuFlow_v2")
    ap.add_argument("--requantize", type=float, default=0, help="round stored fields to 1/N stored px")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--metal", help="in-between frames from `vergence interpolate` (packed BGRA)")
    ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    args = ap.parse_args()
    dev = torch.device(args.device)

    header, records = read_track(args.track)
    flows = sorted((r for r in records if r["kind"] == "flowPair"), key=lambda r: r["time"])
    disp = {round(r["time"], 4): r for r in records if r["kind"] == "disparity" and r["eye"] == 2}
    times = sorted(disp)
    print(f"{header['models']}; {len(flows)} flow pairs, {len(disp)} disparities, "
          f"{sum(r['bytes'] for r in records) / max(len(disp), 1) / 1024:.1f} KB a frame")

    models = iq.Models(argparse.Namespace(rife=args.rife, neuflow=args.neuflow), dev)
    est = ssf.Disparity(models)
    rgb, _ = iq.read_clip(args.clip)
    p = lambda a, b: iq.psnr(((iq.luma(a) - iq.luma(b)) ** 2).mean().item())  # noqa: E731
    rows, sizes, metal_rows = [], [], []
    metal = np.memmap(args.metal, np.uint8, "r").reshape(-1, 2 * H, W, 4) if args.metal else None
    for k, rec in enumerate(flows[:args.limit or None]):
        i = 2 * times.index(round(rec["time"], 4))  # track frame k is clip frame 2k
        L = [iq.tensor(rgb[j, 0], dev) for j in (i, i + 1, i + 2)]
        R = [iq.tensor(rgb[j, 1], dev) for j in (i, i + 1, i + 2)]
        fv = rec["values"]
        d0 = disp[round(rec["time"], 4)]["values"]
        d1 = disp[round(rec["end"], 4)]["values"]
        if args.requantize:
            step = 1 / args.requantize
            fv = np.concatenate([np.round(fv[:4] / step) * step, fv[4:]])
            d0, d1 = np.round(d0 / step) * step, np.round(d1 / step) * step
            sizes.append(deflated_size(fv[:4], step) + deflated_size(fv[4:], 1 / 64)
                         + deflated_size(d0, step))
        with torch.no_grad():
            # Track: F½→1 = F0→1 / 2, F½→0 = F1→0 / 2 (the mask says RIFE ran at ½).
            f01, f10 = up(fv[0:2], dev), up(fv[2:4], dev)
            ft0, ft1 = f10 / 2, f01 / 2
            m = up(fv[4:5], dev, units=False).clamp(0, 1)
            dd0, dd1 = (ssf.horizontal(torch.cat([up(d, dev), torch.zeros_like(up(d, dev))], 1)) for d in (d0, d1))
            left = iq.warp_blend(L[0], L[2], ft0, ft1, m)
            rt0, rt1, rm, _ = ssf.transfer(ft0, ft1, m, dd0, dd1, 0.5)
            right = iq.warp_blend(R[0], R[2], rt0, rt1, rm)
            # Reference: PyTorch at full precision and size.
            g0, g1, gm = iq.run_rife(models.rife_small, L[0], L[2], 0.5, (288, 480))
            ref_left = iq.warp_blend(L[0], L[2], g0, g1, gm)
            _, e0 = est.small(L[0], R[0])
            _, e1 = est.small(L[2], R[2])
            q0, q1, qm, _ = ssf.transfer(g0, g1, gm, e0, e1, 0.5)
            ref_right = iq.warp_blend(R[0], R[2], q0, q1, qm)
            rows.append([p(L[1], left), p(L[1], ref_left), p(R[1], right), p(R[1], ref_right),
                         p(ref_left, left), p(ref_right, right),
                         (ft0 - g0).norm(dim=1).median().item(), (dd0 - e0).norm(dim=1).median().item()])
            if metal is not None and k < len(metal) and metal[k].any():
                bgr = torch.from_numpy(np.array(metal[k][..., [2, 1, 0]])).to(dev).permute(2, 0, 1)[None].float() / 255
                ml, mr = bgr[:, :, :H], bgr[:, :, H:]
                metal_rows.append([p(L[1], ml), p(R[1], mr), p(left, ml), p(right, mr)])
        print(f"   {k + 1}/{len(flows)}", end="\r", flush=True)
    r = np.mean(rows, 0)
    print(f"\nleft  PSNR: track {r[0]:.2f}, PyTorch {r[1]:.2f}  (track vs PyTorch render {r[4]:.2f})")
    print(f"right PSNR: track {r[2]:.2f}, PyTorch {r[3]:.2f}  (track vs PyTorch render {r[5]:.2f})")
    print(f"median field difference at 1080p: flow {r[6]:.2f} px, disparity {r[7]:.2f} px")
    if metal_rows:
        m = np.mean(metal_rows, 0)
        print(f"Metal ({len(metal_rows)} frames): left {m[0]:.2f}, right {m[1]:.2f} dB against the real frame; "
              f"against this script's track render {m[2]:.2f} / {m[3]:.2f} dB")
    if sizes:
        print(f"requantized to 1/{args.requantize:g} px: ~{np.mean(sizes) / 1024:.1f} KB a frame deflated")


if __name__ == "__main__":
    main()
