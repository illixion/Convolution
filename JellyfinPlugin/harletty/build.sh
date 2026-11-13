#!/usr/bin/env bash
# Build the harletty the Atmos Objects plugin runs for DTS:X: upstream at a
# pinned commit plus our patches (applied in order).
#
#   JellyfinPlugin/harletty/build.sh [--force]
#
# Leaves the binary at JellyfinPlugin/harletty/checkout/target/release/harletty.
# Copy it beside truehdd in the plugin's folder (or set HarlettyPath).
#
# harletty is a fork of truehdd that also decodes DTS:X into the same DAMF
# master set (https://github.com/harletty/harletty-bridge). Its sources are
# Apache-2.0 except the dca crate (LGPL-2.1-or-later, a Rust translation of
# FFmpeg's DTS decoder), so the binary is conveyed under LGPL-3.0; it runs as
# a separate process and nothing links it.
#
# cli-workspace.patch trims the workspace to the CLI and its decoders: the
# runtime bridge plugins in the same repo need an Omniphony checkout, which
# the CLI never links.
#
# audio-stdout.patch adds `decode --audio-stdout` for DTS input, as
# truehdd/audio-stdout.patch does for TrueHD: decoded PCM (24-bit LE,
# interleaved, the master set's channels) streams to stdout instead of a CAF
# file, so the plugin can serve audio while the decode runs. The .atmos header
# and .atmos.metadata still go to --output-path (the metadata flushed after
# every frame). Frames before the stream has shown a spatial one (right after
# a seek, a few can come from the core alone) are held in memory, since a
# pipe can't be rewritten as the master set the way harletty rewrites a file.
set -euo pipefail

REPO=https://github.com/harletty/harletty-bridge
COMMIT=69a31ac010d18bb6a9dbdb1095f2f85e1e95ff9d   # main after 0.9.0, 2026-11-13
PATCHES=(cli-workspace.patch audio-stdout.patch)

here=$(cd "$(dirname "$0")" && pwd)
checkout="$here/checkout"

if [[ "${1:-}" == "--force" ]]; then
    rm -rf "$checkout"
fi

if [[ ! -d "$checkout" ]]; then
    git clone --quiet "$REPO" "$checkout"
    git -C "$checkout" checkout --quiet "$COMMIT"
    for patch in "${PATCHES[@]}"; do
        echo "==> Applying $patch"
        git -C "$checkout" apply "$here/$patch"
    done
else
    echo "==> $checkout exists, rebuilding as is (--force to start over)"
fi

cargo build --release -p harletty --manifest-path "$checkout/Cargo.toml"
echo "Built $checkout/target/release/harletty"
