#!/bin/sh
# Builds and runs the Quest's native analysis tests on a desktop (macOS or
# Linux, with zlib): the VGAT reader and chunk store against tracks VergenceCore
# and vergence-worker wrote (fixtures/), and the vendored pairing maths against
# vergence-companion's vectors. With a track path as the first argument, also
# prints that track's sums for comparing with `MakeFixtures --sums` (fixtures/swift).
set -e
here=$(cd "$(dirname "$0")" && pwd)
cpp="$here/../app/src/main/cpp"
bridge="$cpp/third_party/controller-bridge"
out=${TMPDIR:-/tmp}/convolution-quest-native-tests
mkdir -p "$out"
cc -std=c99 -Wall -Wextra -Werror -c -I"$bridge" "$bridge/qcb_crypto.c" -o "$out/qcb_crypto.o"
cc -std=c99 -c "$bridge/third_party/monocypher/monocypher.c" -o "$out/monocypher.o"
c++ -std=c++17 -Wall -Wextra -Werror -I"$cpp/analysis" -I"$bridge" \
    "$cpp/analysis/analysis_track.cpp" "$here/test_analysis.cpp" \
    "$out/qcb_crypto.o" "$out/monocypher.o" -lz -o "$out/test_analysis"
"$out/test_analysis" "$here/fixtures"
if [ -n "$1" ]; then "$out/test_analysis" --sums "$1"; fi
