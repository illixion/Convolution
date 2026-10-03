# Plan — Restore custom window size after visionOS cold relaunch

> **Status: implemented** (`3062971`, 2026-06-03). The mechanism described here now lives in the shared
> `WindowSizePersistence` (`PhotoWindowView`, `VideoWindowView`, `RemoteViewerWindowView` and `WebPageWindowView` all drive it),
> and is summarised in `CLAUDE.md`. This file is kept as the design rationale; the class and file names below are
> from before that extraction, so read the code for current behaviour.

## Problem

When visionOS restores wall-snapped pop-out windows after a reboot or app
reinstall:

- **Remote slideshow** windows come back at `.defaultSize(1400×900)` — the user's
  custom size and aspect ratio are lost.
- **Photo viewer** windows come back at `.defaultSize(1200×900)` — the per-image
  size persisted via `ImageEnhancementTracker` does not survive in time on
  restored launches.

This works correctly when the user opens windows via `openWindow` in the running
app; it only breaks on system-driven scene restoration.

## Root cause

visionOS persistent-window restoration restores **identity** (the Codable
`WindowGroup` value) and **wall-snap pose**, but **not custom size** — on
restore the OS applies the scene's `.defaultSize(...)` and hands the app the
decoded window value. The app is then responsible for resizing.

- `RemoteViewerWindowView` has no size persistence at all (`windowSize` is local
  `@State`, only used to send the `ratio:` filter to the server).
- `PhotoWindowModel.savedWindowSize` is keyed by image URL via
  `ImageEnhancementTracker` and loaded **asynchronously** in `start()`. The
  500 ms verifier in `PhotoDisplayView.verifyWindowSizeMatchesContent()` races
  this load and the `isLoadingDetailImage` check, so on restored launches it
  often falls back to `appModel.mainWindowSize` instead of the user's size.
- The size used at shutdown is per-*window instance*; URL-keyed storage
  conflates two windows showing the same image.

## Apple's intended mechanism

The `WindowGroup(..., for: Value.self) { $value in ... }` binding is the
documented restoration surface — anything written back into `$value` is
serialized by visionOS for next-launch decoding. The pattern (see
"Adopting best practices for persistent UI" / WWDC25 290 "Set the scene with
SwiftUI in visionOS") is:

1. Encode user-visible scene state (here: size) into the bound Codable value.
2. Mutate the binding when the state changes.
3. On `onAppear` of a restored window, apply the decoded state once before any
   programmatic resize logic runs.

`@SceneStorage` is the alternative, but each `WindowGroup` instance has its own
storage namespace anyway and our values already carry a per-window UUID — the
bound value is the more natural fit.

## Design

### 1. Encode size in the Codable window values

`PhotoWindowValue` and `RemoteViewerWindowValue` gain an optional
`restoredSize: CGSize?` (Codable). It is `nil` on fresh opens — the app
continues to size from image aspect ratio / scene default. It is non-nil only
after the user has interacted with the window and a debounced write has
captured the resolved size.

`CGSize` is not directly Codable, so encode as `Size` (a small Codable struct
wrapping `width`/`height`) or via a dedicated `CodableSize` extension.

### 2. Write back on geometry settle

Use `UIWindowScene.effectiveGeometry` (KVO) or `windowScene(_:didUpdateEffectiveGeometry:)`
as the "geometry settled" signal — these fire only after the OS has resolved a
request or user-drag, which avoids feedback loops with our own
`requestGeometryUpdate` calls. Debounce ~500 ms and write the latest size to
`$windowValue.restoredSize`.

Implementation notes:

- The bound `$windowValue` is available in `HypnosApp.swift:29-38` (photo)
  and `:97-106` (remote). Thread the `Binding<PhotoWindowValue>` /
  `Binding<RemoteViewerWindowValue>` into `PhotoWindowView` /
  `RemoteViewerWindowView` so the views can mutate `restoredSize`.
- Add a small `WindowSizeWriteback` helper (or inline in the view) that owns the
  debounce task and writes via the binding.

### 3. Apply restored size on appear

On `onAppear`, when `RestoredWindowTracker.isRestored(id)` is true **and**
`windowValue.restoredSize != nil`:

- Call `windowScene.requestGeometryUpdate(.Vision(size: restoredSize))` once,
  immediately.
- Set a `suppressInitialAspectResize` flag for ~1 s so the aspect-ratio /
  saved-size resize paths in `PhotoDisplayView.onAppear` do not stomp the
  restored size.
- After the OS confirms the size via `effectiveGeometry`, normal write-back
  resumes.

### 4. Photo viewer — coexist with `ImageEnhancementTracker`

`ImageEnhancementTracker.windowSize(url:)` keeps its current job (size-by-image
for fresh window opens — "this image had this size last time you viewed it").
It is no longer the source of truth for restored windows:

- On restored launches, `windowValue.restoredSize` wins.
- The 500 ms `verifyWindowSizeMatchesContent` safety net can stay but should
  skip when `windowValue.restoredSize` was applied (avoid double-resize).

### 5. Remote viewer — net-new

`RemoteViewerWindowView` currently has no resize logic. Add:

- A `resolvedWindowScene` lookup (mirror the photo viewer pattern).
- A single `requestGeometryUpdate` call on `onAppear` when restoring.
- A debounced write-back from `onChange(of: geo.size)` (already present at
  `RemoteViewerWindowView.swift:131`) into `$windowValue.restoredSize`.

No aspect-ratio-driven resize is needed for the remote viewer — the user picks
the size and the slideshow fits to it.

## File changes

### Model
- `Model/PhotoWindowValue.swift` — add `var restoredSize: CodableSize?`
- `Model/RemoteViewerWindowValue.swift` — add `var restoredSize: CodableSize?`
- New `Model/CodableSize.swift` (or extension) — `struct CodableSize: Codable, Hashable { var width, height: CGFloat }` with `CGSize` interop. Reusable.

### App / Scene wiring
- `HypnosApp.swift:29-38` — pass `$windowValue` binding into
  `PhotoWindowView` so it can write `restoredSize` back.
- `HypnosApp.swift:97-106` — same for `RemoteViewerWindowView`.

### Photo viewer
- `Views/Pictures/PhotoWindowView.swift` — accept `Binding<PhotoWindowValue>`,
  forward to display view.
- `Views/Pictures/PhotoDisplayView.swift`:
  - Add `@Binding var windowValue: PhotoWindowValue` (or a closure
    `onSizeSettled: (CGSize) -> Void`).
  - In `onAppear`, if `RestoredWindowTracker.isRestored(id)` AND
    `windowValue.restoredSize != nil`, request that geometry and set
    `suppressWindowResize = true` for ~1 s.
  - In `verifyWindowSizeMatchesContent()`, prefer `windowValue.restoredSize`
    over `windowModel.savedWindowSize` when the window is restored.
  - Add a debounced size write-back driven by the existing
    `viewerWindowSize` changes (KVO on `effectiveGeometry` or
    `onChange(of: viewerWindowSize)` — whichever is already wired).

### Remote viewer
- `Views/Remote/RemoteViewerWindowView.swift`:
  - Accept `@Binding var windowValue: RemoteViewerWindowValue`.
  - Add a `resolvedWindowScene` lookup.
  - In `onAppear`, when `RestoredWindowTracker.isRestored(windowValue.id)` AND
    `windowValue.restoredSize != nil`, call
    `windowScene.requestGeometryUpdate(.Vision(size: restoredSize))`.
  - Replace `onChange(of: geo.size)` so it both informs the model (for the
    server `ratio:` filter) **and** debounces a write to
    `$windowValue.restoredSize`.

## Edge cases / gotchas

- **First write must not run on restored apply.** Guard the write-back so it
  ignores the synthesized `effectiveGeometry` change caused by our own
  `requestGeometryUpdate(restoredSize)` on launch. Easiest: skip the first
  geometry change for ~500 ms after applying restored size.
- **Migration.** Adding a non-optional field would break decoding of windows
  persisted by the prior build; `restoredSize: CodableSize?` is optional so
  existing scene archives decode cleanly with `nil`.
- **Resizability.** Photo/video/remote `WindowGroup`s currently inherit
  `.automatic` resizability, which the docs say maps to `.contentMinSize` for
  `WindowGroup` — no change needed.
- **Animated images / GIFs.** `resizeGIFWindowToFit` sets
  `.resizingRestrictions: .uniform`. When restoring a GIF window, replay that
  too (use the GIF path's request variant).
- **Multiple windows on the same image.** Storage is now per-window-instance
  via the Codable value, so two windows can hold independent sizes. The
  URL-keyed `ImageEnhancementTracker` size remains a per-image *default* for
  fresh opens only.

## Validation

1. Open a photo viewer, resize to a non-default shape, snap to a wall.
2. Open a remote slideshow window, resize, snap to a wall.
3. Force-quit the app (or reboot). Relaunch.
4. Expected: both windows reappear at the snapped location AND at the size they
   had at shutdown. No flash to default size.
5. Repeat with a GIF window (uniform resizing) and with a fresh
   (never-resized) window — fresh windows should still use `.defaultSize`.

## Out of scope (for now)

- Video windows (`VideoWindowValue`) — same fix applies but defer until the
  pattern is proven on photo + remote.
- Shared photo / shared video — these are transient share-sheet windows; not
  worth restoring.
