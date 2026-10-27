---
paths:
  - "Hypnos/Hypnos/Views/PhotoWindowView.swift"
  - "Hypnos/Hypnos/Views/SharedPhotoWindowView.swift"
  - "Hypnos/Hypnos/Views/Pictures/Photo*"
  - "Hypnos/Hypnos/Views/Pictures/MetalImageView.swift"
  - "Hypnos/Hypnos/Views/Pictures/Spatial3D*"
  - "Hypnos/Hypnos/Views/Pictures/QuickLook3DView.swift"
  - "Hypnos/Hypnos/Views/ZoomPan.swift"
  - "Hypnos/Hypnos/Model/PhotoWindow*"
  - "Hypnos/Hypnos/Services/WindowResizeCoalescer.swift"
  - "Hypnos/Hypnos/Services/WindowSizeNudge.swift"
  - "Hypnos/Hypnos/Services/MetalImageRenderer.swift"
  - "Hypnos/Hypnos/Services/BackgroundRemov*"
  - "Hypnos/Hypnos/Services/AutoEnhanceCache.swift"
  - "Hypnos/Hypnos/Services/ImageEnhancementTracker.swift"
  - "Hypnos/Hypnos/Services/Spatial3DImageHandoff.swift"
  - "Hypnos/Hypnos/Shaders.metal"
---

# Hypnos: photo viewer, image display, spatial 3D

Moved out of `CLAUDE.md`. Window sizing, the GPU 2D path, deep colour and `ImagePresentationComponent`.

## Photo Viewer Architecture
All three photo viewer windows share the same rendering components:
- **PhotoDisplayView** - Shared image display with four rendering paths (in priority order): animated GIF (HEVC video player), RealityKit 3D (`ImagePresentationComponent`), GPU-backed 2D (`MetalImageView` with `MTLTexture`), and fallback UIImage. Two overlays sit on the 2D path: Diorama and AI 3D (below). Manages window sizing, swipe navigation, and resize-triggered re-downsampling.
- **Window sizing goes through `WindowResizeCoalescer`** (`Services/`), and every new geometry request in the photo viewer must too. visionOS has no window-*position* API — `requestGeometryUpdate` carries only a size and the system decides where the resized window lands — so each granted resize is also an uncorrectable move. A pushed viewer shares the gallery's scene (`pushWindow` swaps content in place), so that move is the grid window walking around the room. Six triggers compute the same target size for one image open (branch `.onAppear`, `imageAspectRatio` change, load completion, end of swipe, `setUniformResizing`, the 0.5s verification pass); they are redundant as *requests*, not as triggers, so the coalescer sends the first and drops the restatements. Its evidence test is **not** "the window is the size I asked for": a requested size and the scene geometry that comes back differ by the chrome insets (the same mismatch `WindowSizeNudge` documents as a size ratchet), so it compares the scene geometry against itself — sampled before each request, and a restatement dropped only if the window has moved since. A window that has *not* moved means the request did nothing or was dropped, indistinguishable from here, so it goes through. Callers holding read-back evidence that a grant is wrong pass `force: true` and bypass the dedupe entirely: `verifyWindowSizeMatchesContent` (measured >5% mismatch) and the immersive verifier.
- **Immersive 3D always asks for the largest window the platform will give.** `requestVerifiedImmersiveResize` fits the image into a 3000x3000 box, which is always clamped (~2700x1360, height far tighter), so its request never equals its own grant — hence `force: true` and hence the verifier can't use "grant == request" as its settle test. It watches instead: a re-request needs *evidence* the grant is wrong — either the wrong shape (aspect mismatch: a competing request stomped ours) or the window still sitting at the scene-space size it had before the request across two samples (the request never landed). An aspect-correct grant still growing toward the ceiling is watched, not pushed; the old seeding made that case re-request on every single immersive entry. Entering and leaving immersive is inherently 2+ window moves, so on a pushed window it is the biggest single displacement source. Exiting invalidates the coalescer — its memory is of a request made against immersive bounds and says nothing about the windowed geometry being restored.
- **PhotoOrnamentView** - Unified ornament bar with `PhotoViewerContext` enum (`.pushedFromGallery`, `.standalone`, `.shared`) controlling which buttons appear. Layout: `[Gallery] | [< N/M >] | [Slideshow] | [3D v] | [Info] | [Share] | [Adjustments] | [extras] | [Resolution]`. The 3D button is a Menu: **RealityKit 3D**, **RealityKit 3D (Immersive)**, **Diorama**, **AI 3D** (always last), then 2D. Menus spell "RealityKit" out; "RK" is only the short form, used in the button's tooltip (`threeDMenuHelp`) and the slideshow's (`Slideshow3DMode.shortLabel`). The persisted raw values (`spatial3D`, `spatial3DImmersive`) predate the names and stay. The Adjustments button opens `VisualAdjustmentsPopover`, the single home for all image enhancements: brightness/contrast/saturation/sharpen/opacity, auto-enhance, background removal, **and flip**. There is no "More" (triple-dot) menu — context-specific items (Pop Out when pushed, Save when shared) render inline as icon-only buttons via the `extraMenuItems` closure (at most one per context, so a drop-down would be single-item). The Info button opens `MediaDetailSheet` as a sheet.
- **PhotoWindowModel** - Per-window state, split across extension files by concern (see App Structure in `CLAUDE.md`). Created with `@State` in each wrapper view. Primary display property is `displayTexture: MTLTexture?` with `displayImage: UIImage?` as fallback. Cached texture variants: `backgroundRemovedTexture`, `originalDisplayTexture`, `autoEnhancedDisplayTexture`, `preAutoEnhanceDisplayTexture`.

The two thin wrapper views:
- **PhotoWindowView** - Handles both pushed and standalone modes via `wasPushed` parameter. Pushed mode: opened via `pushWindow` from gallery, dismisses back to gallery, has pop-out menu item. Standalone mode: opened via `openWindow` as independent pop-out window, has gallery button.
- **SharedPhotoWindowView** - Opens for images received via share sheet. Has save menu item and cache cleanup.

**Important pattern:** `PhotoWindowModel.init` must be side-effect-free because SwiftUI may re-create the view struct multiple times while `@State` discards duplicate models. All side effects (window count tracking, image loading tasks) are deferred to the `start()` method called from `onAppear`.

## Image Display Strategy
- **Default (Dynamic Image Resolution on):** Images open in GPU-backed 2D mode using an `MTLTexture` with `.private` storage (not counted as dirty CPU memory by jetsam). The source is downsampled via `CGImageSource`, uploaded to GPU via `CIContext.render`, and displayed through `MetalImageView` (MTKView wrapper). Re-downsampled on window resize (1-second debounce, 20% threshold). RealityKit is only loaded when the user activates 3D mode.
- **Dynamic Image Resolution off:** Images load at full native resolution. No re-downsampling on resize.
- **Deep color preservation:** Images with >8 bits per component (e.g. 16-bit JXL) use `rgba16Float` textures with `extendedLinearDisplayP3` color space. Standard 8-bit images use `bgra8Unorm` with `deviceRGB`.
- **Auto-3D restore prompt:** If an image was previously viewed in 3D (tracked via `ImageEnhancementTracker`), a capsule prompt pill appears at the bottom of the viewer offering "Restore" or dismiss. Image always opens in 2D — restoration is opt-in. Controlled by `showAutoRestorePrompt` + `autoRestoreImmersive` on `PhotoWindowModel`. Dismisses automatically after 10s (`autoRestorePromptDismissTask`) and when the user navigates to a different image via `switchToImage`. Use `presentAutoRestorePrompt(immersive:)` / `dismissAutoRestorePrompt()` helpers rather than toggling the flag directly so the timer stays in sync.
- **Important:** When swapping `displayTexture` (e.g. toggling background removal or auto-enhance from in-memory cache), `imageAspectRatio` must always be updated from the new texture's dimensions. The Metal renderer stretches the texture to fill its view — aspect ratio is controlled externally by SwiftUI's `.aspectRatio()` modifier driven by `imageAspectRatio`.

## AI 3D
Full-size AI 3D uses RAVEMedia's `RAVEStereoPhotoView` and Vergence's
`StillStereoRenderer`: the video pipeline's per-eye warp, with nearest depth on
the window and background behind it. `RAVEDepthMesh` remains the raised thumbnail
presentation; the old `RAVEAIDepthPhotoView` is retained for other consumers.
- `PhotoWindowModel+AIDepth` decodes through `MetalImageRenderer.downsampledImage`,
  using the same `displayTargetDimension` as 2D, global max and per-photo override,
  then `StillStereoResolution`'s stereo working-set bound. The resolution readout
  reports the actual AI source. Resizes debounce, resolution/model changes reload,
  and memory-pressure downscale releases the presentation and restores it later.
- Photos infer their own full-precision depth via the pre-process model role
  (real-time fallback); they never borrow a thumbnail-cache map. Still refinement
  uses the shared edge-aware kernels without temporal state or luma snapping.
- RAVEMedia serializes bakes across windows, uses half-float extended-P3 colour
  through adjustment/warp, and presents a 10-bit stereo frame through
  `VideoPlayerComponent`: tagged SDR (P3, BT.709 transfer) for an SDR photo, since
  a PQ tag made it visibly brighter than the flat one (SDR white lands at 203
  nits, shown as HDR); HLG (BT.2020, mid-tone power 1.09) for an HDR photo.
  See "HDR photos" below. The usual flat image keeps sizing the window, remains
  until stereo is ready, and reappears for failures and transitions. Stereo
  stays on while ornaments and popovers are shown: the old relief-mesh fade
  workaround is unnecessary for depth that stays behind the window.
- `photoStereo` on the debug server reports dimensions/limits/readiness and can
  toggle AI 3D, a resolution override, or `separated` for the experimental
  antialiased disconnected renderer. The latter defaults off pending headset A/B.
- Pinch zoom remains off in AI 3D. The front input layer owns taps/swipes; normal
  photo sizing still goes through `WindowResizeCoalescer`.

Device checks confirmed natural recession and correct size. The shared video
window recess hid the photo behind its window; `RAVEVideoPlaneView.windowSurface`
now places it on the surface on every resize. Do not use the component's square
placeholder mesh as a readiness gate: it remained square while the photo was
visibly rendering. Further checks cover resize/ornament stability, colour,
transparency, transitions and thin structures. JXL decoder internals
can exceed the rendition budget; measure `_memory` on device. Do not infer a
Vision Pro memory ceiling or comfort result from Mac harness measurements.

## HDR photos
`HDRStills` decodes a photo with a gain map (iPhone and ISO 21496 HEICs) or a PQ/HLG
transfer as HDR, through ImageIO's `kCGImageSourceDecodeToHDR` (every decode in
`MetalImageRenderer` goes through `HDRStills.decodeOptions`). The picture is tone mapped
with Core Image's headroom filter to `targetHeadroom` (2.5, **measured on the AVP in a
photo window, 2026-10-27**: `photoHDRTest dots` keeps brightening to about 3-4x SDR white,
`patches` stops at about 2.5-3x, a brightness limiter; Oneiros's immersive test found 2x,
a different path) and uploaded as an `rgba16Float` texture, whose headroom is registered in
`MetalImageRenderer.headroom(of:)`. `MetalImageView` turns EDR on for such a texture
(`wantsExtendedDynamicRangeContent`, extended linear Display P3) and the shaders clamp at the
photo's own peak instead of 1.0. An SDR photo decodes as before.
- **AI 3D** gets the same tone-mapped picture as half-float (`aiDepthHeadroom`) and
  encodes it HLG (RAVESDK's `CLAUDE.md`, stereo stills, has why PQ failed).
  Slideshow AI 3D, auto-enhance, background removal and RealityKit 3D still decode SDR.
- **Many photos have no gain map**: the share sheet converts to JPEG unless Options is set
  to Current/Unmodified Original, and iPhones before the 12 never wrote one (an iPhone 11
  Pro Max HEIC is SDR). `photoStereoState` reports `flatHeadroom`/`aiHeadroom` per
  window: above 1 means the photo really decoded as HDR.
- **AI HDR** (Adjustments, sun icon; `GainMapHDR`, `PhotoWindowModel+AIHDR`): an SDR photo
  gets a gain map from GMNet (Liao et al., ICLR 2025, MIT; real-world checkpoint, peak 5x),
  converted by `scripts/convert-gainmap-model.py` and bundled as
  `Resources/GainMapGMNet.mlpackage` (fp16, ~4 MB, enumerated inputs about a megapixel plus
  a 256x256 thumbnail; GMNet's per-image depthwise conv is unrolled into shifted
  multiply-adds so it converts with constant weights). The model returns the linear
  multiplier per pixel; it is cached per photo URL and stretched over any decode, and the
  result is an extended linear P3 `CGImage` with `contentHeadroom` set, so the flat view and
  AI 3D take step 1's path unchanged. Shared textures key it as `<url>#aihdr`. Per window,
  defaulting to the last choice (`aiHDRPhotos`); skipped for HDR, transparent, animated,
  auto-enhanced and background-removed pictures, and on tvOS (no EDR). **Device, 2026-10-27:**
  1.4 s for the first photo (model load), 0.63 s warm; the iPhone 11 sunset came out at
  headroom 3.5 (5 % of pixels above SDR white on the Mac, the sun and its glow).
  `photoAIHDR` (window, enabled, clearCache) toggles it; `photoStereoState` reports `aiHDR`.
- **Screenshots from the headset are SDR** (8-bit, sRGB transfer): they can compare relative
  brightness but cannot measure HDR.
- Debug server: `photoHDR` (enabled, headroom, midGamma) and `photoHDRTest` (`dots`,
  `patches`, `dots3d`, `patches3d`, `flip`, `off`: a raw pattern through the flat EDR path
  or AI 3D's video path). Open item: the AI 3D picture's black looked grey beside the flat one
  on the PQ build; not re-checked on HLG.

## Spatial 3D Images
Uses RealityKit's `ImagePresentationComponent` for 2D→3D conversion. States tracked via `Spatial3DImageState` enum: notGenerated → generating → generated. `ImagePresentationComponent` is a black-box component — it manages its own geometry and materials internally, so there's no direct access to its mesh or rendering pipeline.

**visionOS limitation:** `PostProcessEffect` / `PostProcessEffectContext` are unavailable on visionOS. Custom post-processing on `RealityView` content must use SwiftUI-level modifiers (`.mask()`, `.overlay()`) instead.
