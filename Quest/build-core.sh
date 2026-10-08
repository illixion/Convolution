#!/usr/bin/env bash
set -euo pipefail
quest_dir="$(cd "$(dirname "$0")" && pwd)"
sdk_repo="${RAVE_SDK_PATH:-$quest_dir/../../RAVESDK}"
: "${SWIFT_ANDROID_BIN:?Set SWIFT_ANDROID_BIN to the matching open-source swift executable}"
: "${SWIFT_ANDROID_BUNDLE:?Set SWIFT_ANDROID_BUNDLE to the installed Android artifactbundle directory}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME (NDK r27 or newer)}"
triple=aarch64-unknown-linux-android29
scratch="$quest_dir/build/swift"
# SwiftPM 6.3.3 can choose an arbitrary architecture from the multi-triple SDK.
# Describe one arm64 destination explicitly; keep the installed SDK immutable.
python3 "$quest_dir/arm64-sdk.py" "$SWIFT_ANDROID_BUNDLE" "$quest_dir/build/sdk"
"$SWIFT_ANDROID_BIN" build --package-path "$sdk_repo" --product RAVEQuestCore \
  --swift-sdks-path "$quest_dir/build/sdk" \
  --swift-sdk convolution-quest-arm64 --triple "$triple" \
  --scratch-path "$scratch" -c release -Xlinker -soname -Xlinker libRAVEQuestCore.so
python3 "$quest_dir/package-runtime.py" \
  "$scratch/$triple/release/libRAVEQuestCore.so" \
  "$SWIFT_ANDROID_BUNDLE/swift-android/swift-resources/usr/lib/swift-aarch64/android" \
  "$ANDROID_NDK_HOME" "$quest_dir/app/src/main/jniLibs/arm64-v8a"
