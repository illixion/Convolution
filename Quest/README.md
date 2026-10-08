# Convolution on Quest

First implementation slice: an Android shell calling portable Swift, with
Jellyfin playback on OpenXR compositor surfaces. This is a development app,
not the complete Quest port.

## Architecture

- `RAVESDK/RAVEMediaCore`: the existing subtitle parser and stream quality /
  stall rules, plus authenticated Jellyfin HTTP request construction. RAVEUI
  re-exports the models so Apple players retain their existing API.
- `RAVESDK/RAVEQuestCore`: dynamic Swift library exposing a UTF-8 JSON C ABI.
  Login, a first page of movies/episodes, playback planning, subtitle fetching,
  and watch progress run on an Android worker executor through JNI.
- Java owns sign-in, library selection, Media3 / MediaCodec, audio and transport.
  C++ owns the OpenXR session, controller actions and quad layers.
- The decoder writes directly to `XR_KHR_android_surface_swapchain`. No video
  texture is drawn into an eye buffer. Packed SBS/OU content uses one cropped
  quad per eye. Captions use a transparent surface slightly nearer the viewer.

## Build

Install matching **open-source Swift 6.3.3** and its Android Swift SDK. Apple's
Xcode toolchain cannot cross-compile this target. Follow the official
[Swift Android setup](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html),
including the SDK's `setup-android-sdk.sh` step with the NDK selected below.

Required Android tools: SDK 36, NDK `27.0.12077973`, CMake `3.22.1`, and JDK 21.
Python 3 packages the native runtime dependency closure.

```sh
export SWIFT_ANDROID_BIN=/path/to/swift-6.3.3/usr/bin/swift
export SWIFT_ANDROID_BUNDLE=/path/to/swift-6.3.3-RELEASE_android.artifactbundle
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.0.12077973"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
./Quest/build-core.sh
./Quest/gradlew -p Quest :app:assembleDebug
```

The default RAVESDK path is `../../RAVESDK` relative to `Quest/`, matching the
Apple worktree layout. Override with `RAVE_SDK_PATH` if needed. The build creates
an arm64-only SDK descriptor to avoid SwiftPM 6.3.3 selecting armv7 resources
from the multi-architecture SDK. Generated SDK files, libraries and APKs are
ignored by Git.

This app branch requires RAVESDK commit `36df41b` (available on
`wt/Hypnos-quest-player` in the package repository).

## Run on USB

Enable developer mode and USB debugging on a Quest 2 or Quest 3, connect it,
and accept the ADB authorization prompt in the headset.

```sh
adb devices
adb install -r Quest/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.illixion.convolution.quest/com.illixion.convolution.MainActivity
```

Open Convolution from Unknown Sources if the launcher panel is not visible.
Sign in to Jellyfin, choose a title, quality and subtitle track. Credentials
remain in memory for this app session; only the server URL and subtitle language
are saved. The app allows HTTP for local development servers.

| Controller input | Action |
| --- | --- |
| A | Pause / play (restart after the end) |
| B | Return to the library |
| X | Recenter the screen in front of the current head pose |
| Right stick left/right | Seek backward/forward 10 seconds |

For the disposable local Jellyfin, start `scripts/dev-jellyfin.sh up` and use
`adb reverse tcp:8097 tcp:8097`. The headset can then reach
`http://127.0.0.1:8097`. Never use a real Stash server for development checks.

A DEBUG-only `files/dev-launch.json` can automate local sign-in and one title.
Fields: `server`, `username`, `password`, `playName`, optional `startOver` and
`subtitleLanguage`. Push a file to `/data/local/tmp/` and copy it with
`adb shell run-as com.illixion.convolution.quest cp ... files/dev-launch.json`.
It is consumed and deleted at startup. Keep fixtures out of Git and avoid
putting credentials or access tokens in shell arguments or logs.

## Validation and limits

Quest 3 has loaded the Swift library, authenticated to the disposable Jellyfin,
listed 15 titles, and decoded the 3840×2160 HEVC demo with sound. Hardware decoder
initialization measured 54–84 ms; the first frame arrived about one second after
the compositor surface was created. The user confirmed pause and seeking.
The user also confirmed upright, readable orientation after enabling Meta's
image-layout extension and requesting OpenXR 1.0.34 (the initial 1.0.0 path
mirrored the picture). These are startup observations, not sustained playback or picture-quality
benchmarks. Some dropped frames were reported during seeks.

Apple visionOS, iOS, tvOS and macOS builds also pass with the shared code split.
The generated half-SBS clip decoded and seven French subtitle cues were fetched
and parsed on Quest 3. The user confirmed correct picture/caption proportions
after avoiding a duplicate SAR correction on half-packed content. Packed eye
crops inset one pixel to avoid compositor filtering across their boundaries;
the user confirmed this removed a cyan line at the picture's left edge.
Quest 2 has not been checked. Use `adb logcat -s ConvolutionCore ConvolutionMedia
ConvolutionXR` for code-defined telemetry. Recent Horizon OS versions prevent
scrcpy from providing useful app screenshots; headset observation is required.

Still outside this slice: Stash browsing, full Jellyfin home / pagination /
Up Next / skip segments, offline downloads, object audio / Opus rendering, MVC
discs, hand input, rich subtitle styling and adjustable stereo subtitle depth,
HDR tone-mapping validation, and depth-based 2D→3D. No comparison against
Bigscreen's sampling path or other players has been established.
