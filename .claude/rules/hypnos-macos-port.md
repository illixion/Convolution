---
paths:
  - "**/Views/Mac/**"
  - "**/Mac*.swift"
  - "**/HypnosCommands.swift"
  - "**/PlatformImage.swift"
  - "**/PlatformPasteboard.swift"
---

# Hypnos: macOS port

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

## Shape: real multiple windows, a sidebar, a menu bar

macOS gets **real multiple windows**, like visionOS — not the iOS/tvOS
single-scene router. `HypnosApp.macOSScenes` mirrors visionOS's scene *set*
(main window, `photo-detail`, `video-detail`, Film Player, Console, GPU
Memory) but deliberately not its scene *content*: visionOS's `photo-detail`/
`video-detail` windows host `PhotoDisplayView`/`VideoWindowView`, which pull
in the full RealityKit/fake-3D/adjustments machinery and several UIKit-
specific representables (see "UIKit gaps" below) that this pass didn't port.
So macOS gets its own lightweight window content instead — the same choice
tvOS made for its viewers, and for the same reason (a squeezed port of
gaze/touch-shaped chrome is worse than a small platform-native one):

- **`Views/Mac/MacRootView.swift`** — the main window's root. A
  `NavigationSplitView` sidebar (`MacTab`: Pictures, Videos, Albums, Films,
  Settings — same five sections as `TVTab`, same reasoning: no Windows tab,
  nothing to summon from a single main window yet; no Filters tab, nothing to
  filter by) in place of visionOS/iOS's `TabBarOrnament`/`TabView`.
- **`MacPicturesView.swift`** / **`MacVideosView.swift`** — grids over
  `appModel.galleryImages`/`galleryVideos`, the same source/filter/pagination
  every platform uses. Clicking a cell opens a **real, separate window**
  (`openWindow(id: "photo-detail"/"video-detail", value:)`) — the ordinary
  Mac convention, not a push-in-place or a cover.
- **`MacPhotoViewerWindow.swift`** — the `photo-detail` window: a plain
  `Image(nsImage:)` fed by `ImageLoader` (so the same `MediaAuthorization` as
  every other platform). No adjustments, no 3D.
- **`MacVideoPlayerWindow.swift`** — the `video-detail` window: a direct
  `NSViewRepresentable` over AppKit's `AVPlayerView` (see "UIKit gaps"
  below for why not SwiftUI's `VideoPlayer`), following the same
  auth-then-decode-probe-then-transcode-fallback sequence as
  `TVVideoPlayerView` (see the tvOS rule's "Auth" section) — VP9 is
  registered as a supplemental decoder at launch on macOS too
  (`HypnosApp.init`), so VP9-in-MP4 may decode natively; VP9-in-WebM still
  needs the transcode, since WebKit isn't wired up on macOS this pass.
  Verified against the dev Stash instance: the H.264 clip plays natively
  through a real `AVPlayerView` (timecode advancing, genuine
  `AVAudioSession`/`FigPlayer` activity in the log) — the VP9 fallback path
  itself wasn't independently re-verified on macOS, since
  `NativeVideoDecodeProbe`/`MediaAuthorization` are the exact same shared
  code already proven on tvOS.
- **`MacAlbumsView.swift`** — same `MediaContainer` grid as tvOS's, minus
  Local's nested folder browser (known gap, same as tvOS).
- **`MacFilmsView.swift`** — Jellyfin search over the same `FilmSession`;
  opens the film in its own "Film Player" window rather than a cover/sheet
  (macOS has no `fullScreenCover`).
- **`MacSettingsView.swift`** — library source, Stash server + test
  connection, `NextcloudSettingsSection` and `CacheSettingsSection` reused
  verbatim (same as tvOS — neither needed any change for a third platform).
- **`HypnosCommands.swift`** — the menu bar (`.commands` on the main
  `WindowGroup`): File → New Window, a Library menu with one item per
  `MacTab` plus Play/Pause (space bar). Tab selection and play/pause both go
  through `NotificationCenter` (`.hypnosSelectTab`/`.hypnosTogglePlayPause`)
  rather than shared `@State`, because a `.commands` closure belongs to the
  app, not to one scene instance, and has no handle on a specific window's
  view state — the ordinary AppKit pattern for routing a menu action to
  whichever window is key. With more than one main or video window open, all
  of them react, which is an accepted simplification for this pass.

**Not reused: `RAVEWindowSessionRegistry`/`RAVEWindowManagerView`
("Windows tab" style management) and `AppDelegate`'s main-window-summon
logic** — `AppDelegate.swift` gets its own `#if os(macOS)` branch
(`NSApplicationDelegate`, just the local-media/shared-cache launch
housekeeping) rather than calling `RAVEWindowSessionRegistry.shared.
ensureMainWindowVisible()` the iOS/visionOS branch does. Known gap, not a
compatibility problem: RAVEUI already builds for macOS (Longwave's Mac app
links it), but wiring Hypnos's macOS windows through the shared registry
wasn't attempted this pass — ordinary AppKit window restoration (Cmd+N, the
Dock icon) covers "how do I get a window back" well enough for a first port.

## UIKit gaps: the seam files

Shared code uses `UIImage`, `UIPasteboard`, `UIActivityViewController`,
`UIDevice`, `UIViewRepresentable`/`UIViewControllerRepresentable`
(`MetalImageView` over `MTKView`, the native video views,
`AVPlayerViewController`), none of which exist without UIKit. One seam file
per concern, in `Support/`, plus a handful of `#if os(macOS)` branches at the
handful of call sites each gap actually reaches:

- **`Support/PlatformImage.swift`** — `PlatformImage` is the typealias new
  macOS-aware code should use (`UIImage` on UIKit platforms, `NSImage` on
  macOS). But the file *also* aliases `UIImage = NSImage` on macOS, so the
  **226 existing `UIImage` call sites across ~30 files keep compiling
  unchanged** — renaming every one of them to `PlatformImage` would have been
  exactly the "scattered edits" these seams exist to avoid. An `NSImage`
  extension adds the handful of UIKit-isms those call sites actually use
  that `NSImage` lacks natively: `.cgImage`, `.scale`, `.imageOrientation`
  (mirroring `UIImage.Orientation`'s cases/raw values exactly, since shared
  code switches over them), `pngData()`, `jpegData(compressionQuality:)`,
  `init(cgImage:)`/`init(cgImage:scale:orientation:)`, and a no-op
  `byPreparingForDisplay()` (a Core Animation pre-decode hint with no AppKit
  equivalent). `.scale`/`.imageOrientation` are stored via associated
  objects (`nonisolated(unsafe)` keys — they're pointer-identity keys for
  `objc_get/setAssociatedObject`, never actually mutated as data, so Swift 6's
  shared-mutable-state check is a false positive here). Also adds
  `Image(platformImage:)`, since SwiftUI's `Image(uiImage:)`/`Image(nsImage:)`
  are two different initializers with two different argument labels despite
  the type being the same via the alias — the ~15 call sites that build an
  `Image` from a loaded `PlatformImage` go through this one spelling instead
  of branching at each site. **Known gap:** `NSImage`'s bottom-left-origin,
  resolution-independent coordinate system means pixel-exact parity with
  iOS/visionOS (especially anything orientation-sensitive) is unverified —
  this seam buys compilation and the common decode/encode paths, not a
  guarantee every transform produces identical output.
- **`Support/PlatformPasteboard.swift`** — macOS-only `UIPasteboard.general`
  stand-in (backed by `NSPasteboard`) with the same settable-`.string` shape,
  so the two existing `#if !os(tvOS)` "Copy" call sites
  (`MediaDetailSheet`, `DepthPipelineSpikeSection`) needed no change.
- **`PlatformWindowScene`** (in `Support/PlatformShims.swift`) — stand-in for
  `UIWindowScene`, which macOS has no equivalent object for at all (a
  `Window`/`WindowGroup` scene maps straight to a real `NSWindow`, no
  delegate in between). Never actually instantiated on macOS; exists purely
  so `SceneDelegate`, `WindowGeometry`/`WindowResizeCoalescer`/
  `WindowSizeNudge` and the several `resolvedWindowScene` properties
  (`GalleryGridView`, `PhotoDisplayView`, `VideoWindowView`,
  `LocalFolderBrowserView`, `RemoteViewerWindowView`) have a type to compile
  against. This costs nothing functionally: `WindowGeometry.request` was
  *already* a no-op on iOS and tvOS (only visionOS's branch does anything
  with the scene it's handed), so macOS joining that no-op list is exactly
  consistent, not a new limitation. `effectiveGeometrySize` replaces every
  direct `.effectiveGeometry.coordinateSpace.bounds.size` call so the same
  spelling reads on every platform.
- **`Support/WindowActions.swift`** — macOS now shares visionOS's branch (the
  real `OpenWindowAction`/`DismissWindowAction`), not iOS/tvOS's
  `IOSWindowRouter` branch, since it has real windows too. `pushWindow` has
  no macOS equivalent at all (visionOS-only API: "replace this window's
  content in place"), so a push on macOS just opens a new window — the
  ordinary Mac convention is separate windows, not one that swaps content.
- **`Delegates/SceneDelegate.swift` / `AppDelegate.swift`** — each gets a
  `#if os(macOS)` branch. `SceneDelegate`'s cross-platform static pieces (the
  cold-launch shared-URL backlog `IncomingURLHandler` reads on every
  platform) moved into a plain `extension SceneDelegate` so both branches
  share them without duplicating; the macOS branch itself just carries a
  `weak var windowScene: PlatformWindowScene?` and none of the real
  `UIWindowSceneDelegate` lifecycle methods, which don't apply. See "Not
  reused" above for why `AppDelegate`'s macOS branch skips
  `RAVEWindowSessionRegistry`.
- **`MetalImageView.swift` / `NativeMetalVideoPlayerView.swift`** —
  **stubbed on macOS**, not ported. Both are already real
  `UIViewRepresentable`s (nothing visionOS-only in either — they already
  compile and run on iOS unchanged), and both have essentially zero other
  UIKit surface: the fix would have been small and mechanical (a second
  wrapper struct with `makeNSView`/`updateNSView` instead of `makeUIView`/
  `updateUIView`, sharing the exact same `Coordinator` — MTKView/AVPlayer/
  Metal setup code is already fully cross-platform). Not done this pass
  because nothing in `Views/Mac/` mounts either view (the Mac photo/video
  windows use plain `Image(nsImage:)` and `AVPlayerView` instead — see
  above) — a real, bounded upgrade for later, not a platform limitation.
- **WKWebView-based views — also stubbed, for the same "nothing calls it"
  reason, but with a real platform-API wrinkle**: `AnimatedImageWebView`,
  `AnimatedJXLWebView`, `WebVideoPlayerView`, `PinnedWebPageView` (+
  `WebPageWindowModel`/`WebPageWindowView`/`WebPageOrnamentView`, whose sole
  caller is one of the above). Their transparent-background/no-scroll setup
  (`webView.isOpaque`, `.backgroundColor`, `.scrollView.*`) is UIKit-`WKWebView`
  API with **no macOS equivalent property** (macOS's `WKWebView` has no
  `.scrollView` at all, and no public `drawsBackground`-style toggle either —
  the well-known workaround is an undocumented `setValue(_:forKey:
  "drawsBackground")` KVC call). WebKit itself is fully available on macOS
  (Raven already proves `WKWebView` works fine there) and none of these gates
  block that — they're stubs (fail-closed: `onError`/`onSourceUnplayable`
  fire immediately so a caller's fallback chain still does something
  sensible) pending a real `NSViewRepresentable` with the KVC workaround.
  Known gap, tracked here rather than silently degraded.
- **Small, scattered `#if !os(macOS)` fences** at the handful of call sites
  each of these needs, mirroring the existing tvOS pattern exactly:
  `.hoverEffect`/`.hoverEffectDisabled()` (no pointer-hover concept on
  macOS's real cursor the way iPad's trackpad pointer needs help — `.hoverEffect`
  is unavailable there outright), `.keyboardType`/`.textInputAutocapitalization`
  (soft-keyboard-only, meaningless with a physical keyboard),
  `.navigationBarTitleDisplayMode`/`ToolbarItemPlacement.topBarLeading`/
  `.topBarTrailing`/`.toolbarVisibility(for: .tabBar)` (iOS/tvOS-only
  placements), `AVAudioSession` (no per-app audio-session category system on
  macOS — `AudioSessionConfig.configureMixedPlayback()` no-ops there),
  `os_proc_available_memory()` (iOS/tvOS/visionOS jetsam telemetry, no macOS
  equivalent — `DeviceMetrics` reports 0 for `availableMB` there),
  `UIBackgroundTaskIdentifier`/`UIApplication.beginBackgroundTask`
  (`RemoteViewerModel`'s background-flush assertion — macOS apps aren't
  suspended when backgrounded the way iOS ones are, so there's nothing to
  hold open), `UIAccessibility.isReduceMotionEnabled`/
  `reduceMotionStatusDidChangeNotification` → `NSWorkspace.shared.
  accessibilityDisplayShouldReduceMotion`/`accessibilityDisplayOptionsDidChangeNotification`,
  `UIApplication.openSettingsURLString` → `x-apple.systempreferences:` (only
  reachable from `MediaLibraryStateView`'s visionOS/iOS Photos-denied screen,
  which the Mac UI doesn't use — a generic System Settings open rather than a
  crash). `IOSRootView.swift`/`IOSTabToolbar.swift`/`ContentView.swift`'s
  iOS `TabView` branch and `ShareSheetHelper.swift`'s `ActivityViewController`
  are excluded from macOS entirely (`#if !os(visionOS) && !os(macOS)` /
  `#if !os(tvOS) && !os(macOS)`) — dead code kept compiling only to satisfy
  the whole-module build, exactly like they already are on tvOS. **Share is a
  known gap on macOS**: `NSSharingServicePicker` would be the real
  replacement; not implemented this pass since nothing in the Mac UI offers a
  Share button yet.

## Films

`FilmPlayerView` gained a third content branch (`#elseif os(iOS)` for the
existing AirPods-head-tracking Form, `#else` for macOS) rather than falling
into the old iOS-shaped `#else` unconditionally: `HeadphoneHeadTracker` is
iOS-only (AirPods motion), so macOS plays the film's picture **and its Atmos
object audio**, just without head tracking — `RAVEFilm`'s `FilmStageView`
already documents itself as supporting exactly this ("iOS and macOS: a
virtual camera") and its `listenerOrientation` parameter defaults to
identity, which *is* "no tracking": the sound stage stays fixed relative to
the picture. No RAVESDK changes were needed. Films weren't tested end-to-end
this pass (no dev Jellyfin instance, same constraint as every other
platform) — verified compile and the Settings/Films UI only.

## A real SwiftUI bug: `VideoPlayer` crashes, `AVPlayerView` doesn't

`MacVideoPlayerWindow` wraps AppKit's `AVPlayerView` directly via a small
`NSViewRepresentable` rather than using SwiftUI's own `VideoPlayer(player:)`
(which wraps the same class internally). `VideoPlayer` crashed at launch on
this Xcode 27 / macOS 26 pairing every time, with `failed to demangle
superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC': unknown
error` — a Swift runtime metadata bug in SwiftUI's own wrapper type, not
anything in this app. Going one layer down to the AppKit class directly
(`makeNSView`/`updateNSView` on a plain `NSViewRepresentable`) avoids
whatever synthesized type trips it, and is arguably the more idiomatic Mac
choice anyway — it's the seam the task's own UIKit-gap notes named
(`AVPlayerView` on macOS). Revisit `VideoPlayer` on a later Xcode/macOS if
this app ever wants its convenience over the representable.

## Reusable pattern, for the next app to go cross-platform

The shape that generalizes: **one seam file per concern in `Support/`**
(`PlatformImage`, `PlatformPasteboard`, `PlatformWindowScene`), each
providing either a typealias bridging the two platforms' types plus an
extension filling the gap (`PlatformImage`), or a macOS-only stand-in with
the same call shape as the UIKit type it replaces (`PlatformPasteboard`,
`PlatformWindowScene`). **`WindowActions.swift`'s three-way branch**
(visionOS real actions / macOS real actions / iOS-tvOS router) is the
template for "does this platform have real multi-window or not" — check
`PlatformCapabilities.supportsMultipleWindows`-style booleans before
reaching for a router. **Stub, don't port, a UIKit-`Representable` view
nothing on the new platform mounts yet** — `MetalImageView`,
`NativeMetalVideoPlayerView` and the WKWebView family show the pattern:
confirm the real fix is small (usually just the wrapper struct's protocol
conformance, never the shared `Coordinator`) before spending the time: if
nothing calls it, a stub buys compilation now and the real port stays a
scoped, well-understood follow-up. **Give the new platform its own root
under `Views/<Platform>/`** rather than reusing the touch/gaze-shaped one —
tvOS proved this first (`TVRootView`), macOS confirms it generalizes
(`MacRootView`): a NavigationSplitView sidebar is exactly as
platform-appropriate as a `TabView` was for tvOS, and porting the ornament
instead would have dragged in everything the seam list above had to stub.
