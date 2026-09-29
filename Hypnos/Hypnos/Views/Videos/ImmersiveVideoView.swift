/*
 Hypnos - Immersive Video View

 RealityKit-based immersive view for stereoscopic MV-HEVC video playback.
 Uses VideoMaterial with AVPlayer for true 3D rendering on Vision Pro.
 */

import AVKit
import CoreMedia
import DebugTrace
import RAVEMedia
import RealityKit
import SwiftUI

#if os(visionOS)

struct ImmersiveVideoView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var player: AVPlayer = AVPlayer()
    @State private var videoMaterial: VideoMaterial?
    @State private var videoEntity: Entity?
    @State private var endOfPlayObserver: NSObjectProtocol?
    @State private var isLoaded: Bool = false

    var body: some View {
        RealityView { content in
            guard let videoURL = appModel.immersiveVideoURL else {
                AppLogger.immersiveVideo.warning("No video URL available")
                return
            }

            let asset = AVURLAsset(url: videoURL)
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.applySpatialAudioPolicy()

            // Get video info for mesh generation
            guard let videoInfo = await getVideoInfo(asset: asset) else {
                AppLogger.immersiveVideo.error("Failed to get video info")
                return
            }

            // Generate mesh based on video dimensions
            guard let (mesh, transform) = await makeVideoMesh(videoInfo: videoInfo) else {
                AppLogger.immersiveVideo.error("Failed to create video mesh")
                return
            }

            // Create VideoMaterial with the player
            let material = VideoMaterial(avPlayer: player)
            videoMaterial = material

            // Set viewing mode based on override or auto-detect
            // Force 2D (override == false) uses mono to show only left eye
            if appModel.immersiveVideoOwner?.stereoscopicOverride == false {
                material.controller.preferredViewingMode = .mono
            } else {
                material.controller.preferredViewingMode = videoInfo.isSpatial ? .stereo : .mono
            }

            // Create entity with video mesh and material
            let entity = Entity()
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
            entity.transform = transform
            videoEntity = entity
            content.add(entity)

            // Start playback
            player.replaceCurrentItem(with: playerItem)
            player.applySpatialAudioPolicy(for: asset)
            player.play()
            isLoaded = true

            // Setup looping
            endOfPlayObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [player] _ in
                Task { @MainActor in
                    player.seek(to: .zero)
                    player.play()
                }
            }
        }
        .onDisappear {
            if let observer = endOfPlayObserver {
                NotificationCenter.default.removeObserver(observer)
                endOfPlayObserver = nil
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
            videoMaterial = nil
            videoEntity = nil
        }
        .onChange(of: appModel.immersiveVideoOwner?.stereoscopicOverride) { _, newValue in
            // Update viewing mode dynamically when user changes it
            guard let material = videoMaterial else { return }
            if newValue == false {
                material.controller.preferredViewingMode = .mono
            } else {
                material.controller.preferredViewingMode = .stereo
            }
        }
    }

    // MARK: - Video Info

    private func getVideoInfo(asset: AVAsset) async -> VideoInfo? {
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            AppLogger.immersiveVideo.error("No video track found")
            return nil
        }

        guard let (naturalSize, formatDescriptions, mediaCharacteristics) = try? await videoTrack.load(
            .naturalSize, .formatDescriptions, .mediaCharacteristics
        ),
              let formatDescription = formatDescriptions.first else {
            AppLogger.immersiveVideo.error("Failed to load video properties")
            return nil
        }

        let isSpatial = mediaCharacteristics.contains(.containsStereoMultiviewVideo)
        let projection = getProjection(formatDescription: formatDescription)

        return VideoInfo(
            size: naturalSize,
            isSpatial: isSpatial,
            projectionType: projection.projectionType,
            horizontalFieldOfView: projection.horizontalFieldOfView
        )
    }

    private func getProjection(formatDescription: CMFormatDescription) -> (projectionType: CMProjectionType?, horizontalFieldOfView: Float?) {
        var projectionType: CMProjectionType?
        var horizontalFieldOfView: Float?

        if let extensions = CMFormatDescriptionGetExtensions(formatDescription) as Dictionary? {
            if let projectionKind = extensions["ProjectionKind" as CFString] as? String {
                projectionType = projectionTypeFromString(projectionKind)
            }

            if let horizontalFieldOfViewValue = extensions[kCMFormatDescriptionExtension_HorizontalFieldOfView] as? UInt32 {
                horizontalFieldOfView = Float(horizontalFieldOfViewValue) / 1000.0
            }
        }

        return (projectionType, horizontalFieldOfView)
    }

    private func projectionTypeFromString(_ string: String) -> CMProjectionType? {
        switch string {
        case "Rectilinear": return .rectangular
        case "Equirectangular": return .equirectangular
        case "HalfEquirectangular": return .halfEquirectangular
        case "Fisheye": return .fisheye
        default: return nil
        }
    }

    // MARK: - Mesh Generation

    private func makeVideoMesh(videoInfo: VideoInfo) async -> (mesh: MeshResource, transform: Transform)? {
        let zDistance: Float = 50.0
        let horizontalFieldOfView = videoInfo.horizontalFieldOfView ?? 65.0

        if videoInfo.projectionType == .equirectangular || videoInfo.projectionType == .halfEquirectangular {
            // Generate sphere for equirectangular content
            guard let mesh = generateVideoSphere(
                radius: 10000.0,
                sourceHorizontalFov: horizontalFieldOfView,
                sourceVerticalFov: 180.0,
                clipHorizontalFov: horizontalFieldOfView,
                clipVerticalFov: 180.0,
                verticalSlices: 60,
                horizontalSlices: Int(horizontalFieldOfView) / 3
            ) else {
                return nil
            }

            let transform = Transform(
                scale: .init(x: 1, y: 1, z: 1),
                rotation: .init(angle: -Float.pi / 2, axis: .init(x: 0, y: 1, z: 0)),
                translation: .init(x: 0, y: 0, z: 0)
            )

            return (mesh, transform)
        } else {
            // Assume rectilinear - generate plane
            let width: Float = 1.0
            let height: Float = Float(videoInfo.size.height / videoInfo.size.width)

            let mesh = MeshResource.generatePlane(width: width, depth: height)

            let scale = calculateScaleFactor(
                videoWidth: width,
                videoHeight: height,
                zDistance: zDistance,
                fovDegrees: horizontalFieldOfView
            )

            let transform = Transform(
                scale: .init(x: scale, y: 1, z: scale),
                rotation: .init(angle: Float.pi / 2, axis: .init(x: 1, y: 0, z: 0)),
                translation: .init(x: 0, y: 0, z: -zDistance)
            )

            return (mesh, transform)
        }
    }

    private func calculateScaleFactor(videoWidth: Float, videoHeight: Float, zDistance: Float, fovDegrees: Float) -> Float {
        let fovRadians = fovDegrees * .pi / 180.0
        let halfWidthAtZDistance = zDistance * tan(fovRadians / 2.0)
        return 2.0 * halfWidthAtZDistance
    }

    private func generateVideoSphere(
        radius: Float,
        sourceHorizontalFov: Float,
        sourceVerticalFov: Float,
        clipHorizontalFov: Float,
        clipVerticalFov: Float,
        verticalSlices: Int,
        horizontalSlices: Int
    ) -> MeshResource? {
        // Vertices
        var vertices: [simd_float3] = Array(repeating: simd_float3(), count: (verticalSlices + 1) * (horizontalSlices + 1))

        let verticalScale: Float = clipVerticalFov / 180.0
        let verticalOffset: Float = (1.0 - verticalScale) / 2.0

        let horizontalScale: Float = clipHorizontalFov / 360.0
        let horizontalOffset: Float = (1.0 - horizontalScale) / 2.0

        for y in 0...horizontalSlices {
            let angle1 = ((Float.pi * (Float(y) / Float(horizontalSlices))) * verticalScale) + (verticalOffset * Float.pi)
            let sin1 = sin(angle1)
            let cos1 = cos(angle1)

            for x in 0...verticalSlices {
                let angle2 = ((Float.pi * 2 * (Float(x) / Float(verticalSlices))) * horizontalScale) + (horizontalOffset * Float.pi * 2)
                let sin2 = sin(angle2)
                let cos2 = cos(angle2)

                vertices[x + (y * (verticalSlices + 1))] = SIMD3<Float>(sin1 * cos2 * radius, cos1 * radius, sin1 * sin2 * radius)
            }
        }

        // Normals (inverted to show on inside of sphere)
        var normals: [SIMD3<Float>] = []
        for vertex in vertices {
            normals.append(-normalize(vertex))
        }

        // UVs
        var uvCoordinates: [simd_float2] = Array(repeating: simd_float2(), count: vertices.count)

        let uvHorizontalScale = clipHorizontalFov / sourceHorizontalFov
        let uvHorizontalOffset = (1.0 - uvHorizontalScale) / 2.0
        let uvVerticalScale = clipVerticalFov / sourceVerticalFov
        let uvVerticalOffset = (1.0 - uvVerticalScale) / 2.0

        for y in 0...horizontalSlices {
            for x in 0...verticalSlices {
                var uv: simd_float2 = [Float(x) / Float(verticalSlices), 1.0 - (Float(y) / Float(horizontalSlices))]
                uv.x = (uv.x * uvHorizontalScale) + uvHorizontalOffset
                uv.y = (uv.y * uvVerticalScale) + uvVerticalOffset
                uvCoordinates[x + (y * (verticalSlices + 1))] = uv
            }
        }

        // Indices / triangles
        var indices: [UInt32] = []
        for y in 0..<horizontalSlices {
            for x in 0..<verticalSlices {
                let current = UInt32(x) + (UInt32(y) * UInt32(verticalSlices + 1))
                let next = current + UInt32(verticalSlices + 1)

                indices.append(current + 1)
                indices.append(current)
                indices.append(next + 1)

                indices.append(next + 1)
                indices.append(current)
                indices.append(next)
            }
        }

        var meshDescriptor = MeshDescriptor(name: "videoSphereMesh")
        meshDescriptor.positions = MeshBuffer(vertices)
        meshDescriptor.normals = MeshBuffer(normals)
        meshDescriptor.primitives = .triangles(indices)
        meshDescriptor.textureCoordinates = MeshBuffer(uvCoordinates)

        return try? MeshResource.generate(from: [meshDescriptor])
    }
}

// MARK: - Video Info Helper

private struct VideoInfo {
    let size: CGSize
    let isSpatial: Bool
    let projectionType: CMProjectionType?
    let horizontalFieldOfView: Float?
}

#endif
