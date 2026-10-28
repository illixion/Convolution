/*
 Hypnos - Depth Tile View

 A gallery thumbnail presented as the same tagged-eye stereo picture as full
 AI 3D photos. The image and depth map are cropped together to the cell's
 scaled-to-fill region before rendering.
 */

#if os(visionOS)
import DebugTraceUI
import RAVEMedia
import SwiftUI

struct DepthTileView: View {
    nonisolated static let cornerRadius: CGFloat = 12
    nonisolated static let edgeFalloff: CGFloat = 14

    let image: UIImage
    let depth: StillDepthMap
    let size: CGSize

    @PatchRefresh var patchRefresh
    @State private var prepared: CroppedSource?
    @State private var ready = false

    private var preparationKey: String {
        "\(ObjectIdentifier(image))-\(depth.id)-\(size.width)x\(size.height)"
    }

    var body: some View {
        ZStack {
            // Keep the familiar flat thumbnail visible until the stereo frame
            // is ready, including when a resized cell is being prepared.
            if !ready {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }

            if let prepared {
                RAVEStereoPhotoView(
                    image: prepared.image,
                    depth: prepared.depth,
                    contentID: AnyHashable(preparationKey),
                    cornerRadius: Self.cornerRadius,
                    onReady: { ready = $0 }
                )
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            }

        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .task(id: preparationKey) {
            ready = false
            prepared = nil
            guard let source = image.cgImage, size.width > 0, size.height > 0 else { return }
            let cellSize = size
            let map = depth
            let cropped = await Task.detached(priority: .userInitiated) {
                Self.crop(source: source, depth: map, cell: cellSize)
            }.value
            guard !Task.isCancelled else { return }
            prepared = cropped
        }
        .rebuildsOnPatch()
    }

    private struct CroppedSource: @unchecked Sendable {
        let image: CGImage
        let depth: StillDepthMap
    }

    nonisolated private static func crop(source: CGImage, depth: StillDepthMap, cell: CGSize) -> CroppedSource? {
        let crop = RAVEDepthMesh.fillCrop(
            imageWidth: CGFloat(source.width), imageHeight: CGFloat(source.height), cell: cell
        )
        guard let croppedImage = RAVEDepthMesh.renderTexture(
            source, crop: crop, cell: cell, cornerRadius: 0, maxPixels: 640
        ) else { return nil }

        let values = depth.preciseValues ?? depth.values.map { Float($0) / 255 }
        guard depth.width > 1, depth.height > 1, values.count == depth.width * depth.height else { return nil }
        let outWidth = max(2, Int((CGFloat(depth.width) * crop.width).rounded()))
        let outHeight = max(2, Int((CGFloat(depth.height) * crop.height).rounded()))
        var output = [Float](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            let v = crop.minY + (CGFloat(y) / CGFloat(outHeight - 1)) * crop.height
            let sy = Float(v) * Float(depth.height - 1)
            let y0 = Int(sy), y1 = min(y0 + 1, depth.height - 1), fy = sy - Float(y0)
            for x in 0..<outWidth {
                let u = crop.minX + (CGFloat(x) / CGFloat(outWidth - 1)) * crop.width
                let sx = Float(u) * Float(depth.width - 1)
                let x0 = Int(sx), x1 = min(x0 + 1, depth.width - 1), fx = sx - Float(x0)
                let a = values[y0 * depth.width + x0] * (1 - fx) + values[y0 * depth.width + x1] * fx
                let b = values[y1 * depth.width + x0] * (1 - fx) + values[y1 * depth.width + x1] * fx
                output[y * outWidth + x] = a * (1 - fy) + b * fy
            }
        }
        return CroppedSource(
            image: croppedImage,
            depth: StillDepthMap(width: outWidth, height: outHeight, normalizedValues: output)
        )
    }
}
#endif
