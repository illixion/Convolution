#!/usr/bin/env bash
# Exercise the real AVPlayer session on macOS without app credentials or a server.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/hypnos-music-checks.XXXXXX")"
swiftc -swift-version 6 -parse-as-library \
    "$repo_root/Hypnos/Hypnos/Services/Library/JellyfinMusic.swift" \
    "$repo_root/Hypnos/Hypnos/Services/Library/MusicCatalog.swift" \
    "$repo_root/Hypnos/Hypnos/Services/Library/MusicSearchIndex.swift" \
    "$repo_root/Hypnos/Hypnos/Services/Library/MusicSearchStore.swift" \
    "$repo_root/scripts/checks/MusicPlayerChecks.swift" \
    -o "$checks_dir/music-player-checks"
"$checks_dir/music-player-checks"
