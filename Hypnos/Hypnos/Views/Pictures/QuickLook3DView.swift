/*
 Hypnos - Quick Look 3D Preview

 Tap-and-hold "Quick Look" preview presented over the gallery grid.

 Animation: SwiftUI `.transition()` only fires when the view it's on
 is conditionally inserted/removed, so wrapping sub-views in their
 own transitions inside an always-mounted parent gives no animation.
 Instead this view drives the pop entirely from internal `@State`:
 on appear it animates a `presented` flag from false → true, which
 the preview reads to interpolate scale + offset between (cellSize,
 cellCenter) and (fullSize, naturalCenter). Dismiss reverses the
 animation and only nils the parent state after the spring settles.
 The side menu has its own slightly-delayed fade/slide so it doesn't
 visually grow out of the cell alongside the preview.

 Progressive load:
   1. Memory-cached thumbnail (instant, often warm from the grid).
   2. Disk-cached or downloaded full file, decoded at the user's
      `maxImageResolution` cap from Settings.
   3. RealityKit Spatial3DImage at the user's `spatial3DMaxResolution`,
      only when the "View in 3D" side-menu button is pressed.

 Z-stacking: `.offset(z:)` lifts the preview and side menu well in
 front of diorama-thumbnail foreground layers (z: 24) so the popped
 preview can't be visually intersected by a thumbnail's diorama pop.

 Reduce Motion: the host grid passes `useScalePop: false`, which
 collapses the scale/translate animation into a plain opacity fade.

 Only one preview is alive at a time — RealityKit enforces a hard
 cap on concurrent ImagePresentationComponent instances on visionOS.
 */

import DebugTrace
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

/// Z-offset applied to the preview and side menu so they sit clearly
/// in front of any diorama-thumbnail foreground layers (z: 24) in
/// the underlying grid.
private let quickLookZOffset: CGFloat = 80

private let sideMenuWidth: CGFloat = 220
private let previewMenuSpacing: CGFloat = 24

struct QuickLook3DView: View {
    @Environment(AppModel.self) private var appModel
    let image: GalleryImage
    /// Source cell frame in the gallery coordinate space. Drives the
    /// scale-from-cell animation. `nil` falls back to a center pop.
    let sourceFrame: CGRect?
    /// Container size resolved by the host's outer `GeometryReader`.
    /// Passed in (rather than read via a local GeometryReader) so the
    /// first paint already has correct geometry — otherwise the first
    /// frame may render with a stale/default size before layout
    /// settles, which is visible as a brief flicker on entry.
    let containerSize: CGSize
    let useScalePop: Bool
    /// Seed bitmap from the source cell. Used as the very first paint
    /// so the entry animation never starts on an empty/loading frame
    /// — eliminates the gray placeholder flash and the "zoomed-crop"
    /// artifact caused by the image arriving mid-animation.
    let initialImage: UIImage?
    /// Invoked AFTER the dismiss animation has settled, so the host
    /// can finally nil-out the optional that drives this view's
    /// presence in the hierarchy.
    let onDismiss: () -> Void

    @State private var presented = false
    /// Gesture grace period after the view appears. The pinch that
    /// completed the long-press tends to register as a tap on the
    /// freshly-presented backdrop on visionOS, immediately firing
    /// `animateDismiss()` — you see the entry animation but the view
    /// vanishes before settling. Tap targets are inert until this
    /// flips true.
    @State private var dismissEnabled = false
    @State private var entity = Entity()
    @State private var aspectRatio: CGFloat = 1
    @State private var spatialReady = false
    @State private var spatialRequested = false
    @State private var spatialLoading = false
    @State private var spatialFailed = false
    @State private var loadFailed = false
    @State private var loadedImage: UIImage?
    @State private var hasHighResImage = false
    @State private var localURL: URL?

    init(
        image: GalleryImage,
        sourceFrame: CGRect?,
        containerSize: CGSize,
        useScalePop: Bool,
        initialImage: UIImage?,
        onDismiss: @escaping () -> Void
    ) {
        self.image = image
        self.sourceFrame = sourceFrame
        self.containerSize = containerSize
        self.useScalePop = useScalePop
        self.initialImage = initialImage
        self.onDismiss = onDismiss
        // Seed @State from the cell's bitmap so the first paint is
        // the actual thumbnail, not a placeholder. aspectRatio seeds
        // from the server-reported native dimensions when available —
        // the cell bitmap may be a square/16:9 crop whose aspect would
        // wrongly size (and zoom) the pop frame until the real image
        // loads — falling back to the seed bitmap's aspect.
        _loadedImage = State(initialValue: initialImage)
        if let w = image.sourceWidth, let h = image.sourceHeight, w > 0, h > 0 {
            _aspectRatio = State(initialValue: CGFloat(w) / CGFloat(h))
        } else if let initialImage, initialImage.size.height > 0 {
            _aspectRatio = State(initialValue: initialImage.size.width / initialImage.size.height)
        }
    }

    var body: some View {
        let menuReserve = sideMenuWidth + previewMenuSpacing
        let maxW = max(containerSize.width * 0.92 - menuReserve, 200)
        let maxH = containerSize.height * 0.92
        let fitted = fittedSize(in: CGSize(width: maxW, height: maxH))
        let cellSide = sourceFrame?.width ?? 200
        // Animating the preview's *frame* between (cellSide × cellSide)
        // and (fitted.width × fitted.height) makes the inner
        // `.scaledToFill().clipped()` produce a continuous crop
        // transition — at the collapsed end, the image fills a square
        // and crops top/bottom (or left/right) exactly like the cell;
        // at the expanded end it fills the natural aspect. No sudden
        // aspect snap when the cell takes over.
        let previewSize = (useScalePop && !presented)
            ? CGSize(width: cellSide, height: cellSide)
            : fitted
        let cornerR: CGFloat = (useScalePop && !presented) ? 12 : 20
        let offsetVec = popOffset(containerSize: containerSize)

        ZStack {
            Color.black
                .opacity(presented ? 0.55 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { animateDismiss() }

            HStack(alignment: .center, spacing: previewMenuSpacing) {
                previewContent(size: previewSize, cornerRadius: cornerR)
                    .offset(x: presented ? 0 : offsetVec.dx, y: presented ? 0 : offsetVec.dy)
                    // Animate z from the lifted-forward position back
                    // to the cell's z (0) on dismiss. Without this the
                    // preview ends the spring at z=80 and then snaps
                    // backwards to where the cell sits, which reads as
                    // a sudden depth pop on no-diorama thumbnails.
                    .offset(z: presented ? quickLookZOffset : 0)
                    // Reduce-motion path uses opacity for the fade.
                    // Scale-pop path keeps opacity at 1 throughout so
                    // the cell→preview handoff is invisible: the
                    // preview is born at the cell's exact position
                    // and size with full opacity, then animates out.
                    .opacity(useScalePop ? 1 : (presented ? 1 : 0))

                sideMenu
                    .frame(width: sideMenuWidth)
                    .opacity(presented ? 1 : 0)
                    .scaleEffect(useScalePop ? (presented ? 1 : 0.85) : 1, anchor: .leading)
                    .offset(x: useScalePop ? (presented ? 0 : -30) : 0)
                    .offset(z: quickLookZOffset)
            }
            .frame(width: containerSize.width, height: containerSize.height, alignment: .center)
        }
        .onAppear {
            // Defer one runloop so SwiftUI commits the initial
            // `presented == false` frame before the animation
            // begins — otherwise the change is coalesced into the
            // first paint and the spring snaps instead of running.
            DispatchQueue.main.async {
                withAnimation(presentAnim) { presented = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismissEnabled = true
            }
        }
        .task(id: image.id) {
            await loadProgressive()
        }
        .onChange(of: spatialRequested) { _, requested in
            guard requested else { return }
            Task { await loadSpatial() }
        }
    }

    private var presentAnim: Animation {
        useScalePop
            ? .spring(response: 0.5, dampingFraction: 0.78)
            : .easeOut(duration: 0.25)
    }

    private var dismissAnim: Animation {
        useScalePop
            ? .spring(response: 0.4, dampingFraction: 0.86)
            : .easeIn(duration: 0.2)
    }

    /// Approximate duration the dismiss animation runs for. Spring
    /// `response` is roughly the perceptual settling time on visionOS;
    /// we add a small slack so onDismiss fires after the spring has
    /// visually finished, never before.
    private var dismissCompletionDelay: TimeInterval {
        useScalePop ? 0.55 : 0.25
    }

    private func animateDismiss() {
        guard dismissEnabled else { return }
        withAnimation(dismissAnim) { presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissCompletionDelay) {
            onDismiss()
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewContent(size: CGSize, cornerRadius: CGFloat) -> some View {
        ZStack {
            if spatialReady {
                // Hand the visible surface entirely to RealityKit once
                // the depth map is ready. Leaving the 2D image stacked
                // beneath caused the spatial scene to look "missing"
                // on visionOS — the RealityView's container can mask
                // SwiftUI compositing in ways that hide the 2D layer
                // anyway, so swapping is both more correct and avoids
                // wasted bandwidth.
                //
                // iOS never sets `spatialReady` (the "View in 3D" side-menu
                // button that starts spatial generation is hidden there —
                // see `sideMenu`), so this branch is unreachable in
                // practice; it still needs to type-check, hence the #else.
                #if os(visionOS)
                GeometryReader3D { geometry3D in
                    RealityView { content in
                        content.add(entity)
                        scaleEntityToFit(content: content, geometry: geometry3D)
                    } update: { content in
                        scaleEntityToFit(content: content, geometry: geometry3D)
                    }
                }
                .frame(width: size.width, height: size.height)
                #else
                EmptyView()
                #endif
            } else if let loadedImage {
                Image(platformImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.secondary.opacity(0.2)
                    .frame(width: size.width, height: size.height)
            }

            if (loadedImage == nil && !loadFailed) || spatialLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(cornerRadius)
        .contentShape(Rectangle())
        .onTapGesture { animateDismiss() }
        #if !os(tvOS)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if abs(value.translation.height) > 60 || abs(value.translation.width) > 60 {
                        animateDismiss()
                    }
                }
        )
        #endif
    }

    // MARK: - Pop offset

    private struct PopOffset {
        let dx: CGFloat
        let dy: CGFloat
    }

    /// Offset that translates the HStack-centered preview to sit on
    /// top of the source cell. The HStack always centers (preview +
    /// spacing + menu) as a unit, so the preview's natural center is
    /// fixed at `containerWidth/2 - (menu + spacing)/2`, regardless
    /// of the preview's own width — so the offset is independent of
    /// the animated frame size. With the preview's frame shrunk to
    /// `cellSide × cellSide`, applying this offset lands its rendered
    /// box exactly on the cell.
    private func popOffset(containerSize: CGSize) -> PopOffset {
        guard useScalePop, let frame = sourceFrame else {
            return PopOffset(dx: 0, dy: 0)
        }
        let previewCenter = CGPoint(
            x: containerSize.width / 2 - (sideMenuWidth + previewMenuSpacing) / 2,
            y: containerSize.height / 2
        )
        let cellCenter = CGPoint(x: frame.midX, y: frame.midY)
        return PopOffset(
            dx: cellCenter.x - previewCenter.x,
            dy: cellCenter.y - previewCenter.y
        )
    }

    // MARK: - Side menu

    private var sideMenu: some View {
        VStack(spacing: 0) {
            if PlatformCapabilities.supportsSpatial3D {
                menuButton(
                    title: spatialReady ? "Spatial 3D" : (spatialLoading ? "Generating…" : "View in 3D"),
                    systemImage: "cube",
                    tinted: spatialReady,
                    disabled: spatialLoading || spatialReady || spatialFailed
                ) {
                    spatialRequested = true
                }

                Divider().opacity(0.3)
            }

            menuButton(
                title: "Close",
                systemImage: "xmark",
                tinted: false,
                disabled: false
            ) {
                animateDismiss()
            }
        }
        .padding(.vertical, 6)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func menuButton(title: String, systemImage: String, tinted: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(tinted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        .hoverEffect()
        #endif
        .disabled(disabled)
    }

    // MARK: - Geometry

    private func fittedSize(in container: CGSize) -> CGSize {
        let ratio = max(aspectRatio, 0.0001)
        let containerRatio = container.width / container.height
        if ratio >= containerRatio {
            return CGSize(width: container.width, height: container.width / ratio)
        } else {
            return CGSize(width: container.height * ratio, height: container.height)
        }
    }

    #if os(visionOS)
    private func scaleEntityToFit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard let ipc = entity.components[ImagePresentationComponent.self] else { return }
        let presentation = ipc.presentationScreenSize
        guard presentation.x > 0, presentation.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
        let scale = min(
            bounds.extents.x / presentation.x,
            bounds.extents.y / presentation.y
        )
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }
    #endif

    // MARK: - Progressive load

    /// Three-stage progressive load:
    ///   1. Memory-cached gallery thumbnail (instant for already-
    ///      scrolled cells).
    ///   2. Disk-cached or just-downloaded source file, decoded at
    ///      the user's `maxImageResolution` cap.
    /// Spatial 3D is *not* eagerly loaded — it waits for the side
    /// menu's "View in 3D" press.
    @MainActor
    private func loadProgressive() async {
        // Note: `presented` is NOT reset here. The view is conditionally
        // rendered by the host, so each invocation gets a fresh @State
        // with `presented == false` already. Resetting it here would
        // race with `.onAppear`'s withAnimation and could slam the view
        // back to invisible after the present animation has started.
        spatialReady = false
        spatialRequested = false
        spatialLoading = false
        spatialFailed = false
        loadFailed = false
        // Note: loadedImage is NOT reset to nil — it's seeded from
        // the cell's bitmap in init so the first paint is correct.
        // Resetting here would blank the view at the start of the
        // task and the entry animation would still be empty for a
        // moment.
        hasHighResImage = false
        localURL = nil

        // Stage 1: thumbnail-cached image as a fast first paint.
        if let thumb = await ImageLoader.shared.loadRemoteThumbnailCached(from: image.thumbnailURL) {
            if !Task.isCancelled, !hasHighResImage {
                // Suppress animation on aspectRatio so an arriving
                // thumbnail with a non-1:1 ratio doesn't ride the
                // still-settling present spring — that produced the
                // "accordion expand" on wide images.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    loadedImage = thumb
                    if thumb.size.height > 0 {
                        aspectRatio = thumb.size.width / thumb.size.height
                    }
                }
            }
        }

        // Stage 2: full source file.
        let sourceURL = image.fullSizeURL
        let resolved: URL
        if let local = await PhotoWindowModel.localFileURL(for: sourceURL) {
            resolved = local
        } else {
            do {
                guard let data = try await ImageLoader.shared.loadRawData(from: sourceURL) else {
                    loadFailed = true; return
                }
                await DiskImageCache.shared.saveData(data, for: sourceURL)
                guard let cached = await DiskImageCache.shared.cachedFileURL(for: sourceURL) else {
                    loadFailed = true; return
                }
                resolved = cached
            } catch {
                AppLogger.views.warning("QuickLook3DView: download failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                loadFailed = true
                return
            }
        }
        if Task.isCancelled { return }
        localURL = resolved

        // Decode at the user's `maxImageResolution` cap (0 = native).
        let maxRes = appModel.maxImageResolution
        let downsampledData: Data? = (maxRes > 0)
            ? PhotoWindowModel.createDownsampledImageData(from: resolved, maxDimension: CGFloat(maxRes))
            : nil
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            if let downsampledData {
                return UIImage(data: downsampledData)
            }
            return UIImage(contentsOfFile: resolved.path)
        }.value
        if Task.isCancelled { return }
        if let decoded {
            // Cross-fade the image swap but never animate aspectRatio
            // — a layout-affecting change rides any in-flight spring
            // and warps the preview's bounds.
            withAnimation(.easeInOut(duration: 0.2)) {
                loadedImage = decoded
            }
            hasHighResImage = true
            if decoded.size.height > 0 {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    aspectRatio = decoded.size.width / decoded.size.height
                }
            }
        }
    }

    @MainActor
    private func loadSpatial() async {
        guard !spatialLoading, !spatialReady, let localURL else { return }
        spatialLoading = true
        spatialFailed = false

        let maxDim = appModel.spatial3DMaxResolution

        let spatial: ImagePresentationComponent.Spatial3DImage
        do {
            if maxDim > 0,
               let downsampled = PhotoWindowModel.createDownsampledImageData(from: localURL, maxDimension: CGFloat(maxDim)),
               let source = CGImageSourceCreateWithData(downsampled as CFData, nil) {
                spatial = try await ImagePresentationComponent.Spatial3DImage(imageSource: source)
            } else {
                spatial = try await ImagePresentationComponent.Spatial3DImage(contentsOf: localURL)
            }
        } catch {
            AppLogger.views.warning("QuickLook3DView: Spatial3DImage init failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            spatialLoading = false
            spatialFailed = true
            return
        }

        if Task.isCancelled { spatialLoading = false; return }

        var ipc = ImagePresentationComponent(spatial3DImage: spatial)
        ipc.desiredViewingMode = .spatial3D
        entity.components.set(ipc)
        if let ar = ipc.aspectRatio(for: .spatial3D) {
            aspectRatio = CGFloat(ar)
        }

        // Strong-ref hold across generate(): RealityKit's progress
        // callbacks crash if the entity is freed mid-flight. Mirrors
        // SlideshowSpatial3DSlotView's pattern.
        let heldEntity = entity
        let heldSpatial = spatial
        Task { @MainActor in
            do {
                try await heldSpatial.generate()
                withAnimation(.easeInOut(duration: 0.25)) {
                    spatialReady = true
                }
            } catch {
                AppLogger.views.warning("QuickLook3DView: generate failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                spatialFailed = true
            }
            spatialLoading = false
            _ = heldEntity
        }
    }
}
