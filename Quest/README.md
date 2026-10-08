# Convolution on Quest

An Android shell calling portable Swift, with Home-window and spatial
presentations of Jellyfin playback. This is a development app,
not the complete Quest port.

## Architecture

- `RAVESDK/RAVEMediaCore`: the existing subtitle parser and stream quality /
  stall rules, plus authenticated Jellyfin HTTP request construction. RAVEUI
  re-exports the models so Apple players retain their existing API.
- `RAVESDK/RAVEQuestCore`: dynamic Swift library exposing a UTF-8 JSON C ABI.
  Login, a first page of movies/episodes, playback planning, subtitle fetching,
  and watch progress run on an Android worker executor through JNI.
- Compose owns the library and shared transport UI. An app-scoped Java
  `PlaybackSession` owns Media3 / MediaCodec, soundtrack audio, subtitles and
  watch reports. Activities borrow surfaces; switching presentation preserves
  position, pause intent, subtitle track and the reporting session. Playback
  pauses while detached. This is not a background-playback service, and state
  does not survive process termination.
- `HomePlayerActivity` is an ordinary Horizon Home window. Flat video uses a
  SurfaceView; packed stereo uses OS 207's stereo composition API when available.
  Older OS versions route stereo into the spatial presentation.
- `SpatialPlayerActivity` uses Spatial SDK 0.14, passthrough, a movable video panel,
  a movable Compose control panel and a caption panel parented to the
  picture. Video uses `VideoSurfacePanelRegistration` for direct decoder output.
  Controls and captions use compositor layers at 320 dpi; captions have a dark
  backing and do not intercept pointer hits. Initial placement uses the first
  valid head pose, with the picture centred 15 cm above eye height. Controls
  follow a dragged picture and can also be moved independently. Direct-surface
  interaction components are bound after the panel SceneObject is created.
  The scene publishes listener and screen poses in a shared SDK reference space
  through `SpatialPoseSink`, the boundary for a future object-audio renderer.
  No object audio is rendered yet. Home-window pose access remains unresolved.
- The retained C++ `PlayerActivity` is the first milestone's OpenXR presentation,
  available through the DEBUG fixture's `presentation: "native"` setting.
  Its decoder writes directly to `XR_KHR_android_surface_swapchain`. No video
  texture is drawn into an eye buffer. Packed SBS/OU content uses one cropped
  quad per eye. Captions use a transparent surface slightly nearer the viewer.

## Build

Install matching **open-source Swift 6.3.3** and its Android Swift SDK. Apple's
Xcode toolchain cannot cross-compile this target. Follow the official
[Swift Android setup](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html),
including the SDK's `setup-android-sdk.sh` step with the NDK selected below.

Required Android tools: SDK 36, NDK `27.0.12077973`, CMake `3.22.1`, and JDK 21.
The Gradle wrapper selects 8.13; AGP is 8.11.1 and Kotlin/Compose compiler 2.1.0.
The Android 14 minimum follows Spatial SDK; stereo Home windows additionally
require Meta VR OS SDK 207. JSDK stubs are compile-only and never packaged.
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

Home and spatial modes use the same Play/Pause, ±10s and scrub controls. **Spatial
view** enters the passthrough scene. **Window** returns through Horizon Home;
it is unavailable for stereo on OS versions below 207. Library returns to the
Compose catalog, whose Resume button reuses the retained session.

The following controller shortcuts apply to the retained native presentation:

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
`subtitleLanguage`, and `presentation` (`spatial`, `native`, or default Home).
Push a file to `/data/local/tmp/` and copy it with
`adb shell run-as com.illixion.convolution.quest cp ... files/dev-launch.json`.
It is consumed and deleted at startup. Keep fixtures out of Git and avoid
putting credentials or access tokens in shell arguments or logs.

## Validation and limits

The first milestone's native presentation on Quest 3 has loaded the Swift library, authenticated to the disposable Jellyfin,
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

The hybrid app builds and runs on Quest 3 after its update to OS SDK 207. The user
confirmed Home-window HEVC picture, sound and controls while Home remained
visible, then confirmed correct SBS proportions, stereo and French captions.
Spatial passthrough video also runs, and telemetry confirms listener/screen
pose updates. The first spatial controls/captions were blurry; compositor
layers and increased pixel density improved them, though the user still described
some softness. The user confirmed picture dragging, caption backgrounds,
normal-sized controls below the picture, and Window → Spatial mode changes
preserving the paused playhead. Telemetry also records video grab transitions.
The retained native presentation was not visually rechecked after this refactor.

Still outside this slice: Stash browsing, full Jellyfin home / pagination /
Up Next / skip segments, offline downloads, object audio / Opus rendering, MVC
discs, separate confirmation of controller versus hand input, rich subtitle styling and adjustable stereo subtitle depth,
HDR tone-mapping validation, and depth-based 2D→3D. No comparison against
Bigscreen's sampling path or other players has been established.
