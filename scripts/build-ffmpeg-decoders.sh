#!/usr/bin/env bash
#
# build-ffmpeg-decoders.sh
#
# Builds the sideload edition's audio decoders: FFmpeg's DTS (core and DTS-HD
# MA lossless) and TrueHD/MLP decoders, nothing else, linked with the small C
# surface in Packages/FFmpegDecoders/Shim into one dynamic framework per
# Apple platform, packed into
#
#   Packages/FFmpegDecoders/HypnosFFmpeg.xcframework   (gitignored)
#
# Nothing links against the framework. The FFmpegDecoders package loads it
# with dlopen, and only a build with HYPNOS_FFMPEG embeds it (the app
# target's "Embed FFmpeg decoders" phase), so an App Store build has no
# FFmpeg code whether or not this script was ever run on the machine that
# made it (CLAUDE.md, "An App Store build never does Dolby processing
# itself").
#
# Licence: FFmpeg's own LGPL-2.1+ code (no --enable-gpl, no external
# libraries), as a separately loaded dynamic library in a sideload IPA whose
# complete source (MIT) and this script are public.
#
# Usage: scripts/build-ffmpeg-decoders.sh [--force]
# --force rebuilds FFmpeg itself (seven configure + make runs, about five
# minutes); without it a previous build's static libraries are reused and
# only the frameworks are relinked.

set -euo pipefail

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
MIN_OS=26.0
MIN_MACOS=14.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/ffmpeg-decoders"
SHIM="$ROOT/Packages/FFmpegDecoders/Shim"
OUT="$ROOT/Packages/FFmpegDecoders/HypnosFFmpeg.xcframework"
TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"

if [[ "${1:-}" == "--force" ]]; then
    rm -rf "$WORK/out" "$WORK/obj"
fi
mkdir -p "$WORK"

if [[ ! -f "$TARBALL" ]]; then
    curl -fL --retry 3 -o "$TARBALL.part" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    mv "$TARBALL.part" "$TARBALL"
fi
actual="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [[ "$actual" != "$FFMPEG_SHA256" ]]; then
    echo "SHA-256 mismatch for $TARBALL: $actual" >&2
    exit 1
fi
if [[ ! -d "$SRC" ]]; then
    tar -xf "$TARBALL" -C "$WORK"
fi

# One entry per slice: name, SDK, platform name for Info.plist, clang target
# triples (a macOS slice is universal).
SLICES=(
    "ios iphoneos iPhoneOS arm64-apple-ios$MIN_OS"
    "ios-simulator iphonesimulator iPhoneSimulator arm64-apple-ios$MIN_OS-simulator"
    "xros xros XROS arm64-apple-xros$MIN_OS"
    "xros-simulator xrsimulator XRSimulator arm64-apple-xros$MIN_OS-simulator"
    "tvos appletvos AppleTVOS arm64-apple-tvos$MIN_OS"
    "tvos-simulator appletvsimulator AppleTVSimulator arm64-apple-tvos$MIN_OS-simulator"
    "macos macosx MacOSX arm64-apple-macos$MIN_MACOS x86_64-apple-macos$MIN_MACOS"
)

# FFmpeg's static libraries for one triple, built once.
build_ffmpeg() { # sdk triple
    local sdk=$1 triple=$2
    local prefix="$WORK/out/$triple"
    [[ -f "$prefix/lib/libavcodec.a" ]] && return 0
    local arch=${triple%%-*}
    local sysroot cc build="$WORK/obj/$triple"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" -f clang)"
    rm -rf "$build"; mkdir -p "$build"
    echo "==> FFmpeg for $triple"
    (
        cd "$build"
        "$SRC/configure" \
            --prefix="$prefix" \
            --enable-cross-compile --target-os=darwin \
            --arch="$([[ $arch == arm64 ]] && echo aarch64 || echo x86_64)" \
            --cc="$cc" --sysroot="$sysroot" \
            --extra-cflags="-target $triple -Os -fno-common" \
            --extra-ldflags="-target $triple" \
            --enable-static --disable-shared --enable-pic \
            --disable-programs --disable-doc --disable-debug --disable-network \
            --disable-autodetect --disable-everything \
            --disable-avdevice --disable-avformat --disable-avfilter \
            --disable-swscale --disable-swresample \
            --disable-x86asm \
            --enable-decoder=dca,truehd,mlp \
            --enable-parser=dca,mlp \
            > configure.log 2>&1 || { tail -30 configure.log; exit 1; }
        make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -40 make.log; exit 1; }
        make install > install.log 2>&1
    )
}

# The framework's binary for one triple: the shim and FFmpeg in one dylib,
# exporting only the shim's functions.
link_one() { # sdk triple install_name output
    local sdk=$1 triple=$2 install_name=$3 output=$4
    local prefix="$WORK/out/$triple"
    local exports="$WORK/exports.txt"
    grep -o 'hyp_ff_[a-z_]*(' "$SHIM/CFFmpegShim.h" | tr -d '(' | sed 's/^/_/' | sort -u > "$exports"
    xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        -dynamiclib -Os -I"$prefix/include" -I"$SHIM" \
        "$SHIM/shim.c" "$prefix/lib/libavcodec.a" "$prefix/lib/libavutil.a" \
        -install_name "$install_name" -Wl,-exported_symbols_list,"$exports" -Wl,-dead_strip \
        -o "$output"
}

info_plist() { # path platform
    local platform=$2
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>HypnosFFmpeg</string>
    <key>CFBundleIdentifier</key><string>com.illixion.hypnos.ffmpeg</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>HypnosFFmpeg</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$FFMPEG_VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
$( [[ $platform == MacOSX ]] && echo "    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>" \
                             || echo "    <key>MinimumOSVersion</key><string>$MIN_OS</string>" )
</dict>
</plist>
PLIST
}

rm -rf "$WORK/frameworks" "$OUT"
ARGS=()
for slice in "${SLICES[@]}"; do
    read -r name sdk platform triples <<<"$slice"
    framework="$WORK/frameworks/$name/HypnosFFmpeg.framework"
    mkdir -p "$framework"
    if [[ $name == macos ]]; then
        binary_dir="$framework/Versions/A"
        install_name="@rpath/HypnosFFmpeg.framework/Versions/A/HypnosFFmpeg"
        mkdir -p "$binary_dir/Resources"
        plist="$binary_dir/Resources/Info.plist"
    else
        binary_dir="$framework"
        install_name="@rpath/HypnosFFmpeg.framework/HypnosFFmpeg"
        plist="$framework/Info.plist"
    fi
    binaries=()
    for triple in $triples; do
        build_ffmpeg "$sdk" "$triple"
        link_one "$sdk" "$triple" "$install_name" "$WORK/frameworks/$name/$triple.dylib"
        binaries+=("$WORK/frameworks/$name/$triple.dylib")
    done
    lipo -create "${binaries[@]}" -output "$binary_dir/HypnosFFmpeg"
    info_plist "$plist" "$platform"
    if [[ $name == macos ]]; then
        ln -s A "$framework/Versions/Current"
        ln -s Versions/Current/HypnosFFmpeg "$framework/HypnosFFmpeg"
        ln -s Versions/Current/Resources "$framework/Resources"
    fi
    ARGS+=(-framework "$framework")
done

xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT" >/dev/null
echo "Built $OUT"
ls "$OUT"
