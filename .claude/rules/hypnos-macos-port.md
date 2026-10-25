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
`"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"`): `app-sandbox`, `network.client`,
`network.server` (Device Setup's Show Setup Code), `files.user-selected.read-write`
(Backup's export/import). The app icon's `AppIcon.appiconset` has a `mac` idiom
from the same flattened source (square, no mask baked in).

## Shape: the visionOS UI in real Mac windows (since 2026-10-25)

The Mac used to have its own lightweight UI (`Views/Mac/`: a sidebar over plain
grids, an `Image` photo window, an `AVPlayerView` video window). That left it
without subtitles, playback speed, quality, the next episode, filters, Local
folders, slideshows, adjustments, Info and share, so it was replaced by the
shared views. `HypnosApp.macOSScenes` is visionOS's scene list minus the
immersive spaces and the window manager:

- **`main`** — `ContentView`. Its non-visionOS `TabView(.sidebarAdaptable)` is a
  sidebar on a Mac; `IOSTabToolbar` puts the library switch, the slideshow
  button and Select in the window toolbar (`.navigation`/`.primaryAction`
  placements). The first-run flow shows here too (an opaque panel: the Mac's
  material and glass let the gallery read through the copy).
- **`photo-detail`, `video-detail`, `shared-photo`, `remote-viewer`** — the same
  values and views as visionOS (`PhotoWindowValue` → `PhotoWindowView`, and so
  on), each with `.viewerWindowChrome()` (dark, picture under a hidden title bar)
  and titled ("Video", "Picture") for scenes the system names. A restored window
  whose value no longer decodes (the old Mac UI saved `GalleryVideo` values)
  closes itself (`UnrestorableWindow`).
- **Film Player, Adjustments, Console, GPU Memory** windows, and
  `DebugApprovalWindow` (the gallery opens it through `debugApprovalPrompts`).

`PlatformCapabilities` on macOS: `supportsMultipleWindows` is true (pop-out and
"Open in New Window" items), `supportsWindowManagement` false (no Windows tab,
no saved window groups, no "Always Open In New Window": nothing can push a
viewer in place of a Mac window, so `AppModel` pins `openMediaInNewWindows` on
and every viewer opens standalone). `supportsWindowResizing`,
`supportsStereoVideo`, `supportsSpatial3D`, `supportsImmersiveSpaces` stay
false: the 3D modes, AI 3D and the cinema are visionOS-only.

**URLs and files.** Only the gallery's scene handles external events
(`handlesExternalEvents(matching: ["*"])` on `main`, `[]` on the rest); left to
itself SwiftUI opens a new window of whichever group it picks for every URL.
`hypnos://` links and files opened with the app (Finder's Open With, `open -a`)
go through the same `IncomingURLHandler` as elsewhere.

**`Support/MacViewerWindow.swift`** gives each viewer window what a Mac expects:
the title of what it shows (`navigationTitle`; Stash leaves an untitled scene's
title empty, so `videoDisplayName` falls back to the file name, and an empty
title also drops the window from the Window menu), the shape of what it shows
(`MacWindowReference.fit`: keeps the width, fits the screen, sets
`contentAspectRatio` so resizing keeps it), and its keys as `onKeyPress` (space
plays/pauses, ←/→ step 10 s or change picture). They are the window's, not
menu shortcuts, which would also take what is typed into a text field. The
menu bar (`HypnosCommands`) has New Window, a Library menu (tab selection via
`.hypnosSelectTab`, which every gallery follows) and a Playback menu acting on
the key video window through `FocusedValues.videoWindowModel`.

The video window's controls lie over the picture as on iOS
(`ornamentBottomPadding` 0, `overlayBottomInset` clears them), and the
subtitles rise 96 pt while they show (`VideoWindowView.subtitleLift`; iOS
120 pt). The
picture readout's frame rate comes from `currentVideoFrameRate` for HLS,
which reads low (≈5 fps) while macOS has the window occluded (seen with the
Mac shown on a Vision Pro's virtual display); it isn't the decode rate.

## UIKit gaps: the seam files

- **`Support/PlatformImage.swift`** — `PlatformImage`, plus `UIImage = NSImage`
  on macOS so the existing call sites compile, and an `NSImage` extension for the
  UIKit-isms they use (`cgImage`, `scale`, `imageOrientation`, `pngData()`,
  `jpegData`, `byPreparingForDisplay()` as a no-op) and `Image(platformImage:)`.
  Pixel-exact parity of orientation-sensitive transforms is unverified.
- **`Support/PlatformPasteboard.swift`** — `UIPasteboard.general` over
  `NSPasteboard`.
- **`PlatformWindowScene`** (`Support/PlatformShims.swift`) — a never-made
  stand-in for `UIWindowScene`; `WindowGeometry.request` is a no-op on macOS as on
  iOS and tvOS (`MacWindowReference` does the Mac's window shaping instead).
- **`Support/WindowActions.swift`** — real `openWindow`/`dismissWindow`; a
  `pushWindow` opens a window.
- **The `UIViewRepresentable`s are `NSViewRepresentable`s on macOS**, over the
  same coordinator: `NativeMetalVideoPlayerView` (an `NSView` host; the system
  video layer is a layer-hosting `AVPlayerLayer` with `preferredDynamicRange =
  .high`, and the Metal layer asks for `.high` while HDR, or macOS 26 tone-maps
  both to SDR), `MetalImageView` (`viewDidMoveToWindow`/`layout` re-arm the
  draw), `WebVideoPlayerView`, `AnimatedImageWebView`, `AnimatedJXLWebView`.
  Each struct is `@MainActor` and conforms in a per-platform extension that calls
  shared `make…`/`update…` methods. `WKWebView.makeTransparentAndFixed()`
  (`Support/WebViewTransparency.swift`) is the one difference among the web
  views: macOS's WKWebView has no `isOpaque`/`scrollView`, only
  `drawsBackground` by key.
- **WebM thumbnails** (`WebMThumbnailGenerator`) render in one of the app's
  windows as on iOS. macOS's WebKit gives each file URL an origin of its own,
  so the video tainted the canvas ("The operation is insecure"); the capture
  page sets `allowFileAccessFromFileURLs`.
- **Share** — `View.shareSheet(url:onDismiss:)` (`Services/ShareSheetHelper.swift`):
  the activity sheet on iOS/visionOS, `NSSharingServicePicker` shown from the
  button on macOS.
- Scattered `#if !os(macOS)` fences remain where macOS has no API:
  `.hoverEffect`, soft-keyboard modifiers, `topBar*` placements,
  `AVAudioSession`, `allowsInlineMediaPlayback`.

## Films

`FilmPlayerView`'s macOS branch plays the picture and the object audio without
head tracking (`FilmStageView`'s identity orientation). Sound and Picture is a
sheet, as on iOS.

## `VideoPlayer` crashed, `AVPlayerView` didn't

SwiftUI's `VideoPlayer(player:)` crashed at launch on Xcode 27 / macOS 26
("failed to demangle superclass of VideoPlayerView from mangled name
'So12AVPlayerViewC'"). Nothing uses either now; if a Mac view ever wants
AVKit's chrome again, wrap `AVPlayerView` in an `NSViewRepresentable`.

## Running and checking the Mac build without clicking

A Mac app needs no device: build it ad hoc signed into its own DerivedData
(`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
PROVISIONING_PROFILE_SPECIFIER=`, plus `YOUTUBE_CONDITION=HYPNOS_YOUTUBE` if
wanted; the bundle id is `com.illixion.hypnos.debug`) and run the binary with
`DEBUGTRACE_SERVER=1` for the debug server on localhost:8642 (`_screen`,
`_logs`, `videoAudio`; `_screenshot` misses Metal and video layers, so use
`screencapture -x -o -l <window id>`). Don't drive it with clicks while the
user is on the Mac (or its Virtual Display on a Vision Pro). The DEBUG
`-UITest -UITestDefault key=value` launch defaults do the driving instead:
`hasCompletedWelcome=1`, `stashServerURL=…`, `librarySource=stash|local`,
`mainInitialTab=Videos`, `autoHideDelay=0` (controls stay up),
`subtitles.language=en`, `debugOpenURL=hypnos://scene?id=6` (any URL, handled as
if the system opened it), `autoOpenVideoIndex=n` / `autoOpenImageIndex=n`,
`autoStartSlideshow=1`, `libraryAutoOpenItemId=<id>` + `libraryAutoPlay=1` (with
`HYPNOS_DEV_JELLYFIN_SIGNIN_USER`/`_PASS` in the environment and
`filmPlayer.jellyfinServer=http://127.0.0.1:8097`). `open -g -a <app> <url or
file>` delivers a real URL or file without activating the app. Other agents'
Mac builds run as "Convolution" too: match windows by your own pid.

Checked this way on 2026-10-25 against the dev Stash and dev Jellyfin: gallery
sidebar and toolbar, a Stash MKV remuxed with its embedded subtitles drawn, a
Library episode with Quality and the next episode following on its own, a
VP8 WebM through WebKit, a picture from the grid ("3 / 12", previous/next), a
picture slideshow, `hypnos://play` and Open With, window titles in the Window
menu, WebM thumbnails. Not yet tried: Share, the Info sheet's editing, the
Film Player window since this change, HDR on an EDR display.
