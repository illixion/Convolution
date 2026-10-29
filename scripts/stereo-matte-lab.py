#!/usr/bin/env python3
"""Offline two-layer stereo experiment, NOT a production renderer.

Consumes source.png + lossless depth.f32/depth.json from VideoStereoFrameLabTests.
Requires numpy, scipy, Pillow; --method closed-form additionally needs pymatting.
The explicit depth partition is a scene hypothesis, not general segmentation.
No coat colors, pixel coordinates, or model-specific values enter the renderer.

python stereo-matte-lab.py CAPTURE NEW_OUTPUT [--crop 620,550,760,800]
python stereo-matte-lab.py CAPTURE_SEQUENCE NEW_OUTPUT --sequence
python stereo-matte-lab.py --self-test
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt, gaussian_filter, map_coordinates


def budget(depth, knees):
    lo, hi = knees
    result = depth.copy()
    if hi < 1:
        result[depth > hi] = hi + (1 - hi) * np.tanh((depth[depth > hi] - hi) / (1 - hi))
    if lo > 0:
        result[depth < lo] = lo - lo * np.tanh((lo - depth[depth < lo]) / lo)
    return result


def load_capture(path):
    meta = json.loads((path / 'depth.json').read_text())
    if meta['format'] != 'float32-little-endian' or meta['origin'] != 'top-left':
        raise ValueError('unsupported depth format/origin')
    color = np.asarray(Image.open(path / 'source.png').convert('RGB'), dtype=np.float32) / 255
    h, w = color.shape[:2]
    if (w, h) != (meta['sourceWidth'], meta['sourceHeight']):
        raise ValueError('source dimensions disagree with metadata')
    raw = np.fromfile(path / 'depth.f32', dtype='<f4').reshape(meta['height'], meta['width'])
    if not np.isfinite(raw).all():
        raise ValueError('nonfinite depth')
    y, x = np.mgrid[:h, :w].astype(np.float32)
    sx, sy = meta['uvScale']
    ox, oy = meta['uvOffset']
    depth = map_coordinates(raw, [((y + .5) / h * sy + oy) * raw.shape[0] - .5,
                                  ((x + .5) / w * sx + ox) * raw.shape[1] - .5],
                            order=1, mode='nearest')
    depth = depth * meta['valueScale'] + meta['valueBias']
    return color, budget(depth, meta['depthBudget']), meta


def extend(values, known, sigma):
    """Smooth normalized convolution near known samples; nearest far away.

    This supplies a background guess, not recovered scene content. It can blur
    structure behind an occluder. The same operation extends each layer's depth.
    """
    if not np.any(known):
        raise ValueError('partition has no confident samples on one side')
    nearest_indices = distance_transform_edt(~known, return_distances=False, return_indices=True)
    nearest = values[tuple(nearest_indices)]
    denominator = gaussian_filter(known.astype(np.float32), sigma)
    if values.ndim == 3:
        denominator = denominator[..., None]
        numerator = gaussian_filter(values * known[..., None], (sigma, sigma, 0))
    else:
        numerator = gaussian_filter(values * known, sigma)
    return np.where(denominator > 1e-5, numerator / np.maximum(denominator, 1e-5), nearest)


def separate(color, depth, threshold, band, method):
    foreground = depth > threshold
    inside = distance_transform_edt(foreground)
    outside = distance_transform_edt(~foreground)
    near_seed, far_seed = inside > band, outside > band
    sigma = band * .625
    near_depth = np.where(near_seed, depth, extend(depth, near_seed, sigma))
    far_depth = np.where(far_seed, depth, extend(depth, far_seed, sigma))
    F, B = extend(color, near_seed, sigma), extend(color, far_seed, sigma)
    if method == 'local-color':
        direction = F - B
        alpha = np.clip(np.sum((color - B) * direction, axis=2) /
                        np.maximum(np.sum(direction * direction, axis=2), 1e-6), 0, 1)
        alpha = np.where(near_seed, 1, np.where(far_seed, 0, alpha)).astype(np.float32)
        # A hard alpha==0 switch tears the background where the projection hits
        # zero. Fade to the exact visible source continuously near zero coverage.
        # .1 is an experimental confidence transition, NOT a validated default.
        confidence = np.clip(alpha / .1, 0, 1)
        confidence = confidence * confidence * (3 - 2 * confidence)
        B = color * (1 - confidence[..., None]) + B * confidence[..., None]
        # Keep the residual in float. Clipping premultiplied radiance here made
        # a second contour in the right eye. Record violations instead of hiding
        # the fact that this approximate decomposition can be nonphysical.
        P = color - (1 - alpha)[..., None] * B
    else:
        from pymatting import estimate_alpha_cf, estimate_foreground_ml
        trimap = np.where(near_seed, 1., np.where(far_seed, 0., .5))
        alpha = estimate_alpha_cf(color.astype(np.float64), trimap).astype(np.float32)
        F, fitted_background = estimate_foreground_ml(color, alpha, return_background=True)
        P = F * alpha[..., None]
        if method == 'closed-form':
            B = fitted_background
        else:
            # Diagnostic: replace the solver's contaminated hidden background.
            blend = np.clip(outside / band, 0, 1).astype(np.float32)
            blend = blend * blend * (3 - 2 * blend)
            B = B * (1 - blend[..., None]) + color * blend[..., None]
    return P, alpha, B, near_depth, far_depth


def sample(values, y, x):
    if values.ndim == 2:
        return map_coordinates(values, [y, x], order=1, mode='nearest')
    return np.stack([map_coordinates(values[..., i], [y, x], order=1, mode='nearest')
                     for i in range(values.shape[2])], axis=2)


def feather(x, width):
    uv = (x + .5) / width
    a, b = np.clip(uv / .05, 0, 1), np.clip((1 - uv) / .05, 0, 1)
    return a * a * (3 - 2 * a) * b * b * (3 - 2 * b)


def inverse_map(depth, strength, convergence, sign):
    """Intersect destination rays with forward-warped row segments.

    Fixed-point inverse warping diverges on steep gradients, even when a
    solution exists. Enumerate the bounded disparity interval instead and
    choose the nearest surface when segments overlap, like a depth buffer.
    """
    h, w = depth.shape
    y, x = np.mgrid[:h, :w].astype(np.float32)
    ix = np.arange(w)
    source_x = np.zeros_like(x)
    nearest = np.full_like(x, -np.inf)
    shifts = sign * strength * w * (depth - convergence) * feather(x, w)
    low = int(np.floor(-shifts.max())) - 1
    high = int(np.ceil(-shifts.min())) + 1
    for offset in range(low, high + 1):
        start = ix + offset
        sx0 = np.clip(start.astype(np.float32), -.5, w - .5)
        sx1 = np.clip(start.astype(np.float32) + 1, -.5, w - .5)
        z0 = depth[:, np.clip(start, 0, w - 1)]
        z1 = depth[:, np.clip(start + 1, 0, w - 1)]
        dest0 = sx0 + sign * strength * w * (z0 - convergence) * feather(sx0, w)
        dest1 = sx1 + sign * strength * w * (z1 - convergence) * feather(sx1, w)
        delta = dest1 - dest0
        valid = (np.abs(delta) > 1e-7) & (x >= np.minimum(dest0, dest1)) & (x <= np.maximum(dest0, dest1))
        t = np.zeros_like(x)
        np.divide(x - dest0, delta, out=t, where=valid)
        z = z0 + t * (z1 - z0)
        front = valid & (z > nearest)
        nearest[front] = z[front]
        roots = sx0 + t * (sx1 - sx0)
        source_x[front] = roots[front]
    if not np.isfinite(nearest).all():
        raise ValueError('uncovered ray in a continuous layer')
    residual = np.abs(source_x + sign * strength * w *
                      (sample(depth, y, source_x) - convergence) * feather(source_x, w) - x)
    return y, source_x, residual


def render(layers, strength, convergence, sign):
    P, alpha, B, near_depth, far_depth = layers
    y, near_x, near_error = inverse_map(near_depth, strength, convergence, sign)
    _, far_x, far_error = inverse_map(far_depth, strength, convergence, sign)
    a = sample(alpha, y, near_x)
    image = sample(P, y, near_x) + (1 - a)[..., None] * sample(B, y, far_x)
    return image, {
        'nearInverseResidualOverQuarterPixel': int(np.count_nonzero(near_error > .25)),
        'farInverseResidualOverQuarterPixel': int(np.count_nonzero(far_error > .25)),
        'maximumInverseResidualPx': float(max(near_error.max(), far_error.max())),
        'outOfRangeChannels': int(np.count_nonzero((image < 0) | (image > 1))),
    }


def save(path, image):
    if image.ndim == 2:
        image = np.repeat(image[..., None], 3, axis=2)
    Image.fromarray(np.uint8(np.clip(image, 0, 1) * 255 + .5)).save(path)


def comparison(capture, output, crop):
    images = [('Source', capture / 'source.png'),
              ('Production left', capture / 'connected-left.png'),
              ('Prototype left', output / 'left.png'),
              ('Production right', capture / 'connected-right.png'),
              ('Prototype right', output / 'right.png')]
    if not all(path.exists() for _, path in images):
        return
    cw, ch = (crop[2] - crop[0]) * 2, (crop[3] - crop[1]) * 2
    canvas = Image.new('RGB', (cw * len(images), ch + 32), '#222222')
    draw = ImageDraw.Draw(canvas)
    for i, (label, path) in enumerate(images):
        image = Image.open(path).convert('RGB').crop(crop).resize((cw, ch), Image.Resampling.NEAREST)
        canvas.paste(image, (cw * i, 32))
        draw.text((cw * i + 8, 8), label, fill='white')
    canvas.save(output / 'comparison.png')


def process(capture, output, args):
    started = time.perf_counter()
    color, depth, meta = load_capture(capture)
    layers = separate(color, depth, args.threshold, args.band, args.method)
    separation_seconds = time.perf_counter() - started
    P, alpha, B, near_depth, far_depth = layers
    reconstruction = P + (1 - alpha)[..., None] * B
    report = {
        'method': args.method, 'threshold': args.threshold, 'unknownBandPx': args.band,
        'warning': 'Offline SDR two-layer hypothesis; not a general renderer or headset validation.',
        'inputSHA256': {n: hashlib.sha256((capture / n).read_bytes()).hexdigest()
                        for n in ['source.png', 'depth.f32', 'depth.json']},
        'frameSeconds': meta.get('frameSeconds'), 'temporalState': meta['temporalState'],
        'strength': meta['strength'], 'convergence': meta['convergence'],
        'separationSeconds': separation_seconds,
        'zeroDisparityRMSECodeValues': float(np.sqrt(np.mean((reconstruction - color) ** 2)) * 255),
        'nonphysicalPremultipliedChannels': int(np.count_nonzero((P < -1/255) | (P > alpha[..., None] + 1/255))),
        'eyes': {},
    }
    output.mkdir(parents=True, exist_ok=False)
    save(output / 'alpha.png', alpha)
    save(output / 'background.png', B)
    save(output / 'foreground-premult.png', P)
    for eye, sign in [('left', 1), ('right', -1)]:
        image, diagnostics = render(layers, meta['strength'], meta['convergence'], sign)
        report['eyes'][eye] = diagnostics
        save(output / (eye + '.png'), image)
    report['totalSeconds'] = time.perf_counter() - started
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.crop:
        comparison(capture, output, args.crop)
    print(json.dumps({'frame': capture.name, **report}), flush=True)


def self_test():
    # Analytic two-surface scene: soft diagonal coverage over textured background.
    # Ground truth is independent translation of each layer, not a connected warp.
    h, w = 96, 192
    y, x = np.mgrid[:h, :w].astype(np.float32)
    alpha = np.clip((100 + .3 * y - x) / 5 + .5, 0, 1)
    F = np.stack([.8 + x * 0, .5 + y * 0, .1 + x * 0], axis=2)
    B = np.stack([.1 + .04 * np.sin(x / 7), .2 + .04 * np.cos(y / 5), .4 + .05 * np.sin(x / 9)], axis=2)
    P = F * alpha[..., None]
    layers = (P, alpha, B, np.full((h, w), .8, dtype=np.float32), np.full((h, w), .2, dtype=np.float32))
    source = P + (1 - alpha)[..., None] * B
    zero, _ = render(layers, 0, 1, 1)
    np.testing.assert_allclose(zero, source, atol=1e-6)
    for sign in [1, -1]:
        result, stats = render(layers, .008, 1, sign)
        nx, bx = x - sign * .008 * w * (.8 - 1), x - sign * .008 * w * (.2 - 1)
        expected = sample(P, y, nx) + (1 - sample(alpha, y, nx))[..., None] * sample(B, y, bx)
        np.testing.assert_allclose(result[:, 30:-30], expected[:, 30:-30], atol=2e-6)
        assert stats['maximumInverseResidualPx'] < .01
    # Check lossless source recomposition for the actual approximate separation.
    depth = .2 + .6 * alpha
    approximate = separate(source, depth, .5, 8, 'local-color')
    reconstructed = approximate[0] + (1 - approximate[1])[..., None] * approximate[2]
    np.testing.assert_allclose(reconstructed, source, atol=1e-6)
    print('PASS: zero disparity, both analytic eye shifts, inverse convergence, source recomposition')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path, nargs='?')
    parser.add_argument('output', type=Path, nargs='?')
    parser.add_argument('--method', choices=['local-color', 'closed-form', 'closed-form-clean'], default='local-color')
    parser.add_argument('--threshold', type=float, default=.5)
    parser.add_argument('--band', type=float, default=16)
    parser.add_argument('--crop', type=lambda s: tuple(map(int, s.split(','))))
    parser.add_argument('--sequence', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.capture is None or args.output is None:
        parser.error('capture and output are required')
    if args.output.exists():
        parser.error('output exists; choose a new directory')
    if not np.isfinite(args.band) or args.band <= 0 or not 0 < args.threshold < 1:
        parser.error('band must be positive and finite, threshold must be between zero and one')
    if args.crop and (len(args.crop) != 4 or args.crop[0] >= args.crop[2] or args.crop[1] >= args.crop[3]):
        parser.error('crop must be left,top,right,bottom with positive dimensions')
    captures = sorted(p for p in args.capture.iterdir() if (p / 'depth.json').is_file()) if args.sequence else [args.capture]
    if not captures:
        parser.error('no captures found')
    for capture in captures:
        process(capture, args.output / capture.name if args.sequence else args.output, args)


if __name__ == '__main__':
    main()
