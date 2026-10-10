#!/usr/bin/env bash
set -euo pipefail
quest_dir="$(cd "$(dirname "$0")" && pwd)"
sdk_repo="${RAVE_SDK_PATH:-$quest_dir/../../RAVESDK}"
# Defaults are where the swift.org .pkg (installed for this user) and
# `swift sdk install` put them.
: "${SWIFT_ANDROID_BIN:=$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
: "${SWIFT_ANDROID_BUNDLE:=$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle}"
: "${ANDROID_NDK_HOME:=$HOME/Library/Android/sdk/ndk/27.0.12077973}"
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
