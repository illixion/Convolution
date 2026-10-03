# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hypnos is a visionOS app for Apple Vision Pro that displays images and videos with 2D to 3D spatial photo conversion. It integrates with [Stash](https://stashapp.cc/) media server via GraphQL API, supports local files, and can receive media via the system share sheet.

## Names

**Convolution** is the shipping, user-facing name (decided 2026-10-03; the App Store Connect
reservation is still pending). **Hypnos** is the internal codename and stays in code: the Xcode
project/scheme/folders, `Hypnos*` types, the `com.illixion.hypnos` bundle id and the `hypnos://` URL
scheme. User-visible strings (display name, permission prompts, in-app copy, README, the Jellyfin
plugin's display name) say Convolution. Never put "Dolby"/"Atmos" in user-facing text — say "object
audio".

## Workflow

Always create a git commit at the end of a task, without waiting for the user to ask. Group related changes into a single commit; keep the commit message focused on the "why".

## Build Commands

Run this command to test your changes:
```bash
xcodebuild -quiet -project Hypnos/Hypnos.xcodeproj -scheme Hypnos -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO
```

## iOS / iPadOS

The same target builds for iOS 26 (`SUPPORTED_PLATFORMS` covers iphoneos,
iphonesimulator, xros, xrsimulator; device family 1,2,7). Compile check:

```bash
xcodebuild -quiet -project Hypnos/Hypnos.xcodeproj -scheme Hypnos -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

**Always compile both platforms before committing** — a visionOS-only API is
an iOS build break and vice versa.

How the port is structured (all in `Support/` unless noted):

- **`WindowActions.swift`** — `@OpenWindowProxy` / `@PushWindowProxy` /
  `@DismissWindowProxy` property wrappers replace SwiftUI's
  `@Environment(\.openWindow)` etc. **everywhere**. Call sites keep the
  `openWindow(id:value:)` shape. On visionOS they wrap the real actions; on
  iOS they talk to `IOSWindowRouter`. Never read the raw environment actions
  in shared code — it will not compile on iOS.
- **`IOSWindowRouter.swift`** + **`Views/IOS/IOSRootView.swift`** — iOS has
  one scene. The value-carrying scene ids (`photo-detail`, `video-detail`,
  `shared-photo`, `remote-viewer`, `remote-alert`) become a stack of
  full-screen covers over the gallery; `console`/`gpu-memory`/
  `video-adjustments` become sheets; `main` dismisses back to the gallery.
  Opening a value already on the stack pops back to it (the summon).
  `HypnosApp` declares the visionOS scenes under `#if os(visionOS)`
  and a single `WindowGroup` hosting `IOSRootView` otherwise.
- **`PlatformShims.swift`** — iOS-only same-name stand-ins so shared views
  compile unchanged: `.ornament(...)` → edge overlay (horizontally scrolling
  when wider than the screen), `.glassBackgroundEffect()` → iOS 26
  `.glassEffect`, `.offset(z:)` → no-op, a **null-object
  `ImagePresentationComponent`** (every query answers mono/unsupported, the
  `Spatial3DImage` inits throw) so `PhotoWindowModel`'s 3D code compiles and
  fails closed, and `applySpatialAudioPolicy()` no-ops. Also the two
  cross-platform helpers: **`PlatformCapabilities`** (`supportsSpatial3D`,
  `supportsImmersiveSpaces`, `supportsMultipleWindows`, `supportsStereoVideo`,
  `supportsDiorama`, `supportsWindowResizing` — all false on iOS; shared views
  branch on these to hide controls) and **`WindowGeometry.request(scene,
  size:restriction:animated:)`**, the only way shared code may call
  `requestGeometryUpdate` (`.Vision` preferences don't exist on iOS).
  A bar that wants to know it is being dragged reads the shim's
  `\.ornamentIsScrolling` environment value, published down from the scroller.
  **Never attach a `DragGesture(minimumDistance: 0)` to an ornament bar**: it
  claims the touch at touch-down, the scroll view's pan never begins, and every
  control past the screen edge becomes unreachable (measured on an iPhone 18
  Pro Max, iOS 27 — identical bars scrolled 171pt without it, 0pt with it).
- **Whole-file `#if os(visionOS)` gates** with iOS stubs where other files
  reference the type: `Pseudo3DVideoPlayerView` (stub calls
  `onPlaybackError` so callers fall back to the flat player),
  `StereoscopicVideoView` (stub offers "Play as 2D"), `SlideshowSpatial3DLayer`
  (empty), `ImmersiveVideoView`, `Spatial3DImmersiveView`, `ManagedWindows`,
  `TabBarOrnament`, `HypnosAppIntents`, and `LiftHoverEffect`/
  `ScaleHoverEffect` (degrade to the system pointer hover).
- **`Views/MainTabCatalog.swift`** — which tabs are visible and what the
  slideshow button starts, shared by `TabBarOrnament` (visionOS) and
  `ContentView`'s iOS `TabView` + `Views/IOS/IOSTabToolbar.swift` (library
  switch and slideshow in each tab's navigation bar). The Windows tab is
  hidden on iOS.
- `VideoWindowModel.shouldUse3DMode` / `pseudo3DAvailable` and
  `PhotoWindowModel.switchToViewingMode` / `activate3DMode` /
  `presentAutoRestorePrompt` are fenced by `PlatformCapabilities`, so a
  remembered 3D preference never activates a 3D path on iOS.
- The iOS app icon is `Assets.xcassets/AppIcon.appiconset` (a flattened
  composite of the visionOS layer stack, which keeps the same `AppIcon` name).
- `HypnosUITests` stays visionOS-only.

## tvOS

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
are unavailable on tvOS, and the whole shared module (views the tvOS UI
never presents included) has to compile as one target.

The tvOS-specific root UI (`Views/TV/`), the all-platform auth bug tvOS
testing surfaced, the capability-flag/`#if !os(tvOS)` fencing, known gaps,
the tvOS icon format, and the disposable Jellyfin dev instance + Library
feature seed data are all documented in
`.claude/rules/hypnos-tvos-port.md` (auto-loads when touching `Views/TV/`,
`TVTab.swift`, `TVLab/`, `JellyfinPlugin/`, or `scripts/dev-jellyfin.sh`).

## macOS

Native SwiftUI on macOS 26 (`SUPPORTED_PLATFORMS` adds `macosx`,
`MACOSX_DEPLOYMENT_TARGET = 26.0`) — not Catalyst, not Designed-for-iPad.
Compile check:

```bash
xcodebuild -quiet -project Hypnos/Hypnos.xcodeproj -scheme Hypnos -destination 'generic/platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Sandboxed (`Hypnos/Hypnos.entitlements`, wired only for macOS via
`"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"` — iOS/tvOS/visionOS still ship with no
entitlements file at all): `app-sandbox`, `network.client` (Stash/Nextcloud),
`files.user-selected.read-write` (Settings → Backup's `fileExporter`/
`fileImporter`, which — unlike tvOS — already works unmodified on macOS under
sandbox with this entitlement). The app icon's `AppIcon.appiconset` gained a
`mac` idiom (16→512pt, 1x/2x) alongside the existing iOS `universal` entry,
generated from the same flattened 1024×1024 source as the other platforms —
square, no rounded-square mask baked in (a cosmetic gap, same spirit as
tvOS's "no per-layer parallax art was made").

The macOS window shape (real multiple windows, `Views/Mac/`, the menu bar),
the UIKit-gap seam files (`PlatformImage`, `PlatformPasteboard`,
`PlatformWindowScene`, the stubbed Metal/WKWebView views), Films audio
without head tracking, the `VideoPlayer`-crashes/`AVPlayerView`-doesn't
finding, and the reusable cross-platform-port pattern are all documented in
`.claude/rules/hypnos-macos-port.md` (auto-loads when touching `Views/Mac/`,
`Mac*.swift`, `HypnosCommands.swift`, `PlatformImage.swift`, or
`PlatformPasteboard.swift`).

## UI Tests (XCUITest)

```bash
./scripts/run-ui-tests.sh                                   # whole suite, ~3.5 min
./scripts/run-ui-tests.sh WelcomeFlowUITests                # one class
./scripts/run-ui-tests.sh WelcomeFlowUITests/testSkipDismissesTheFlowAndLandsInTheApp
```

`HypnosUITests` is the app's only test target and exists because **XCUITest is
the only way to drive a visionOS app's UI**: `simctl` has no tap/swipe/scroll
subcommand of any kind, so the alternative is coordinate math against a screenshot
through `macos-control`, one Touch ID prompt per session, and gestures the simulator
handles badly. XCUITest is accessibility-driven, needs no coordinates, and runs
headless. The script exists mainly to keep `-collect-test-diagnostics never` on every
invocation — without it a *passing* run hangs for exactly 600 s afterwards (see
`~/Projects/CLAUDE.md`).

Three pieces make it work:

- **`Shared/AccessibilityIdentifiers.swift` is a member of both targets.** It is the
  one file in the project referenced explicitly in `project.pbxproj` rather than
  picked up by the synchronized folder group, and that is the point: a test target
  shares no module with the app, so identifiers otherwise get written twice and the
  copy in the test target rots. Shared-component identifiers come from RAVEUI's
  `RAVEA11y` instead, which both targets link — a tab is `rave.tab.<enum case name>`,
  deliberately the case name rather than the display title, which is mid-rename.
- **`Support/UITestingConfiguration.swift`** applies `-UITestDefault key=value` launch
  arguments to UserDefaults before `AppModel.init` reads them (hence
  `HypnosApp.init` being written out rather than using a property default —
  a default value expression would run first). DEBUG-only, so a release build has no
  launch arguments that rewrite settings.
- **`AppLauncher.baseline` states the flags every test reads.** Resetting the defaults
  domain is not sufficient on the simulator: `cfprefsd` serves values that survive
  both `removeObject(forKey:)` and `removePersistentDomain(forName:)` — measured with
  `persistentDomain` returning empty, no plist on the device containing the key, and
  `bool(forKey:)` still returning `true` on the next line. Any new test that depends
  on a persisted flag must declare it via `defaults:` rather than assume a wipe.

Two things worth knowing before writing more:

- **Identify containers with `.accessibilityElement(children: .contain)`.** SwiftUI
  only puts a group in the accessibility tree when asked, so a bare
  `.accessibilityIdentifier` on a `VStack` attaches to nothing and the test cannot see
  it. `app.anyElement(id)` then avoids also having to guess which element *type* the
  view mapped onto.
- **Spatial 3D generation is device-only.** In the simulator it fails with
  `Spatial3DImageError error 9`, so the welcome sample's conversion test asserts the
  designed fallback (back to the flat photo, Convert offered again) rather than
  success. Anything else touching `ImagePresentationComponent` needs the same shape.

Not yet covered: any window actually *listed* in the Windows tab, which needs a
pop-out, which needs media. Seeding that is `simctl addmedia` plus
`simctl privacy grant photos` from outside the test process — harness work for
`run-ui-tests.sh`, not a gap in the app.

## Architecture

### App Structure
- **HypnosApp.swift** - App entry point defining scenes: main window, photo-detail pop-out, video-detail, shared-photo viewer (shared *videos* reuse video-detail), console, GPU memory monitor, remote-viewer, remote-video, remote-alert, and StereoscopicVideoSpace (immersive)
- **HypnosAppIntents.swift** - App-target glue for `RAVEOpenMainWindowIntent` (RAVEUI): the `AppIntentsPackage` chain plus the Siri/Shortcuts phrases ("Open a Hypnos window"). Exists because a visionOS icon tap with any window alive summons the nearest window to the user (dragging pinned windows out of their rooms) with no public opt-out — the intent is the supported way to always get a fresh main window at your location. The window-session registry itself is RAVEUI's `RAVEWindowSessionRegistry` (the local `WindowSessionRegistry` was deleted). The type window values persist their size as is likewise RAVEUI's now, `RAVECodableSize` — same property names as the deleted local `CodableSize`, so existing scene-restoration archives still decode.
- **AppModel.swift** - Central `@Observable` state container for gallery data, server config, filter state, video playback state, memory monitoring, and persisted settings (UserDefaults)
- **PhotoWindowModel.swift** - Per-window `@Observable` model for individual photo viewers. Contains all stored properties, init/start lifecycle, core image loading pipeline, interaction tracking, shared utilities, and resource cleanup. Split into extension files by concern:
  - **PhotoWindowModel+VisualAdjustments.swift** - Auto-enhance (3-tier cache), brightness/contrast/saturation adjustments, 3D adjustment preview with debounced reload
  - **PhotoWindowModel+Spatial3D.swift** - 3D mode activation/deactivation, `ImagePresentationComponent` creation, spatial 3D generation, viewing mode switching, resolution override
  - **PhotoWindowModel+BackgroundRemoval.swift** - Background removal pipeline: toggle, full-resolution processing, cache loading, resolution reloading, state management
  - **PhotoWindowModel+MemoryManagement.swift** - Idle downscale (release/thumbnail/restore), scene phase tracking, lightweight display transition
  - **PhotoWindowModel+GalleryNavigation.swift** - Gallery image switching, prev/next navigation, lazy loading pagination, rating/O-counter updates
  - **PhotoWindowModel+UIControls.swift** - Share sheet, UI auto-hide timers, image flip

### Windows Tab (window manager)
`WindowsTabView` is the app's window inventory: every open window with **Summon** and **Close** on each, plus Hide All / Close All underneath. The registry, the rows and the recycle mechanics are **RAVEUI's** `RAVEWindowRegistry` / `RAVEWindowManagerView`; the app supplies only labels and fresh-identity clones, in `Model/ManagedWindows.swift`, applied to each scene root in `HypnosApp` via `.manageWindow(...)`.

**Summon is a recycle, not a recall** — it dismisses the scene and opens an equivalent fresh one. That serves the ordinary case (fetch a window snapped in another room) *and* the visionOS 27 regression where a summoned scene is activated but never re-attached to a compositor placement, leaving the window permanently invisible while the scene still reports itself active and visible (`internal_docs/visionos27-invisible-window-feedback.md`; reproduces with stock Clock). Nothing app-side redraws such a scene, so destroying it is the only recovery — and `openWindow` against the live scene is the call that *causes* it, which is why the same dismiss-then-reopen shape already guards the cross-room summon in `ContentView.handleRemoteViewerOpenIfNeeded` / `handlePhotoWindowOpenIfNeeded`.

The `recreated()` clones on `PhotoWindowValue` / `VideoWindowValue` / `RemoteViewerWindowValue` / `RemoteAlertWindowValue` carry the same content under a **new window id**, which is what lets the dismiss and the open be issued in the same turn without the fresh window matching the dying scene. `SharedMediaItem` has no separable identity, so its window reopens verbatim after waiting for teardown. Recreated windows drop `wasPushed` — there is no originating gallery window left to pop back to.

Main windows are managed too, so a second Gallery window parked in another room is recoverable; each Windows tab excludes the window it is displayed in (RAVEUI's `raveWindowToken` environment value). Close All goes underneath SwiftUI to UIKit scene sessions (`RAVEWindowScenes.destroyAll(except:)`) because a window that never got a layout pass never registered — which is exactly the launch-time variant of the same bug.

### Data Flow
Three library sources, chosen via `AppModel.librarySource` (`LibrarySource`: `.photos`/`.stash`/`.local`) and resolved to the pair actually in force by `AppModel.effectiveLibrarySource`/`makeSources(for:apiClient:)`:
1. **PhotosImageSource/PhotosVideoSource** - The device photo library, via `PhotosIndexStore`. The default with no server configured, and always available — no setup needed.
2. **GraphQLImageSource/GraphQLVideoSource** - Fetches from a Stash server via `StashAPIClient`. Selectable once `stashServerURL` is set.
3. **LocalImageSource/LocalVideoSource** - Scans `Documents/Photos`/`Documents/Videos` for local files. Always available too, like Photos — needs no permission and no setup, so unlike Stash there's nothing to gate it behind. Settings → Local Files is informational only (where to put the files), not a toggle.

`AppModel.availableLibrarySources` is which of the three currently apply — Photos and Local unconditionally, Stash once a server is configured; `effectiveLibrarySource` falls back to Photos when the stored choice isn't one of them (server removed). The tab bar's library-switch button (`TabBarOrnament`, only shown on Pictures/Videos with more than one source available — which, with Local always in the list, means Pictures/Videos always) is a dropdown menu rather than a cycling button, since a third source made "tap to switch to the other one" ambiguous about where a tap would land.

Source protocols:
- `ImageSource` - Protocol for paginated image fetching with optional filter support
- `VideoSource` - Protocol for paginated video fetching

### Tab Navigation
Tabs defined in `Tab.swift`: Pictures, Videos, Albums, Filters, Windows, Settings, Remote (developer), Console (developer). Tab switching managed by `ContentView` with ornament-based navigation via `TabBarOrnament`. Remote and Console are conditionally visible based on `appModel.enableRemoteViewer`/`showDebugConsole`; Filters hides itself while browsing Local (nothing there to filter by — no tags, albums or galleries) and `ContentView` redirects away from it if it was already open when the library changed.

Past a separator at the **end of the tab bar**, `TabBarOrnament` shows a **play button** that starts a slideshow of what the current tab is showing (Pictures/Videos with the filter in force). It's absent on other tabs, and on Pictures/Videos until content has loaded. This is the supported way to get "slideshow of what I'm looking at"; see Gallery mode under Remote API Viewer. There used to be a Local tab with its own ornament-level slideshow case; Local is a library source now (see Data Flow above), and its folder browser (`LocalFolderBrowserView`, under Albums) offers its own per-folder "Play Slideshow" control in context instead.

### Albums Tab
`AlbumsTabView` browses whichever library is in force. For Photos and Stash, a container (`MediaContainer` — a Photos album/smart album, a Stash gallery, or for video a Stash group) is a single filter value: opening one calls `AppModel.applyContainer(_:isVideo:)`, which sets the matching field on `currentFilter`/`currentVideoFilter` and switches to Pictures/Videos, so there's no second content pipeline — paging, sort, and the rest of the filter are all the one the grids already use. `AppliedContainerBanner` is the way back, reading the applied filter rather than separate state so it can't disagree with the grid it's captioning.

Local doesn't fit that shape — a folder nests, and a `MediaContainer` is one filter value applied once, not a place to descend into and climb back out of — so `LocalFolderBrowserView` renders instead of the container grid whenever `appModel.effectiveLibrarySource == .local`: real up/down navigation over `Documents/Photos` or `Documents/Videos` (whichever `isVideo` — the same flag Photos/Stash use to split image vs. video containers — picks), with a folder tree state (`MainWindowModel.localFolderPath`, `.albumsReselected` for "pop to root" on a re-tap) that outlives tab switches for the same reason `albumsShowingVideos` does. Tapping a file opens it directly (no filter/apply step, since a folder's contents aren't a filter criterion); a per-folder "Play Slideshow" button covers what the ornament's slideshow button used to do for the old Local tab.

### Photo Viewer Architecture
All three photo viewer windows share the same rendering components:
- **PhotoDisplayView** - Shared image display with four rendering paths (in priority order): animated GIF (HEVC video player), RealityKit 3D (`ImagePresentationComponent`), GPU-backed 2D (`MetalImageView` with `MTLTexture`), and fallback UIImage. Manages window sizing, swipe navigation, and resize-triggered re-downsampling.
- **Window sizing goes through `WindowResizeCoalescer`** (`Services/`), and every new geometry request in the photo viewer must too. visionOS has no window-*position* API — `requestGeometryUpdate` carries only a size and the system decides where the resized window lands — so each granted resize is also an uncorrectable move. A pushed viewer shares the gallery's scene (`pushWindow` swaps content in place), so that move is the grid window walking around the room. Six triggers compute the same target size for one image open (branch `.onAppear`, `imageAspectRatio` change, load completion, end of swipe, `setUniformResizing`, the 0.5s verification pass); they are redundant as *requests*, not as triggers, so the coalescer sends the first and drops the restatements. Its evidence test is **not** "the window is the size I asked for": a requested size and the scene geometry that comes back differ by the chrome insets (the same mismatch `WindowSizeNudge` documents as a size ratchet), so it compares the scene geometry against itself — sampled before each request, and a restatement dropped only if the window has moved since. A window that has *not* moved means the request did nothing or was dropped, indistinguishable from here, so it goes through. Callers holding read-back evidence that a grant is wrong pass `force: true` and bypass the dedupe entirely: `verifyWindowSizeMatchesContent` (measured >5% mismatch) and the immersive verifier.
- **Immersive 3D always asks for the largest window the platform will give.** `requestVerifiedImmersiveResize` fits the image into a 3000x3000 box, which is always clamped (~2700x1360, height far tighter), so its request never equals its own grant — hence `force: true` and hence the verifier can't use "grant == request" as its settle test. It watches instead: a re-request needs *evidence* the grant is wrong — either the wrong shape (aspect mismatch: a competing request stomped ours) or the window still sitting at the scene-space size it had before the request across two samples (the request never landed). An aspect-correct grant still growing toward the ceiling is watched, not pushed; the old seeding made that case re-request on every single immersive entry. Entering and leaving immersive is inherently 2+ window moves, so on a pushed window it is the biggest single displacement source. Exiting invalidates the coalescer — its memory is of a request made against immersive bounds and says nothing about the windowed geometry being restored.
- **PhotoOrnamentView** - Unified ornament bar with `PhotoViewerContext` enum (`.pushedFromGallery`, `.standalone`, `.shared`) controlling which buttons appear. Layout: `[Gallery] | [< N/M >] | [Slideshow] | [3D v] | [Info] | [Share] | [Adjustments] | [extras] | [Resolution]`. The 3D button is a Menu (3D, Immersive 3D, 2D off). The Adjustments button opens `VisualAdjustmentsPopover`, the single home for all image enhancements: brightness/contrast/saturation/sharpen/opacity, auto-enhance, background removal, **and flip**. There is no "More" (triple-dot) menu — context-specific items (Pop Out when pushed, Save when shared) render inline as icon-only buttons via the `extraMenuItems` closure (at most one per context, so a drop-down would be single-item). The Info button opens `MediaDetailSheet` as a sheet.
- **PhotoWindowModel** - Per-window state, split across extension files by concern (see App Structure above). Created with `@State` in each wrapper view. Primary display property is `displayTexture: MTLTexture?` with `displayImage: UIImage?` as fallback. Cached texture variants: `backgroundRemovedTexture`, `originalDisplayTexture`, `autoEnhancedDisplayTexture`, `preAutoEnhanceDisplayTexture`.

The two thin wrapper views:
- **PhotoWindowView** - Handles both pushed and standalone modes via `wasPushed` parameter. Pushed mode: opened via `pushWindow` from gallery, dismisses back to gallery, has pop-out menu item. Standalone mode: opened via `openWindow` as independent pop-out window, has gallery button.
- **SharedPhotoWindowView** - Opens for images received via share sheet. Has save menu item and cache cleanup.

**Important pattern:** `PhotoWindowModel.init` must be side-effect-free because SwiftUI may re-create the view struct multiple times while `@State` discards duplicate models. All side effects (window count tracking, image loading tasks) are deferred to the `start()` method called from `onAppear`.

### Pictures Grid (`GalleryGridView`)
Two modes, chosen by Settings → Display → **Pictures Grid** (`AppModel.galleryGridStyle`, `GalleryGridStyle`; default `.square`):
- **Square** — the original uniform `LazyVGrid` of center-cropped cells.
- **Original Aspect Ratio** — justified rows (`Views/JustifiedRowLayout.swift`, pure geometry, no SwiftUI): every cell in a row shares a height, widths follow each image's ratio, and the row height is whatever fills the window width. `LazyVGrid` can't express this and a custom `Layout` isn't lazy, so rows render in a `LazyVStack`. Layout comes from metadata alone (`GalleryImage.reportedAspectRatio`, i.e. `sourceWidth/Height`), so it is settled before any pixel loads and skipped ranges of a fast flick are already the right size. Appending a page only changes the trailing partial row. Extreme ratios are clamped (0.5–2.5) and the cell center-crops. The rows are memoized in `JustifiedRowsCache`; `scrollTo` targets the row's id, not the nested cell's.
- **Sources that report no dimensions** (Nextcloud that was bulk-scanned rather than uploaded, Local files) are laid out at 1:1 until the thumbnail loads; `GalleryThumbnailView.show` then records the true ratio in `MediaAspectStore` (JSON in Application Support, keyed by `GalleryImage.identity`), and its debounced `revision` re-lays the grid out once. Each item reflows at most once per install. Nextcloud's own Photos app records `nc:metadata-photos-size` for files uploaded *through* Nextcloud; `AppModel.nextcloudDimensionCoverage` drives a Settings hint explaining the server-side backfill (`GenerateMetadataJob`, then a worker for `UpdateSingleMetadata`; see `scripts/dev-nextcloud.sh backfill`).
- **Thumbnails are never cropped in advance.** `loadRemoteThumbnailCached` with no `crop` stores the uncropped bitmap under `ThumbnailCache`'s `"uncropped"` variant (the unlabelled entries are older square crops, kept for the video grid), and both modes use `scaledToFill` in the cell. Dioramas (`ThumbnailDioramaCache`, disk key `…:uncropped`) are generated from the uncropped image, so Vision sees the whole subject; "no foreground subject" is remembered per URL and logged quietly.
- **Flicks.** A cold cell waits 120 ms before fetching (`coldLoadDelay`), warm caches paint immediately (`cachedRemoteThumbnail`). `ImageLoader.loadRawData` counts waiters per shared fetch and cancels the download when the last one leaves; thumbnail fetches (`throttled: true`) pass through `FetchGate` (6 at once, newest first). Without the waiter count, cancelling a cell's task did not cancel the shared download.

### Image Display Strategy
- **Default (Dynamic Image Resolution on):** Images open in GPU-backed 2D mode using an `MTLTexture` with `.private` storage (not counted as dirty CPU memory by jetsam). The source is downsampled via `CGImageSource`, uploaded to GPU via `CIContext.render`, and displayed through `MetalImageView` (MTKView wrapper). Re-downsampled on window resize (1-second debounce, 20% threshold). RealityKit is only loaded when the user activates 3D mode.
- **Dynamic Image Resolution off:** Images load at full native resolution. No re-downsampling on resize.
- **Deep color preservation:** Images with >8 bits per component (e.g. 16-bit JXL) use `rgba16Float` textures with `extendedLinearDisplayP3` color space. Standard 8-bit images use `bgra8Unorm` with `deviceRGB`.
- **Auto-3D restore prompt:** If an image was previously viewed in 3D (tracked via `ImageEnhancementTracker`), a capsule prompt pill appears at the bottom of the viewer offering "Restore" or dismiss. Image always opens in 2D — restoration is opt-in. Controlled by `showAutoRestorePrompt` + `autoRestoreImmersive` on `PhotoWindowModel`. Dismisses automatically after 10s (`autoRestorePromptDismissTask`) and when the user navigates to a different image via `switchToImage`. Use `presentAutoRestorePrompt(immersive:)` / `dismissAutoRestorePrompt()` helpers rather than toggling the flag directly so the timer stays in sync.
- **Important:** When swapping `displayTexture` (e.g. toggling background removal or auto-enhance from in-memory cache), `imageAspectRatio` must always be updated from the new texture's dimensions. The Metal renderer stretches the texture to fill its view — aspect ratio is controlled externally by SwiftUI's `.aspectRatio()` modifier driven by `imageAspectRatio`.

### Spatial 3D Images
Uses RealityKit's `ImagePresentationComponent` for 2D→3D conversion. States tracked via `Spatial3DImageState` enum: notGenerated → generating → generated. `ImagePresentationComponent` is a black-box component — it manages its own geometry and materials internally, so there's no direct access to its mesh or rendering pipeline.

**visionOS limitation:** `PostProcessEffect` / `PostProcessEffectContext` are unavailable on visionOS. Custom post-processing on `RealityView` content must use SwiftUI-level modifiers (`.mask()`, `.overlay()`) instead.

### Video Infrastructure

**The fake-3D pipeline now lives in `RAVEMedia`** (`~/Projects/RAVESDK`), linked as a local
Swift package: `Pseudo3DStereoEngine`, `StereoPump`, `PumpDepthSource` and its two
implementations, `CoreMLDepthProvider`, the whole `Depth*` family, `Pseudo3DSettings`, and
the stereo/depth Metal shaders. The descriptions below still hold — they describe the same
code — but the sources are in the package, and files that touch any of it need
`import RAVEMedia`. What stayed here: `Pseudo3DVideoPlayerView` itself (the SwiftUI
surface, window-chrome constants, gestures, and the `bindCommands` extension that wires the
engine's transport to `VideoWindowModel`/`VideoLoopController`).

Three seams that migration created, and that will bite if missed:
- `AppModel.init` sets `RAVEMediaPolicy.depthCacheCap`. Remove it and the depth cache
  never evicts — the package has no notion of `CacheBudget`.
- `Shaders.metal` here holds only the image shaders. The pseudo-3D warp and every depth
  kernel are in the package's own `default.metallib`; `MetalImageRenderer` no longer has
  any `pseudo3D*` member.
- The two depth log categories were renamed with the move (`VideoCache`/`VideoWindow` →
  `DepthCache`/`Pseudo3D`). Same subsystem, so the in-app console still shows them.
- **VideoWindowModel** - Per-window `@MainActor @Observable` model (mirrors `PhotoWindowModel`) owning the window's current video, navigation snapshot (own copy of `galleryVideos` + `currentIndex` + lazy pagination), 3D intent (`stereoscopicOverride`/`video3DSettings`), flip, per-window `currentAdjustments`, playback state (`currentTime`/`duration`/`isPaused`/`isMuted`/`bufferedEnd`/`isScrubbing`), the `VideoLoopController`, share state, and auto-hide timers. Side-effect-free `init`; side effects in `start()`; `cleanup()` on dismiss. This replaced the old shared `AppModel.selectedVideo`/`videoStereoscopicOverride`/`video3DSettings`/`isVideoFlipped`/`videoVisualAdjustments` + app-level auto-hide, so multiple video windows are fully independent (fixes the bug where every pushed window showed the last-selected video). Created with `@State` in `VideoWindowView(windowValue:appModel:)`.
- **VideoWindowView** - Thin wrapper handling both pushed and standalone modes via `wasPushed` (same pattern as `PhotoWindowView`). Picks the render path per `windowModel`: immersive `StereoscopicVideoView` (`shouldUse3DMode`), real-time `Pseudo3DVideoPlayerView` (`shouldUsePseudo3D`), else the flat player (`playbackRenderer`: `.resolving` → `.nativeMetal` `NativeMetalVideoPlayerView` → `.webKit` `WebVideoPlayerView`). Hosts one `RAVEPlayerControls` ornament for both 2D and fake-3D, with app actions supplied by `VideoOrnamentsView`. Locks window aspect ratio using **this** window's scene via `@Environment(SceneDelegate.self)` (not an arbitrary foreground scene); after each lock request a one-shot follow-up (`aspectRelockTask`) reads back the *granted* scene size and re-locks to a video-true size fitting inside it — portrait videos hit the platform's max window height, and a clamped grant under `.uniform` otherwise locks a wrong ratio (permanent letterbox between video and chrome, no room to enlarge). **Fake-3D chrome depth:** the ornament is kept coplanar with the visionOS window controls (`pseudo3DChromeZOffset = 0`; an earlier 20cm push floated the chrome off that plane and occluded the window controls) and the video is pulled back to that same plane by `Pseudo3DVideoPlayerView.videoPlaneZRecess` (90pt ≈ 9cm; the front-aligned `.frame(depth: 0, alignment: .front)` slab sits at the front of the window's depth region, measured ~9cm proud of the chrome on-device — the recess is applied as `.offset(z:)` on the GeometryReader3D so the fit math is unaffected; both constants stay tunable). `pseudo3DChromeBottomLift`/`ornamentBottomPadding` reserve the shared controls' footprint and keep it clear of the video and system window controls.
- **VideoControlBar** - Thin adapter from `VideoWindowModel` command closures to RAVEUI's `RAVEPlayerControls`: native SwiftUI scrubber, ±10s, play/pause, mute, buffering and A/B markers. It supplies A/B loop actions beside the host's feature row. WebKit, Metal and stereo all drive the same UI through the active renderer's closures. A drag seeks once on release; scrub/scroll lifecycles suspend auto-hide.
- **VideoOrnamentsView** - Unified ornament bar, styled to match `PhotoOrnamentView`. Layout: `[Gallery] | [< N/M >] | [ViewMode v] | [Info] | [Share] | [... More v] | [Title]`. The ViewMode menu switches **2D**, immersive **3D** (+ "Edit 3D Settings" when active), and **"Convert to 3D (Beta)"** — the fake-3D path (gated `disabled` to `windowModel.pseudo3DAvailable` — AVFoundation-decodable now, or reachable via the Stash transcode; realtime or pre-processed, see the engage flow below). The three modes are a **radio group** (`modeButton` + `currentViewMode`): exactly one carries the checkmark, selecting another switches directly, re-selecting the active one is a no-op (leaving a mode = picking another). There is no "3D Depth" preset submenu (strength is pinned — see `Pseudo3DSettings`; convergence lives in the Adjustments window); whenever fake-3D is available (`pseudo3DAvailable`) the menu also shows **both** depth-model submenus — **Depth Model (Real-Time)** and **Depth Model (Pre-Process)** — and this video's conversion progress + Cancel while a background conversion runs; the mode label reads `3D*` in fake-3D. Playback transport and feature actions share one `RAVEPlayerControls` ornament in both 2D and fake-3D. The immersive scene owns its own transport. The More menu's **Adjustments** button opens the standalone `video-adjustments` window (`VideoAdjustmentsWindowView`) rather than a popover — it sets `appModel.videoAdjustmentsTarget`, so the panel is freely repositionable and never occluded by the front-plane fake-3D video; also Slideshow and Pop Out (when pushed). Info button opens `MediaDetailSheet`. Takes `@Bindable var windowModel`.
- **VideoLoopController** - `@Observable @MainActor` per-window model (owned by `VideoWindowModel`) for the A-B loop on the 2D web player. Cycles `idle → aSet → active → idle`: 1st press sets A, **2nd press sets B and engages immediately** (no confirmation step), 3rd press (or the control-bar clear button → `clear()`) disables. Owns its own toast state. Wires `queryCurrentTime`/`setLoopBounds` closures bound by `WebVideoPlayerView` to the JS rVFC monitor (`window.__startABLoop` / `window.__stopABLoop`).
- **Stream-URL strategy (Stash scenes)** - `GalleryVideo.streamURL` is **always the server's original file**; `transcodeStreamURL` holds Stash's live transcode (HLS `/stream.m3u8` preferred, else the non-seekable fragmented `/stream.mp4`) as a *reserve*, populated for every scene advertising endpoints when Settings → Server-Side Transcoding is on (`enableStashTranscoding`, default on). WebKit decodes WebM (VP8/VP9) on-device, so nothing transcodes up front. The transcode is engaged in exactly three cases: (1) the WebKit player reports the original unplayable — a decode/unsupported-source error immediately, a network error after its retries — via `onSourceUnplayable` → `VideoWindowModel.handleSourceUnplayable()`; (2) any fake-3D engage on a WebKit-decoded source, funnelled through `enablePseudo3D()`; (3) `transcodedDownloadURL` (MV-HEVC + depth pre-process), which prefers the transcode rewritten to `/stream.mp4` because AVAssetReader can't read WebM at all. `VideoWindowModel.activeStreamURL`/`usingTranscodedStream` track which one is playing (reset per video switch); `canUseTranscodedStream` and `pseudo3DAvailable` gate the UI. **AVFoundation still cannot decode WebM on visionOS 27** (VP8 and VP9 both fail `AVURLAsset.isPlayable`), which is why the transcode detour exists at all — the renderer probe (`canPlayNatively`) is a live check, so if that ever changes the native path unlocks itself with no code change.
- **WebVideoPlayerView** - `WKWebView`-based player (kept for WebM support). Native `controls` are off for the main video window; a custom-controls bridge is enabled by passing an optional `playbackModel: VideoWindowModel`. State flows JS→Swift over the `videoPlayback` message channel (`timeupdate`/`play`/`pause`/`seeked`/`volumechange`/`loadedmetadata` post `{currentTime,duration,paused,muted,buffered}`); commands flow Swift→JS via `play`/`pause`/`seek`/`setMuted` closures bound in `updateUIView`. The bridge is additive/optional — other callers (animated GIFs in `PhotoDisplayView`, remote-viewer videos, stereoscopic 2D fallback) pass no `playbackModel` and are unaffected. Error escalation has two independent forms: `fallbackVideoURL` swaps `src` **inside the page** (remote slideshow's raw → HLS tiers), while `onSourceUnplayable` reports up to Swift (main video window) so the re-route also re-resolves the renderer. **Autoplay is driven from inside the page** (`kickAutoplay`, retried on `loadeddata`/`canplay`, cancelled by an explicit pause): the bare `autoplay` attribute is dropped when the page loads into a WKWebView not yet in the window hierarchy, which is what left prev/next-switched videos sitting on a blank frame. `window._roomActive` is likewise baked into the HTML at load (and `lastIsRoomActive` seeded) so the room-activity JS never fires against a page that hasn't loaded.
- **NativeMetalVideoPlayerView** - Flat-video path used when the source is AVFoundation-decodable (`playbackRenderer == .nativeMetal`): `AVPlayer` + `AVPlayerItemVideoOutput` → per-frame `MTLTexture` → `MetalImageView`. Preferred over WebKit for local/HLS sources; audio uses `.mixWithOthers` (see `AudioSessionConfig`) so it doesn't interrupt other apps. Falls back to `WebVideoPlayerView` on decode failure (`forceWebKitPlayback`). Being `.nativeMetal` — or being *reachable* via the server transcode, i.e. `pseudo3DAvailable` — is the gate for the fake-3D "Convert to 3D" option.
- **Pseudo3DVideoPlayerView** / **Pseudo3DStereoEngine** - Real-time "fake 3D": converts a **mono** video to windowed stereoscopic 3D in an ordinary Shared-Space window — no immersive space, no MV-HEVC pre-compute. `AVPlayer` owns audio/clock/transport/scrubbing/A-B loop; decoded mono frames are warped per-eye and enqueued into an `AVSampleBufferVideoRenderer` feeding a `VideoPlayerComponent(.stereo)` inside a `RealityView`. The video plane is aligned `.front` then recessed by `videoPlaneZRecess` (~90pt) back to the chrome/window-controls plane (a centered slab was the old "Flip3D recession"; the bare front alignment sat ~9cm proud). The window is sized to the video by the aspect lock in `VideoWindowView`; the plane itself is fitted from the **video aspect, never the measured mesh** — `VideoPlayerComponent`'s screen mesh for renderer-backed components reads 1×1 (placeholder square) until the first tagged frames present, then silently settles at (videoAspect × 1)m with no `VideoSizeDidChange` event, so any scale derived from measured bounds is computed against the stale square; `fitVideo` derives the screen dims from the pump-reported video size instead (measured bounds only as a pre-size fallback), and `scheduleRefitBurst` re-installs the tap target once the mesh adopts the real aspect. A menu/popover open (`chromeOpen`) fades the video via `OpacityComponent` so presented chrome shows through it (depth can't dodge the zero-depth slab). Carries its own `SpatialTapGesture` tap target (a 2D overlay can't catch gaze over a `RealityView`) to toggle chrome. Falls back to the flat native player via `onPlaybackError`. Also used by the **slideshow** (see Slideshow 3D below) and `VideoQuickLookView`; `loops` / `contentOpacity` / `onDurationKnown` exist for those callers.
- **StereoPump** - `@unchecked Sendable`; owns **all** per-frame GPU work on a dedicated background queue with its own `MTLCommandQueue` — **never** the main thread (an earlier main-actor pump SIGKILLed backboardd via the compositor watchdog). Each tick: pull the newest decoded frame, get depth for **that exact frame** from its `PumpDepthSource`, warp into two BGRA eye targets (occlusion-correct depth-displaced mesh, 193×109 grid — `MetalImageRenderer.pseudo3DGridColumns/Rows`), convert each to full-range 420f via `VTPixelTransferSession` (carrying the source's color tags), tag `.leftEye`/`.rightEye`, and enqueue a `CMReadySampleBuffer`. Tick rate is **60 fps in both modes**; in realtime mode `RealtimeDepthSource` infers at ~30Hz (`reinferInterval` 1/35s on the video timeline) and **holds** the map for the in-between frame — a *bounded* ≤1-frame depth age (never the unbounded staleness of an async-decoupled pump, which the user rejected); ≤30fps content's frame spacing exceeds the interval so it stays fully lock-step, seeks always re-infer, and a slow inference gates its own tick so the cadence self-throttles back to ~30fps video. Bounded eye-buffer pool; each eye gets its **own** depth attachment (sharing one cross-contaminated the right eye = over-warp). In cached mode a missing depth frame (post-seek rebuild gap) renders **flat** with a ~150ms strength ramp back — never the heuristic warp, never wrong-frame depth. Per-stage `os_signpost` intervals (`AppLogger.pseudo3DSignposter`) cover inference/stabilize/warp/transfer.
- **PumpDepthSource** (protocol, called only on the pump queue) - `RealtimeDepthSource` wraps `CoreMLDepthProvider` (synchronous same-frame inference, identity value mapping); `CachedDepthSource` wraps `DepthCacheReader` (below). `PumpFrameDepth` carries the texture + letterbox UV transform + per-frame value scale/bias + median (auto-convergence).
- **CoreMLDepthProvider** (conforms to **DepthProvider**) - Core ML monocular depth (Depth Anything V2) driving the mesh warp; `depth(for:) -> MTLTexture?` is synchronous; `inferRawDepth(from:)` returns the raw, unnormalized map for the offline converter. Vision uses **`.scaleFit`** (aspect-preserving letterbox); the warp remaps UVs into the content region via `letterboxUVTransform` (shared with the converter; anchor is a named constant — flip if on-device parallax reads vertically offset). Model is loaded by name from the managed store (`DepthModelStore`), honoring the role-specific preference: `CoreMLDepthProvider(device:role:)` with `DepthModelRole` `.realtime` (RealtimeDepthSource, engage checks) or `.preprocess` (DepthConverter, cache-store lookups); `hasAvailableModel(role:)`/`resolvedModelName(role:)` take the role too. **Fake-3D requires real depth — no heuristic fallback**: `Pseudo3DStereoEngine.load` requires a cache entry (cached mode) or `hasAvailableModel()` (realtime), else falls back to the flat 2D player via `onPlaybackError`. Stabilization is a separable gaussian (`depthBlurH`/`depthBlurVEMA`, one command buffer) + motion-adaptive temporal EMA on ping-pong `r16Float`; the raw Vision output is read via a zero-copy texture-cache view held across the stabilize wait (blit copy only when stabilization can't run).
- **DepthConverter / DepthCacheStore / DepthConversionManager / DepthCacheReader** - The **pre-processed** fake-3D path ("Convert to 3D" → Pre-Process). `DepthConverter` (two-stage `.utility` pipeline: stage A decodes + runs ANE inference while stage B — the `PostStage` class, serial post queue with a 2-frame backpressure semaphore — does all GPU work + encoding on earlier frames, so total time ≈ pure inference time) decodes every frame (downscaled at decode to ~2× model input), infers depth, computes per-frame robust stats on GPU (min/max reduction + 256-bin histogram → p2/p98/median), refines with a **joint-bilateral** filter guided by the frame's luma (edge-aware — depth snaps to image edges), applies a **lookahead** ±2-frame temporal window (truncated at scene cuts, detected by histogram shape + range jumps), and encodes depth into an HEVC grayscale `depth.mov` (luma plane, source PTS verbatim, VFR-safe). A post-pass smooths the display range within cut-delimited segments (snaps across cuts — no pumping, no lag) and writes per-frame `displayScale/Bias/Median` arrays to `meta.json`. **Motion-adaptive inference skipping** (`FrameChangeDetector`, stage A): a sparse 48×48 luma signature per decoded frame is compared against the last *inferred* frame (drift accumulates, so slow motion still re-infers; 60-skip staleness cap); a static frame hands stage B `inferred: nil`, which already means "repeat the previous depth" — exact when nothing moved, zero ANE work. Conservative threshold (mean |Δluma| < 1.0/255-scale) so grainy footage simply never skips. **High-frame-rate sources (≥48fps, `twoPassMinFrameRate`) convert in two passes**: pass 1 infers every other frame into a complete half-rate `depth.mov` (watchable in half the time — the reader serves the nearest earlier depth frame in the gaps, ≤1 frame of depth lag), then pass 2 infers only the skipped frames into `depth-b.mov` (a finished AVAssetWriter file can't accept interleaved PTS) and finalizes metadata **merged across both lattices** (display-range smoothing over one timeline — per-lattice ranges would shimmer at 60Hz; adjacent duplicate cut flags collapse to the exact cut frame). Total inference cost is unchanged; the entry stays `completed: false` until pass 2 finishes, so an interrupted pass 2 never leaves a half-rate cache posing as done (cancel/failure deletes the directory as always), and the manager reports pass 2 as the `.refining` phase with frontier pinned to the duration — the progressive-engage condition passes immediately. `DepthCacheStore` keys entries by (video identity = stashId, model name, `pipelineVersion` — bump to invalidate old caches) under backup-excluded `Application Support/DepthCache/`; `entry(videoIdentity:)` (playback) prefers the selected pre-process model but accepts any completed entry (baked depth outlives model deletion); `engageEntry(videoIdentity:)` (engage flow) accepts only the selected pre-process model's entry while any model is installed — switching the model re-offers conversion instead of silently reusing another model's depth — falling back to any entry only when no model remains. The depth cache participates in `CacheBudget`: `enforceBudget(activeIdentity:)` LRU-evicts least-recently-watched completed entries (`DepthCacheReader` touches its entry's directory on open), called after each conversion and from the Settings cache section; in-progress and just-completed entries are never evicted. `DepthConversionManager` (`@MainActor @Observable` singleton) runs one job at a time (ANE contention), downloads remote sources first (AVAssetReader needs local files), exposes per-phase progress/cancel and `lastCompleted`/`lastError` events. `DepthCacheReader` decodes the entry's depth file(s) sequentially with a small lookahead, PTS-matched to the pulled frame — two-pass entries get one decode stream per file, merged by PTS, and a growing entry probes for `depth-b.mov` appearing so playback upgrades to full-rate depth mid-conversion; seeks outside the window rebuild the reader at the target (~50-100ms flat gap).
- **DepthModelStore** - Filesystem management for depth models. Managed store is `Application Support/DepthModels/` (excluded from backup — models are large, re-downloadable). Documents is a drop-off **inbox**: `importInboxModels()` (run at launch from `AppModel.init` and on Settings appear) moves any `.mlmodelc`/`.mlpackage` there into the store and deletes it from Documents, so the manual `scripts/push-depth-model.sh` path and the in-app download converge on the same switchable/deletable store. Custom models are generated with `scripts/convert-depth-model.py` (DA V2 Small/Base/Large at any multiple-of-14 resolution; a validated precision ladder keeps overflow-prone ops in fp32 — all-FP16 Base/Large shows a wave/grid artifact from DINOv2 float16 overflow). Also owns the shared compiled-`.mlmodelc` cache dir (`CompiledDepthModels/`), cleared per-model on delete.
- **DepthModelManager** - `@MainActor @Observable` singleton for in-app model download/management. Offers 4 Depth Anything V2 **Small** variants (F16 / INT8 / 6-bit / 8-bit palettized — no F32) downloaded straight from Apple's canonical HF repo (`apple/coreml-depth-anything-v2-small`); nothing is re-hosted. Each model is a `.mlpackage` of 3 fixed files fetched via `resolve/main/…` URLs (via a delegate-driven `FileDownloader` for byte progress), rebuilt in the store, then Core-ML-compiled on first use. Per-file size + SHA-256 come from HF's tree API for integrity verification. Add/download/delete happens ONLY in the **Depth Model Manager modal** (`DepthModelManagerSheet`, Settings → Developer): per-row delete (incl. custom models; clears any preference pointing at the deleted model), download progress, and role badges. Which installed model each pipeline *uses* is chosen by two Display-settings dropdowns — **Real-Time 3D Depth Model** (`AppModel.realtimeDepthModelName`) and **Pre-Process 3D Depth Model** (`AppModel.preprocessDepthModelName`, so a slower/larger model can serve conversions only). "" = automatic (first installed); the legacy `preferredDepthModelName` key is migrated into both on launch and still read as a fallback. The video ViewMode menu carries a submenu per role: **Depth Model (Real-Time)** applies to the video being watched immediately — `Pseudo3DVideoPlayerView` observes `appModel.realtimeDepthModelName` and calls `engine.reloadDepthPipeline()` (rebuilds the pump, preserving position/pause) — while **Depth Model (Pre-Process)** picks the model future conversions and the engage flow's cache lookup use. A third Display setting, **Real-Time 3D for All Videos** (`AppModel.defaultRealtimePseudo3D`, default off), auto-engages fake-3D on every eligible video once its renderer resolves to `.nativeMetal` (`VideoWindowModel.autoEngagePseudo3DIfPreferred`): prefers the strict `engageEntry` cache, else realtime when a model is installed, else silently stays 2D (never forces the setup sheet, never overrides restored fake-3D or genuine stereoscopic).
- **Convert to 3D engage flow** (`VideoWindowModel.requestPseudo3D()`, all paths funnelled through `enablePseudo3D()` — which first swaps a WebKit-decoded source onto the server transcode and replays the parked intent via `pendingPseudo3DEngage` once the renderer resolves): a completed depth cache **from the selected pre-process model** (`DepthCacheStore.engageEntry`) → engage **pre-processed** playback directly (`pseudo3DDepthMode = .cached`); no model AND no cache → `DepthModelSetupSheet` (re-enters the flow after install); otherwise an **alert** asks **Real-Time** (engages the 30fps synchronous path; never starts a conversion — it would fight live inference for the ANE) vs **Pre-Process** (background conversion while the window plays 2D). The ViewMode menu shows the conversion's phase/progress with a Cancel item, and the same status appears at the **rightmost of the ornament** so it's visible without opening the menu. **Progressive playback:** the depth video is a *fragmented* QuickTime with provisional meta.json writes, so a Pre-Process window auto-engages cached 3D **mid-conversion** once safe — `startProgressiveEngageMonitor` polls `DepthConversionManager.progressiveStatus` (frontier + rate EMA) and engages when `remainingConversion ≤ rate × remainingPlayback × 0.8` and the frontier leads the playhead by ≥10s (constants on `VideoWindowModel`); `DepthCacheReader` follows the growing file (fresh `AVURLAsset` per rebuild — a cached asset never sees new fragments); while a conversion runs, `Pseudo3DStereoEngine.load` prefers the growing entry over an older completed one from a different model, and an underrun (thermal throttle) degrades to flat depth + ramp, never a stall. The progressive engage is **paused** (`engageCachedPseudo3D(startPaused: true)` → `pseudo3DEngagePaused` → `engine.load(startPaused:)`): the stereo player seeks and warps a **single frame** (visibly playable in 3D) but doesn't start sustained playback — a second decode session concurrent with the converter's `AVAssetReader` can trip a transient VideoToolbox decode failure ("Invalid sample cursor"; `DepthConversionManager` also auto-retries those). The user's manual **Play** opts into the second session; `startPaused` also clears `wasPlayingBeforeRoomExit` so a room activation doesn't auto-play the still. Engaging fake-3D resumes at the 2D player's position (`pseudo3DEngageResumeTime` → `engine.load(startAt:)`). Completion while the window moved on shows the **"3D version ready — Watch in 3D" capsule pill** (photo auto-restore pattern, `presentDepthReadyPrompt`/`dismissDepthReadyPrompt`, 10s auto-dismiss); cancel mid-progressive-playback drops back to 2D; failure alerts once. Restored windows with fake-3D engaged prefer the cache when one exists (`start()`); `switchToVideo` resets mode to `.realtime`. Settings (Developer) lists converted videos ("Converted 3D Videos": size/model/outdated marker, per-entry delete, Clear All — `DepthCacheSettingsView`).
- **Pseudo3DSettings** - Per-window fake-3D tuning: `depthStrength` (max per-eye horizontal disparity in UV, default = Subtle `0.008`) and `convergence` (which depth sits on the window plane, default `1.0`). **Convergence polarity is easy to get backwards:** the shader is `disparity = (depth − convergence) × depthStrength` over an *inverse*-depth map, so 1 is the NEAR end and **raising convergence pushes the scene back** — at `1.0` every frame's nearest content lands on the glass and nothing crosses in front of the window frame (no window violation). Disparity is baked (not IPD-scaled) and its *angular* size grows with window size, so it starts conservative. `isModified` drives per-window vs. `AppModel.globalPseudo3DSettings` fallback (`effectivePseudo3DSettings`) and Reset, mirroring `VisualAdjustments`. **Corollary for persistence:** `VideoWindowView`'s pop-out snapshot writes `pseudo3DSettings` into the `VideoWindowValue` **only when `isModified`** (nil otherwise, so the window keeps following the global). Snapshotting an unmodified value would bake in whatever `.default` happened to be, and a later default change would make that stale value start counting as modified and shadow the global. Anything else persisting a `Pseudo3DSettings` needs the same guard. **Codable back-compat:** `init(from:)` is hand-written with `decodeIfPresent` so persisted JSON survives new fields — keep it updated when adding fields; retired keys need no handling (keyed decoding ignores unmatched JSON keys). It also **normalizes the legacy `0.45` convergence default to the current one** (`legacyConvergenceDefault`) — required, not cosmetic: a persisted global would otherwise keep the old plane forever, and since `isModified` compares against `.default`, a per-window `0.45` would start counting as modified and shadow the global. Any future default change needs the same treatment (the slider is continuous and unstepped, so an exact old-default value is only ever reachable *as* the old default). Live-editable via the Adjustments window's **Convergence** control (strength is pinned, see above). **Removed: auto-convergence** (tracked the conversion's lookahead-smoothed median as the zero-parallax plane, cached-mode-only). The realtime depth map is min/max normalized *per frame* (`CoreMLDepthProvider.makeTexture`), so a fixed convergence is already scene-adaptive — the frame's nearest content is always exactly 1.0 — and unlike a tracked median it cannot wander, which is why the converter needed ±2-frame lookahead plus cut detection to make its median usable at all. `DepthCacheStore.Entry.Meta.displayMedian` is still written (free by-product of the p2/p98 histogram; removing it would force a `pipelineVersion` bump and invalidate every existing cache) but no longer consumed.
- **StereoscopicVideoPlayer** - Coordinates download → MV-HEVC conversion → immersive playback. The immersive space is global (one at a time): `StereoscopicVideoView` registers `AppModel.immersiveVideoOwner` (the owning `VideoWindowModel`) on enter, and `ImmersiveVideoView` reads that window's `stereoscopicOverride`.
- **MVHEVCConverter** - Converts side-by-side/over-under stereoscopic video to MV-HEVC format
- **ImmersiveVideoView** - RealityKit-based immersive player in full immersion space
- **Video3DSettingsSheet** - Manual override for stereoscopic format detection

### Memory Management
- **Disk caches (`LRUDiskCache` + `CacheBudget`):** every on-disk cache (images, videos, thumbnails, auto-enhance, bg-removal, GIF-HEVC, thumbnail dioramas) shares one engine: incremental size tracking (no per-write directory enumeration; counter resynced on each eviction pass), LRU eviction to 80% of cap, mtime touch on read. Caps derive from device storage: the Settings cache preset (Standard/Large/Maximum = 10/18/30% of capacity, `CacheSizePreset`) × per-domain share (`CacheBudget.Domain`), bounded by a 15 GB free-space floor that pushes caps below current usage when the disk fills (caches actively give space back). Engine hooks: `companionURLs` (video metadata sidecars evicted together), `evictsFirst` (auto-enhance/bg-removal entries are xattr-tagged with their source's image-cache key and evict first once the original is gone; tag only set when the original is actually in DiskImageCache — local files are never tagged), `pendingBytes` (`DiskVideoCache.reserveCapacity(token:expectedBytes:)` counts an in-flight MV-HEVC conversion against the cap). Settings → Cache is the manager UI (`CacheSettingsSection`): preset picker, per-cache usage vs nominal cap, inline Clear, free space.
- **GPU-private textures:** 2D display uses `MTLTexture` with `.private` storage mode. These live in GPU memory (not dirty CPU pages), avoiding jetsam pressure. Apple Silicon applies automatic lossless compression to private textures (~30-50% savings).
- **`SendableTexture` wrapper:** `@unchecked Sendable` struct wrapping `MTLTexture` for crossing actor/Task boundaries, since `MTLTexture` protocol doesn't declare `Sendable`.
- **`DispatchSource` memory pressure:** `AppModel` monitors system memory pressure via `DispatchSource.makeMemoryPressureSource`. On critical pressure, triggers LRU idle-downscale of photo windows. On warning, trims caches.
- **`.mappedIfSafe` data loading:** Disk cache reads use `Data(contentsOf:options:.mappedIfSafe)` for memory-mapped I/O where possible.
- **`autoreleasepool`:** Used around image decode/upload paths to promptly release transient Objective-C objects.
- `useLightweightDisplay` flag triggers all photo windows to switch from RealityKit to SwiftUI Image on memory warning
- `openPhotoWindowCount` tracks active photo windows; `memoryBudgetExceeded` gates new window creation
- `ImageLoader` uses NSCache with 512MB memory limit
- `PhotoWindowModel.cleanup()` explicitly releases GPU textures and image data on window dismiss

### Services
- **MetalImageRenderer** - Sendable singleton managing Metal device, command queue, CIContext, and two render pipeline states (8-bit bgra8Unorm and 16-bit rgba16Float). Creates GPU-private textures from CGImage, UIImage, or URL (with CGImageSource downsampling). Uses `CIContext.render` for correct handling of all source pixel formats and color spaces. Flips CIImage vertically before render (CIImage origin is bottom-left, Metal expects top-left).
- **Shaders.metal** - Vertex shader (procedural fullscreen quad, 6 vertices, no vertex buffer) + fragment shader (brightness/contrast/saturation adjustments matching SwiftUI modifiers).
- **MetalImageView** - `UIViewRepresentable` wrapping `MTKView`. Draw-on-demand mode (`isPaused=true`, `enableSetNeedsDisplay=true`). Transparent background. Auto-detects deep color textures and switches framebuffer format and pipeline state.
- **NativeVideoDecodeProbe** - Shared "can AVFoundation decode this URL?" check (`AVURLAsset.isPlayable` + a non-empty video track, trusting `isPlayable` alone for `.m3u8` since HLS exposes video via `AVAssetVariant`), plus a timeout-bounded overload. Being decodable is what unlocks the native Metal player and real-time fake-3D. Used by `VideoWindowModel.resolvePlaybackRenderer` and `SlideshowEngine.resolvePseudo3DTarget`.
- **StashAPIClient** - Actor for GraphQL communication with Stash server
- **ImageLoader** - Actor-based image loader with NSCache and disk cache
- **DiskImageCache/DiskVideoCache** - Persistent disk caching (excluded from backup). Files stored as SHA256 hashes with `.heic` extension.
- **ThumbnailCache** - HEIC-format thumbnail cache
- **ThumbnailGenerator** - Generates thumbnails and performs CGImageSource downsampling
- **BackgroundRemover** - Actor using Vision `VNGenerateForegroundInstanceMaskRequest` + CIFilter blendWithMask for background removal with auto-crop of transparent margins
- **BackgroundRemovalCache** - HEIC-format persistent cache for background-removed images (separate from main disk cache)
- **AutoEnhanceCache** - Persistent cache for auto-enhanced images
- **ImageEnhancementTracker** - Tracks per-image viewing mode (mono/backgroundRemoved/autoEnhanced/spatial3D) for auto-restoration on reopen
- **SharedMediaCache** - Temporary storage for share sheet media
- **SharedMediaSaver** - Saves shared media to Documents folder
- **AppLogger** - One DebugTrace `DebugLogger` per domain (os.Logger's API; lines also land in DebugTrace's in-memory ring for the in-app console and debug traces). Privacy follows os_log's default — strings private unless marked — and the rules are in `AppLogger`'s doc comment: `.public` only for app-defined values, `.private(mask: .hash)` for server/library ids, `.sensitive` for credentials. `error.logCode` gives the public domain + code next to a private `localizedDescription`

### Shared player controls and Atmos films

`RAVEUI.RAVEPlayerControls` owns the custom transport UI shared with Raven. App adapters supply playback state, commands and feature actions; the control never owns a decoder or an audio session. The platform-native AVKit players on Mac/tvOS and Raven's cinema player retain their system transport and media-selection UI.

`FilmPlayerView` uses those same custom controls on every platform: a picture with a separate Sound and Picture window on visionOS (a sheet elsewhere), mute, and Recenter Audio while iOS/macOS AirPods tracking is active (tvOS uses its PHASE recenter request). `FilmPlayer.isMuted` zeros render gains independently of the saved gain tuning. visionOS offers realtime 3D via `FilmVideoPlayer.onSampleBuffer` / `onFlush` into RAVEMedia's `SampleBufferFrameSource`, which decodes BGRA on the pump queue, selects pictures by the film timebase and resets at seeks. It does not open another AVPlayer or move audio to another clock. The normal picture renderer remains mounted; the stereo tap adds a second video decode session. Both film picture paths reserve 180pt for the ornament in a plain window and retains the measured 90pt recess. Decode failures return to 2D; model installation uses the existing setup sheet. The visualizer lives only in adjustments: visionOS/macOS have scrolling controls on the left and a pinned object map on the right. B-frame selection/reset tests run in RAVEMediaTests on macOS. Device confirmation of the new film stereo layout, HDR appearance, decode cost and Atmos synchronization remains required.

### Incoming URLs & web-yt-dlp (YouTube-in-3D)
The app registers a `hypnos://play?url=<link>` custom URL scheme (declared in `Info.plist`, handled by **IncomingURLHandler**; a `SceneDelegate` notification path covers file-share cold launches that SwiftUI's `.onOpenURL` misses, so `AppModel.shouldProcessIncomingURL` de-dupes the double-fire). This is the primary way to send arbitrary web videos into the app — most conveniently via the **"Open in Spatial Viewer"** iOS/visionOS Shortcut (<https://www.icloud.com/shortcuts/c313953ed4c245f988ca746808109b8d>), which shares any link into the scheme; a bookmarklet works too.

- **StreamableURLResolver** classifies the incoming URL: `.directVideo` (MP4/HLS — plays immediately, no proxy), `.webPage` (routed through web-yt-dlp when enabled), or `.notPlayable`. Direct links open a stream video window straight away.
- **WebYTDLPClient** (`struct`, built from `AppModel.webYTDLPClient`) builds `{endpoint}/stream?url=<page>&token=<token>&preset=<preset>&height=<height>` for a self-hosted [web-yt-dlp](https://github.com/illixion/web-yt-dlp) instance. The app does **not** pre-resolve metadata — it hands the stream URL straight to AVPlayer and the server runs yt-dlp + muxes + streams on the fly (HTTP Range supported). Token rides as a query param because AVPlayer can't easily attach a Bearer header. Playing web videos this way feeds the native-Metal player, so they can be converted to fake-3D — the point of the feature is watching e.g. 4K YouTube in windowed stereoscopic 3D.
- **Settings (Developer → Web yt-dlp Support):** `webYTDLPEnabled` gates web-page routing; `webYTDLPEndpoint`/`webYTDLPToken` configure the proxy; and two dropdowns pick the re-encode target — `webYTDLPPreset` (`AppModel.webYTDLPPresetOptions`: HEVC/`h265` default — tagged `hvc1` for AVPlayer's native path, source stream-copied when already HEVC — or `h264`) and `webYTDLPHeight` (`AppModel.webYTDLPHeightOptions`: 1080 or 2160/4K default). Defaults live on `WebYTDLPClient.defaultPreset`/`defaultHeight`; `streamURL(forPage:preset:height:)` takes both as overridable params. All persisted to UserDefaults and included in `SettingsBackup`. The section links both the web-yt-dlp repo and the Shortcut.

### API Client
`StashAPIClient` is an actor that handles GraphQL communication with Stash server. Accessible via `appModel.apiClient` (private(set)). Supports:
- **List queries:** `findImages`, `findScenes`, `findGalleries`, `findTags`, `findStudios`, `findPerformers` (paginated, with filters)
- **Detail queries:** `fetchImageDetail(id:)` → `ImageDetail`, `fetchSceneDetail(id:)` → `SceneDetail` (on-demand full metadata)
- **Mutations:** `updateImage`/`updateScene` (full field update), `updateImageRating`/`updateSceneRating`, `incrementImageOCounter`/`decrementImageOCounter`, `incrementSceneOCounter`/`decrementSceneOCounter`
- **Delete:** `destroyImage`/`destroyScene` (single), `destroyImages`/`destroyScenes` (bulk), with `deleteFile` and `deleteGenerated` options
- Server config persisted via UserDefaults

### Media Metadata & Detail Views
- **MediaMetadata.swift** - Lightweight shared structs: `MediaTag`, `MediaPerformer`, `MediaStudio`, `MediaGalleryRef`, `MediaGroupRef`, plus full detail structs `ImageDetail` and `SceneDetail` (fetched on-demand, not in list queries)
- **MediaDetailSheet** - Two-tab sheet (Info read-only + Edit) opened from the ornament Info button. Info tab shows file metadata, associations (tags/performers/studio/galleries as chips via `FlowLayout`), and stats. Edit tab has searchable pickers for tags/performers/studio, text fields, rating editor, URL list, and organized toggle. **Edits are committed automatically when the sheet closes** (both the "Done" button and swipe/other dismissal via `onDisappear`) — there is no explicit Save button; `commitChanges(using:)` writes only when `hasUnsavedChanges` (diffed against an `EditSnapshot` baseline). O-counter +/- is committed immediately (separate from the save-on-close path). On a successful save the `onSaved(rating100)` callback lets the presenting ornament update `windowModel.image`/`video.rating100` so the Info icon refreshes live. Delete section at bottom with confirmation dialog ("Remove from Stash" vs "Delete File from Disk")

### Multi-Select
Gallery grids (`GalleryGridView`, `VideoGalleryView`) support multi-select mode:
- Toolbar "Select" button toggles `appModel.isSelectingImages`/`isSelectingVideos`
- Thumbnails show checkbox overlay; tapping toggles selection in `selectedImageIds`/`selectedVideoIds` (Set<String> of stash IDs)
- Bottom selection toolbar: Select All / Deselect All, count label, Delete button with bulk confirmation dialog
- Bulk delete via `destroyImages`/`destroyScenes` API calls

### Remote API Viewer
A slideshow viewer that fetches images from a [RoboFrame](https://github.com/illixion/RoboFrame) API and displays them with clock/sensor overlays, Ken Burns animation, WebSocket control, and Home Assistant integration. Enabled via Settings → Developer → Enable Remote API Viewer, which adds a "Remote" tab.

**Protocol reference:** The authoritative WebSocket protocol spec lives in the RoboFrame repo at `~/Projects/RoboFrame/docs/protocol.md` (frames, readiness barrier, playback cycle, action scoping). Consult it before changing any WS message handling.

**Architecture:**
- **RemoteViewerConfig** — Codable config struct with all settings, saved to UserDefaults via AppModel. `Equatable` (the Remote tab editor diffs drafts against it). `mode` (`RemoteViewerMode`) decides which window the profile launches **and where its content comes from** — it used to hinge on `apiEndpoint.isEmpty`, which conflated "no server configured" with "show the app's own gallery":
  - `.slideshow` — RoboFrame server (label "RoboFrame"). An empty endpoint is **refused**, not a fallback (`isLaunchable` / `launchBlockedReason`, enforced in `enqueueRemoteViewerOpen` and the Remote tab's buttons)
  - `.webPage` — pinned website (label "Website")
  - `.appGallery` — slideshow of the app's own content, launched by the tab bar's play button with a transient source override. Excluded from `RemoteViewerMode.userSelectable`, so the Remote tab never offers it: a saved profile can't describe "whatever I'm looking at", which is exactly what made the old blank-endpoint mode unpredictable
  `duplicated(name:)` is the Copy path (copies wholesale — the old hand-enumerated copy had silently drifted); `applyViewerDisplaySettings(from:)` is the viewer write-back merge (see Gallery mode below)
- **RemoteViewerSceneRoot** — the `remote-viewer` scene's root: resolves the profile via `AppModel.remoteViewerConfig(id:)` and builds either `RemoteViewerWindowView` or `WebPageWindowView`. Both modes share the scene, so they also share the open-window registry, the duplicate-open summon path, and the size write-back binding
- **WindowSizePersistence** — shared "remember this window's size across cold relaunches" engine (restore-with-retry against *this* window's scene, plausibility floors on both ends of the round-trip, debounced write-back into the scene archive + a `RestoredWindowTracker` fallback). Extracted from `RemoteViewerWindowView`; both it and `WebPageWindowView` drive the one implementation
- **SlideshowEngine** — `@MainActor @Observable` reusable base class running a state machine (idle → loading → displaying ⇄ paused / backgrounded → stopped). Owns prefetch buffer (3 images ahead), crossfade transitions, Sobel-based Ken Burns focus, dynamic brightness, scene-phase handling, and navigation. Content is preserved across background cycles — the engine has no aggressive unload timer and relies on normal image cycling to bound memory.
- **RemoteViewerModel** — `SlideshowEngine` subclass adding WS integration, save/block, sensor display, Display Sync, and config persistence. Also used as the app's slideshow engine (replaces the old PhotoWindowModel slideshow; `.appGallery` windows use `GalleryContentProvider` for images and `VideoSlideshowContentProvider` for videos)
- **RemoteTabView** — the profile manager. Everything below the profile list is a **draft**: nothing reaches `savedRemoteConfigs` until an explicit Save, and the Editing section names the profile a save would overwrite plus whether the draft still matches it (the matching list row carries an "Editing · unsaved" chip). Save / Revert / **Save as Copy** are separate acts; switching profiles or hitting New with unsaved edits confirms first. If an open viewer window changes the loaded profile, a clean draft silently re-adopts it and a dirty one is flagged with a Reload — a blind save would revert the window's change
- **SlideshowContentProvider** / **RemoteContentProvider** / **GalleryContentProvider** — protocol + implementations that abstract post fetching and image downloading so the engine is agnostic to the source
- **RemoteViewerWindowView** — Main viewer window with image/clock/sensor layers, ornament with auto-hide. Supports both remote API and gallery image sources
- **RemoteAPIClient** — Actor for search/get/save/history HTTP endpoints
- **RemoteWebSocketClient** — `@Observable` class managing a single `URLSessionWebSocketTask` with auto-reconnect. Not owned by a single viewer — acquired from `SlideshowSyncHub`.
- **SlideshowSyncHub** — `@MainActor` singleton providing (1) WS connection pooling keyed by endpoint URL so multiple viewer windows share one connection (RoboFrame server messages broadcast to every subscriber), and (2) local Display Sync broadcast between in-process `RemoteViewerModel` instances (current/next image, prefetched queue, cached posts, cursor, delay — `UIImage` is reference-typed so no bitmap copies)
- **SobelFocusAnalyzer** — Pure functions for Sobel edge detection (Ken Burns focus) and average luminance (dynamic brightness)

**Web page mode (`RemoteViewerMode.webPage`)** pins an arbitrary URL as an interactive panel in the user's space — no slideshow engine, no WebSocket, no content provider. The Remote tab's Mode picker switches the editor between the slideshow sections and a Web Page section (URL, transparent background, auto-refresh).
- **WebPageWindowModel** — per-window `@MainActor @Observable` model that **owns the `WKWebView` for the window's whole lifetime**. That ownership *is* the "retained state" feature: the page keeps its scroll position, logins and in-page JS while the user looks away, because nothing about the WebView depends on SwiftUI view identity. Side-effect-free `init`, `start()` builds + loads, `cleanup()` on dismiss. Also owns nav state for the ornament, the auto-refresh timer, and a nested non-isolated `Delegate` (nav/UI/script-message; separate from the model so `@Observable` stays off NSObject). `target="_blank"` loads in place — a pinned page is one panel, not a browser with tabs.
- **Interaction gate** — the page only accepts input while the ornaments are visible (`webView.isUserInteractionEnabled`, plus `.allowsHitTesting`), because visionOS paints gaze-hover highlights inside web content and that's distracting on a page pinned as decoration. **The reveal target must be a drawn layer in *front* of the page:** a tap gesture on the container *behind* the WebView is never delivered on device — with the page non-interactive, gaze targeting finds nothing in that region and the window goes completely dead. So a `Color.white.opacity(0.001)` catcher (not `.clear` — a fully clear layer isn't gaze-targetable) covers the page while hidden. That catcher is device-confirmed and is the **sole** way back: the ornaments, the window controls (`persistentSystemOverlays`) and any visible affordance are all gone in the hidden state — deliberately, so a pinned page reads as content in the room — so don't remove it without replacing it.
- **Auto-refresh** (`webAutoRefreshInterval`, 0 = off, presets in `RemoteViewerConfig.webAutoRefreshOptions`) is "reload after N seconds of *idleness*": an injected throttled interaction reporter (`pageInteraction` message) restarts the countdown, so a reload never lands mid-form-fill. It also restarts the ornament auto-hide — the ornaments gate input, so letting them hide mid-scroll would yank the page out from under the user's hands. Paused while the window isn't in the current room; on return, a page past its interval refreshes immediately.
- **Transparent background** (`webTransparentBackground`, deliberately *not* the slideshow's `transparentBackground`, which `applySlideshowDefaults` seeds) injects a document-start user script forcing `html`/`body` transparent and sets `isOpaque`/`backgroundColor`/`underPageBackgroundColor` — the last one matters, without it WebKit paints an opaque backdrop derived from the page colour and defeats the CSS. Opaque pages get a `glassBackgroundEffect` backing and rounded corners instead. The WebView's configuration is immutable after creation, so this is read at window-open; editing the profile takes effect on the next launch.

**Slideshow 3D (`Slideshow3DMode`: `.off` / `.spatial3D` / `.immersive3D`)** applies to both media kinds. Images go to `SlideshowSpatial3DLayer` (RealityKit `ImagePresentationComponent`, two slots). **Videos are converted to windowed stereoscopic 3D in real time** whenever a real-time depth model is installed — the slideshow mounts `Pseudo3DVideoPlayerView` with `depthMode: .realtime` in place of the WebKit tiers. Deliberately **never** `.cached`: the pre-processed path writes a depth video per clip to `DepthCache/`, and a slideshow cycles through far too much content to do that; slideshow depth exists only as long as the frame it warps. Because the stereo pump pulls frames from an `AVPlayerItemVideoOutput`, eligibility needs an AVFoundation-decodable source: `SlideshowEngine.resolvePseudo3DTarget` probes the raw URL then the provider's `hlsURL` (the server transcode — WebKit-only WebM/VP9 is reachable only that way) via the shared `NativeVideoDecodeProbe`, memoizing answers in RAM and bounded by a 2s per-candidate timeout. The probe runs *before* the transition so the clip mounts straight into the stereo player instead of painting a flat frame and swapping renderers; it returns without suspending when 3D is off, so the 2D path pays nothing. The resolved `Pseudo3DVideoTarget` is post-id-keyed and read through `activePseudo3DVideoURL`, which re-checks it against the video on screen — so it self-invalidates on every post change with no clearing at the call sites. No model installed, an undecodable source, or `onPlaybackError` → flat playback (`reportPseudo3DVideoFailure`, ignored when it arrives late for a post already gone). Toggling the ornament's 3D mode mid-video re-resolves immediately. Two `Pseudo3DVideoPlayerView` params exist for this caller: `loops` (the slideshow only loops clips shorter than its dwell interval; the video window always loops) and `contentOpacity`, which drives the crossfade through `OpacityComponent` because RealityKit ignores SwiftUI's `.opacity` — routed via the `Animatable` `AnimatableSceneOpacity` modifier so the fade interpolates instead of cutting to black. Adjustments (incl. dynamic brightness) are baked into the warp shader for the same reason.

**RoboFrame Proxy API:**
- `GET {baseURL}/get?id={postId}` → serves image directly (used as img src)
- `GET {baseURL}/save?id={postId}` → saves post, returns status text
- `GET {baseURL}/addtohistory?id={postId}` → adds to viewing history
- There is no `/search` endpoint — the RoboFrame server is the single DuckDB reader. Posts arrive via the WebSocket `playback` channel.

**WebSocket Protocol (JSON, `{ action, payload }`):**
- **Outgoing:** `slideshowConfig {sessionId, deviceId, interval, width, height, bright, convert, lowmem, ratio?}` (sent on connect), `present {deviceId, present}` (slideshow-control — see below), `visibility {deviceId, visible}` (home-location telemetry only → HA motion sensor), `block {id}`, `displaySync {sessionId, enabled}` (claim/release primary), `setModTags {sessionId, tags}`, `requestNext {sessionId}`, `setTagList {sessionId, listNumber}` (per-channel — only the sender's deviceId switches list)
- **Incoming:** `tagLists [[String]]` (server-pushed catalog), `playback {primary, enabled, interval, currentList, modTags, current: {id, ext}, next: {id, ext}}` (active list index lives in `currentList`; there is no standalone `currentTagList` frame any more), `playVideo {url}`, `stopVideo`, `showText {text, bgColorHex, imageUrl}`, `dismissText`, `update {entity, state, attributes}` (HA sensors), `refresh`
- `playVideo`/`showText` open new windows via `openWindow()`; `stopVideo`/`dismissText` dismiss them

**Key implementation details:**
- The server is authoritative on tag list, mod tags, current/next post, and channel timing. Clients render whatever `playback` says and preload the announced `next` via `/get`.
- **No client-side advance in remote mode.** The engine is purely server-driven (`serverDriven` flag set in `start()`): it has no local dwell clock and only ever transitions to a server-pushed `current` (via `setServerCurrent` → `reconcileWithServer`). Advancing locally races the orchestrator and surfaces a prefetched post that ignores the window's advertised ratio (e.g. a wide image in a tall window with fit-to-aspect on). So: **Block** just sends `block` (server drops the post and broadcasts a fresh ratio-appropriate `current`); the **Next button** emits `requestNext` (`advanceToNext()`, the protocol's per-channel advance) rather than `goToNextImage`; the **refresh** frame clears caches and calls `reconcileWithServer` (reload, not advance). `goToNextImage` is gallery-mode only. The exceptions are **Prev** and **history-jump**, which replay already-seen posts or are explicit manual overrides. Never implement a wake-advance (requesting next on returning from background) — the server already owns dwell timing; see protocol.md "no client-side wake-advance". **Fresh image on re-entry** is delivered *server-side*, not by a wake-advance: `present`/`visibility` are split — `RemoteViewerModel.scheduleSceneStateReport(effectiveVisible)` reports both, but only `present` drives the slideshow. While every display on a `deviceId` is absent (`present:false`) the RoboFrame orchestrator does one **dark advance** to a fresh post and parks; on return (`present:true`) the server commits that fresh post and broadcasts it, and the window adopts it through the normal `playback` path (which re-reports `imageReady` on render). So `rejoinReadinessBarrier()` only calls `reconcileWithServer()` — no stale `imageReady` re-send. `visibility` is now pure telemetry (drives the HA motion sensor; no slideshow/`displayState` side effects).
- Ratio filter uses `..` separator (e.g. `ratio:1.32..1.79`), matching server expectations
- Blocked posts/tags from WS `blocked` are merged into local config and persisted
- Save button has 1.5s grace period after image transition (saves previous post)
- Visual adjustments (brightness/contrast/saturation) stack: auto (luminance-based) + per-viewer + global
- Ornament: [ Grid | Prev | Next | Save | Home | Cycle Tags | Display Sync | Adjustments | Block ] (Save/Home/Cycle/Display Sync/Block hidden in gallery mode)
- Adjustments popover has a "Viewer" tab with display toggles (clock, sensors, Ken Burns, background, aspect ratio)
- Images are downsampled on load using `maxImageResolution` from app settings via `CGImageSourceCreateThumbnailAtIndex`
- **Gallery mode (`.appGallery`):** a slideshow of the app's own content — "whatever I'm looking at". The *profile* is one of two reused slots (`AppModel.gallerySlideshowConfig` / `videoSlideshowConfig`, persisted under their own UserDefaults keys and kept out of `savedRemoteConfigs` so they don't clutter the Remote tab), so ornament tweaks persist between launches; the *content* rides along as a transient override (`pendingGallerySlideshowSource` / `pendingVideoSlideshowSource`) set immediately before the window opens. Entry points all funnel through `AppModel.startGallerySlideshow(imageSource:filter:)` / `startVideoSlideshow(videoSource:filter:)`: the tab bar's play button (Pictures/Videos), the photo viewer's Slideshow button, `LocalFolderBrowserView`'s per-folder slideshow (Albums, browsing Local), and the video viewer's Slideshow button. API-only features (WS, save, block, history, tag cycling) are disabled via `RemoteViewerModel.isGalleryMode`, which tests the **mode** — testing for a `GalleryContentProvider` mislabelled *video* slideshows as remote and left them `serverDriven` with no orchestrator to drive them. A restored `.appGallery` window (from a saved window group, long after the override was consumed) falls back to the app-wide source and filter.
- **Viewer write-back:** ornament/adjustment changes persist through `onConfigChanged` → `AppModel.persistRemoteViewerConfig`, which routes to whichever store owns the profile (saved list vs. the two slideshow slots). The window holds a snapshot from when it opened, so only the viewer-owned display fields are merged onto the current profile (`applyViewerDisplaySettings(from:)`) — writing the snapshot wholesale reverted unrelated edits the Remote tab had saved since
- **Background handling:** On background the engine transitions to `.backgrounded` (pausing the run loop) and remembers `stateBeforeBackground`. Content (current/next image, prefetch queue, cached posts) is preserved locally, but on return the server has dark-advanced to a fresh post (see the `present` split above), so the engine adopts that rather than resuming the stale one. WS present/visibility reporting is immediate. Previously the engine had a 30s unload timer but it was removed — the recovery path from nil content was fragile and the normal cycle already bounds memory.
- **Display Sync:** When the toggle is on, `onPostTransitioned` both sends the WS `displaySync` message (RoboFrame server coordination) and calls `SlideshowSyncHub.broadcastLocalSync` to mirror current/next image, prefetched queue, cached posts, cursor, and delay to every other registered local instance via `RemoteViewerModel.applyLocalDisplaySync`. An `isApplyingIncomingSync` flag suppresses rebroadcast during the crossfade await to prevent feedback loops. Pause/play state is intentionally not mirrored. Shared `TagListManager` already propagates tag list switches across windows so those don't need to ride the sync payload.
- **Shared WS:** All `RemoteViewerModel`s with the same `wsEndpoint` share a single `RemoteWebSocketClient` obtained via `SlideshowSyncHub.subscribeWS`. Each subscriber passes its own `deviceId` to `sendVisibilityChange(deviceId:visible:)`. Server messages (RoboFrame broadcasts for all device IDs by design) fan out to every subscriber; the connection closes when the last subscriber leaves.

## Key Patterns

- MainActor-bound `@Observable` AppModel passed through SwiftUI environment
- Per-window `@Observable` PhotoWindowModel with side-effect-free init (side effects in `start()`)
- Async/await for all network and image generation operations
- Actor-based concurrency for services (ImageLoader, StashAPIClient, LocalMediaSource, SharedMediaCache)
- Protocol-based data sources (`ImageSource`, `VideoSource`) for swappable implementations
- UserDefaults for persisting server config, saved filter views, and display settings
- Explicit resource cleanup in `cleanup()` methods rather than relying on ARC/deinit
- The Xcode project's files are automatically managed, therefore there is no need to update project files when adding new source files. Just create the new .swift file in the appropriate folder and it will be included in the build.

# Testing against Stash: use the dev instance

**Never point tests, simulators or agents at a real Stash server**, not even read-only. `scripts/dev-stash.sh up` runs a disposable Stash in Docker at `http://127.0.0.1:9998` (loopback only, no API key by default), seeded with 12 generated photos and 5 clips covering H.264, 10-bit HEVC 4K and VP9/Opus WebM. The simulators share the Mac's loopback, so configure the app with that URL (in the simulator via `-UITestDefault stashServerURL=http://127.0.0.1:9998`). Use `reset` to re-seed and `rm` to delete it. `scripts/dev-stash.sh auth [user pass]` turns on login for testing the app's API-key path (see "Auth" in `.claude/rules/hypnos-tvos-port.md`) — the generated key is written to a file, never printed, since it's a live (if disposable) credential.

`scripts/dev-nextcloud.sh up` does the same for Nextcloud (`http://127.0.0.1:9997`, admin / dev-nextcloud-1): `uploaded/` has photos with server-side dimensions, `scanned/` has photos without, and `backfill` runs the server's metadata job over them. Signing in from a simulator needs Login Flow v2, and a `CODE_SIGNING_ALLOWED=NO` simulator build cannot use the Keychain at all (`OSStatus -34018`), so the Nextcloud and Stash-API-key paths can't be driven from an unsigned simulator run; the Local source exercises the same dimensionless-ratio path without a secret.

Testing against the disposable Jellyfin instance (Atmos Objects plugin, Library feature seed data, and driving the tvOS Library UI without a remote) is documented in `.claude/rules/hypnos-tvos-port.md` (auto-loads when touching `JellyfinPlugin/` or `scripts/dev-jellyfin.sh`).

# Stash GraphQL API

You can find the Stash GraphQL API documentation in `internal_docs/Stash_Api_Docs`. **Important:** Claude Code prevents access to this folder while it is in .gitignore, therefore you must temporarily remove it from .gitignore to access the documentation and for your search tool to be able to see it. Undo changes to .gitignore after you are done.
