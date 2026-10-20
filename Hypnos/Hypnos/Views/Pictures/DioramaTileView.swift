/*
 Hypnos - Diorama Tile View

 The two-layer diorama (blurred-subject backdrop, cut-out subject lifted
 `lift` points forward) as one RealityView instead of two SwiftUI layers at
 different `offset(z:)`s. Same reason as `DepthTileView`: the gaze hover
 scales a cell as one 2D layer, and two layers at different depths slid
 against each other under it (device, 2026-10-07, worst in the square grid).
 Inside one RealityView the pair scales as one unit.

 Shares `DepthMesh`'s crop-and-round texture path, so both panels show
 exactly the cell's visible region, and the same input and z-fight rules
 (see the cell in `GalleryThumbnailView`).
 */

#if os(visionOS)
import DebugTraceUI
import RealityKit
import SwiftUI

struct DioramaTileView: View {
    let backdrop: UIImage
    let foreground: UIImage
    let size: CGSize

    @PatchRefresh var patchRefresh
    @Environment(\.physicalMetrics) private var metrics
    @State private var ready = false

    /// How far the subject floats in front of the backdrop, in points.
    nonisolated static let lift: CGFloat = 24

    var body: some View {
        let widthMeters = Float(metrics.convert(size.width, to: .meters))
        let heightMeters = Float(metrics.convert(size.height, to: .meters))
        let pointMeters = Float(metrics.convert(1, to: .meters))
        ZStack {
            if !ready {
                Image(platformImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: DepthTileView.cornerRadius))
            }
            RealityView { content in
                guard let entity = await Self.makeEntity(
                    backdrop: backdrop, foreground: foreground, size: size,
                    widthMeters: widthMeters, heightMeters: heightMeters, pointMeters: pointMeters
                ) else { return }
                content.add(entity)
                ready = true
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
        .id(size)
    }

    private struct Textures: @unchecked Sendable {
        let backdrop: CGImage
        let foreground: CGImage
    }

    @MainActor
    private static func makeEntity(
        backdrop: UIImage, foreground: UIImage, size: CGSize,
        widthMeters: Float, heightMeters: Float, pointMeters: Float
    ) async -> Entity? {
        guard let bg = backdrop.cgImage, let fg = foreground.cgImage, size.width > 0, size.height > 0 else { return nil }
        let rendered = await Task.detached(priority: .userInitiated) { () -> Textures? in
            // The pair is uncropped and shares one frame, so one crop fits both.
            let crop = DepthMesh.fillCrop(imageWidth: CGFloat(bg.width), imageHeight: CGFloat(bg.height), cell: size)
            guard let bgTexture = DepthMesh.renderTexture(bg, crop: crop, cell: size, cornerRadius: DepthTileView.cornerRadius),
                  let fgTexture = DepthMesh.renderTexture(fg, crop: crop, cell: size, cornerRadius: DepthTileView.cornerRadius, edgeFade: DepthTileView.edgeFalloff)
            else { return nil }
            return Textures(backdrop: bgTexture, foreground: fgTexture)
        }.value
        guard let rendered,
              let bgPanel = await panel(rendered.backdrop, width: widthMeters, height: heightMeters, order: 0),
              let fgPanel = await panel(rendered.foreground, width: widthMeters, height: heightMeters, order: 1)
        else { return nil }
        // Both off the window plane, where the cell's own fill would be drawn.
        bgPanel.position.z = pointMeters
        fgPanel.position.z = pointMeters * Float(1 + lift)
        let root = Entity()
        root.addChild(bgPanel)
        root.addChild(fgPanel)
        return root
    }

    private static let sortGroup = ModelSortGroup(depthPass: nil)

    @MainActor
    private static func panel(_ image: CGImage, width: Float, height: Float, order: Int32) async -> ModelEntity? {
        guard let texture = try? await TextureResource(
            image: image,
            options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)
        ) else { return nil }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: DepthMesh.clampedTexture(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        let entity = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
        // Both panels are transparent; the subject must always draw over the
        // backdrop, whatever RealityKit's depth sort decides at grazing angles.
        entity.components.set(ModelSortGroupComponent(group: sortGroup, order: order))
        return entity
    }
}
#endif
