#!/usr/bin/env python3
"""Package only the Swift shared-library dependency closure, failing if incomplete."""
import re
import shutil
import subprocess
import sys
from pathlib import Path

core, runtime, ndk, output = map(Path, sys.argv[1:])
prebuilt = next((ndk / "toolchains/llvm/prebuilt").iterdir())
readelf = prebuilt / "bin/llvm-readelf"
standard = prebuilt / "sysroot/usr/lib/aarch64-linux-android"
sources = {p.name: p for p in runtime.glob("*.so")}
sources[core.name] = core
sources["libc++_shared.so"] = standard / "libc++_shared.so"
system = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so", "libz.so"}
pending, selected = [core.name], {}
while pending:
    name = pending.pop()
    if name in selected or name in system:
        continue
    if name not in sources:
        raise SystemExit(f"Missing Android runtime dependency: {name}")
    library = sources[name]
    selected[name] = library
    dynamic = subprocess.check_output([readelf, "-d", library], text=True)
    pending.extend(re.findall(r"\(NEEDED\).*\[(.*?)\]", dynamic))
output.mkdir(parents=True, exist_ok=True)
# This directory is generated exclusively by this script.
for stale in output.glob("*.so"):
    if stale.name not in selected:
        stale.unlink()
for name, source in selected.items():
    shutil.copy2(source, output / name)
print(f"Packaged {len(selected)} libraries ({sum(p.stat().st_size for p in selected.values()) // 1024**2} MiB)")
