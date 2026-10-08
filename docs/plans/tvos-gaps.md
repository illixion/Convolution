# tvOS: open issues and gaps

Collected 2026-10-08 from on-device use (Apple TV 4K 2nd gen) plus a read of `Views/TV/`.
Background on how the tvOS UI is built: `.claude/rules/hypnos-tvos-port.md`. Nothing
below is fixed yet unless marked **Done**.

Items 1-6 were reported by the owner; 7-12 were found while checking the code.

## Reported

### 1. No destructive or editing actions on tvOS
tvOS has no lock screen, so anyone in the room with the remote can act as the owner.
Deleting Stash items/files and editing Stash metadata\* must not exist on the platform at all
(compiled out, not just hidden or confirmed).

\* Metadata writes of simple values (numbers and booleans: rating, activity counter, organized flag,
Jellyfin played/favorite) are fine on tvOS. The ban covers free-form and structural edits (tags,
performers, studio, URLs, titles/text) and anything destructive.

Currently reachable on tvOS (verified in code, none are gated):
- `MediaQuickActionMenuItems` (`Views/MediaQuickActions.swift`): **Delete…** (`target.deletion`) and
  **Select** (bulk-delete mode) are in the Pictures/Videos/Albums long-press menus. Only Share is
  behind `#if !os(tvOS)`. **Rating** (`updateImageRating`/`updateSceneRating`) is a simple value and
  stays.
- **Info** opens `MediaDetailSheet`, whose Edit tab edits tags/performers/studio/URLs (not allowed)
  alongside rating/organized (allowed) and has its own Delete section, saved automatically on close.
- Confirm no other path: Library lockup menu (`LibraryItemContextMenu`: Mark Watched/Unwatched and
  Favorite are booleans, so allowed), Settings → Stash/Nextcloud/Jellyfin credentials and Sign Out,
  Settings → Cache Clear, Developer.

Direction: gate Delete, Select and the text/structural parts of `MediaDetailSheet`'s Edit tab
behind `#if !os(tvOS)`; keep Info read-only plus the number/boolean controls (rating, activity counter,
organized).
Decide separately whether Settings (credentials, sign-out) needs the same treatment.

### 2. Video player has almost no controls
`TVVideoPlayerView` wraps a bare `AVPlayerViewController` around an `AVPlayer`. Compared with
Infuse it lacks:
- subtitles (the Stash caption and Jellyfin sources exist in `SubtitleController` but are only
  wired into the visionOS/iOS/macOS players via `RAVESubtitleOverlay`; on tvOS, offer them through
  the system's legible-media menu or an overlay),
- audio track selection,
- quick controls (speed, skip, A/B loop, aspect fill/fit, info),
- anything beyond what AVKit gives for free (the only app-specific piece is the Skip Intro
  contextual action).
Note the Jellyfin object-audio film player (`FilmPlayerView`) has its own tvOS transport; this item
is about the generic video player used for Stash/Local/Nextcloud/Photos and non-Atmos Library titles.

### 3. Audio hitches on a stereo HomePod pair; output stereo when the output is stereo
`item.applySpatialAudioPolicy()` is applied to the `AVPlayerItem`. With a HomePod stereo pair the
app is offered 2 channels (see the tvOS notes: no Atmos from apps over AirPlay), but audio
hitches often. To investigate:
- what `applySpatialAudioPolicy()` does on tvOS and whether it forces spatialization/virtualization
  on a plain stereo route,
- `AVAudioSession` route (`currentRoute.outputs`, `maximumOutputNumberOfChannels`, whether the
  output is a stereo pair vs. an Atmos-capable receiver) and
  `allowedAudioSpatializationFormats`,
- AirPlay buffering: `AVPlayerItem.preferredForwardBufferDuration`, audio session category and
  `prefersNonInterruptionBy…`, and whether the generic player and the film player (PHASE, forced
  binaural on a stereo pair per the tvOS notes) behave differently.
Goal: when the route is just stereo, play plain stereo with no spatial processing.

### 4. No video looping
No loop control in `TVVideoPlayerView`. visionOS has the A-B loop (`VideoLoopController`) and the
video window always loops; tvOS should at least offer loop-on-end, ideally A-B.

### 5. Letterboxing on all four corners of images
`TVPhotoViewerView` puts the image in a `ZStack` over `Color.black.ignoresSafeArea()` but the
`Image` itself respects the tvOS title-safe insets, so a fit image sits inside a margin on every
side. The image should ignore the safe area (and fit/fill the full 1920x1080 or 3840x2160 frame),
keeping any overlay UI inside the safe area. Check the video player for the same inset.

### 6. Photo viewer has no quick controls
Only Menu (close), left/right (prev/next) and Play/Pause (slideshow toggle) exist. Missing: info,
favorite/rating (simple values, allowed per item 1), slideshow interval and loop/shuffle,
fit/fill toggle, zoom/pan, a position indicator (N / M), and a way to discover any of this (no
on-screen hint).

## Found while checking

### 7. tvOS and macOS grids use the chip-sized thumbnail path
`TVPicturesTabView`, `TVVideosTabView`, `TVAlbumsTabView` and the Mac grids use `MediaThumbnail`,
written for filter chips and album covers. visionOS/iOS use `GalleryThumbnailView`
(warm-cache first paint, 120 ms cold-load delay, `FetchGate` newest-first, cancellation, HEIC
disk cache). **Partly done** in `ef2fc8f`: `ImageLoader.loadThumbnail`'s remote branch now
downsamples from bytes (via `loadRemoteThumbnailCached`) instead of decoding the full image, which
had been running the app out of memory (Jetsam `vm-pageshortage`, ~726 MB peak). Still to do: move
these grids onto the shared loading pipeline so they stop drifting. Verify scroll speed on a
JXL-only Stash library.

### 8. JXL on the Nextcloud source
Nextcloud has no JXL preview provider, so `index.php/core/preview` fails for every file in an
all-JXL library, and the `?? item.downloadURL` fallback in `NextcloudMediaSource` is dead code
(`previewURL` never returns nil). Needs client-side thumbnails: download, downsample with ImageIO
(decodes JXL natively), store in `ThumbnailCache`.

### 9. Photo viewer loads the original at full resolution
`TVPhotoViewerView.load()` calls `ImageLoader.loadImage(from: fullSizeURL)`: full decode plus
normalize, no downsampling to the display size, and it goes into the 512 MB memory cache. For large
JXL/HEIC originals that is the same OOM risk as item 7. Downsample to the screen size
(`ThumbnailGenerator`/`CGImageSource`), and prefetch only the neighbouring image.

### 10. The Library tab appearing rebuilds every other tab
Typing a server and API key into Settings → Jellyfin makes `LibraryService.isAvailable` true, which
adds the Library tab and rebuilds the other tabs' content (documented in `TVSettingsState`). With a
heavy Pictures grid underneath this is what turned item 7 into a crash. Worth measuring whether the
rebuild itself is avoidable now that `Tab(value:)` is in use.

### 11. No on-device debugging for the Apple TV
`build-and-sign --mcp` did not have a session for this crash, so the only evidence was the Jetsam
reports (`devicectl device info files --domain-type systemCrashLogs`), which name no allocation.
Run the Apple TV with `--mcp` before reproducing anything memory-related so `_memory` / `_profile`
can be used.

### 12. tvOS has no automated UI coverage
`HypnosUITests` stays visionOS-only and `simctl` cannot press remote buttons, so every fix above is
verified by hand on the Apple TV or through the DEBUG launch arguments (`tvInitialTab`,
`tvAutoOpenPictureIndex`, `tvSettingsInitialPage`). Consider extending those hooks for the new
controls so each can at least be screenshotted in the simulator.
