---
paths:
  - "Quest/**"
  - "docs/plans/quest-parity-roadmap.md"
---

# Convolution: Quest port

## Resume here

The port is merged into Hypnos and RAVESDK `main` (2026-10-08). The authoritative
forward plan is `docs/plans/quest-parity-roadmap.md`; it records source evidence,
open findings, ownership boundaries and milestone exit criteria. `Quest/README.md`
contains the working toolchain/deployment recipe and prior device observations.
Read both before extending features. Old work branches are not required to build.

The next slice is correctness and ownership: account-scoped downloads/offline
sync, chapter ends derived from all chapters, and correct active stream/job IDs
when switching quality. Then migrate duplicated Jellyfin backend decisions into
portable RAVESDK services and replace mutable JSON/global UI state with typed
repositories/ViewModels. The earlier first-two-milestone implementation is a
foundation, not completed production parity. Do not start object audio before
these session/backend boundaries are established.

## Architecture constraints

- `RAVEMediaCore` shares subtitle parsing, Jellyfin HTTP construction, quality/
  stall rules, Up Next ordering and segment policy with Apple. RAVEUI re-exports
  it. `RAVEQuestCore` exposes UTF-8 JSON through a C ABI/JNI. It still contains
  duplicated Jellyfin DTOs/planning; the roadmap explicitly retires that debt.
- Shared capabilities become targets inside RAVESDK or RAVEEngine; never a third
  sibling package. SDK and Engine do not depend on one another. Keep decoder,
  credential-store, graphics and UI framework bindings platform-specific.
- Compose owns library/settings/controls. `PlaybackSession` owns the one player,
  audio/clock, subtitles and reports; Home/Spatial/OpenXR activities borrow
  surfaces. Preserve time, pause intent and chosen tracks across every switch.
  Separate logical session identity from Jellyfin job identity and account.
- Never send frames, PCM or realtime pose updates through JSON polling. Spatial
  poses use one SDK reference space, meters and xyzw quaternions. Pose lifecycle,
  audio clock alignment and Home tracking access still need implementation.
- The native OpenXR presentation is retained behind the DEBUG fixture's
  `presentation: "native"`; normal playback uses Home or Spatial SDK.

## Device-proven details to preserve

Quest 3 on Meta VR OS SDK 207 confirmed Home HEVC and packed SBS playback,
sound, transport, subtitles, library contrast/layout, movable secondary Settings
window, picture dragging, following controls and paused-playhead handoffs/dock.
Caption/control compositor layers at higher density improved softness but did
not establish a resolution or performance benchmark. Controller versus hand
input is not separately confirmed; Quest 2 and older-OS fallbacks need checks.

Direct video panels bind ISDK interaction in `panelSetup` after SceneObject
creation. Captions use `NoCollision` so they cannot intercept picture input.
Initial placement waits for a valid head pose and seeds previous picture pose
immediately; otherwise the follow-controls transform applies placement twice.
Half SBS/OU must not apply the squeeze twice through pixel aspect ratio. Native
eye crops inset one pixel to avoid an adjacent-eye filtering seam. These were
device-found fixes; preserve them when refactoring presentation bindings.

Home stereo is gated by OS SDK 207; older releases route stereo into Spatial
mode. Secondary windows have the SDK's inline fallback. Settings currently
shows informational rows. Object audio is not rendered; film/disc package
downloads, offline subtitle sidecars, series/season navigation and fake-3D
remain incomplete. Read the roadmap for the additional correctness risks.

## Build and validation

Use the matching open-source Swift 6.3.3 toolchain and Android Swift SDK, not
Xcode's Swift. Set `SWIFT_ANDROID_BIN`, `SWIFT_ANDROID_BUNDLE`,
`ANDROID_NDK_HOME`, `ANDROID_HOME` and JDK 21's `JAVA_HOME` as documented in the
README, then run `./Quest/build-core.sh` followed by
`./Quest/gradlew -p Quest :app:assembleDebug`. Build scripts resolve sibling
RAVESDK by relative path and package the arm64 runtime dependency closure.
Generated SDK/native libraries/APKs stay ignored. Build from the actual
`apple-worktree` app directory when working in isolation.

After shared API changes, compile the Android Swift product/APK and affected
Apple consumers on visionOS/iOS/tvOS/macOS. Use `~/bin/build-and-sign --no-deploy`
for the visionOS check and the established platform checks for other targets.
Record new build/device evidence separately from earlier confirmations.

Use disposable Jellyfin/Stash/Nextcloud fixtures; never use the real Stash
server. Request a Quest 2/3 connected via USB/ADB when a device gate requires
one. Recent Horizon OS makes scrcpy screenshots unsuitable; use headset
observations and sanitized logs. Do not log credentials, URLs or user titles.
The debug launch fixture is deleted after reading and must remain DEBUG-only.

## Cross-repo handoff

Commit shared-package changes first and `apple-worktree land` their branch
refs, then commit app bindings. Updating a clone alone does not update the
primary package `main`; perform the explicitly authorized integration there.
When continuing after this merge, create any requested new worktree from the
current primary branches so later audio/depth changes are included. Update the
roadmap when findings close, including validation evidence rather than just
changing their status.
