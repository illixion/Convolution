/*
 Hypnos - AI Depth Photo View

 "AI 3D" for a photo: the "3D Depth" thumbnail's displaced mesh
 (`DepthMesh`) at window size. One pass of the real-time depth model and one
 RealityKit mesh, so it engages in about the time the model takes, against the
 seconds and the memory spike of RealityKit's own conversion ("RealityKit 3D",
 `ImagePresentationComponent`). The photo viewer and image slideshows mount it
 over their flat picture.

 - Laid over the flat picture, never instead of it: the flat picture shows
   while the mesh builds, and owns sizing. The mesh covers it exactly (same
   rect, same corner radius) and floats 1 pt off its plane.
 - Purely visual. A RealityView takes input even with `allowsHitTesting(false)`
   (the 3D Depth thumbnails found this), so a caller that needs taps or swipes
   puts a target in front of it, at `inputTargetZ`.
 - Built once per picture at the size it first appears; a resize scales the
   entity (the aspect is fixed, so it is a uniform scale), and only a resize
   of more than about 30% rebuilds it at the new size, for texture detail.
 - Brightness, contrast and saturation are baked into the texture, because
   RealityKit ignores SwiftUI's colour modifiers. A change rebuilds the
   texture after the sliders settle, and swaps the entity in place.
 */

#if os(visionOS)
import CoreImage
import RAVEMedia
import RealityKit
import SwiftUI

struct AIDepthPhotoView: View {
    let image: CGImage
    let depth: StillDepthMap
    /// Changes when the picture does. The mesh is rebuilt for a new one.
    let contentID: AnyHashable
    var adjustments: Adjustments = .neutral
    var cornerRadius: CGFloat = 0
    var isFlipped = false
    /// Applied through `OpacityComponent`: RealityKit ignores SwiftUI's
    /// `.opacity`. Callers hide the mesh (0) while a menu or popover is open,
    /// which the popped-forward picture would otherwise cover, and during a
    /// slideshow's crossfade.
    var opacity: Double = 1
    /// How long an opacity change takes. RealityKit animates it, since
    /// SwiftUI's animations don't reach an entity's components.
    var fadeDuration: TimeInterval = 0.25

    struct Adjustments: Hashable, Sendable {
        var brightness: Double = 0
        var contrast: Double = 1
        var saturation: Double = 1
        var autoEnhance = false

        static let neutral = Adjustments()
        var isNeutral: Bool { self == .neutral }
    }

    /// Deepest the nearest content gets, in points. Input targets sit in
    /// front of it.
    nonisolated static let maxSpan: CGFloat = 64
    nonisolated static let inputTargetZ: CGFloat = maxSpan + 2

    /// Depth scales with the picture: 8% of its short side, so a small
    /// window isn't all relief and a large one isn't flat.
    nonisolated static func shape(for size: CGSize) -> DepthMesh.Shape {
        let shortSide = min(size.width, size.height)
        return DepthMesh.Shape(
            span: min(max(shortSide * 0.08, 24), maxSpan),
            edgeFalloff: min(max(shortSide * 0.02, 10), 24),
            gridLongSide: 192
        )
    }

    @Environment(\.physicalMetrics) private var metrics
    @State private var root = Entity()
    @State private var builtWidth: CGFloat = 0
    @State private var fadeTask: Task<Void, Never>?
    /// `adjustments` once the sliders have stopped moving.
    @State private var settledAdjustments: Adjustments?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let adjustments = settledAdjustments ?? self.adjustments
            RealityView { content in
                root.components.set(OpacityComponent(opacity: 0))
                content.add(root)
            } update: { _ in
                let scale = builtWidth > 0 ? Float(size.width / builtWidth) : 1
                root.scale = SIMD3(isFlipped ? -scale : scale, scale, scale)
            }
            .task(id: BuildKey(content: contentID, adjustments: adjustments, sizeBucket: Self.sizeBucket(size))) {
                await build(size: size, adjustments: adjustments)
            }
        }
        .allowsHitTesting(false)
        .onDisappear { fadeTask?.cancel() }
        .onChange(of: opacity) { _, newValue in
            guard builtWidth > 0 else { return }
            fade(to: newValue)
        }
        .task(id: adjustments) {
            guard settledAdjustments != nil else {
                settledAdjustments = adjustments
                return
            }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            settledAdjustments = adjustments
        }
    }

    private struct BuildKey: Hashable {
        let content: AnyHashable
        let adjustments: Adjustments
        let sizeBucket: Int
    }

    /// Steps of ~30% in width: a resize within one step only rescales.
    private static func sizeBucket(_ size: CGSize) -> Int {
        guard size.width > 1 else { return 0 }
        return Int((log(size.width) / log(1.3)).rounded())
    }

    private func build(size: CGSize, adjustments: Adjustments) async {
        guard size.width > 1, size.height > 1 else { return }
        let shape = Self.shape(for: size)
        let widthMeters = Float(metrics.convert(size.width, to: .meters))
        let heightMeters = Float(metrics.convert(size.height, to: .meters))
        let spanMeters = Float(metrics.convert(shape.span, to: .meters))
        let image = self.image, depth = self.depth, cornerRadius = self.cornerRadius
        let built = await Task.detached(priority: .userInitiated) { () -> Built? in
            let source = adjustments.isNeutral ? image : (Self.adjusted(image, adjustments) ?? image)
            let crop = DepthMesh.fillCrop(imageWidth: CGFloat(source.width), imageHeight: CGFloat(source.height), cell: size)
            guard let texture = DepthMesh.renderTexture(
                source, crop: crop, cell: size, cornerRadius: cornerRadius, maxPixels: 2560
            ) else { return nil }
            let mesh = DepthMesh.meshDescriptor(
                depth: depth, crop: crop, cell: size, shape: shape,
                widthMeters: widthMeters, heightMeters: heightMeters, spanMeters: spanMeters
            )
            return Built(texture: texture, mesh: mesh)
        }.value
        guard !Task.isCancelled, let built,
              let model = await DepthMesh.makeModel(texture: built.texture, mesh: built.mesh),
              !Task.isCancelled
        else { return }
        // Swapped in place, so a re-bake never shows an empty frame.
        let isFirst = builtWidth == 0
        root.children.removeAll()
        root.addChild(model)
        builtWidth = size.width
        // The first mesh fades in over the flat picture under it.
        if isFirst { fade(to: opacity) }
    }

    /// Stepped by hand rather than with a RealityKit animation, so the
    /// component always holds the value on screen and the next fade starts
    /// from it.
    private func fade(to value: Double) {
        fadeTask?.cancel()
        let target = Float(value)
        let start = root.components[OpacityComponent.self]?.opacity ?? 1
        guard fadeDuration > 0, start != target else {
            root.components.set(OpacityComponent(opacity: target))
            return
        }
        let root = self.root, duration = fadeDuration
        fadeTask = Task { @MainActor in
            let began = Date()
            while !Task.isCancelled {
                let t = Float(min(Date().timeIntervalSince(began) / duration, 1))
                let eased = t * t * (3 - 2 * t)
                root.components.set(OpacityComponent(opacity: start + (target - start) * eased))
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Built off the main actor, handed back once. `MeshDescriptor` isn't
    /// `Sendable`, but nothing touches it after the hand-off.
    private struct Built: @unchecked Sendable {
        let texture: CGImage
        let mesh: MeshDescriptor
    }

    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The picture with the viewer's adjustments applied, matching the flat
    /// path's SwiftUI modifiers. CIColorControls' contrast is ~8× SwiftUI's
    /// for the same deviation from 1, hence the remap (as in the RealityKit
    /// 3D re-bake, `PhotoWindowModel+VisualAdjustments`).
    nonisolated private static func adjusted(_ image: CGImage, _ adjustments: Adjustments) -> CGImage? {
        var result = CIImage(cgImage: image)
        if adjustments.autoEnhance {
            result = PhotoWindowModel.applyAutoAdjustmentFilters(to: result)
        }
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(result, forKey: kCIInputImageKey)
        filter.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(1.0 + (adjustments.contrast - 1.0) * 0.12, forKey: kCIInputContrastKey)
        filter.setValue(adjustments.saturation, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
#endif
