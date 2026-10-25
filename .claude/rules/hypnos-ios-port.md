---
paths:
  - "Hypnos/Hypnos/Views/IOS/**"
  - "Hypnos/Hypnos/Support/PlatformShims.swift"
  - "Hypnos/Hypnos/Support/WindowActions.swift"
  - "Hypnos/Hypnos/Support/IOSWindowRouter.swift"
---

# Hypnos: iOS / iPadOS port

Moved out of `CLAUDE.md` (the compile check and the "compile both platforms" rule stayed there).

## How the port is structured

- **`WindowActions.swift`** — `@OpenWindowProxy` / `@PushWindowProxy` /
  `@DismissWindowProxy` property wrappers replace SwiftUI's
  `@Environment(\.openWindow)` etc. **everywhere**. Call sites keep the
  `openWindow(id:value:)` shape. On visionOS they wrap the real actions; on
  iOS they talk to `IOSWindowRouter`. Never read the raw environment actions
  in shared code — it will not compile on iOS.
- **`IOSWindowRouter.swift`** + **`Views/IOS/IOSRootView.swift`** — iOS has
  one scene. The value-carrying scene ids (`photo-detail`, `video-detail`,
  `shared-photo`, `remote-viewer`) become a stack of
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
- **Tabs under More that bring their own `NavigationStack`** (Settings,
  Filters, Library, YouTube) showed two navigation bars once a page was
  pushed: More is a UINavigationController of its own, and SwiftUI offers no
  opt-out (Apple forums thread 764293). `Views/IOS/MoreTabNavigation.swift`:
  `ownsNavigationInMoreTab()` on the tab page (in `ContentView.iosTabPage`)
  hides More's bar while the tab is on screen, and `moreTabBackButton()` on
  the stack's root page adds the way back to the More list. A new
  stack-owning tab needs both. Verified on an iPhone 17 simulator
  (2026-10-20).
- **Incoming URLs** (`hypnos://`, shared files) are handled by `IOSRootView`'s
  `handleIncomingMediaURLs`, which must sit *inside* `.environment(router)`:
  outside it the handler's `@OpenWindowProxy` had no router and every link
  or shared file opened nothing (since the iOS port; found 2026-10-25 with the
  DEBUG `-UITestDefault debugOpenURL=<url>` launch default).
- The video window's subtitles rise 120 pt while the controls show
  (`VideoWindowView.subtitleLift`): the bar lies over the foot of a landscape
  picture and hid the last line (checked on an iPhone 17 simulator).
- `HypnosUITests` stays visionOS-only.
