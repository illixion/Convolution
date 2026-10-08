#!/usr/bin/env python3
"""Describe exactly one architecture to avoid SwiftPM's multi-triple SDK selection."""
import json
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
source = source.resolve() / "swift-android"
bundle = destination / "quest-arm64.artifactbundle"
bundle.mkdir(parents=True, exist_ok=True)
config = json.loads((source / "swift-sdk.json").read_text())
triple = "aarch64-unknown-linux-android29"
target = config["targetTriples"][triple]
for key in ("sdkRootPath", "swiftResourcesPath", "swiftStaticResourcesPath"):
    target[key] = str(source / target[key])
target["toolsetPaths"] = [str(source / p) for p in target["toolsetPaths"]]
(bundle / "swift-sdk.json").write_text(json.dumps({"schemaVersion": "4.0", "targetTriples": {triple: target}}, indent=2))
(bundle / "info.json").write_text(json.dumps({"schemaVersion": "1.0", "artifacts": {
    "convolution-quest-arm64": {"type": "swiftSDK", "version": "0.1", "variants": [{"path": "."}]}
}}, indent=2))
