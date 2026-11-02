/*
 Hypnos - HDR Test Plane (debug)

 `photoHDRTest dotsRK`: the HDR test pattern on a RealityKit unlit plane, to
 find out whether a RealityKit material shows values above SDR white in a
 window. If it does, AI 3D could draw its eyes through a material instead of
 VideoPlayerComponent, whose HLG rendering mutes highlights. The texture
 semantic and RealityKit's tone map are tunables (`ai3d.rkSemantic`,
 `ai3d.rkToneMap`), so each combination can be tried without a rebuild.
 */

#if os(visionOS)
import DebugTrace
import RealityKit
import SwiftUI

struct HDRTestPlaneView: View {
    let image: CGImage
    @Environment(\.physicalMetrics) private var metrics
    @State private var root = Entity()

    static var semantic: String {
        DebugTunables.choice("ai3d.rkSemantic", "hdrColor", choices: ["hdrColor", "color", "raw"],
                             label: "RealityKit test: texture semantic")
    }
    static var toneMap: Bool {
        DebugTunables.boolean("ai3d.rkToneMap", false, label: "RealityKit test: post-process tone map")
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            RealityView { content in
                content.add(root)
            }
            .task(id: BuildKey(width: Int(size.width), height: Int(size.height),
                               semantic: Self.semantic, toneMap: Self.toneMap, revision: DebugTunables.revision)) {
                await build(size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private struct BuildKey: Hashable {
        let width: Int
        let height: Int
        let semantic: String
        let toneMap: Bool
        let revision: Int
    }

    private func build(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        let semantic: TextureResource.Semantic = switch Self.semantic {
        case "color": .color
        case "raw": .raw
        default: .hdrColor
        }
        guard let texture = try? await TextureResource(image: image, options: .init(semantic: semantic)) else {
            AppLogger.photoWindow.error("HDR test plane: texture creation failed")
            return
        }
        var material = UnlitMaterial(applyPostProcessToneMap: Self.toneMap)
        material.color = .init(tint: .white, texture: .init(texture))
        let width = Float(metrics.convert(size.width, to: .meters))
        let height = Float(metrics.convert(size.height, to: .meters))
        let plane = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
        // Just in front of the flat picture, which keeps sizing the window.
        plane.position.z = Float(metrics.convert(2, to: .meters))
        root.children.removeAll()
        root.addChild(plane)
        AppLogger.photoWindow.info("HDR test plane: semantic \(Self.semantic, privacy: .public), tone map \(Self.toneMap, privacy: .public)")
    }
}
#endif
