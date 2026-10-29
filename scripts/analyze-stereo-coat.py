#!/usr/bin/env python3
"""Measure the 2026-10-29 coat capture and its offline mesh replays.

Requires numpy, Pillow and scipy. Input/output pictures remain local artifacts.
Usage: python analyze-stereo-coat.py CAPTURE_DIR LAB_DIR NEW_REPORT_DIR
These shot-specific measurements are diagnostics, never renderer thresholds.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter1d


def rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=float)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("lab", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output exists; choose a new directory")
    args.output.mkdir(parents=True)
    source = rgb(args.capture / "source.png")
    if source.shape != (1080, 1920, 3):
        parser.error("this shot-specific measurement requires the 1920x1080 coat capture")
    edges = {}
    for name in ["source", "left", "right"]:
        image = rgb(args.capture / f"{name}.png")
        positions, widths = [], []
        for y in range(570, 671):
            base = source[y, :, 0] - source[y, :, 2]
            guess = int(660 + .38 * (y - 570))
            xx = np.arange(guess - 15, guess + 16)
            candidates = xx[:-1][(base[xx[:-1]] >= 15) & (base[xx[1:]] < 15)]
            if not len(candidates):
                raise ValueError("reference edge absent; this is not the expected coat frame")
            edge = candidates[np.argmin(abs(candidates - guess))]
            near = np.mean(base[edge - 9:edge - 4])
            far = np.mean(base[edge + 5:edge + 10])
            score = (image[y, :, 0] - image[y, :, 2] - far) / (near - far)

            def crossing(threshold):
                xx = np.arange(edge - 20, edge + 21)
                found = xx[:-1][(score[xx[:-1]] >= threshold) & (score[xx[1:]] < threshold)]
                if not len(found):
                    raise ValueError("edge crossing absent")
                j = found[np.argmin(abs(found - edge))]
                return j + (score[j] - threshold) / (score[j] - score[j + 1])

            positions.append(crossing(.5))
            widths.append(crossing(.1) - crossing(.9))
        positions = np.array(positions)
        edges[name] = {
            "rows": len(positions),
            "medianTransitionWidthPx": float(np.median(widths)),
            "contourHighFrequencyRMSPx": float(np.std(positions - gaussian_filter1d(positions, 3))),
        }
    replay = []
    for eye in ["left", "right"]:
        reference = rgb(args.lab / f"supersample4-{eye}.png")[550:1050, 600:835]
        for variant in ["grid193-msaa4", "baseline", "no-msaa", "sample-shading4", "grid1537", "supersample2", "footprint4"]:
            difference = rgb(args.lab / f"{variant}-{eye}.png")[550:1050, 600:835] - reference
            replay.append({"eye": eye, "variant": variant,
                           "rmseVs4x": float(np.sqrt(np.mean(difference ** 2)))})
    hashes = {name: hashlib.sha256((args.capture / name).read_bytes()).hexdigest()
              for name in ["source.png", "left.png", "right.png", "depth.png", "capture.json"]}
    report = {"warning": "Offline replays use a normalized 8-bit depth PNG, not raw device depth. Supersampling is a same-geometry integration reference, not correct scene geometry.",
              "sha256": hashes, "capturedEdges": edges, "replay": replay}
    (args.output / "metrics.json").write_text(json.dumps(report, indent=2) + "\n")
    names = [(args.capture / f"{name}.png", name) for name in ["source", "left", "right"]]
    canvas = Image.new("RGB", (840, 520), "#222222")
    draw = ImageDraw.Draw(canvas)
    for i, (path, label) in enumerate(names):
        crop = Image.open(path).convert("RGB").crop((620, 550, 760, 790))
        canvas.paste(crop.resize((280, 480), Image.Resampling.NEAREST), (i * 280, 40))
        draw.text((i * 280 + 8, 10), label + " (device capture, 2x)", fill="white")
    canvas.save(args.output / "captured-coat.png")
    print(json.dumps(edges, indent=2))


if __name__ == "__main__":
    main()
