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
The right eye of a Smooth Motion in-between pair, made from the left eye's motion
(docs/plans/blu-ray-3d-smooth-motion.md, option E step 4 and option B), measured
against eyes interpolated independently (option A).

    uv run scripts/stereo-shared-field.py build/interp-quality/*.mkv [--stride 4] [--limit N]

Same clips, models and helper as scripts/interp-quality.py (imported from it). For each
triplet (i, i+1, i+2) the in-between pair at t = ½ is made by:

    A-vt        each eye by VideoToolbox, independently (what ships for 2D today)
    A-rife      each eye by RIFE 4.25 lite 480×288, independently
    E           left by RIFE 480; the right eye's flow is the left eye's read across by
                disparity (F_R(x) = F_L(x + D(x)), D mixed in place between the real pairs) and
                the *real right eyes* are warped along it. Disparity is NeuFlow 512×288, both
                directions, on the real pairs i and i+2 (what the headset can run: 14 ms).
                Vertical disparity is forced to 0: a 3D Blu-ray is rectified.
    E-ref       E with the quarter-size disparity sharpened at full size by picking, per pixel,
                the neighbouring low-res value whose left/right match is best (a 25-tap shader)
    E-hy        horizontal motion from the right eye's own RIFE run, vertical from E (two runs)
    B-mc        B-rife with each real pair's disparity read where E's right-eye flow says the
                pixel was, rather than in place
    E+B         E, switching to B-mc where E's and B-mc's right eyes disagree (the shared flow is
                wrong there; copying the left picture at least keeps the pair consistent)
    E-fb        E, where the real pairs' left→right and right→left disagree (content only the
                right eye sees: the left eye's motion there belongs to whatever hides it), the
                right eye's own RIFE result instead (a second 12 ms run on the right eye)
    E-blend     E, the same places filled by blending the real right eyes by phase (no second run)
    B-vt        left by VideoToolbox; right = that left eye moved sideways by disparity
                interpolated in place between the real pairs; right-only places from the real
                right eyes blended by phase (the VideoToolbox-only fallback)
    B-rife      the same from RIFE's left eye

Measured on the in-between pair, against the real i+1 pair, as in interp-quality.py's stereo
table (NeuFlow at full size, pixels where the real pair's two directions agree within 1 px):
vertical disparity (pure rivalry on a rectified disc; the real pairs show 0.1–1.2%, the
estimator's noise; also counted on detailed pixels only), horizontal disparity against the real pair's, and the right eye's own
PSNR against the real right frame it replaces.
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("interp_quality", HERE / "interp-quality.py")
iq = importlib.util.module_from_spec(_spec)
sys.modules["interp_quality"] = iq
_spec.loader.exec_module(iq)

np, torch, F, conv = iq.np, iq.torch, iq.F, iq.conv
H, W = iq.H, iq.W
backwarp = conv.backwarp


def horizontal(d):
    """A rectified pair has no vertical disparity: keep only x."""
    return torch.cat([d[:, :1], torch.zeros_like(d[:, 1:])], 1)


def lr_valid(d_rl, d_lr, tol=2.0):
    """Soft 1 where a right-eye pixel's match in the left eye comes back to it (within tol px)."""
    e = (d_rl + backwarp(d_lr, d_rl))[:, :1].abs()
    return torch.sigmoid((tol - e) * 2.0)


def transfer(ft0_l, ft1_l, m_l, d0rl, d1rl, t):
    """Right-eye flows and mask at t from the left eye's, through disparity (plan: F_R(x) ≈ F_L(x + D(x))).

    A right pixel x at time t sits at x + Dt(x) in the left eye, Dt the in-place mix of the real
    pairs' right→left disparities, and moves as the left eye does there. The change in disparity
    over half a frame is left out on purpose: adding it means reading disparity a second time, at
    the moved position in the real frame, and near a silhouette either read can land on the
    other depth layer. On the crowd pan that cost 7 dB of the right eye's PSNR (a doubled outline
    along the foreground); one read costs 0.7 dB against the right eye's own RIFE flow.
    """
    dt = (1 - t) * d0rl + t * d1rl
    return backwarp(ft0_l, dt), backwarp(ft1_l, dt), backwarp(m_l, dt), dt


def refine(d, src, dst, step=1920 / 512, r=2, box=7):
    """Edge-aware upsampling of a quarter-size disparity: per pixel, the candidate from d's
    (2r+1)² low-res neighbourhood whose match dst ≈ backwarp(src, d) is best over a box×box
    patch. A shader on the headset (25 taps)."""
    ys = iq.luma(dst)[None, None]
    cands, costs = [], []
    for oy in range(-r, r + 1):
        for ox in range(-r, r + 1):
            off = torch.zeros_like(d)
            off[:, 0], off[:, 1] = ox * step, oy * step
            c = backwarp(d, off)
            cost = (iq.luma(backwarp(src, c))[None, None] - ys).abs()
            cands.append(c)
            costs.append(F.avg_pool2d(cost, box, 1, box // 2))
    k = torch.cat(costs, 1).argmin(1, keepdim=True)
    return torch.gather(torch.stack(cands, 1), 1, k[:, :, None].expand(-1, -1, 2, -1, -1))[:, 0]


class Disparity:
    def __init__(self, models):
        self.m = models

    @torch.no_grad()
    def small(self, left, right):
        """NeuFlow 512×288, one batched run: (L→R, R→L) at 1080p, horizontal only."""
        lr, rl = iq.run_neuflow(self.m.nf512, left, right, (288, 512))
        return horizontal(lr), horizontal(rl)


@torch.no_grad()
def candidates(models, disp, L, R, vt_l, vt_r, t=0.5):
    """L, R: the real eyes at i, i+2 (index 0, 1). Returns {name: (left, right)}, extras."""
    a, b = L
    ft0, ft1, m = iq.run_rife(models.rife_small, a, b, t, (288, 480))
    rife_l = iq.warp_blend(a, b, ft0, ft1, m)
    r_ft0, r_ft1, r_m = iq.run_rife(models.rife_small, R[0], R[1], t, (288, 480))
    rife_r = iq.warp_blend(R[0], R[1], r_ft0, r_ft1, r_m)
    out = {"A-vt": (vt_l, vt_r), "A-rife": (rife_l, rife_r)}

    phase_blend = (1 - t) * R[0] + t * R[1]
    d0lr, d0rl = disp.small(L[0], R[0])
    d1lr, d1rl = disp.small(L[1], R[1])
    rt0, rt1, rm, dt = transfer(ft0, ft1, m, d0rl, d1rl, t)
    right = iq.warp_blend(R[0], R[1], rt0, rt1, rm)
    out["E"] = (rife_l, right)
    e0, e1 = refine(d0rl, L[0], R[0]), refine(d1rl, L[1], R[1])
    q0, q1, qm, _ = transfer(ft0, ft1, m, e0, e1, t)
    out["E-ref"] = (rife_l, iq.warp_blend(R[0], R[1], q0, q1, qm))
    # Hybrid: the right eye's own RIFE run for horizontal motion (depth), the left eye's carried
    # across for vertical (the rivalry). Two RIFE runs.
    h0 = torch.cat([r_ft0[:, :1], rt0[:, 1:]], 1)
    h1 = torch.cat([r_ft1[:, :1], rt1[:, 1:]], 1)
    out["E-hy"] = (rife_l, iq.warp_blend(R[0], R[1], h0, h1, r_m))
    # Right-only content at t (the left eye's motion there belongs to whatever hides it): where
    # the real pairs' left→right and right→left disagree at the right pixel's source, the right
    # eye's own RIFE result (E-fb, a second run) or the real right eyes blended (E-blend).
    v0 = backwarp(lr_valid(d0rl, d0lr), rt0)
    v1 = backwarp(lr_valid(d1rl, d1lr), rt1)
    ok = torch.maximum(v0, v1)
    out["E-fb"] = (rife_l, right * ok + rife_r * (1 - ok))
    out["E-blend"] = (rife_l, right * ok + phase_blend * (1 - ok))
    # Option B: the in-between left eye moved across by disparity mixed in place.
    ok_b = (1 - t) * lr_valid(d0rl, d0lr) + t * lr_valid(d1rl, d1lr)
    for name, left in (("B-vt", vt_l), ("B-rife", rife_l)):
        out[name] = (left, backwarp(left, dt) * ok_b + phase_blend * (1 - ok_b))
    # B with motion-compensated disparity: each real pair's disparity read where E's right-eye
    # flow says the pixel was, instead of in place (moving objects get one depth, not two).
    dmc = (1 - t) * backwarp(d0rl, rt0) + t * backwarp(d1rl, rt1)
    b_mc = backwarp(rife_l, dmc) * ok_b + phase_blend * (1 - ok_b)
    out["B-mc"] = (rife_l, b_mc)
    # E where the flow can be trusted, B-mc where it can't: E's right eye and B's right eye are
    # two independent guesses at the same picture; where they disagree (> ~12 of 255 in luma,
    # over a 9×9 patch), the shared flow is wrong there and the right eye is copied from the
    # left in-between picture so at least the pair agrees.
    diff = F.avg_pool2d((iq.luma(right) - iq.luma(b_mc)).abs()[None, None], 9, 1, 4) / 255.0
    trust = torch.sigmoid((12 / 255.0 - diff) * 255.0 / 3.0)
    out["E+B"] = (rife_l, right * trust + b_mc * (1 - trust))
    extra = {"right_only": float((ok < 0.5).float().mean()), "untrusted": float((trust < 0.5).float().mean())}
    return out, extra


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--rife", default="build/interp-spike/dl/rife425lite/train_log")
    ap.add_argument("--neuflow", default="build/interp-spike/NeuFlow_v2")
    ap.add_argument("--vt-helper", default="build/interp-quality/vt-interp-helper")
    ap.add_argument("--out", default="build/interp-quality/stereo")
    ap.add_argument("--stride", type=int, default=4, help="step between triplets")
    ap.add_argument("--limit", type=int, default=0, help="max triplets per clip (0 = all)")
    ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    args = ap.parse_args()

    dev = torch.device(args.device)
    out = Path(args.out)
    (out / "crops").mkdir(parents=True, exist_ok=True)
    scratch = out / "scratch"
    scratch.mkdir(exist_ok=True)
    models = iq.Models(args, dev)
    disp = Disparity(models)
    helper = Path(args.vt_helper)
    names = ["real", "A-vt", "A-rife", "E", "E-ref", "E-hy", "E-fb", "E-blend", "B-vt", "B-rife", "B-mc", "E+B"]
    acc = {n: {} for n in names}
    per_clip = {}
    right_only = []
    untrusted = []

    for clip in args.clips:
        name = Path(clip).stem
        print(f"== {name}", flush=True)
        rgb, i420 = iq.read_clip(clip)
        n = rgb.shape[0]
        ly = rgb[:, 0, ::8, ::8].astype(np.float32).mean(-1)
        d2 = np.array([np.abs(ly[i + 2] - ly[i]).mean() for i in range(n - 2)])
        cut = d2 > max(4 * np.median(d2), 25)
        idx = [i for i in range(0, n - 2, args.stride) if not cut[i]]
        if args.limit:
            idx = idx[:args.limit]
        vt = {e: iq.vt_interpolate(helper, [(i420[i, e], i420[i + 2, e]) for i in idx], [0.5], scratch)
              for e in (0, 1)}
        clip_acc = {n_: {} for n_ in names}
        worst = (-1.0, None)
        for k, i in enumerate(idx):
            L = [iq.tensor(rgb[j, 0], dev) for j in (i, i + 1, i + 2)]
            R = [iq.tensor(rgb[j, 1], dev) for j in (i, i + 1, i + 2)]
            cand, extra = candidates(models, disp, (L[0], L[2]), (R[0], R[2]),
                                     iq.tensor(vt[0][k, 0], dev), iq.tensor(vt[1][k, 0], dev))
            right_only.append(extra["right_only"])
            untrusted.append(extra["untrusted"])
            cand["real"] = (L[1], R[1])
            # The measurement, as in interp-quality.py.
            d0, dm, d2_ = (models.disparity(L[j], R[j]) for j in range(3))
            drl, _ = iq.run_neuflow(models.nf_disp, R[1], L[1], (1088, 1920), bidirectional=False)
            valid = ((dm + backwarp(drl, dm)).norm(dim=1)[0] < 1.0)
            # Detail: a disparity estimator only measures where there is something to match, and
            # rivalry is only visible there. Local luma standard deviation (9×9) ≥ 4 of 255 on the
            # real left eye; featureless dark sky and smoke otherwise dominate the vertical count
            # with the estimator's own guesses.
            ly1 = iq.luma(L[1])[None, None]
            mu = F.avg_pool2d(ly1, 9, 1, 4)
            sd = (F.avg_pool2d(ly1 * ly1, 9, 1, 4) - mu * mu).clamp(min=0).sqrt()[0, 0]
            textured = sd[valid] >= 4.0
            ry = iq.luma(R[1])
            for cn in names:
                lp, rp = cand[cn]
                d = dm if cn == "real" else models.disparity(lp, rp)
                err_h = (d[0, 0] - dm[0, 0]).abs()[valid]
                v_abs = d[0, 1].abs()[valid]
                row = {"err": err_h.median().item(), "over1": (err_h > 1.0).float().mean().item(),
                       "over4": (err_h > 4.0).float().mean().item(),
                       "v_over1": (v_abs > 1.0).float().mean().item(),
                       "v_tex": (v_abs[textured] > 1.0).float().mean().item(),
                       "tex": textured.float().mean().item(),
                       "right_psnr": iq.psnr(((ry - iq.luma(rp)) ** 2).mean().item())}
                for key, val in row.items():
                    acc[cn].setdefault(key, []).append(val)
                    clip_acc[cn].setdefault(key, []).append(val)
                if cn == "E":
                    vbad = torch.zeros_like(dm[0, 0])
                    vbad[valid] = (v_abs > 1.0).float()
                    y0, x0, score = iq.worst_window(vbad)
                    if score > worst[0]:
                        crop = lambda x: iq.to_u8(x[:, :, y0:y0 + 256, x0:x0 + 256])  # noqa: E731
                        worst = (score, (i, y0, x0, [crop(R[1])] + [crop(cand[c][1]) for c in
                                                                    ("A-vt", "A-rife", "E", "B-vt", "B-mc", "E+B")]))
            print(f"   {k + 1}/{len(idx)} (frame {i})", end="\r", flush=True)
        print()
        per_clip[name] = {cn: {key: float(np.mean(v)) for key, v in a.items()} for cn, a in clip_acc.items()}
        for cn in names:
            r = per_clip[name][cn]
            print(f"   {cn:8s} |Dv|>1 {r['v_over1'] * 100:5.1f}% (detail {r['v_tex'] * 100:5.1f}%)  |Dh−real|>1 {r['over1'] * 100:5.1f}%  "
                  f">4 {r['over4'] * 100:5.1f}%  right PSNR {r['right_psnr']:.2f}")
        if worst[1]:
            i, y0, x0, tiles = worst[1]
            p = out / "crops" / f"{name}-f{i + 1:03d}-y{y0}-x{x0}-right.png"
            iq.save_strip(p, tiles, ["real R", "A-vt", "A-rife", "E", "B-vt", "B-mc", "E+B"])
            print(f"   worst right-eye region (E's vertical disparity): {p}")

    total = {cn: {key: float(np.mean(v)) for key, v in a.items()} for cn, a in acc.items()}
    (out / "results.json").write_text(json.dumps({"ALL": total, "clips": per_clip,
                                                  "right_only": float(np.mean(right_only)),
                                                  "untrusted": float(np.mean(untrusted))}, indent=1))
    print(f"\nE+B's untrusted pixels (switched to B-mc): {np.mean(untrusted) * 100:.1f}%")
    print(f"right-only pixels (left/right check fails on both real pairs): {np.mean(right_only) * 100:.1f}%")
    print("\n| candidate | |Dv| > 1 px | |Dv| > 1 px, detail only | |Dh − real| > 1 px | > 4 px | median |Dh − real| | right-eye PSNR |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for cn, r in total.items():
        print(f"| {cn} | {r['v_over1'] * 100:.1f}% | {r['v_tex'] * 100:.1f}% | {r['over1'] * 100:.1f}% | {r['over4'] * 100:.1f}% | "
              f"{r['err']:.2f} | {r['right_psnr']:.2f} |")
    print("\n## per clip, |Dv| > 1 px, all (detail only)")
    clips = list(per_clip)
    print("| candidate | " + " | ".join(clips) + " |")
    print("| --- |" + " --- |" * len(clips))
    for cn in names:
        print(f"| {cn} | " + " | ".join(f"{per_clip[c][cn]['v_over1'] * 100:.1f}% ({per_clip[c][cn]['v_tex'] * 100:.1f}%)" for c in clips) + " |")


if __name__ == "__main__":
    main()
