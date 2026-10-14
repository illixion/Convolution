---
paths:
  - "Hypnos/Hypnos/Views/Pictures/GalleryGridView.swift"
  - "Hypnos/Hypnos/Views/Pictures/GalleryThumbnailView.swift"
  - "Hypnos/Hypnos/Views/Pictures/DepthTileView.swift"
  - "Hypnos/Hypnos/Views/Pictures/DioramaTileView.swift"
  - "Hypnos/Hypnos/Views/Pictures/QuickLook*"
  - "Hypnos/Hypnos/Views/Videos/VideoGalleryView.swift"
  - "Hypnos/Hypnos/Views/Videos/VideoThumbnailView.swift"
  - "Hypnos/Hypnos/Views/Videos/VideoQuickLookView.swift"
  - "Hypnos/Hypnos/Views/JustifiedRowLayout.swift"
  - "Hypnos/Hypnos/Views/MediaThumbnail.swift"
  - "Hypnos/Hypnos/Views/MediaQuickActions.swift"
  - "Hypnos/Hypnos/Views/ScaleHoverEffect.swift"
  - "Hypnos/Hypnos/Views/LiftHoverEffect.swift"
  - "Hypnos/Hypnos/Views/Albums/**"
  - "Hypnos/Hypnos/Views/Library/LibraryItemContextMenu.swift"
  - "Hypnos/Hypnos/Services/Thumbnail*"
  - "Hypnos/Hypnos/Services/MediaAspectStore.swift"
  - "Hypnos/Hypnos/Model/GalleryGridStyle.swift"
  - "Hypnos/Hypnos/Model/ThumbnailStyle.swift"
---

# Hypnos: Pictures grid, thumbnails and context menus

Moved out of `CLAUDE.md`, including the 2026-10-07 device findings on 3D depth thumbnails.

## Pictures Grid (`GalleryGridView`)
Two modes, chosen by Settings → Display → **Pictures Grid** (`AppModel.galleryGridStyle`, `GalleryGridStyle`; default `.square`):
- **Square** — the original uniform `LazyVGrid` of center-cropped cells.
- **Original Aspect Ratio** — justified rows (`Views/JustifiedRowLayout.swift`, pure geometry, no SwiftUI): every cell in a row shares a height, widths follow each image's ratio, and the row height is whatever fills the window width. `LazyVGrid` can't express this and a custom `Layout` isn't lazy, so rows render in a `LazyVStack`. Layout comes from metadata alone (`GalleryImage.reportedAspectRatio`, i.e. `sourceWidth/Height`), so it is settled before any pixel loads and skipped ranges of a fast flick are already the right size. Appending a page only changes the trailing partial row. Extreme ratios are clamped (0.5–2.5) and the cell center-crops. The rows are memoized in `JustifiedRowsCache`; `scrollTo` targets the row's id, not the nested cell's.
- **Sources that report no dimensions** (Nextcloud that was bulk-scanned rather than uploaded, Local files) are laid out at 1:1 until the thumbnail loads; `GalleryThumbnailView.show` then records the true ratio in `MediaAspectStore` (JSON in Application Support, keyed by `GalleryImage.identity`), and its debounced `revision` re-lays the grid out once. Each item reflows at most once per install. Nextcloud's own Photos app records `nc:metadata-photos-size` for files uploaded *through* Nextcloud; `AppModel.nextcloudDimensionCoverage` drives a Settings hint explaining the server-side backfill (`GenerateMetadataJob`, then a worker for `UpdateSingleMetadata`; see `scripts/dev-nextcloud.sh backfill`).
- **Thumbnails are never cropped in advance.** `loadRemoteThumbnailCached` with no `crop` stores the uncropped bitmap under `ThumbnailCache`'s `"uncropped"` variant (the unlabelled entries are older square crops, kept for the video grid), and both modes use `scaledToFill` in the cell. Dioramas (`ThumbnailDioramaCache`, disk key `…:uncropped`) are generated from the uncropped image, so Vision sees the whole subject; "no foreground subject" is remembered per URL and logged quietly.
- **3D Depth thumbnails** (`ThumbnailStyle.depth`, visionOS): each cell is one RealityKit mesh (`DepthTileView`) displaced by a DAv2 depth map from RAVEMedia's `CoreMLDepthProvider.stillDepth`, run once per thumbnail and cached as an 8-bit PNG beside the diorama pair (`ThumbnailDioramaCache`). No model installed → the cell behaves as `.diorama`. `ThumbnailDepthEstimator` keeps fast scrolling cheap: requests wait 250 ms, the newest runs first, a cell that scrolls away is dropped before it reaches the model, one inference at a time at utility QoS, model released after 20 s idle. Device findings (2026-10-07) that fixed the shape:
  - **Not stacked SwiftUI planes.** Depth-masked image planes at stepped `offset(z:)` desynced under the gaze lift (`ScaleHoverEffect` scales the cell as one 2D layer; per-plane hover groups didn't help either), and soft masks showed each pixel's copy one plane back as a 1-px "doubled layer". One entity lifts as a unit.
  - **The RealityView takes input even with `allowsHitTesting(false)`**: pointer and hand scrolling stopped at every tile. A `Color.white.opacity(0.001)` layer offset in front of the tile (`span + 2`) gets them first.
  - **The Diorama is a tile too** (`DioramaTileView`): its backdrop and subject are two flat panels in one RealityView (subject 24 pt forward, `ModelSortGroupComponent` keeps it drawn over the backdrop), because two SwiftUI layers at different `offset(z:)`s desynced under the lift in the square grid exactly as the depth planes did. The subject's alpha fades out over the outer 14 pt of the cell (`renderTexture(edgeFade:)`), or its edge showed as a seam against the backdrop from the side.
  - **Clamp the tile textures** (`DepthTileView.clampedTexture`): RealityKit's default sampler repeats, and the top row's filtering pulled in the bottom row as a 1-px line.
  - **Nothing coplanar with the tile's flat parts.** The cell's grey fill z-fought with depth-0 regions as TV static; the fill is skipped behind a tile and the mesh floats 1 pt off the plane. Depth also fades to 0 over the outer 14 pt so the outline can't project past itself off-axis, and the rounded corners are baked into the texture's alpha (SwiftUI clipping doesn't reach RealityKit).
- **Flicks.** A cold cell waits 120 ms before fetching (`coldLoadDelay`), warm caches paint immediately (`cachedRemoteThumbnail`). `ImageLoader.loadRawData` counts waiters per shared fetch and cancels the download when the last one leaves; thumbnail fetches (`throttled: true`) pass through `FetchGate` (6 at once, newest first). Without the waiter count, cancelling a cell's task did not cancel the shared download.

## Thumbnail context menus
Every thumbnail grid opens a `.contextMenu` on long-press (right-click on macOS, hold Select on tvOS): Pictures/Videos (all platforms), Albums containers (Show, Play Slideshow via `AppModel.startContainerSlideshow`), the Local folder browser, and every Library lockup. **Quick Look is a menu item now, not the long-press itself**: the thumbnails take `onQuickLook` + `contextMenuItems` (handed a Quick Look action bound to the cell's loaded bitmap, which seeds the pop).
- **`Views/MediaQuickActions.swift`** — the shared tail for a picture/video (Info sheet and Rating for Stash, Share for on-device files, Select, Delete). A grid owns one `MediaQuickActions` and applies `.mediaQuickActions(_:)` once; menus only record intent, since a menu can't host a sheet or dialog. `MediaDeletion` decides what Delete means: Stash → the "Remove from Stash" / "Delete File from Disk" dialog; Photos → straight to PhotoKit's own confirmation (no second prompt; unavailable on tvOS); Local → "Delete File". Nextcloud and share-sheet media get no Delete.
- **`Views/Library/LibraryItemContextMenu.swift`** — Play/Resume/Start Over, Go to Details / Go to <show> (through the `libraryOpenDetail` environment closure the Library roots set to push onto their path), Mark Watched/Unwatched, Favorite. Toggles bump `LibraryWatchState`, so shelves and detail pages reload; Browse passes `onUpdated` to swap the fresh item in.
- **visionOS: long-press is Quick Look, and the actions live in it.** visionOS never presents a `.contextMenu` on a view that carries a `CustomHoverEffect`. The grid's `ScaleHoverEffect` blocked it on the cell, inside a Button and on the Button (device, 2026-10-08), and the system `.lift` reads as a flat highlight or white spot on a 3D tile. The menu's own preview of a RealityKit tile is an empty grey card. So `thumbnailMenu` (`Views/ScaleHoverEffect.swift`) on visionOS is a held `onLongPressGesture` (dip, then grow): it opens Quick Look when the grid has one, otherwise a popover of the same items (the Local folder browser). The grids hand Quick Look the same items (`contextMenu(for:quickLook: nil)`) for its side menu (`QuickLookActionRows`). Each row closes Quick Look, then acts. A tap on the preview opens the item, and a tap outside closes it: the dimmed backdrop sits at z 50, in front of the tiles' input targets (≤ 34 pt). Over 3D tiles the pop starts and ends at z 40 (`restingZ`), from the cell's real size. It fades in and out there, while the cell's tile stays visible under it: hiding the tile made it reappear with its own animation, and flattening it rebuilt the cell (a spinner, a second hover). iOS and macOS keep the system context menu, with Quick Look as an item.
- **XCUITest can't open these on visionOS**: `press(forDuration:)` in the visionOS simulator never presents a context menu (tried 1.2 s and 3 s). Verify on the iOS simulator with the Xcode device-interaction tool (`t x y 1.5`), which does.

## tvOS: nothing deletes
A TV has no lock screen, so tvOS offers no way to delete or edit the library's data: `MediaDeletion.isAvailable` is false there (no Delete in menus, no Delete section in `MediaDetailSheet`), and `MediaDetailSheet` shows its Info tab only. Ratings stay in the thumbnail menu. Local caches (Settings → Cache) can still be cleared.
