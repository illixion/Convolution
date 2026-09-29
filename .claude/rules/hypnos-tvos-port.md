---
paths:
  - "**/Views/TV/**"
  - "**/TVTab.swift"
  - "**/TVLab/**"
  - "**/JellyfinPlugin/**"
  - "**/scripts/dev-jellyfin.sh"
---

# Hypnos: tvOS port

The same target builds for tvOS 26.2+ (`SUPPORTED_PLATFORMS` adds appletvos,
appletvsimulator; device family adds `3`, alongside iOS/iPadOS's `1,2,7`).
Compile check:

```bash
xcodebuild -project Hypnos/Hypnos.xcodeproj -target Hypnos -sdk appletvos \
  SDKROOT=appletvos SUPPORTED_PLATFORMS='appletvos appletvsimulator' \
  TARGETED_DEVICE_FAMILY=3 TVOS_DEPLOYMENT_TARGET=26.2 CODE_SIGNING_ALLOWED=NO \
  SYMROOT=<scratch dir> build
```

**Always compile all three platforms before committing.** tvOS is the
strictest of the three SDKs here — several APIs the iOS build happily links
(`Slider`, `DatePicker`, `DisclosureGroup`, `popover`, `.textFieldStyle(.roundedBorder)`,
`UIPasteboard`, `Gauge`, `navigationBarTitleDisplayMode`, `DragGesture`,
`UIActivityViewController`, `FileDocument`/`fileExporter`/`fileImporter`,
`WebKit` at all) are unavailable on tvOS, and the whole shared module
(views the tvOS UI never presents included) has to compile as one target.

## Root UI: a real Apple TV app, not a squeezed iPad UI

`Views/TV/` is a from-scratch root, selected in `HypnosApp` for `os(tvOS)`
(`TVRootView`, a `WindowGroup` alongside iOS's), built for a Siri Remote and
the focus engine — it shares data (`AppModel.galleryImages`/`galleryVideos`,
`MediaContainer`, `FilmSession`) with the visionOS/iOS screens but reuses
almost none of their views, whose gestures and chrome are touch/gaze-shaped:

- **`TVRootView`** — a plain `TabView`, which tvOS renders as the platform's
  own top tab bar with no ornament or custom chrome needed. Five tabs:
  Pictures, Videos, Albums, Films, Settings (`TVTab.swift`, a small tvOS-only
  enum — not an extra case on the shared `Tab`, which is keyed to
  `RAVEA11y`/`RAVETabItem` and the visionOS/iOS developer-tab rules). No
  Windows tab (one scene, nothing to summon), no Filters tab, no Remote
  tab. A sixth, Console (RAVEConsole's live log), appears while Settings →
  Developer → Show Debug Console is on.
- **`TVPicturesTabView` / `TVVideosTabView`** — `LazyVGrid` over the same
  source/filter/pagination the visionOS/iOS grids use
  (`loadInitialGallery`/`loadNextPage`/`hasMorePages`, and the `Videos`
  equivalents). Cells are plain `Button`s styled `.buttonStyle(.card)` for
  the standard tvOS focus lift — no custom hover/press gesture code, unlike
  `GalleryThumbnailView`'s long-press-to-QuickLook handling (touch-only).
  Thumbnails load through the existing `MediaThumbnail` view
  (`Views/MediaThumbnail.swift`), already gesture-free and cross-platform.
- **`TVPhotoViewerView`** — fullscreen image. Siri Remote left/right
  (`.onMoveCommand`) move prev/next, Play/Pause (`.onPlayPauseCommand`) starts
  or stops a slideshow timer, Menu (`.onExitCommand`) dismisses. None of
  `PhotoDisplayView`'s rendering tiers, adjustments or 3D modes are reused.
- **`TVVideoPlayerView`** — `AVPlayerViewController` via
  `UIViewControllerRepresentable`. **There is no WebKit fallback on tvOS** —
  WebKit doesn't exist there at all — but it still follows the same two
  moves every other AVFoundation path in the app makes before opening a URL:
  a `photos-asset:///` identity resolves through `PhotosAssetStore` first;
  every other source runs through `NativeVideoDecodeProbe.canPlayNatively`
  (which is what the VP9 supplemental decoder below actually unlocks — VP9
  *inside an MP4* can decode, but the WebM *container* still can't) and
  falls back to Stash's HLS transcode (`GalleryVideo.transcodeStreamURL`) —
  the *only* fallback tier here, unlike the two-tier native/WebKit split
  visionOS and iOS get — when it can't; a source with neither simply reports
  it can't play rather than showing a stuck black screen. Every URL goes
  through `MediaAuthorization.shared.asset(for:)`/`authorizedURL(_:)` so a
  Stash server behind a login authenticates like everywhere else in the app
  (see "Auth" below). DEBUG-only `tvAutoOpenPictureIndex=N` /
  `tvAutoPlayVideoIndex=N` launch args (mirroring `tvInitialTab`) open a
  specific gallery item's viewer/player immediately, since there is no other
  way to drive a tap into either view for testing this path.
- **`TVAlbumsTabView`** — the same `MediaContainer` grid and
  `AppModel.applyContainer(_:isVideo:)` the visionOS/iOS Albums tab uses;
  switches the tab selection to Pictures/Videos afterward instead of a
  window-model field. **Local's nested folder browser
  (`LocalFolderBrowserView`) isn't ported** — built for pointer/touch
  up/down-a-folder-stack taps — so Local shows a placeholder directing back
  to Pictures/Videos instead. Known gap.
- **`TVFilmsTabView`** — Jellyfin search over the existing `FilmSession`,
  presenting `FilmPlayerView` unchanged. `FilmPlayerView` already has a real
  `#elseif os(tvOS)` branch (added alongside the visionOS/iOS ones): the
  picture only, no `FilmStageView`, and a `Slider`-free transport
  (`TVFilmTransport`, `Views/FilmPlayer/FilmPlayerView.swift`).
  Atmos object audio plays through RAVEFilm's `FilmPhaseStageView`
  (RAVESDK's `RAVESpatialAudio`, a PHASE stage), not RealityKit's
  `FilmStageView`: PHASE is one of the engines the system gives AirPods
  head tracking and the listener's personalized spatial audio profile to,
  and RealityKit isn't. Both need entitlements
  (`com.apple.developer.coremotion.head-pose`,
  `com.apple.developer.spatial-audio.profile-access`), which only the tvOS
  profile ("my atv prof") carries; iOS/visionOS stay on the wildcard profile
  on purpose (the VisionVNC app identity breaks Now Playing there). Output
  is forced binaural: on a HomePod mini stereo pair PHASE's automatic mode
  chose plain panning, which heard as stereo. Apps can't send real Atmos
  (AVAudioEngine and PHASE output is ≤ 7.1 PCM; only AVPlayer passes EAC3
  JOC through), and an AirPlay HomePod pair offers the app 2 channels
  anyway. The transport's Sound button opens `TVFilmSoundSettings` (room
  preset, reverb, room size, bass, head tracking, picture offset), saved
  by `FilmSession.saveSound()`. Measured with the FilmLabTV bench
  (`TVLab/`, `-FilmAudio 1`, and `-SpatialProbe 1` for the engine
  comparison): the Dolby demo plays with 12 elements, no underruns, and
  the picture within ~20 ms of the sound (AirPlay and AirPods Max).
  While the player shows it claims Now Playing (RAVEFilm's
  `FilmNowPlaying`, with a non-mixable session from
  `AudioSessionConfig.configureFilmPlayback()`): without that, an AirPods
  pause press went to Music, which took the session and silenced the
  film. The PHASE engine pauses with the film, because tvOS picks
  play-or-pause for the remote/AirPods from whether the app makes sound.
  The stage rebuilds after interruptions and output-device changes
  (pausing when the output goes away), and recentres on every resume and
  on the transport's Recenter button. Show Objects overlays
  `FilmObjectMapPanel` (top and front views, overhead count).
- **`TVSettingsView`** — a remote-friendly subset of `SettingsTabView`,
  laid out like the tvOS Settings app: a short top page of rows showing
  their current value (Set Up from Another Device, Library Source, the
  three servers, Cache, Developer), each opening its own page. No display
  adjustments, depth models, or Backup import/export (no Files app on tvOS
  to pick a file from or save one to). Two tvOS rules the pages follow,
  both learned on hardware: **no `Picker`** — its default style pushes a
  list that stalls on a blank page inside the tab bar ("_UIReplicantView
  as a subview of UIHostingController.view"), and its menu style is a pill
  sized to its label that focus skips from the tab bar and can't move past
  — so choices are full-width checkmarked rows; and **no trailing buttons
  in a row** (Clear, Sign Out), which moving down the list never reaches.
  `CacheSettingsSection`, `NextcloudSettingsSection` and
  `JellyfinServerSection` have `#if os(tvOS)` branches for both. Disabled
  rows can't take focus either, so an all-empty cache list ends focus at
  Cache Size. **A tab appearing or disappearing rebuilds the other tabs'
  content** (the Library tab shows up once Jellyfin is configured), taking
  view `@State` with it: with `.tag`/`.tabItem` tabs a pushed Settings page
  went blank with no way back. `TVRootView` uses `Tab(value:)`, which stops
  the blanking, and Settings keeps its navigation path and the setup
  receiver in `TVSettingsState` rather than `@State`, so a rebuild lands on
  the same page. (`Tab.hidden` would avoid the rebuild but is unavailable
  on tvOS.) DEBUG `-UITestDefault tvSettingsInitialPage=<page>` opens a
  Settings page directly; with it, a setup transfer can be driven in the
  simulator by decoding the QR code from a `simctl io` screenshot with
  `RAVESetupQRCode.codes(inImageData:service:)` and sending from a Mac
  harness.
- **Apple TV setup** (`Services/DeviceSetup/`, RAVESDK's
  `RAVEDeviceSetup`) — Settings → Set Up from Another Device
  (`TVDeviceSetupView`) shows a QR code; Hypnos on another device sends
  its server addresses and credentials to it, encrypted to the key in the
  code: the iPhone/iPad Camera opens the code's `hypnos://setup` link,
  and Settings → Apple TV → Scan a Photo of the Code works everywhere
  (`DeviceSetupSendSection`, then `DeviceSetupSendSheet` to pick servers).
  Neither route asks for camera or photo access. `DeviceSetupPayload` is
  what travels — Stash URL and API key, Nextcloud URL, user, app password
  and root, Jellyfin server, API key and signed-in session
  (`JellyfinAuth.install`) — deliberately not `SettingsBackup`, which
  leaves every secret out. The keys are copied, so each server lists the
  TV and the sender as one device. Needs `_hypnos-setup._tcp` in
  `NSBonjourServices` (Info.plist). `Packages/NextcloudMedia/Package.swift`
  now declares `.tvOS(.v26)` (2026-09-24) — an undeclared platform gets
  SwiftPM's ancient default deployment floor, not an excluded one, so
  linking the package from the tvOS target needs the explicit entry.
- **Default library source** (`AppModel.defaultTVLibrarySource`, `#if
  os(tvOS)`) — applied only when nothing is persisted yet (a fresh install):
  Stash if configured, else Nextcloud, else Photos when it's actually
  readable, else Local. This is tvOS-only because the general default
  (`.stash`) predates the setting and exists only to keep an *existing*
  non-tv install's behavior unchanged — tvOS has no such installed base
  to preserve, and Apple TV commonly has no iCloud Photos library at all
  (see Known gaps), so landing a fresh install on an empty, denied Photos
  tab would be a worse first impression than Local. A choice, once made
  (including the user's own), is still persisted exactly as before.
- **Photos on tvOS** — every `PHImageManager` request in
  `PhotosAssetStore` already sets `isNetworkAccessAllowed = true` (images,
  thumbnails, video) regardless of platform, since tvOS keeps almost
  nothing locally and every one of those requests may need to pull from
  iCloud Photos; no tvOS-specific change was needed there. What tvOS did
  need is **`TVPhotosLibraryStateView`** (`Views/TV/`) — the Pictures/Videos
  tabs' empty state when the Photos source is undetermined, denied, or
  genuinely empty, with the fix named explicitly ("enable iCloud Photos in
  Settings → Users and Accounts → iCloud on this Apple TV") rather than the
  visionOS/iOS `PhotoLibraryStateView`'s touch-shaped inline server form.
- **VP9 decoding**: `HypnosApp.init` calls
  `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)` once,
  guarded `#available(tvOS 26.2, *)`, matching the spike in
  `TVLab/FilmLabTV/YouTubeLab.swift`. Without it AVFoundation can't decode the
  WebM/VP9 sources Stash/Jellyfin commonly serve — there is no WebKit
  fallback to decode them another way.
- A DEBUG-only launch argument opens `TVRootView` straight to a given tab —
  `-UITest -UITestDefault tvInitialTab=Videos` — reusing the existing
  `-UITestDefault key=value` mechanism (`Support/UITestingConfiguration.swift`)
  rather than inventing a second one. This exists because there is no XCUITest
  driving tvOS (`HypnosUITests` stays visionOS-only) and `simctl`
  has no remote-button injection of its own, so it was the only way to get
  every tab in front of a screenshot.

## Auth (all platforms, found via tvOS testing)

"Authenticate every AVFoundation path" (commit ea220b7, `MediaAuthorization`)
holds on tvOS the same way it does everywhere else — `TVVideoPlayerView`
builds its `AVURLAsset` through `MediaAuthorization.shared.asset(for:)` — but
testing it against `scripts/dev-stash.sh auth` surfaced a real,
**pre-existing, all-platform** bug: `StashAPIClient.query` unconditionally
sent `Authorization: Bearer <apiKey>` for a plain Stash API key, which real
Stash's session middleware (`pkg/session.ApiKeyHeader`/`ApiKeyParameter` in
Stash's own source) rejects outright with a 401 — verified directly against
the dev instance (`ApiKey: <key>` header and `?apikey=` query param both
succeed; `Authorization: Bearer <key>` is a flat 401). `MediaAuthorization`
itself already had this right (`updateStashMediaCredential` registers
`.queryParam(name: "apikey", …)` for a plain key), so **stream/image URLs
worked while every GraphQL browse call silently 401'd** — this is exactly
what "the owner's real Stash now requires login" would have hit on any
platform, not just tvOS. Fixed to mirror `updateStashMediaCredential`'s two
cases: a plain key now sends the `ApiKey` header; a manually-pasted
`Bearer …` value (the existing escape hatch for a reverse proxy in front of
Stash — Cloudflare Access, Authelia, …) still goes out verbatim as
`Authorization`.

`scripts/dev-stash.sh auth [user pass]` (default `dev`/`dev`) turns login on
for the dev instance — `configureGeneral(username:password:)`, a form-POST
to `/login` for a session cookie, then `generateAPIKey` — so the app's
authenticated path has something to test against. The key is written to
`$root/config/dev-api-key.txt` and **never printed**; read it from that file
when configuring a test run (e.g. `-UITestDefault stashAPIKey=$(cat …)`).
That launch argument round-trips through `KeychainStore`'s existing
UserDefaults→Keychain migration (`AppModel.init` already calls
`KeychainStore.migrateFromUserDefaults(legacyKey: "stashAPIKey", …)` before
reading it) — no new plumbing needed, but the app's build **must be signed**
(the default ad-hoc simulator signing is enough; `CODE_SIGNING_ALLOWED=NO`
is not) or every Keychain call fails with `errSecMissingEntitlement`
(-34018), silently leaving the API key unset.

**Credentials are matched by host, and Stash and Jellyfin often share one.**
Behind a reverse proxy (`host/stash`, `host/jellyfin`) the Stash
`.queryParam("apikey")` credential was appended to every Jellyfin stream URL,
and Jellyfin 10.11 reads it as its own `ApiKey` (ASP.NET query keys are
case-insensitive), prefers it over `api_key`, and 401s the HLS playlist —
AVPlayer reports only `NSURLErrorDomain -1013`. `FilmSession` now registers
its server with `MediaAuthorization.excludeCredentials(under:owner:)` (from
`AppModel.init` too, for restored windows), and the macOS `-LibraryHarness`
replays every routed stream with a fake same-host Stash key both applied and
excluded, so this shows up as a `FAILED`/`playing` pair rather than a silent
blank player. `127.0.0.1` hosts both dev servers, so the dev setup has the
same layout.

## What's excluded, and why (capability flags + fencing)

`PlatformCapabilities` (`Support/PlatformShims.swift`) — visionOS-only
still means visionOS-only on tvOS: `supportsSpatial3D`,
`supportsImmersiveSpaces`, `supportsMultipleWindows`, `supportsStereoVideo`
(the windowed-stereo pseudo-3D pipeline — meaningless on a flat TV even
though it needs no immersive space) and `supportsWindowResizing` are all
false there, exactly as they already are on iOS; shared views that branch on
them need no tvOS-specific change. `deviceFamilyName` adds an `Apple TV`
case.

Whole-file or whole-feature `#if !os(tvOS)` fences, mirroring the iOS
pattern in the main CLAUDE.md:

- **MV-HEVC stereoscopic conversion** — `MVHEVCConverter.swift`,
  `ChunkBufferManager.swift`, `StereoscopicVideoPlayer.swift`. visionOS-immersive
  only; their caller (`StereoscopicVideoView`) was already `#if os(visionOS)`
  with an iOS stub, so nothing else needed to change.
- **Settings → Backup** (`SettingsBackupDocument`'s `FileDocument`
  conformance, and the `fileExporter`/`fileImporter`/`.settingsBackupImport`
  call sites in `SettingsTabView.swift` and `SettingsBackupImport.swift`) —
  no Files app / document picker on tvOS.
- **The Share button** (`ActivityViewController`/`ActivityHostController` in
  `Services/ShareSheetHelper.swift`, and its call sites in
  `PhotoOrnamentView`/`VideoOrnamentsView`) — no `UIActivityViewController`
  on tvOS, no AirDrop/Files/Messages target for a Siri Remote UX to hand a
  file to either.
- **WebKit-only files** (already `#if canImport(WebKit)` since commit
  f4f914e: the web video player, animated GIF/WebP/JXL views, pinned web
  pages, WebM thumbnails) — every *caller* of the types they declare
  (`PhotoDisplayView`'s animated-image tiers, `RemoteViewerWindowView`,
  `VideoWindowView`, `VideoQuickLookView`, `ThumbnailGenerator`'s WebM poster
  path, `RemoteViewerSceneRoot`'s web-page mode) is gated the same way, with
  a Metal/native fallback or a static first frame in place of the animation.
  **There is no WebKit fallback on tvOS, full stop** — an animated
  GIF/WebP/JXL shows its first decoded frame rather than animating, and a
  video whose format needs WebKit to decode simply doesn't play.

`Support/PlatformShims.swift` gained same-name stand-ins so the touch-only
SwiftUI list above compiles out of call sites that belong to visionOS/iOS-only
screens, without duplicating those views:

- `.selectableText()` → `.textSelection(.enabled)` elsewhere, no-op on tvOS.
- `.roundedTextFieldStyle()` → `.textFieldStyle(.roundedBorder)` elsewhere,
  `.textFieldStyle(.plain)` on tvOS.
- `.popover(isPresented:content:)`, `#if os(tvOS)`-only overload standing in
  as a `.sheet` — scoped to exactly the shape every call site uses so it
  can't shadow or ambiguate SwiftUI's real (defaulted-parameter) `popover` on
  iOS/visionOS.
- `platformDisclosureGroup(content:label:)` (a free function, not a `View`
  extension — `DisclosureGroup` is a concrete type used as a value, not a
  modifier chained off `self`) — the real `DisclosureGroup` elsewhere, an
  always-expanded `VStack` on tvOS.
- `hidesStatusBar` gained a tvOS branch (no status bar there either, nothing
  to hide) alongside its existing visionOS/iOS ones.

Remaining `Slider`/`DatePicker`/`DragGesture`/`Gauge`/
`navigationBarTitleDisplayMode`/`UIPasteboard` call sites are wrapped
`#if !os(tvOS)` individually at each site (`FiltersTabView`,
`RemoteTabView`, `VisualAdjustmentsPopover`, `Video3DSettingsSheet`,
`GPUMemoryMonitorView`, `VideoControlBar`, `MediaDetailSheet`,
`DepthCacheSettingsView`/`DepthPipelineSpikeSection`, `ContentView`,
`Views/IOS/IOSRootView.swift`) — all belong to visionOS/iOS-only screens the
tvOS root UI never presents, so the tvOS branch is dead code kept only to
satisfy the compiler. `CacheBudget.volumeStats()` falls back to the plain
`volumeAvailableCapacityKey` on tvOS (`volumeAvailableCapacityForImportantUsageKey`
doesn't exist there).

## Known gaps

- **Local library folder browsing** (Albums tab) — not ported; Local shows a
  placeholder on tvOS.
- **Animated GIF/WebP/JXL** — render as a static first frame, not animated
  (no WebKit).
- **Photos as a library source** may have little or nothing to show on a TV
  that has never had a personal camera roll in the way iOS/visionOS do;
  Stash and Local remain the practical sources. It works end to end when
  iCloud Photos *is* on for the signed-in account (network access is always
  allowed — see above), and the empty/denied states point at
  Settings → Users and Accounts → iCloud rather than showing a bare "no
  photos" message.
- **tvOS has no XCUITest coverage.** `HypnosUITests` stays visionOS-only;
  the DEBUG launch-argument tab selector above is the only automated hook
  into the tvOS UI so far.

## Icon

`Assets.xcassets/AppIcon.brandassets` — tvOS's layered-image-stack format
(`App Icon.imagestack`, three fully-opaque Front/Middle/Back layers — a
partially-transparent layer fails validation — plus a `Top Shelf Image`),
derived from the same flattened 1024×1024 source the iOS `AppIcon.appiconset`
uses. A simple, valid set; no per-layer parallax art was made.

## Testing the Jellyfin Atmos Objects plugin: use the dev instance

**Never point the plugin, tests or agents at a real Jellyfin server**, same
rule as Stash (see main CLAUDE.md). `scripts/dev-jellyfin.sh up` runs a
disposable Jellyfin 10.11.11 in Docker at `http://127.0.0.1:8097` (loopback
only), builds `JellyfinPlugin/Jellyfin.Plugin.AtmosObjects` and installs it,
completes the first-run wizard (user `dev`/`dev12345`), creates a Movies
library, and mints an API key written to `config/dev-api-key.txt` under
`$HYPNOS_DEV_JELLYFIN_DIR` (default `~/.local/share/hypnos-dev-jellyfin`) —
chmod 600, never printed. `reset` wipes config/cache and redoes all of
that; `down`/`rm` stop it or delete everything.

Seeds a Movies library from `$HYPNOS_DEV_JELLYFIN_DEMO` (default
`~/Downloads/DolbyElement4K_VisionAtmos.mkv`, the public Dolby Atmos demo —
TrueHD + EAC3/JOC tracks over the same UHD HEVC video) with three items, one
per plugin code path:

- The demo itself, bind-mounted read-only — has both tracks, so
  `AtmosSceneService.GetState` picks TrueHD (see the "Two source formats"
  note in `JellyfinPlugin/README.md`).
- `DolbyElement-EAC3Only.mkv` — the demo remuxed to drop the TrueHD stream
  (`ffmpeg -map 0:0 -map 0:2 -c copy`), forcing the plugin onto the
  EAC3/Cavern path.
- `NoAtmosTest.mkv` — an ffmpeg-generated H.264 + plain (non-JOC) EAC3 5.1
  clip, for the "no Atmos objects" → 422/`unsupported` path.

**Naming gotcha, lost an hour to this once:** don't name a seeded item
ending in `-clip`, `-sample`, `-trailer` or any other Kodi/Jellyfin "extra"
suffix — such a file is filed as an *extra* of some other item instead of a
standalone `Movie` and never appears in `/Items` at all, with no error
logged anywhere. `NoAtmosTest.mkv`'s name is deliberately plain because of
this.

truehdd (`JellyfinPlugin/truehdd/`) only ships a macOS binary, which can't
run inside the (Linux) container, so the script also builds a **second,
Linux truehdd** — same already-patched checkout, inside a throwaway
`rust:1-bookworm` container. Two things about that build are worth knowing
if it ever needs touching again:
- **`cargo build --release` reliably gets SIGKILLed** compiling the
  `truehd` lib crate for `aarch64-unknown-linux-gnu` at this rustc version
  (1.98.1) — confirmed independent of `evo-protection`/hmac/sha2,
  independent of opt-level (1/2/3 all fail), and independent of available
  memory (still fails at 12 GiB). The same source's release **macOS** build
  (`truehdd/build.sh`) is unaffected. Looks like an LLVM/rustc backend bug
  specific to that target at that toolchain version. A plain **debug** build
  (opt-level 0) compiles fine and is what the script uses — slower than
  release, but this is only ever used to prove the TrueHD path still works
  end-to-end, not to measure its speed.
- Even the debug build needs more memory than colima's shared default
  profile (2 GiB) has, and that profile is shared with other running local
  containers (dev-stash, etc. — see `~/CLAUDE.md`'s rule on not disturbing
  other running work). So the script spins up a **second, throwaway colima
  profile** sized generously (8 GiB) just for this one build, talks to it
  directly via `DOCKER_HOST=unix://.../docker.sock` (not `docker --context`,
  which was seen to race and fail right after `colima start` returns), and
  deletes the profile again afterward. The binary itself is cached on the
  host at `$root/truehdd/truehdd`, so this whole dance only runs once.
- `colima delete` of that profile leaves docker's current context pointed at
  the nonexistent `/var/run/docker.sock` instead of restoring `colima` (the
  default profile's context) — the script explicitly restores it, since
  every later `docker` call in the script would otherwise fail.

Jellyfin's own startup-wizard endpoints (`/Startup/*`) are flaky for a few
seconds right after `/health` first turns 200 and right after
`/Startup/Complete` — a `POST /Startup/User` has been seen to 404, and a
subsequent `AuthenticateByName` with the exact password just set has been
seen denied, in each case only for a few seconds. The script polls
`/Startup/Configuration` before starting the wizard and re-verifies (with
retry) that the user actually landed before moving on, rather than trusting
the first response.

Coordinate mapping and end-to-end verification against this dev instance
(TrueHD vs EAC3, elevated-object positions, decode speed) are written up in
`JellyfinPlugin/README.md`.

### Library feature dev data (movies, a TV show, genres, watch state)

Beyond the three Atmos-plugin items above, `seed_synthetic_library` (called
from `seed_media`) seeds a second, fully offline slice of the same instance
for the Library feature: four more movies (`Crimson Tide Station`/Action,
`Paper Moon Diner`/Comedy, `The Quiet Ledger`/Drama, `Wide Static Field`/
Sci-Fi — deliberately a WebM/VP9 mux, since AVFoundation can't parse that
*container* at all regardless of codec, so this is the one item guaranteed
to force Hypnos's HLS-transcode fallback rather than direct play) and one
series, **Nebula Drift** (2 seasons × 3 episodes). Each gets a real Kodi-style
NFO (`write_movie_nfo`/`write_tvshow_nfo`/`write_episode_nfo`) plus generated
poster/fanart/logo art (`gen_art`) — shaped like real artwork so the
Library UI can be judged against it: a soft *textless* backdrop (real
fanart has no title; the logo carries it), a poster with its title at the
bottom, and a white-on-transparent clear logo. Jellyfin serves the logo's
alpha intact (verified; an earlier note here claimed it flattened alpha
onto white, which was wrong). A `.art-v2` stamp file in each item folder
regenerates art from the older flat-title-card version. Rendered with
ImageMagick's `magick`, not ffmpeg's `drawtext`: **this Homebrew ffmpeg build
has no libfreetype/drawtext support** (`No such filter: 'drawtext'`), even
though `freetype` is installed as a separate formula — confirmed directly,
so don't reach for ffmpeg text overlays here again without checking first.
Movies live under `data/movies/<Title> (<year>)/`, the show under
`data/tvshows/Nebula Drift/Season 0N/`.

Two libraries are created (not one): **Movies** scoped to `/media/movies`
and **TV Shows** scoped to `/media/tvshows`, both with
`EnableInternetProviders:false` — a single library rooted at `/media` (the
original shape, before the TV library existed) would otherwise try to
interpret every episode as its own movie. With providers off, local NFO is
the *only* metadata source in this whole instance; nothing here ever calls
out to the internet.

After the scan-completion wait, `seed_collection_and_watch_state` (idempotent
— safe on every `up`, not just first-time setup) creates a **BoxSet**
("Station Saga", grouping Crimson Tide Station + The Quiet Ledger) and seeds
watch state for the dev user: The Quiet Ledger marked fully played
(`POST /Users/{id}/PlayedItems/{id}`, which works fine against a plain API
key), Crimson Tide Station and Nebula Drift S1E1 left ~35%/~50% through via
`report_partial_progress` — the real `/Sessions/Playing` → `.../Progress` →
`.../Stopped` sequence `JellyfinLibrary`'s progress reporting uses, so this
doubles as a standing proof that call sequence actually moves watch state.

**Two real findings from getting that sequence to work, both worth knowing
before touching progress reporting again:**

- **`/Sessions/Playing*` silently no-ops against a plain admin-issued API
  key.** Confirmed directly: sending the exact same start/progress/stopped
  sequence with `X-Emby-Token: <api key>` left `PlayCount`/
  `PlaybackPositionTicks` completely unchanged (no error, just nothing
  happened), while the identical calls with a real `/Users/AuthenticateByName`
  session token worked. Jellyfin's session manager looks up an actual session
  object for the caller, and a bare `/Auth/Keys`-issued key doesn't have one
  the way a signed-in session does. `report_partial_progress` therefore
  authenticates its own throwaway session (`session_token()`) rather than
  reusing `$key`. **This is not just a seeding-script quirk** — it means a
  Hypnos install configured with only a Jellyfin API key (no sign-in) will
  see the same silent no-op for real playback-progress reporting; username/
  password sign-in (`JellyfinAuth`) isn't just a nicety, it's what makes
  progress sync work at all.
- **`MinResumeDurationSeconds` defaults to 300 (5 minutes).** Any item
  shorter than that — every synthetic clip here, all well under a minute —
  never gets a resume point or a partial `PlayedPercentage` no matter what
  position is reported; Jellyfin just marks a stopped item fully played
  instead once you cross its own small minimum. Confirmed directly (a 35%
  stop report left `PlaybackPositionTicks: 0, Played: true` at the default,
  a real 35% at `MinResumeDurationSeconds: 3`). `setup_and_scan` lowers it via
  `PUT /System/Configuration` on every `up`, so Continue Watching/Next Up
  have something to show against these short clips.

### Library UI: driving it without a remote or taps

DEBUG-only `-UITestDefault` hooks, since the tvOS simulator takes no
remote-button injection and the Xcode device-interaction tool can't press
tvOS buttons:

- `tvLibraryAutoOpenItemId=<id>` (tvOS) / `libraryAutoOpenItemId=<id>`
  (visionOS, iOS, macOS): push that item's detail page on launch.
- `tvLibraryScrollToShelf=N` (tvOS): scroll the home screen to shelf N, or
  a series detail page to its season/episode rows.
- `tvLibraryAutoPlay=1` (tvOS, with the auto-open): press Play on the
  detail page — the resume seek and next-episode autoplay are verified this
  way.

Pair them with `HYPNOS_DEV_JELLYFIN_SIGNIN_USER`/`_PASS` (env, `SIMCTL_CHILD_`
prefixed for `simctl launch`) and `-UITestDefault
filmPlayer.jellyfinServer=http://127.0.0.1:8097`. On iOS also pass
`-UITestDefault hasCompletedWelcome=1`, or the onboarding card covers the
app. For a macOS run, build with a throwaway
`PRODUCT_BUNDLE_IDENTIFIER` so `-UITestDefault` writes land in a disposable
container rather than the real app's settings.
