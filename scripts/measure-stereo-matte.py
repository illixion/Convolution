#!/usr/bin/env python3
"""Shot-specific coat measurements for the nominal 742s consecutive captures.

Usage: measure-stereo-matte.py CAPTURE_SEQUENCE PROTOTYPE_SEQUENCE NEW_JSON
Requires numpy, scipy, Pillow. Color and coordinate assumptions are measurement
fixtures only; never use them to classify a boundary in the renderer.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter1d


def rgb(path):
    return np.asarray(Image.open(path).convert('RGB'), dtype=float) / 255


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('prototype', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('output exists; choose a new path')
    frames = sorted(args.prototype.glob('frame-*'))
    if not frames:
        parser.error('no frame directories found')
    reports = []
    for frame in frames:
        capture = args.capture / frame.name
        source = rgb(capture / 'source.png')
        if source.shape != (1080, 1920, 3):
            parser.error('measurement requires the 1920x1080 coat shot')
        metrics = {}
        images = [('source', capture / 'source.png'),
                  ('production-left', capture / 'connected-left.png'),
                  ('prototype-left', frame / 'left.png'),
                  ('production-right', capture / 'connected-right.png'),
                  ('prototype-right', frame / 'right.png')]
        for name, path in images:
            image = rgb(path)
            positions, widths = [], []
            for y in range(580, 671):
                base = source[y, :, 0] - source[y, :, 2]
                guess = int(675 + .5 * (y - 600))
                xx = np.arange(guess - 25, guess + 26)
                hits = xx[:-1][(base[xx[:-1]] >= .06) & (base[xx[1:]] < .06)]
                if not len(hits):
                    raise ValueError(f'coat reference edge absent in {frame.name}, row {y}')
                edge = hits[np.argmin(abs(hits - guess))]
                near = np.mean(base[edge - 9:edge - 4])
                far = np.mean(base[edge + 5:edge + 10])
                score = (image[y, :, 0] - image[y, :, 2] - far) / (near - far)

                def crossing(threshold):
                    xx = np.arange(edge - 25, edge + 26)
                    hits = xx[:-1][(score[xx[:-1]] >= threshold) & (score[xx[1:]] < threshold)]
                    if not len(hits):
                        raise ValueError(f'edge crossing absent in {frame.name}/{name}, row {y}')
                    j = hits[np.argmin(abs(hits - edge))]
                    return j + (score[j] - threshold) / (score[j] - score[j + 1])

                positions.append(crossing(.5))
                widths.append(crossing(.1) - crossing(.9))
            pos = np.array(positions)
            metrics[name] = {
                'width': float(np.median(widths)),
                'contourRMS': float(np.std(pos - gaussian_filter1d(pos, 3))),
            }
        reports.append({'frame': frame.name, 'metrics': metrics})
    summary = {name: {metric: float(np.mean([r['metrics'][name][metric] for r in reports]))
                      for metric in ['width', 'contourRMS']} for name in reports[0]['metrics']}
    args.output.write_text(json.dumps({
        'warning': 'Shot-specific diagnostics, not ground-truth stereo or general quality scores.',
        'rows': [580, 670], 'frames': reports, 'meanAcrossFrames': summary,
    }, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
