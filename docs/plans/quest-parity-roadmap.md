# Quest parity roadmap and architecture review

Reviewed: 2026-10-08. Source baseline: Hypnos `ce89f56` on `quest-player`,
RAVESDK `890804c` on `wt/Hypnos-quest-player`. The worktree includes the primary
repos' audio updates through Hypnos's `22ee5c8` merge and RAVESDK's `6f41b8e`
merge. This review is based on source inspection and the earlier recorded
build/device results; it does not claim fresh headset validation.

## Assessment

The hybrid architecture is worth continuing. Compose/VR Layout SDK owns Home
windows, Spatial SDK owns the passthrough presentation, Media3 owns normal
Android decoding, and portable Swift owns media and server decisions. Keeping
native UI and decoder adapters is necessary; sharing their business rules is
what prevents the platforms from becoming separate products.

The current implementation is a working development player with a library UI,
not yet a maintainable feature-parity implementation. The first two milestones
established the toolchain and added library features, but their production
completion still requires shared backend convergence, account isolation,
durable storage and lifecycle verification. Stop extending the current mutable
JSON/global-state design before adding object audio or additional sources.

### What is already sound

- `RAVEMediaCore` builds without Apple UI/decoder frameworks. Subtitle parsing,
  quality levels, stall rules, Up Next ordering and skip visibility/landing
  rules are reused by Apple and Quest.
- `RAVEQuestCore` is a target inside RAVESDK, with a C ABI and UTF-8 JSON over
  JNI. This avoids depending on Swift's object ABI. Native returned-buffer
  ownership is explicit and JNI frees the Swift buffer.
- One app-scoped `PlaybackSession` owns the Media3 player and intended playback
  state. Home, Spatial SDK and the retained OpenXR adapter borrow surfaces.
  The same session preserves playhead/pause through presentation changes.
- Video takes a decoder surface path. Compose provides controls and captions;
  it does not copy decoded frames through Swift or JSON.
- Spatial listener and picture poses are published in one SDK reference space.
  This is a useful starting boundary for audio attached to the picture.
- Runtime packaging walks the shared-library dependency closure and fails on
  missing dependencies. The matching Swift/Android toolchain is documented.

### Concrete findings to address

| Priority | Finding and evidence | Required outcome |
| --- | --- | --- |
| P0 | Downloads, saved plans and offline positions in `MainActivity.kt` are keyed only by item ID. Plans erase server/user identity; `syncOfflineProgress` sends every queued record using the newly signed-in account. | Namespace records by stable server/account/item identity, preserve non-secret ownership metadata and sync only the owning account. Migrate or quarantine legacy records rather than guessing their owner. |
| P0 | `QuestCore.swift` filters chapters to recognized skip names **before** finding the next boundary. Apple `JellyfinLibrary.chapterSegments` finds boundaries among all chapters. An Intro at 0, ordinary Chapter at 90 and Credits at 3600 becomes a 3600-second intro on Quest. | Share the entire chapter-to-segment algorithm. Its end is the next chapter, including ordinary/unnamed chapters, or runtime; validate times and minimum lengths. |
| P0 | `PlaybackSession.switchQuality` receives a newly generated `playSessionID` but replaces only URL/quality. Reports continue using the old ID; outgoing transcodes have no explicit cleanup path. Core planning also hardcodes `DeviceId=convolution-quest`, although login has a generated device ID. | Keep a stable logical playback identity while tracking each server stream/job identity separately. Use the installation's device ID, report the active stream correctly and retire replaced jobs without resetting the playhead. |
| P1 | `signIn` publishes a nonempty authorization header before authentication succeeds; errors do not clear it. The UI uses nonempty authorization to select the signed-in screen. `signOut` leaves home/search shelves and paging state behind. | Explicit authentication state; commit the account only after successful login, clear all account state/caches on logout, reject stale completions from an earlier account generation. |
| P1 | `RAVEQuestCore` has its own Jellyfin DTOs, list requests, playback URL construction and download routing. Apple uses PlaybackInfo, remux/object-audio/disc routing and richer permission/offline behavior. Shared HTTP construction alone does not share that backend. | One portable server client and planner, with platform capability input. Apple and Quest become adapters around it. |
| P1 | `MainActivity` owns network operations, settings and download records; Compose reads mutable `JSONObject` lists and global `LibrarySession`. In-place changes and IO callbacks lack a coherent state publication/cancellation rule. Poster cache keys omit server/account. | Typed immutable UI state, repository/ViewModel ownership and account-aware cache keys. Publish state on the UI dispatcher and bound/cancel work on account changes. |
| P1 | Downloads are marked `downloaded` when queued. No downloaded-library entry exists without signing in; saved plans omit duration, while completion sync reads duration. Subtitle tracks are deliberately removed for offline playback. | Durable offline catalog, explicit queued/running/ready/failed states, completion metadata and subtitle sidecars. Offline launch works without reaching Jellyfin. |
| P1 | Most successful core replies omit `protocolVersion`; Java accepts missing versions and discards structured error codes. The synchronous C entry waits without an overall deadline and Kotlin coroutine cancellation does not cancel its detached Swift task. | Consistent typed response envelope, validated versions/errors, request IDs, bounded requests and cancellation semantics. |
| P2 | Playback controls expose basic transport; Settings is informational. Series shelves can open the generic Play detail even though Series/Season items need navigation. Movies/Episodes filter the pages of a combined catalog. | Type-specific paging and navigation, real settings, playback audio/subtitle/quality controls and next-episode behavior. |
| P2 | Subtitle cues are scanned in full every 50 ms. JNI skip polling serializes every segment repeatedly and uses `controlsVisible=true`. Spatial pose publication allocates arrays each frame; sink lifecycle/reference-space invalidation is unspecified. | Indexed cue lookup and event/snapshot state. Reuse session metadata and pass actual chrome visibility. Keep realtime pose/audio paths allocation-free and explicitly invalidate stale poses. |

Evidence files: [MainActivity](../../Quest/app/src/main/java/com/illixion/convolution/MainActivity.kt),
[PlaybackSession](../../Quest/app/src/main/java/com/illixion/convolution/PlaybackSession.java),
[CoreBridge](../../Quest/app/src/main/java/com/illixion/convolution/CoreBridge.java),
[Library UI](../../Quest/app/src/main/java/com/illixion/convolution/LibraryUI.kt),
[Spatial presentation](../../Quest/app/src/main/java/com/illixion/convolution/SpatialPlayerActivity.kt),
[Apple Jellyfin client](../../Hypnos/Hypnos/Services/Library/JellyfinLibrary.swift),
and sibling RAVESDK's `Sources/RAVEQuestCore/QuestCore.swift` and
`Sources/RAVEMediaCore/`.

## Ownership rules for the next implementation

| Layer | Owns | Does not own |
| --- | --- | --- |
| RAVESDK portable targets | Server DTOs/requests, normalized library models, playback/download planning, watch-state reconciliation, subtitle parsing/preferences/timing, segment derivation, quality/governor rules, film scene/bundle formats and timeline math | Platform views, decoder surfaces, Keystore/Keychain or realtime audio callbacks |
| `RAVEQuestCore` | Thin typed boundary over portable services; command validation, response serialization, handle/request lifetime | A second Jellyfin implementation or an Android-specific fork of shared policy |
| Apple app adapters | Map shared results into existing UI models; Apple capabilities, credential storage, URLSession background transfers, AVFoundation/PHASE/Metal bindings | Another copy of server rules already migrated to RAVE |
| Quest repositories and session | Android persistence/transfers/connectivity, lifecycle, Media3/codec/audio bindings; UI-dispatcher state snapshots and session commands | Server DTO decoding or duplicated subtitle/skip/quality policy |
| Compose/Home/Spatial/OpenXR presentations | Window and panel geometry, input, native styling, caption rendering and surface acquisition/release; publish picture/listener poses | Network calls, decoder/clock ownership or watch-state mutation |

Keep `RAVEMediaCore` for established portable media/library rules. Extract film
data and scheduling policies into a portable target inside RAVESDK if their
dependencies warrant it; do not create a third sibling package. RAVESDK and
RAVEEngine retain no dependency on each other. A sensor adapter may use Engine
capabilities, with the app connecting them to SDK playback.

The goal is shared behavior with platform-specific capability choices. Quest
can directly decode formats that Apple needs remuxed, so plans must accept a
capability descriptor rather than inherit Apple's codec assumptions. Keep
framework imports at bindings. Move existing implementations and convert both
consumers in the same change; avoid a permanent copy kept for compatibility.

Use the C/JSON boundary for low-frequency commands and library snapshots.
Version its schema and decode to Kotlin data classes once. Do not send pixels,
PCM or per-frame pose updates through JSON/JNI polling. Separate logical media
session, server stream job, presentation attachment and account identity.

## Ordered implementation plan

### 1. Repair correctness and define account/session ownership

- Fix the P0 findings: scoped offline ownership, shared chapter boundaries and
  server stream identity/cleanup. Preserve position and pause intent on every
  handoff, quality change and source renewal; never report an accidental zero.
- Make authentication transactional, clear account-owned state on logout and
  fence asynchronous callbacks by account/session generation.
- Distinguish DownloadManager transfer state from a ready offline item. Retain
  duration and media ownership; prevent syncing legacy unowned records.
- Document lifecycle states: preparing, ready/paused, playing, buffering,
  detached, ended, failed and closed. Late worker replies cannot revive a closed
  session. Audio focus and headset suspension obey explicit pause intent.

Exit: regression fixtures cover chapter boundaries, two accounts/servers,
failed login and quality-switch job cleanup; on Quest the same paused playhead
survives Home → Spatial → Library → Player with no stale account content.

### 2. Converge the shared backend and make Android state typed

- Move Jellyfin DTOs, paged queries, PlaybackInfo/source selection, stream/job
  planning and subtitle/segment discovery into portable RAVESDK services. Migrate
  Apple `JellyfinLibrary` and `RAVEQuestCore` to those services incrementally.
- Define capabilities for supported containers/codecs/stereo, remux/transcode,
  object audio and discs. Unknown formats fail closed or offer an explicit
  compatible route; no silent claim of 3D/object-audio support.
- Establish a versioned response envelope with stable errors/request IDs and
  bounded/cancellable work. Keep credentials out of URLs, persistence and logs
  where header authentication is supported. Store persistent Android credentials
  using a Keystore-backed mechanism when retained sign-in is introduced.
- Replace mutable JSON UI state with typed `LibraryRepository`, account state
  and ViewModel snapshots. Add typed playback plans/state; activities become
  presentation bindings. Cache artwork by server/account/item/artwork revision.
- Feed time/cost/capabilities into shared decisions; expose cancellation and
  transport through small adapters only where an actual platform difference
  requires them. Do not build an abstraction framework ahead of consumers.

Exit: both Apple and Quest call the same Jellyfin services and policy code.
Contract fixtures validate identical inputs with intentional capability-based
differences. Android core build and all affected Apple consumers compile.

### 3. Complete the everyday library and offline experience

- Implement Series → Seasons → Episodes, collections, server-side type-specific
  pagination, favorites, explicit Start Over and next-episode/autoplay controls.
  Refresh shelves from playback/watch events and tolerate individual shelf
  failures without losing the entire library.
- Make Settings functional and add in-player audio/subtitle selection, subtitle
  delay/language preference, quality status and manual quality switching. Use
  shared preference normalization and stall rules.
- Build an offline catalog independent of authentication/network availability;
  include artwork, subtitles, duration, scoped progress and storage limits.
  Support resume/retry/cancel/failure/deletion, process restart and ownership-aware
  watch-state reconciliation. Use DownloadManager for eligible direct transfers;
  add another Android transfer mechanism only for a demonstrated requirement.
- Keep offline format planning capability-driven; later film/disc packages plug
  into the same catalog rather than creating a separate Downloads product.

Exit: a paged library larger than 100 items, episode progression, disabled
download policy, offline cold launch, interrupted transfer and reconnect sync
are verified using disposable Jellyfin data. This completes the earlier
library milestone beyond its initial implementation.

### 4. Add object audio on the established session clock

- Extract scene/index/track models, compressed AOB1 parsing, encoding/budget
  decisions and portable scheduling from existing RAVEFilm code. Its present
  bundle parser is in the same file as Apple decoding; governor/client also
  have Apple logging/framework dependencies. They are not Android-ready yet.
  Preserve the latest primary-repo governor and fetch-ahead behavior during
  extraction; keep Apple PCM/PHASE rendering in its platform binding.
- Select and measure an Android Opus decoder and spatial renderer in a bounded
  spike. Do not assume SDK availability/performance or object-count limits.
  Prefer a reusable RAVESDK Android binding when another app needs the capability.
- Define meters, axes, quaternion order, media timestamps, audio output latency,
  reference-space generation and recenter behavior. The picture transform is
  the audio anchor; dragging the controls alone cannot move the sound stage.
- Use one authoritative media timeline. Replace the native soundtrack while
  object audio plays; avoid double sound and independently advancing clocks.
  PCM buffers/pose snapshots stay outside JSON; queues and memory are bounded.
- Spatial mode is the first supported tracked presentation. Investigate Home
  listener/screen pose access separately. If it cannot supply valid tracking,
  offer an explicit conventional soundtrack or Spatial mode. Invalidate poses
  on detach/reference reset; do not continue with stale head tracking.

Exit: lip sync, seeks, pause/resume, moving/recentering the picture, switching
audio tracks and link degradation work on Quest 3. Profile CPU, dropped channels,
latency and thermal/memory budgets; measure Quest 2 before claiming support.

### 5. Complete genuine stereo, subtitles and disc playback

- Centralize packed-stereo format/aspect/crop policy while preserving each
  presentation's native compositor binding. Cover half/full SBS and OU, eye
  swap, orientation and edge sampling. Improve caption size/background/depth
  with the shared subtitle model, including correctly anchored stereo captions.
- Port mvc3d/edge264 to Android in a measured spike. Adapt HTTP range reads,
  decoded eye frames, disc audio and PGS to the same playback session and film
  timeline; reuse its existing parser instead of rewriting the disc stack.
- Add object-audio/disc download packages to the portable catalog schema and
  Android transfer adapter. Treat unsupported codecs and costly software
  decode as capability limits with explicit fallback.

Exit: reference stereo/disc fixtures preserve eye geometry, captions, seeks
and AV sync. Quest 2/3 performance results determine supported disc profiles.

### 6. Broaden to the visionOS media workflows

- Inventory Pictures, Videos, Albums, Local, Stash, Nextcloud, metadata edits,
  selection/deletion, slideshow, incoming shares/URLs and window management.
  Record each as shared core, Android binding, or unsupported platform feature.
- Reuse/extract Stash GraphQL models/filters/mutations and Nextcloud wire logic;
  implement Android storage/permissions and image decoding. Do not grow a
  parallel Kotlin backend. Keep server mutation/deletion semantics explicit.
- Add photo viewing/adjustments and slideshow before model-based conversion.
  Share navigation/state/cache policy and portable math; use Android graphics
  bindings for pixels. Native Horizon window management follows platform affordances.
- Treat 2D→3D conversion as a separately measured feature: reuse existing depth
  refinement/warp math where portable, then validate LiteRT/QNN or another
  Android inference binding. No heuristic depth fallback; offer the feature only
  where measured frame/thermal budgets support it. Quest 2 remains genuine-3D
  only until evidence supports more. HDR sources need a validated SDR path.
- Remote/RoboFrame workflows follow after these core media paths, with the
  existing protocol and shared state-machine behavior. Apple-specific features
  such as Photos integration are capability differences, not promised replicas.

## Validation and maintenance gates

For each implementation slice, add focused regression coverage for shared
decisions and boundary behavior, then build the Android Swift product/APK and
affected Apple apps. Cross-platform public API changes require consumer builds,
not just a package test. Fixture sources are the disposable Jellyfin/Stash/
Nextcloud instances; never use the real Stash server.

Maintain a small acceptance matrix: Home/Spatial, flat/SBS/OU, controller/hand,
Quest 3/current OS and Quest 2/fallback OS. Check failed login, two accounts,
offline/process restart, unavailable codecs, network stalls, background/decoder
loss and stale surfaces. Quest 3 confirmed the earlier UI geometry/contrast,
subtitles and paused handoff/dock behavior; the `ce89f56` library additions have
build/install evidence but no recorded headset interaction confirmation yet.

Ask for a headset connected over USB/ADB when a device gate needs one. Use
headset observation and sanitized metrics; recent Horizon OS makes scrcpy
screenshots unsuitable. Do not require headset setup for documentation reviews.
Track first-frame latency, AV drift, dropped frames/channels, memory, thermal
behavior and surface reattachment. Preserve privacy labels in Apple DebugTrace
logs and equivalent structured/redacted Android diagnostics.

Work in the existing `apple-worktree`, commit package changes first, land their
branch refs, then commit app adapters. Primary-repo updates must be deliberately
synced into the worktree before affected implementation. This document is the
forward plan; its findings remain open until code fixes and validation are recorded.
