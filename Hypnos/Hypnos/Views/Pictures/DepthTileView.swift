/*
 Hypnos - Depth Tile View

 A gallery thumbnail as one 3D object: a grid mesh displaced toward the
 viewer by the thumbnail's depth map (`ThumbnailDioramaCache.ThumbnailDepth`),
 textured with the visible crop of the thumbnail. The "3D Depth" style.

 One mesh rather than a stack of masked SwiftUI planes, because the planes
 couldn't be lifted: the gaze hover scales a cell as one 2D layer, and planes
 at different z offsets slid against each other under it (device,
 2026-10-07), whether the scale was applied to the cell or to each plane.
 A single entity scales as one unit, and its depth is continuous rather than
 stepped.

 - The texture is the cell's visible region only (the grid's `scaledToFill`
   crop, done here), with the cell's rounded corners baked into its alpha:
   SwiftUI clipping doesn't reach RealityKit content.
 - Depth falls off to zero over the outer `edgeFalloff` points, so the tile's
   outline stays flat on the window plane and can't project past itself when
   seen off-axis.
 */

#if os(visionOS)
import DebugTraceUI
import RAVEMedia
import RealityKit
import SwiftUI

struct DepthTileView: View {
    let image: UIImage
    let depth: StillDepthMap
    let size: CGSize

    @PatchRefresh var patchRefresh
    @Environment(\.physicalMetrics) private var metrics
    @State private var ready = false

    /// Displacement of the nearest content, in points.
    nonisolated static let span: CGFloat = 32
    nonisolated static let cornerRadius: CGFloat = 12
    nonisolated static let edgeFalloff: CGFloat = 14
    /// Vertices along the tile's long edge. With the depth softened, this
    /// is dense enough that a subject's outline doesn't read as stepped.
    nonisolated static let gridLongSide = 112
    nonisolated static let shape = RAVEDepthMesh.Shape(span: span, edgeFalloff: edgeFalloff, gridLongSide: gridLongSide)

    var body: some View {
        let widthMeters = Float(metrics.convert(size.width, to: .meters))
        let heightMeters = Float(metrics.convert(size.height, to: .meters))
        let spanMeters = Float(metrics.convert(Self.span, to: .meters))
        ZStack {
            // Until the entity is up, the flat thumbnail stands in.
            if !ready {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }
            RealityView { content in
                guard let entity = await Self.makeEntity(
                    image: image, depth: depth, size: size,
                    widthMeters: widthMeters, heightMeters: heightMeters, spanMeters: spanMeters
                ) else { return }
                content.add(entity)
                ready = true
            }
            .frame(width: size.width, height: size.height)
        }
        // Purely visual: the cell around it owns tap, long press and hover.
        // Hit-testable, the RealityView swallowed hand-tracked scrolling and
        // pointer hover over every tile (device, 2026-10-07).
        .allowsHitTesting(false)
        // A resize rebuilds the mesh at the new size.
        .id(size)
    }

    @MainActor
    private static func makeEntity(
        image: UIImage, depth: StillDepthMap, size: CGSize,
        widthMeters: Float, heightMeters: Float, spanMeters: Float
    ) async -> Entity? {
        guard let cgImage = image.cgImage, size.width > 0, size.height > 0 else { return nil }
        let crop = RAVEDepthMesh.fillCrop(imageWidth: CGFloat(cgImage.width), imageHeight: CGFloat(cgImage.height), cell: size)
        let built = await Task.detached(priority: .userInitiated) { () -> Built? in
            guard let texture = RAVEDepthMesh.renderTexture(cgImage, crop: crop, cell: size, cornerRadius: cornerRadius) else { return nil }
            let mesh = RAVEDepthMesh.meshDescriptor(
                depth: depth, crop: crop, cell: size, shape: shape,
                widthMeters: widthMeters, heightMeters: heightMeters, spanMeters: spanMeters
            )
            return Built(texture: texture, mesh: mesh)
        }.value
        guard let built else { return nil }
        return await RAVEDepthMesh.makeModel(texture: built.texture, mesh: built.mesh)
    }

    /// Built off the main actor, handed back once. `MeshDescriptor` isn't
    /// `Sendable`, but nothing touches it after the hand-off.
    private struct Built: @unchecked Sendable {
        let texture: CGImage
        let mesh: MeshDescriptor
    }
}
#endif
