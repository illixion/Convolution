/*
 Hypnos - Depth Mesh

 The pieces of a depth-displaced picture: a grid mesh pushed toward the
 viewer by a still's depth map, and the texture that goes on it. Shared by
 the "3D Depth" thumbnails (`DepthTileView`, `DioramaTileView`) and the
 AI 3D photo views (`AIDepthPhotoView`), which differ only in scale: a
 thumbnail is 32 pt deep on a 112-vertex grid, a photo window a few times
 that on a denser one.

 The device findings behind each rule are in `DepthTileView`'s header and in
 `.claude/rules/hypnos-gallery-grid.md`: clamp the texture, soften the depth,
 fade it to zero at the edges, and keep 1 pt off the window plane.
 */

#if os(visionOS)
import Accelerate
import RAVEMedia
import RealityKit
import SwiftUI

enum DepthMesh {
    /// How a picture is displaced, in points.
    struct Shape: Sendable {
        /// Displacement of the nearest content.
        var span: CGFloat
        /// Depth falls to zero over this distance from each edge, so the
        /// outline stays on the window plane and can't project past itself
        /// seen off-axis.
        var edgeFalloff: CGFloat
        /// Vertices along the long edge.
        var gridLongSide: Int
    }

    /// The image-normalized rect a `scaledToFill` cell shows.
    nonisolated static func fillCrop(imageWidth: CGFloat, imageHeight: CGFloat, cell: CGSize) -> CGRect {
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

    /// The visible crop, rounded corners in alpha, at up to 2 px per point
    /// and `maxPixels` on the long edge. `edgeFade` (points) additionally
    /// fades alpha to zero toward the cell edge: the diorama's subject panel,
    /// which otherwise ran flat into the edge and showed a seam against the
    /// backdrop seen from the side.
    nonisolated static func renderTexture(
        _ image: CGImage, crop: CGRect, cell: CGSize,
        cornerRadius: CGFloat, maxPixels: CGFloat = 640, edgeFade: CGFloat = 0
    ) -> CGImage? {
        let scale = min(2, maxPixels / max(cell.width, cell.height))
        let width = max(Int((cell.width * scale).rounded()), 1)
        let height = max(Int((cell.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if cornerRadius > 0 {
            let radius = cornerRadius * scale
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        }
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
        if edgeFade > 0, let data = context.data {
            fadeEdges(data.assumingMemoryBound(to: UInt8.self), width: width, height: height,
                      bytesPerRow: context.bytesPerRow, fadePixels: Float(edgeFade * scale))
        }
        return context.makeImage()
    }

    /// Premultiplied RGBA, so every channel scales with the alpha.
    nonisolated private static func fadeEdges(
        _ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, fadePixels: Float
    ) {
        func ramp(_ distance: Float) -> Float {
            let t = min(max(distance / fadePixels, 0), 1)
            return t * t * (3 - 2 * t)
        }
        let columns = (0..<width).map { ramp(Float(min($0, width - 1 - $0)) + 0.5) }
        for y in 0..<height {
            let rowFactor = ramp(Float(min(y, height - 1 - y)) + 0.5)
            let row = pixels + y * bytesPerRow
            for x in 0..<width {
                let f = min(rowFactor, columns[x])
                guard f < 1 else { continue }
                for c in 0..<4 {
                    row[x * 4 + c] = UInt8(Float(row[x * 4 + c]) * f + 0.5)
                }
            }
        }
    }

    /// Clamped to the edge: the default repeat let the top row's filtering
    /// pull in the bottom row, a 1-px line along the top of some tiles.
    @MainActor
    static func clampedTexture(_ resource: TextureResource) -> MaterialParameters.Texture {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return MaterialParameters.Texture(resource, sampler: .init(descriptor))
    }

    /// The textured, displaced mesh as one entity.
    @MainActor
    static func makeModel(texture: CGImage, mesh descriptor: MeshDescriptor) async -> ModelEntity? {
        guard let mesh = try? await MeshResource(from: [descriptor]),
              let resource = try? await TextureResource(
                  image: texture,
                  options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)
              )
        else { return nil }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: clampedTexture(resource))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        return ModelEntity(mesh: mesh, materials: [material])
    }

    nonisolated static func meshDescriptor(
        depth: StillDepthMap, crop: CGRect, cell: CGSize, shape: Shape,
        widthMeters: Float, heightMeters: Float, spanMeters: Float
    ) -> MeshDescriptor {
        // Softened first: a hard depth step lands on the vertex grid as a
        // staircase along the subject's outline (device, 2026-10-07). Spread
        // over a few texels, it reads as a slope at any grid density.
        let depth = softened(depth)
        let longSide = shape.gridLongSide
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
        let falloff = Float(shape.edgeFalloff)
        // 1 pt off the window plane, where the cell's own fill is drawn:
        // coplanar, the two z-fought into TV-static shimmer.
        let baseMeters = spanMeters / Float(shape.span) * 1
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

    /// Tent blur over ~1% of the map's long edge (odd kernel, edges extended).
    nonisolated private static func softened(_ map: StillDepthMap) -> StillDepthMap {
        var kernel = max(map.width, map.height) / 100 * 2 + 1
        kernel = max(kernel, 3)
        var source = map.values
        var output = [UInt8](repeating: 0, count: source.count)
        let error = source.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var srcBuffer = vImage_Buffer(
                    data: src.baseAddress, height: vImagePixelCount(map.height),
                    width: vImagePixelCount(map.width), rowBytes: map.width
                )
                var dstBuffer = vImage_Buffer(
                    data: dst.baseAddress, height: vImagePixelCount(map.height),
                    width: vImagePixelCount(map.width), rowBytes: map.width
                )
                return vImageTentConvolve_Planar8(
                    &srcBuffer, &dstBuffer, nil, 0, 0,
                    UInt32(kernel), UInt32(kernel), 0, vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard error == kvImageNoError else { return map }
        return StillDepthMap(width: map.width, height: map.height, values: output)
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
