---
paths:
  - "Hypnos/Hypnos/Views/PhotoWindowView.swift"
  - "Hypnos/Hypnos/Views/SharedPhotoWindowView.swift"
  - "Hypnos/Hypnos/Views/Pictures/Photo*"
  - "Hypnos/Hypnos/Views/Pictures/MetalImageView.swift"
  - "Hypnos/Hypnos/Views/Pictures/Spatial3D*"
  - "Hypnos/Hypnos/Views/Pictures/QuickLook3DView.swift"
  - "Hypnos/Hypnos/Views/Pictures/AIDepthPhotoView.swift"
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
The cheap 3D: the "3D Depth" thumbnail's mesh at window size (`AIDepthPhotoView`, built from `DepthMesh`). One pass of the real-time depth model, then one RealityKit mesh, against RealityKit 3D's seconds-long generation and memory spike. visionOS only; needs a real-time depth model (the menu item says so when there is none).
- **State** in `PhotoWindowModel+AIDepth.swift`: `isAIDepthMode`, `aiDepthSource` (the picture, oriented, ≤2048 px, held only while on), `aiDepthMap`. A sibling mode to Diorama and the RealityKit modes, mutually exclusive with them and with background removal (its cut-out is cropped to the subject, so depth no longer lines up). `switchToViewingMode` to a RealityKit mode and `setDioramaMode(true)` exit it. Recorded as `ViewingModePreference.aiDepth`; a default viewing mode too.
- **Follows gallery navigation** (unlike Diorama): `switchToImage` re-engages it on the next picture without recording it as that picture's mode.
- **Depth is shared with the thumbnail cache**, keyed by `image.thumbnailURL` (`ThumbnailDioramaCache.depth(for:source:)`, same estimator queue): a picture seen in the 3D Depth grid engages without inference, and one seen here shows in 3D in the grid.
- **Laid over the flat picture**, which keeps sizing the window and shows until the mesh fades in. Same rect and corner radius; the mesh floats 1 pt off the plane. Depth is 8% of the short side (24–64 pt).
- **Input:** the mesh's RealityView takes no input but would swallow it, so a near-invisible layer at `AIDepthPhotoView.inputTargetZ` carries the tap and swipe; the restore pill is lifted above it. Pinch zoom is off in AI 3D.
- **Adjustments are baked into the texture** (CIColorControls with the same contrast remap as the RealityKit re-bake, plus auto-enhance), re-baked 350 ms after the sliders settle and swapped in place. Flip is a negative x scale on the entity. The mesh fades out while any menu or popover is open.
- **Resizing** scales the entity uniformly (the aspect is fixed); only a ~30% change rebuilds it, for texture detail.

## Spatial 3D Images
Uses RealityKit's `ImagePresentationComponent` for 2D→3D conversion. States tracked via `Spatial3DImageState` enum: notGenerated → generating → generated. `ImagePresentationComponent` is a black-box component — it manages its own geometry and materials internally, so there's no direct access to its mesh or rendering pipeline.

**visionOS limitation:** `PostProcessEffect` / `PostProcessEffectContext` are unavailable on visionOS. Custom post-processing on `RealityView` content must use SwiftUI-level modifiers (`.mask()`, `.overlay()`) instead.
