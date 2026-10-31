#!/usr/bin/env python3
"""Export the screen-capture-gated retained frame as a lossless Vergence lab fixture.

Run with the player paused after stereoEyes has captured the desired frame.
Authentication stays inside DebugTrace's client. Output must be a new directory.
Requires Pillow for the source preview; the replay uses source.bgra directly.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import runpy
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--app", default="com.illixion.spatialstash")
    args = parser.parse_args()
    if args.out.exists():
        parser.error("Choose a new output directory")
    client_path = Path(__file__).resolve().parents[2] / "DebugTrace/Tools/debugtrace-mcp"
    client = runpy.run_path(str(client_path), run_name="stereo_frame_export")
    session = client["verified"](client["resolve"](args.app))
    status, _, raw = client["request"](session, "/_call", {"name": "stereoFrame", "arguments": {}})
    if status >= 400:
        raise ValueError("capture unavailable")
    payload = json.loads(raw)
    if payload.get("version") != 1:
        raise ValueError("unsupported capture")
    w, h = payload["width"], payload["height"]
    dw, dh = payload["depthWidth"], payload["depthHeight"]
    source = base64.b64decode(payload["sourceBGRA"], validate=True)
    depth = base64.b64decode(payload["depthFloat32"], validate=True)
    if len(source) != w * h * 4 or len(depth) != dw * dh * 4:
        raise ValueError("plane length mismatch")
    from PIL import Image
    image = Image.frombytes("RGBA", (w, h), source, "raw", "BGRA")
    eyes = {eye: base64.b64decode(payload[f"{eye}PNG"], validate=True) for eye in ("left", "right")}
    metadata = dict(payload["warp"], width=dw, height=dh, sourceWidth=w, sourceHeight=h,
                    frameSeconds=payload["itemSeconds"], strength=payload["strength"],
                    convergence=payload["convergence"], format="float32-little-endian",
                    origin="top-left", temporalState="retained-device-capture",
                    sourceSHA256=hashlib.sha256(source).hexdigest(),
                    depthSHA256=hashlib.sha256(depth).hexdigest())
    args.out.mkdir(parents=True)
    (args.out / "source.bgra").write_bytes(source)
    image.save(args.out / "source.png")
    (args.out / "depth.f32").write_bytes(depth)
    for eye, data in eyes.items():
        (args.out / f"captured-{eye}.png").write_bytes(data)
    (args.out / "depth.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Saved lossless {w}x{h} frame at {payload['itemSeconds']:.9f}s to {args.out}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # The transport owns credentials; do not print its exceptions or replies.
        print("Export failed; check capture approval and that AI 3D is showing.", file=sys.stderr)
        sys.exit(1)
