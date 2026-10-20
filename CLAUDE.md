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

## Quest / Horizon OS handoff

The development Android port lives in `Quest/` and is part of this repository,
not a separate app/backend fork. Read `Quest/README.md` for build/deploy commands,
`docs/plans/quest-parity-roadmap.md` for the architecture review and ordered work,
and `.claude/rules/hypnos-quest-port.md` before modifying the port.

Compose/VR Layout SDK owns Home windows; Spatial SDK owns the optional movable
passthrough player. One `PlaybackSession` owns Media3/MediaCodec and lends
surfaces to presentations. Portable Swift is in RAVESDK's `RAVEMediaCore` and
`RAVEQuestCore`; important backend behavior must converge there, with Android
and Apple framework bindings kept outside it. Never reset the playhead when
changing presentation, quality, decoder or server stream identity.

The Quest implementation and reviewed roadmap are merged into the primary
Hypnos and RAVESDK repos as of 2026-10-08. Start new work from their current
`main` branches; the older `quest-player` / `wt/Hypnos-quest-player` branches
are historical integration work. Use `apple-worktree` for any new worktree.

**Next work is roadmap steps 1 and 2, not object audio:** fix unscoped offline
ownership/sync, chapter skip boundaries and stream/job reporting identity,
then converge the duplicated Jellyfin DTO/planner code and introduce typed
Android state. These are documented open findings, not fixed by the merge.
Quest 3 previously confirmed Home/spatial picture, captions, geometry, pause
handoff and the browsing dock. The newer paging/watch/download features have
build/install evidence but still need headset interaction checks. Quest 2,
object audio, MVC discs and fake-3D are not validated implementations.

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

Shared code must never read SwiftUI's raw `openWindow`/`pushWindow`/`dismissWindow` environment actions: use the
`@OpenWindowProxy` / `@PushWindowProxy` / `@DismissWindowProxy` wrappers from `Support/WindowActions.swift`, or it will
not compile on iOS. The rest of the port (window router, `PlatformShims`, capability flags, the ornament-scroll gotcha)
is in `.claude/rules/hypnos-ios-port.md` (auto-loads when touching `Views/IOS/`, `PlatformShims.swift`,
`WindowActions.swift` or `IOSWindowRouter.swift`).

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

`HypnosUITests` is the app's only test target (XCUITest is the only way to drive a visionOS app's UI). Always run it
through the script, which keeps `-collect-test-diagnostics never` (a passing run otherwise hangs 600 s). How the suite
is wired (shared accessibility identifiers, `-UITestDefault` launch arguments, `AppLauncher.baseline`, device-only
Spatial 3D) is in `.claude/rules/hypnos-ui-tests.md` (auto-loads when touching `HypnosUITests/`).

## Architecture

### App Structure
- **HypnosApp.swift** - App entry point defining scenes: main window, photo-detail pop-out, video-detail, shared-photo viewer (shared *videos* reuse video-detail), console, GPU memory monitor, remote-viewer (slideshows; the id predates the rename), and StereoscopicVideoSpace (immersive)
- **HypnosAppIntents.swift** - App-target glue for `RAVEOpenMainWindowIntent` (RAVEUI): the `AppIntentsPackage` chain plus the Siri/Shortcuts phrases ("Open a Hypnos window"). Exists because a visionOS icon tap with any window alive summons the nearest window to the user (dragging pinned windows out of their rooms) with no public opt-out — the intent is the supported way to always get a fresh main window at your location. The window-session registry itself is RAVEUI's `RAVEWindowSessionRegistry` (the local `WindowSessionRegistry` was deleted). The type window values persist their size as is likewise RAVEUI's now, `RAVECodableSize` — same property names as the deleted local `CodableSize`, so existing scene-restoration archives still decode.
- **AppModel.swift** - Central `@Observable` state container for gallery data, server config, filter state, video playback state, memory monitoring, and persisted settings (UserDefaults)
- **PhotoWindowModel.swift** - Per-window `@Observable` model for individual photo viewers. Contains all stored properties, init/start lifecycle, core image loading pipeline, interaction tracking, shared utilities, and resource cleanup. Split into extension files by concern:
  - **PhotoWindowModel+VisualAdjustments.swift** - Auto-enhance (3-tier cache), brightness/contrast/saturation adjustments, 3D adjustment preview with debounced reload
  - **PhotoWindowModel+Spatial3D.swift** - 3D mode activation/deactivation, `ImagePresentationComponent` creation, spatial 3D generation, viewing mode switching, resolution override
  - **PhotoWindowModel+BackgroundRemoval.swift** - Background removal pipeline: toggle, full-resolution processing, cache loading, resolution reloading, state management
  - **PhotoWindowModel+MemoryManagement.swift** - Idle downscale (release/thumbnail/restore), scene phase tracking, lightweight display transition
  - **PhotoWindowModel+GalleryNavigation.swift** - Gallery image switching, prev/next navigation, lazy loading pagination, rating/activity counter updates
  - **PhotoWindowModel+UIControls.swift** - Share sheet, UI auto-hide timers, image flip
  - **PhotoWindowModel+AIDepth.swift** - AI 3D: the depth-mesh viewing mode (RAVEMedia's `RAVEAIDepthPhotoView`), its source picture and depth map, and how it yields to the other modes

### Windows Tab (window manager)
`WindowsTabView` is the app's window inventory: every open window with **Summon** and **Close** on each, plus Hide All / Close All underneath. The registry, the rows and the recycle mechanics are **RAVEUI's** `RAVEWindowRegistry` / `RAVEWindowManagerView`; the app supplies only labels and fresh-identity clones, in `Model/ManagedWindows.swift`, applied to each scene root in `HypnosApp` via `.manageWindow(...)`.

**Summon is a recycle, not a recall** — it dismisses the scene and opens an equivalent fresh one. That serves the ordinary case (fetch a window snapped in another room) *and* the visionOS 27 regression where a summoned scene is activated but never re-attached to a compositor placement, leaving the window permanently invisible while the scene still reports itself active and visible (`internal_docs/visionos27-invisible-window-feedback.md`; reproduces with stock Clock). Nothing app-side redraws such a scene, so destroying it is the only recovery — and `openWindow` against the live scene is the call that *causes* it, which is why the same dismiss-then-reopen shape already guards the cross-room summon in `ContentView.handleRemoteViewerOpenIfNeeded` / `handlePhotoWindowOpenIfNeeded`.

The `recreated()` clones on `PhotoWindowValue` / `VideoWindowValue` / `RemoteViewerWindowValue` / `RemoteAlertWindowValue` carry the same content under a **new window id**, which is what lets the dismiss and the open be issued in the same turn without the fresh window matching the dying scene. `SharedMediaItem` has no separable identity, so its window reopens verbatim after waiting for teardown. Recreated windows drop `wasPushed` — there is no originating gallery window left to pop back to.

Main windows are managed too, so a second Gallery window parked in another room is recoverable; each Windows tab excludes the window it is displayed in (RAVEUI's `raveWindowToken` environment value). Close All goes underneath SwiftUI to UIKit scene sessions (`RAVEWindowScenes.destroyAll(except:)`) because a window that never got a layout pass never registered — which is exactly the launch-time variant of the same bug.

### Data Flow
Four library sources, chosen via `AppModel.librarySource` (`LibrarySource`: `.photos`/`.stash`/`.local`/`.nextcloud`) and resolved to the pair actually in force by `AppModel.effectiveLibrarySource`/`makeSources(for:apiClient:)`:
1. **PhotosImageSource/PhotosVideoSource** - The device photo library, via `PhotosIndexStore`. The default with no server configured, and always available — no setup needed.
2. **GraphQLImageSource/GraphQLVideoSource** - Fetches from a Stash server via `StashAPIClient`. Selectable once `stashServerURL` is set.
3. **LocalImageSource/LocalVideoSource** - Scans `Documents/Photos`/`Documents/Videos` for local files. Always available too, like Photos — needs no permission and no setup, so unlike Stash there's nothing to gate it behind. Settings → Local Files is informational only (where to put the files), not a toggle.
4. **Nextcloud** (`NextcloudMedia`, the in-repo package under `Packages/`) - A Nextcloud server's files under a chosen root folder, listed over WebDAV and signed in through Login Flow v2 so the app never sees the password. Selectable once `hasNextcloudServer`. Photos taken from a scan rather than an upload carry no server-side dimensions, which is what `MediaAspectStore` and the original-aspect grid's "Sources that report no dimensions" note below are about.

**Jellyfin is not a `LibrarySource`.** It feeds the separate **Library** tab and the film player through the server-agnostic `MediaServerLibrary` (`Services/Library/`), not the Pictures/Videos pipeline.

`AppModel.availableLibrarySources` is which of the four currently apply — Photos and Local unconditionally, Stash and Nextcloud once configured; `effectiveLibrarySource` falls back to Photos when the stored choice isn't one of them (server removed). The tab bar's library-switch button (`TabBarOrnament`, only shown on Pictures/Videos with more than one source available — which, with Local always in the list, means Pictures/Videos always) is a dropdown menu rather than a cycling button, since more than two sources made "tap to switch to the other one" ambiguous about where a tap would land.

Source protocols:
- `ImageSource` - Protocol for paginated image fetching with optional filter support
- `VideoSource` - Protocol for paginated video fetching

### Tab Navigation
Tabs defined in `Tab.swift`: Pictures, Videos, Albums, Library (Jellyfin), Filters, Windows (visionOS only), Settings, Console (developer). Tab switching managed by `ContentView` with ornament-based navigation via `TabBarOrnament`. Console is conditionally visible based on `appModel.showDebugConsole`; Filters hides itself while browsing Local (nothing there to filter by — no tags, albums or galleries) and `ContentView` redirects away from it if it was already open when the library changed.

Past a separator at the **end of the tab bar**, `TabBarOrnament` shows a **play button** that starts a slideshow of what the current tab is showing (Pictures/Videos with the filter in force). It's absent on other tabs, and on Pictures/Videos until content has loaded. This is the supported way to get "slideshow of what I'm looking at"; see `.claude/rules/hypnos-slideshows.md`. There used to be a Local tab with its own ornament-level slideshow case; Local is a library source now (see Data Flow above), and its folder browser (`LocalFolderBrowserView`, under Albums) offers its own per-folder "Play Slideshow" control in context instead.

### Albums Tab
`AlbumsTabView` browses whichever library is in force. For Photos and Stash, a container (`MediaContainer` — a Photos album/smart album, a Stash gallery, or for video a Stash group) is a single filter value: opening one calls `AppModel.applyContainer(_:isVideo:)`, which sets the matching field on `currentFilter`/`currentVideoFilter` and switches to Pictures/Videos, so there's no second content pipeline — paging, sort, and the rest of the filter are all the one the grids already use. `AppliedContainerBanner` is the way back, reading the applied filter rather than separate state so it can't disagree with the grid it's captioning.

Local doesn't fit that shape — a folder nests, and a `MediaContainer` is one filter value applied once, not a place to descend into and climb back out of — so `LocalFolderBrowserView` renders instead of the container grid whenever `appModel.effectiveLibrarySource == .local`: real up/down navigation over `Documents/Photos` or `Documents/Videos` (whichever `isVideo` — the same flag Photos/Stash use to split image vs. video containers — picks), with a folder tree state (`MainWindowModel.localFolderPath`, `.albumsReselected` for "pop to root" on a re-tap) that outlives tab switches for the same reason `albumsShowingVideos` does. Tapping a file opens it directly (no filter/apply step, since a folder's contents aren't a filter criterion); a per-folder "Play Slideshow" button covers what the ornament's slideshow button used to do for the old Local tab.

### Area guides (path-scoped rules)

The per-subsystem design notes, and the device findings behind them, live in `.claude/rules/`. Each file loads
automatically when you read or edit a file it covers (the globs are in its frontmatter); open it directly when you start
work on an area without having touched one of those files yet.

| Rule file | Covers |
| --- | --- |
| `hypnos-photo-viewer.md` | Photo viewer windows, `WindowResizeCoalescer`, the GPU 2D path, deep colour, auto-3D restore, Spatial 3D images |
| `hypnos-gallery-grid.md` | Pictures grid (square / justified rows), 3D depth and diorama thumbnails, thumbnail context menus and Quick Look, tvOS no-delete |
| `hypnos-video-window.md` | Video window, ornaments and control bar, WebKit / native Metal players, stream-URL strategy, immersive MV-HEVC, visionOS player chrome |
| `hypnos-ai-3d-video.md` | AI 3D (fake-3D) engage flow, depth models and cache, `Pseudo3DSettings`, live stereo, 3D overload |
| `hypnos-film-player.md` | Object-audio film player, audio governor, Dolby Vision, picture tiers, the room |
| `hypnos-library-jellyfin.md` | Library tab, stream quality, Jellyfin 12.x, subtitles, offline downloads |
| `hypnos-youtube.md` | YouTube resolver chain, surround splice, quality caps, SponsorBlock |
| `hypnos-slideshows.md` | Picture and video slideshows, their profiles and window, Slideshow 3D |
| `hypnos-ios-port.md`, `hypnos-tvos-port.md`, `hypnos-macos-port.md`, `hypnos-quest-port.md` | One file per platform port |
| `hypnos-ui-tests.md` | XCUITest wiring |

Invariants that bite outside the files above, so they stay here:
- **Every photo-viewer geometry request goes through `WindowResizeCoalescer`.** visionOS has no window-position API, so each granted resize is also an uncorrectable move.
- **`AppModel.init` sets `RAVEMediaPolicy.depthCacheCap`.** Remove it and the depth cache never evicts.
- **Fake-3D needs real depth.** No depth model and no cache means the flat 2D player, never a heuristic warp.
- **The app never does Dolby processing itself** (decided 2026-10-10): only the OS codecs and renderers read a Dolby Vision RPU; when a picture needs converting, the server does it.
- **YouTube is sideload-only (`HYPNOS_YOUTUBE`).** Nothing YouTube may compile into a submission build; build all four platforms both with and without `YOUTUBE_CONDITION=HYPNOS_YOUTUBE` before committing.

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

### Incoming URLs
The app registers a `hypnos://` custom URL scheme (declared in `Info.plist`, handled by **IncomingURLHandler**; a `SceneDelegate` notification path covers file-share cold launches that SwiftUI's `.onOpenURL` misses, so `AppModel.shouldProcessIncomingURL` de-dupes the double-fire). Hosts: `play?url=<link>` (also the default for a bare `hypnos://`), `image?id=<stashId>`, `scene`/`video`, and `setup` (settings carried from another device by `RAVEDeviceSetup`'s QR code).

- **StreamableURLResolver** classifies a `play` target as `.directVideo` (a file or an MP4/HLS-style stream, opened in a stream video window straight away) or `.notPlayable` (handed back to the image/file share path). **Web pages are not resolved.** The one exception is a YouTube link in a `HYPNOS_YOUTUBE` build, which `route` hands to `YouTubeResolver` before the page probe (see YouTube below).
- The old "Open in Spatial Viewer" Shortcut still points at `spatialstash://` and has to be recreated against `hypnos://`.

### API Client
`StashAPIClient` is an actor that handles GraphQL communication with Stash server. Accessible via `appModel.apiClient` (private(set)). Supports:
- **List queries:** `findImages`, `findScenes`, `findGalleries`, `findTags`, `findStudios`, `findPerformers` (paginated, with filters)
- **Detail queries:** `fetchImageDetail(id:)` → `ImageDetail`, `fetchSceneDetail(id:)` → `SceneDetail` (on-demand full metadata)
- **Mutations:** `updateImage`/`updateScene` (full field update), `updateImageRating`/`updateSceneRating`, the image and scene activity-counter increment/decrement mutations
- **Delete:** `destroyImage`/`destroyScene` (single), `destroyImages`/`destroyScenes` (bulk), with `deleteFile` and `deleteGenerated` options
- Server config persisted via UserDefaults

### Media Metadata & Detail Views
- **MediaMetadata.swift** - Lightweight shared structs: `MediaTag`, `MediaPerformer`, `MediaStudio`, `MediaGalleryRef`, `MediaGroupRef`, plus full detail structs `ImageDetail` and `SceneDetail` (fetched on-demand, not in list queries)
- **MediaDetailSheet** - Two-tab sheet (Info read-only + Edit) opened from the ornament Info button. Info tab shows file metadata, associations (tags/performers/studio/galleries as chips via `FlowLayout`), and stats. Edit tab has searchable pickers for tags/performers/studio, text fields, rating editor, URL list, and organized toggle. **Edits are committed automatically when the sheet closes** (both the "Done" button and swipe/other dismissal via `onDisappear`) — there is no explicit Save button; `commitChanges(using:)` writes only when `hasUnsavedChanges` (diffed against an `EditSnapshot` baseline). activity counter +/- is committed immediately (separate from the save-on-close path). On a successful save the `onSaved(rating100)` callback lets the presenting ornament update `windowModel.image`/`video.rating100` so the Info icon refreshes live. Delete section at bottom with confirmation dialog ("Remove from Stash" vs "Delete File from Disk")

### Multi-Select
Gallery grids (`GalleryGridView`, `VideoGalleryView`) support multi-select mode:
- Toolbar "Select" button toggles `appModel.isSelectingImages`/`isSelectingVideos`
- Thumbnails show checkbox overlay; tapping toggles selection in `selectedImageIds`/`selectedVideoIds` (Set<String> of stash IDs)
- Bottom selection toolbar: Select All / Deselect All, count label, Delete button with bulk confirmation dialog
- Bulk delete via `destroyImages`/`destroyScenes` API calls

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
