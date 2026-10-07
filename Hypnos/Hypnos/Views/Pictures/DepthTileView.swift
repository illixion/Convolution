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
    /// Vertices along the tile's long edge. Depth is low-frequency, and the
    /// fake-3D warp needs no finer than ~1 vertex per 3 depth texels.
    nonisolated static let gridLongSide = 72

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
        let crop = Self.fillCrop(imageWidth: CGFloat(cgImage.width), imageHeight: CGFloat(cgImage.height), cell: size)
        let built = await Task.detached(priority: .userInitiated) { () -> Built? in
            guard let texture = Self.renderTexture(cgImage, crop: crop, cell: size) else { return nil }
            let mesh = Self.meshDescriptor(
                depth: depth, crop: crop, cell: size,
                widthMeters: widthMeters, heightMeters: heightMeters, spanMeters: spanMeters
            )
            return Built(texture: texture, mesh: mesh)
        }.value
        guard let built,
              let mesh = try? await MeshResource(from: [built.mesh]),
              let texture = try? await TextureResource(image: built.texture, options: .init(semantic: .color))
        else { return nil }

        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Built off the main actor, handed back once. `MeshDescriptor` isn't
    /// `Sendable`, but nothing touches it after the hand-off.
    private struct Built: @unchecked Sendable {
        let texture: CGImage
        let mesh: MeshDescriptor
    }

    /// The image-normalized rect a `scaledToFill` cell shows.
    nonisolated private static func fillCrop(imageWidth: CGFloat, imageHeight: CGFloat, cell: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = imageWidth / imageHeight
        let cellAspect = cell.width / cell.height
        if imageAspect > cellAspect {
            let w = cellAspect / imageAspect
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = imageAspect / cellAspect
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }

    /// The visible crop, rounded corners in alpha, at 2 px per point (capped).
    nonisolated private static func renderTexture(_ image: CGImage, crop: CGRect, cell: CGSize) -> CGImage? {
        let scale = min(2, 640 / max(cell.width, cell.height))
        let width = max(Int((cell.width * scale).rounded()), 1)
        let height = max(Int((cell.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = cornerRadius * scale
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        // Draw the whole image so the crop lands on the context bounds.
        let drawWidth = CGFloat(width) / crop.width
        let drawHeight = CGFloat(height) / crop.height
        // CG's origin is bottom-left; the crop's y is from the top.
        let drawRect = CGRect(
            x: -crop.minX * drawWidth,
            y: -(1 - crop.maxY) * drawHeight,
            width: drawWidth, height: drawHeight
        )
        context.draw(image, in: drawRect)
        return context.makeImage()
    }

    nonisolated private static func meshDescriptor(
        depth: StillDepthMap, crop: CGRect, cell: CGSize,
        widthMeters: Float, heightMeters: Float, spanMeters: Float
    ) -> MeshDescriptor {
        let longSide = gridLongSide
        let cols = cell.width >= cell.height
            ? longSide
            : max(Int((CGFloat(longSide) * cell.width / cell.height).rounded()), 2)
        let rows = cell.height > cell.width
            ? longSide
            : max(Int((CGFloat(longSide) * cell.height / cell.width).rounded()), 2)

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(cols * rows)
        uvs.reserveCapacity(cols * rows)
        let falloff = Float(edgeFalloff)
        // 1 pt off the window plane, where the cell's own fill is drawn:
        // coplanar, the two z-fought into TV-static shimmer.
        let baseMeters = spanMeters / Float(span) * 1
        for j in 0..<rows {
            let v = Float(j) / Float(rows - 1) // 0 at the top
            for i in 0..<cols {
                let u = Float(i) / Float(cols - 1)
                // Distance to the nearest edge, in points.
                let edge = min(
                    min(u, 1 - u) * Float(cell.width),
                    min(v, 1 - v) * Float(cell.height)
                )
                let t = min(max(edge / falloff, 0), 1)
                let fade = t * t * (3 - 2 * t)
                let d = sample(depth,
                               u: Float(crop.minX) + u * Float(crop.width),
                               v: Float(crop.minY) + v * Float(crop.height))
                positions.append(SIMD3(
                    (u - 0.5) * widthMeters,
                    (0.5 - v) * heightMeters,
                    baseMeters + d * fade * spanMeters
                ))
                uvs.append(SIMD2(u, 1 - v))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)
        for j in 0..<(rows - 1) {
            for i in 0..<(cols - 1) {
                let a = UInt32(j * cols + i)
                let b = a + 1
                let c = a + UInt32(cols)
                let d = c + 1
                // Counter-clockwise seen from the front (+z).
                indices += [a, c, b, b, c, d]
            }
        }

        var descriptor = MeshDescriptor(name: "depthTile")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    /// Bilinear sample of the 0…255 map at image-normalized (u, v); 0…1, near = 1.
    nonisolated private static func sample(_ map: StillDepthMap, u: Float, v: Float) -> Float {
        let x = min(max(u * Float(map.width - 1), 0), Float(map.width - 1))
        let y = min(max(v * Float(map.height - 1), 0), Float(map.height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, map.width - 1), y1 = min(y0 + 1, map.height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        func at(_ x: Int, _ y: Int) -> Float { Float(map.values[y * map.width + x]) }
        let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
        let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
        return (top * (1 - fy) + bottom * fy) / 255
    }
}
#endif
