#!/usr/bin/env python3
"""Capture an exact paused-frame A/B through the existing DebugTrace client.

Usage: python3 scripts/compare-stereo-edges.py --out build/edge-comparison/movie-a-rail
Requires a foreground AI 3D player paused on the desired frame. Does not seek,
change the model or recompute depth. Restores all renderer switches afterward.
The manifest rejects differing source/depth images, timestamps or disparity.
Authentication stays inside DebugTrace's client; no token is printed or passed
as an argument. Output images are validation artifacts, not repository assets.
"""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import sys


class CaptureFailure(Exception):
    """Locally generated, credential-free failure messages."""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--app", default="com.illixion.spatialstash")
    parser.add_argument("--client", type=Path, default=Path(__file__).resolve().parents[2] / "DebugTrace/Tools/debugtrace-mcp")
    args = parser.parse_args()
    if args.out.exists():
        parser.error("--out must be a new directory; existing captures are preserved")
    client = runpy.run_path(str(args.client), run_name="stereo_comparison_client")
    session = client["verified"](client["resolve"](args.app))

    def call(name, arguments=None):
        status, kind, raw = client["request"](session, "/_call", {"name": name, "arguments": arguments or {}})
        if status >= 400:
            raise CaptureFailure(f"{name} failed (HTTP {status}); see the app's debug access and screen capture prompts (Allow for 15 Minutes covers the whole run)")
        if kind.startswith("application/json"):
            reply = json.loads(raw)
            if not reply.get("ok"):
                raise CaptureFailure(f"{name} failed; keep an AI 3D frame paused and the app in the foreground")
            return reply["data"]
        if not kind.startswith("image/png"):
            raise CaptureFailure(f"{name} did not return a PNG")
        return raw

    original = call("stereoEdges")
    args.out.mkdir(parents=True)
    manifest = {"valid": False, "originalSwitches": original, "captures": {}}
    try:
        for mode, switches in [("connected", {"separated": False, "holes": False}),
                               ("separated", {"separated": True, "holes": False}),
                               ("holes", {"separated": True, "holes": True})]:
            call("stereoEdges", switches)
            first = True
            hashes = {}
            for view in ["left", "right", "source", "depth", "anaglyph"]:
                raw = call("stereoEyes", {"view": view, "fresh": first, "recompute": False})
                first = False
                (args.out / f"{mode}-{view}.png").write_bytes(raw)
                hashes[view] = hashlib.sha256(raw).hexdigest()
            metadata = call("stereoCaptureInfo")
            manifest["captures"][mode] = {"metadata": metadata, "sha256": hashes}
        baseline = manifest["captures"]["connected"]
        for mode, capture in manifest["captures"].items():
            if capture["metadata"] != baseline["metadata"]:
                raise CaptureFailure(f"{mode}: frame or disparity changed; pause playback and repeat")
            if any(capture["sha256"][v] != baseline["sha256"][v] for v in ["source", "depth"]):
                raise CaptureFailure(f"{mode}: source or depth changed; pause playback and repeat")
        manifest["valid"] = True
    except CaptureFailure as error:
        manifest["failure"] = str(error)
        raise
    finally:
        try:
            call("stereoEdges", {key: bool(original[key]) for key in ["separated", "holes"]})
        finally:
            (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Saved verified paused-frame A/B: {args.out}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # The client owns credentials. Do not echo arbitrary transport errors,
        # raw replies, session dictionaries or tracebacks into agent output.
        message = str(error) if isinstance(error, CaptureFailure) else f"{type(error).__name__}; inspect the app and repeat while paused"
        print(f"Comparison failed: {message}.", file=sys.stderr)
        sys.exit(1)
