/*
 Hypnos - Slideshow Spatial 3D View

 RealityKit-backed image layer used by the slideshow viewer when
 `Slideshow3DMode` is `.spatial3D` or `.immersive3D`.

 `SlideshowSpatial3DSlotView` is a single slot: it owns one entity with an
 `ImagePresentationComponent`, rebuilds the component when the bound
 `UIImage` changes, and drives `Spatial3DImage.generate()` so the depth
 map is finished before the slot is asked to fade in.

 `SlideshowSpatial3DLayer` is the host the window view embeds — it owns
 two slots and swaps their roles each crossfade so the previously-hidden
 slot (which already finished generating against the prefetched next
 image) just becomes visible instead of regenerating from scratch.
 */

import CoreImage
import DebugTrace
import ImageIO
import RealityKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

#if os(visionOS)

/// Two-slot host that orchestrates pre-generation + crossfade. Slot A and
/// Slot B alternate which one is "currently visible" — whichever slot is
/// in the "hidden / next" role takes the engine's prefetched next image
/// and runs `Spatial3DImage.generate()` while the other is on screen, so
/// the eventual fade-in shows a finished depth map instead of restarting
/// the conversion animation.
struct SlideshowSpatial3DLayer: View {
    @Bindable var model: RemoteViewerModel
    /// Fired when a tap lands on either slot's IPC entity. visionOS hit-
    /// tests RealityKit entities in 3D space ahead of SwiftUI's z-order,
    /// so taps over the image can't be caught by an overlay at the
    /// SwiftUI layer — they have to be picked up via a targeted-entity
    /// gesture on the RealityView itself and bubbled back up.
    var onTap: () -> Void = {}
    /// Fired with the source `UIImage` each time a slot finishes
    /// generating its depth map. The viewer model uses this to gate the
    /// outgoing `imageReady` WS event so the server doesn't advance the
    /// channel before RealityKit has actually caught up — matters at
    /// short channel intervals (6 s, etc.) where pre-gen can't keep up.
    var onSpatial3DGenerated: (UIImage) -> Void = { _ in }

    /// Which slot currently holds the visible image (0 = A, 1 = B). Flipped
    /// after each crossfade so the hidden slot — which has been generating
    /// the prefetched image — promotes into the visible role without ever
    /// recreating its entity.
    @State private var visibleSlot: Int = 0
    @State private var slotA: UIImage?
    @State private var slotB: UIImage?
    /// Identity of the image currently displayed in the visible slot. Used
    /// to detect when `currentImage` has actually changed (i.e. crossfade
    /// committed) so role-swapping fires exactly once per transition.
    @State private var lastCommittedImage: ObjectIdentifier?

    var body: some View {
        let immersive = model.slideshow3DMode == .immersive3D
        let res = model.maxImageResolution3D
        let transitioning = model.isTransitioning
        // RealityKit on visionOS doesn't honor SwiftUI compositing
        // modifiers (`.brightness`/etc.) on spatial scene content, so
        // adjustments are baked into the Spatial3DImage's source bytes
        // via CIFilter inside the slot. Including them in the slot's
        // cache key triggers a regenerate on change — affects future
        // images and re-bakes the hidden pre-generated slot.
        let brightness = model.effectiveBrightness
        let contrast = model.effectiveContrast
        let saturation = model.effectiveSaturation

        ZStack {
            SlideshowSpatial3DSlotView(
                image: slotA,
                immersive: immersive,
                maxResolution: res,
                brightness: brightness,
                contrast: contrast,
                saturation: saturation,
                onTap: onTap,
                onSpatial3DGenerated: onSpatial3DGenerated
            )
                .opacity(opacity(forSlot: 0, transitioning: transitioning))
                .animation(.easeInOut(duration: model.reduceMotion ? 0 : 1.0), value: transitioning)

            SlideshowSpatial3DSlotView(
                image: slotB,
                immersive: immersive,
                maxResolution: res,
                brightness: brightness,
                contrast: contrast,
                saturation: saturation,
                onTap: onTap,
                onSpatial3DGenerated: onSpatial3DGenerated
            )
                .opacity(opacity(forSlot: 1, transitioning: transitioning))
                .animation(.easeInOut(duration: model.reduceMotion ? 0 : 1.0), value: transitioning)
        }
        .onAppear { syncSlots(force: true) }
        .onChange(of: identity(model.nextImage)) { _, newId in
            // Crossfade starting: the engine publishes the exact incoming
            // image (the same instance the commit will make `currentImage`)
            // in `nextImage`, inside the same `withAnimation` that flips
            // `isTransitioning`. The hidden slot is about to fade in, so this
            // is the last moment to guarantee it holds the right image.
            // Normally it already does (peek pre-generation) and this is a
            // no-op that preserves the finished depth map. But in
            // server-driven mode the peek can miss — the announced `next`
            // hadn't downloaded before the advance frame landed, or the
            // server advanced to a different post than it announced — leaving
            // the hidden slot holding a stale image from a previous cycle.
            // Without this sync that stale (visibly unrelated) image fades in
            // at full opacity and only snaps to the correct image's
            // generation animation when `handleCommit` reassigns at commit.
            // nil transitions are ignored: the commit clears `nextImage`, and
            // video crossfades never set it.
            guard newId != nil, let incoming = model.nextImage else { return }
            let hiddenSlot = 1 - visibleSlot
            let hiddenImage = hiddenSlot == 0 ? slotA : slotB
            if identity(hiddenImage) != newId {
                assignSlot(hiddenSlot, image: incoming)
            }
        }
        .onChange(of: identity(model.currentImage)) { _, _ in
            // Crossfade just committed — the previously hidden slot now
            // holds the visible image. Flip roles, then refill the freshly
            // hidden slot with the engine's next peek.
            handleCommit()
        }
        .onChange(of: identity(model.peekedNextImage)) { oldId, _ in
            // Never touch the hidden slot mid-advance. While the engine is
            // loading/crossfading toward a new current, the hidden slot holds
            // (and is fading in) the *imminent* image. The look-ahead may have
            // already advanced past it — server-driven mode announces the
            // next-next (`setServerNext`) before the current crossfade
            // commits, and the new peek often arrives via an intermediate nil
            // as it downloads, which defeats the "hidden holds old peek"
            // guard below. Overwriting here swaps the fading-in image out for
            // the one after it, then `handleCommit` swaps it back — the
            // A→B→C→B flicker. `handleCommit` reloads the fresh peek once the
            // crossfade commits, so deferring is both safe and complete.
            switch model.state {
            case .displaying, .paused, .idle: break
            default: return
            }
            // The engine pops `prefetchedImages.first` *before* it sets
            // `isTransitioning`, so an advance flips peek from the image
            // about to display (already loaded in our hidden slot) to
            // the one after it. Reacting to that shift would overwrite
            // the fully-generated incoming image and force a regen
            // mid-crossfade. Detect that case via "hidden currently
            // holds the old peek" and skip — `handleCommit` will refresh
            // hidden once the new current is known. All other peek
            // changes (cold-start fill, prefetch refill after a stall)
            // fall through and load normally.
            let hiddenSlot = 1 - visibleSlot
            let hiddenImage = hiddenSlot == 0 ? slotA : slotB
            let hiddenId = identity(hiddenImage)
            if hiddenId != nil, hiddenId == oldId { return }
            loadPeekIntoHiddenSlot()
        }
    }

    private func opacity(forSlot slot: Int, transitioning: Bool) -> Double {
        // The "visible" slot is fully opaque except during a crossfade,
        // when it fades out as the hidden slot fades in. Once the
        // crossfade commits we flip `visibleSlot`, which keeps the
        // newly-visible slot at opacity 1 without animation.
        let isVisible = slot == visibleSlot
        if transitioning {
            return isVisible ? 0 : 1
        } else {
            return isVisible ? 1 : 0
        }
    }

    private func identity(_ image: UIImage?) -> ObjectIdentifier? {
        guard let image else { return nil }
        return ObjectIdentifier(image)
    }

    private func syncSlots(force: Bool) {
        // Initial population: visible slot gets current image, hidden slot
        // takes the peeked next so it starts generating immediately.
        if visibleSlot == 0 {
            slotA = model.currentImage
            slotB = model.peekedNextImage
        } else {
            slotB = model.currentImage
            slotA = model.peekedNextImage
        }
        if force, let img = model.currentImage {
            lastCommittedImage = ObjectIdentifier(img)
        }
    }

    private func handleCommit() {
        guard let current = model.currentImage else {
            lastCommittedImage = nil
            return
        }
        let newId = ObjectIdentifier(current)
        guard newId != lastCommittedImage else { return }
        lastCommittedImage = newId

        // If the hidden slot already holds this image (the normal pre-gen
        // path), just flip roles — no regeneration. Otherwise the new
        // image bypassed the peek (manual navigation, tag-list change),
        // so install it into the now-hidden slot and flip; that slot will
        // generate on first display.
        let hiddenSlot = 1 - visibleSlot
        let hiddenImage = hiddenSlot == 0 ? slotA : slotB
        if identity(hiddenImage) != newId {
            assignSlot(hiddenSlot, image: current)
        }
        visibleSlot = hiddenSlot
        // The now-hidden slot will pick up the next peek via its own
        // onChange, but if a peek is already waiting we kick it now so
        // generation can start during the new displaying interval.
        loadPeekIntoHiddenSlot()
    }

    private func loadPeekIntoHiddenSlot() {
        let hiddenSlot = 1 - visibleSlot
        let hiddenImage = hiddenSlot == 0 ? slotA : slotB
        guard let peek = model.peekedNextImage else { return }
        // Don't reload if the hidden slot already shows this image —
        // would cause exactly the double-generation the slot view was
        // designed to avoid.
        if identity(hiddenImage) == ObjectIdentifier(peek) { return }
        // Skip if the current image is the peek (cold start: prefetch
        // hasn't refilled past the now-displayed item yet).
        if identity(model.currentImage) == ObjectIdentifier(peek) { return }
        assignSlot(hiddenSlot, image: peek)
    }

    private func assignSlot(_ slot: Int, image: UIImage?) {
        if slot == 0 { slotA = image } else { slotB = image }
    }
}

struct SlideshowSpatial3DSlotView: View {
    let image: UIImage?
    let immersive: Bool
    let maxResolution: Int
    /// Visual adjustments to bake into the Spatial3DImage source via
    /// CIFilter. Photo-viewer-style runtime regeneration (see
    /// `PhotoWindowModel.reloadImagePresentationWithAdjustments`) — values
    /// match SwiftUI's `.brightness/.contrast/.saturation` semantics so
    /// the contrast input is remapped before reaching CIColorControls.
    let brightness: Double
    let contrast: Double
    let saturation: Double
    var onTap: () -> Void = {}
    var onSpatial3DGenerated: (UIImage) -> Void = { _ in }

    @State private var entity = Entity()
    @State private var loadedKey: String?
    /// Identity of the image whose IPC is currently installed on the entity.
    /// Lets `reload` distinguish "different image replacing this slot" (drop
    /// the old IPC immediately — its picture is wrong now) from "same image
    /// re-baking with new adjustments" (keep showing the old IPC until the
    /// re-derived one is ready, avoiding a flash).
    @State private var loadedImageId: ObjectIdentifier?

    var body: some View {
        // GeometryReader3D + scale-to-fit mirrors PhotoDisplayView's
        // windowed 3D path: IPC's `presentationScreenSize` is in meters,
        // and the entity needs an explicit scale to match the SwiftUI
        // bounds — otherwise the spatial 3D scene renders at its native
        // size and crops in. Immersive mode is left at scale 1 since the
        // RealityView's bounds are the immersive space itself.
        GeometryReader3D { geometry in
            RealityView { content in
                installTapTarget(on: entity)
                content.add(entity)
                scaleEntityToFit(content: content, geometry: geometry)
            } update: { content in
                scaleEntityToFit(content: content, geometry: geometry)
            }
            .gesture(
                TapGesture()
                    .targetedToAnyEntity()
                    .onEnded { _ in onTap() }
            )
        }
        .task(id: cacheKey) {
            await reload()
        }
        .onChange(of: immersive) { _, newValue in
            // Mode flip without regeneration: mirrors the regular photo
            // viewer, which mutates the existing IPC component instead
            // of rebuilding the Spatial3DImage. The depth map already
            // generated for this slot stays valid across the toggle.
            guard var ipc = entity.components[ImagePresentationComponent.self] else { return }
            ipc.desiredViewingMode = newValue ? .spatial3DImmersive : .spatial3D
            entity.components.set(ipc)
        }
    }

    /// Adds the `InputTargetComponent` + `CollisionComponent` pair that
    /// makes the slot entity tappable via SwiftUI's targeted-entity tap
    /// gesture — same trick as the photo viewer's `inputPlaneEntity`,
    /// but applied directly to the IPC-bearing entity since the slot
    /// only has the one. Collision box is 1×1×0.01m and gets scaled by
    /// `entity.scale` along with the IPC, so the hit region stays
    /// aligned with the visible image.
    @MainActor
    private func installTapTarget(on entity: Entity) {
        guard entity.components[InputTargetComponent.self] == nil else { return }
        entity.components.set(InputTargetComponent())
        entity.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: SIMD3<Float>(1.0, 1.0, 0.01))],
                mode: .default,
                filter: .default
            )
        )
    }

    private func scaleEntityToFit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard !immersive else {
            entity.scale = SIMD3<Float>(1, 1, 1)
            return
        }
        guard let ipc = entity.components[ImagePresentationComponent.self] else { return }
        let presentationScreenSize = ipc.presentationScreenSize
        guard presentationScreenSize.x > 0, presentationScreenSize.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
        let scale = min(
            bounds.extents.x / presentationScreenSize.x,
            bounds.extents.y / presentationScreenSize.y
        )
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    /// Cache key intentionally excludes the immersive flag — that's a
    /// runtime mode toggle on the existing IPC, not a reason to rebuild
    /// the Spatial3DImage. Re-derives on a new image, resolution-cap
    /// change, or adjustments change (so the hidden slot's pre-generated
    /// depth map gets re-derived against the latest adjustments).
    private var cacheKey: String {
        guard let image else { return "nil" }
        return String(
            format: "%d:%d:%.3f:%.3f:%.3f",
            ObjectIdentifier(image).hashValue,
            maxResolution,
            brightness, contrast, saturation
        )
    }

    private var hasAdjustments: Bool {
        brightness != 0 || contrast != 1 || saturation != 1
    }

    @MainActor
    private func reload() async {
        guard let image else {
            entity.components.remove(ImagePresentationComponent.self)
            loadedKey = nil
            loadedImageId = nil
            return
        }
        let key = cacheKey
        if loadedKey == key { return }

        // A different image is replacing this slot's content. Drop the old
        // IPC up front so the slot renders empty (then the generation
        // placeholder) while the new Spatial3DImage builds — if the slot was
        // corrected at crossfade start, keeping the old component would fade
        // the previous (wrong) picture in for the several hundred ms the
        // rebuild takes. Same-image adjustment re-bakes skip this and keep
        // the old IPC visible until the re-derived one lands.
        let imageId = ObjectIdentifier(image)
        if let loadedImageId, loadedImageId != imageId {
            entity.components.remove(ImagePresentationComponent.self)
        }

        guard let data = image.jpegData(compressionQuality: 0.95) else {
            AppLogger.remoteViewer.warning("SlideshowSpatial3DView: could not encode image data")
            return
        }

        // Bake adjustments into the source bytes when sliders are not at
        // identity. Skipping the CIFilter pass for default values avoids
        // an unnecessary round-trip through CoreImage on every image.
        let sourceData: Data
        if hasAdjustments {
            let adj = Adjustments(brightness: brightness, contrast: contrast, saturation: saturation)
            if let baked = await Task.detached(operation: { Self.applyAdjustments(to: data, adjustments: adj) }).value {
                sourceData = baked
            } else {
                AppLogger.remoteViewer.warning("SlideshowSpatial3DView: adjustment bake failed, using raw bytes")
                sourceData = data
            }
        } else {
            sourceData = data
        }

        do {
            let spatial = try await Self.makeSpatial3DImage(from: sourceData)
            var ipc = ImagePresentationComponent(spatial3DImage: spatial)
            ipc.desiredViewingMode = immersive ? .spatial3DImmersive : .spatial3D
            entity.components.set(ipc)
            loadedKey = key
            loadedImageId = imageId
            // Kick off the depth-map generation in a detached task that
            // captures the entity and Spatial3DImage strongly. RealityKit's
            // generate() ignores Swift cooperative cancellation and crashes
            // inside REImagePresentationComponentNotifySpatial3DImageGenerationProgress
            // if the entity (and thus the IPC component slot) is freed
            // before the progress callbacks finish firing — which is
            // exactly what happens when the slideshow window closes while
            // generation is still in flight. Holding strong refs through
            // the detached task keeps the IPC alive past the SwiftUI
            // teardown so the callbacks land on valid memory.
            let heldEntity = entity
            let heldSpatial = spatial
            let onGenerated = onSpatial3DGenerated
            let generatedImage = image
            // Unstructured Task (not Task.detached) so it inherits the
            // main actor without crossing the Sendable boundary, and not
            // a child of the SwiftUI .task body so it isn't cancelled
            // when this view goes away. We deliberately do NOT cancel it
            // on dismissal — generate() ignores cooperative cancellation
            // anyway, and letting it run to completion is what keeps the
            // IPC alive through the progress callbacks.
            Task { @MainActor in
                do {
                    try await heldSpatial.generate()
                } catch {
                    AppLogger.remoteViewer.warning("SlideshowSpatial3DView: spatial.generate() failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                }
                onGenerated(generatedImage)
                // Explicit reference so the optimizer doesn't release the
                // entity before generate's progress callbacks complete.
                _ = heldEntity
            }
        } catch {
            AppLogger.remoteViewer.warning("SlideshowSpatial3DView: Spatial3DImage init failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    /// Build the `Spatial3DImage` off the main actor. The CGImageSource is
    /// created locally so it never crosses an actor boundary — the
    /// `Spatial3DImage` initializer is nonisolated and bridging the source
    /// from the main actor trips Swift 6's data-race check.
    private nonisolated static func makeSpatial3DImage(from data: Data) async throws -> ImagePresentationComponent.Spatial3DImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await ImagePresentationComponent.Spatial3DImage(imageSource: source)
    }

    /// Sendable adjustments wrapper so the detached task can capture by value.
    private struct Adjustments: Sendable {
        let brightness: Double
        let contrast: Double
        let saturation: Double
    }

    /// Apply brightness/contrast/saturation through CIColorControls and
    /// re-encode to JPEG. CIColorControls' contrast scale is empirically
    /// ~8× more aggressive than SwiftUI's `.contrast()` for the same
    /// deviation from 1.0, so the deviation is scaled by 0.12 to match —
    /// mirrors the remapping in PhotoWindowModel's 3D adjustment regen.
    private nonisolated static func applyAdjustments(to data: Data, adjustments adj: Adjustments) -> Data? {
        guard let ciImage = CIImage(data: data) else { return nil }
        let remappedContrast = 1.0 + (adj.contrast - 1.0) * 0.12

        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(adj.brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(remappedContrast, forKey: kCIInputContrastKey)
        filter.setValue(adj.saturation, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
    }
}

#else

/// iOS stand-in: RealityKit's `ImagePresentationComponent` spatial-photo
/// slideshow has no flat-screen equivalent, so this layer renders nothing.
/// Same init shape as the visionOS version so `RemoteViewerWindowView`
/// compiles unchanged; `Slideshow3DMode` is never offered as a UI choice on
/// iOS (see `PlatformCapabilities.supportsSpatial3D`), so this is unreachable
/// in practice.
struct SlideshowSpatial3DLayer: View {
    @Bindable var model: RemoteViewerModel
    var onTap: () -> Void = {}
    var onSpatial3DGenerated: (UIImage) -> Void = { _ in }

    var body: some View {
        Color.clear
    }
}

#endif
