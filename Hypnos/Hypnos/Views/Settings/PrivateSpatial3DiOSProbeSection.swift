//
//  PrivateSpatial3DiOSProbeSection.swift
//  Hypnos
//
//  GitHub-only build feature, compiled out unless HYPNOS_PRIVATE_API is set.
//

#if HYPNOS_PRIVATE_API && os(iOS)

import Photos
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

/// Developer probe for `PrivateSpatial3DiOS`.
///
/// What it has established so far, on an iPhone 15 Pro Max running iOS 26:
///
///   * `Spatial3DImage.generate()` — 2D→3D conversion — is refused with
///     `Missing entitlement: com.apple.modelmanager.inference`, which no
///     third-party profile grants (signing it in fails the install outright
///     with CoreDeviceError 3002).
///   * `ImagePresentationComponent(contentsOf:)` on a photo that is *already*
///     spatial succeeds and reports its viewing modes, so presentation is not
///     behind that entitlement.
///
/// The open question is whether RealityKit will actually *draw* it on a flat
/// display. The first attempt rendered garbage while logging
/// `setupRENetworkCallbacks failed - scene count is zero`, because the
/// component was set on an entity that was not yet in a scene — this version
/// adds the entity first and attaches afterwards, and carries its own camera,
/// which a non-AR `RealityView` does not supply.
struct PrivateSpatial3DiOSProbeSection: View {
    @State private var state = ProbeState.idle
    @State private var isPresentingScene = false
    @State private var spatialURL: URL?
    @State private var mode = PrivateSpatial3DiOS.Mode.spatialStereo

    private enum ProbeState: Equatable {
        case idle
        case running
        case failed(String)
        case noSample
        case foundSpatialPhoto
        case noSpatialAsset
    }

    var body: some View {
        Section("Spatial 3D (iOS, private)") {
            Button {
                Task { await probeGeneration() }
            } label: {
                Label("Generate From Welcome Sample", systemImage: "cube.transparent")
            }
            .disabled(state == .running)

            Button {
                Task { await findSpatialPhoto() }
            } label: {
                Label("Find a Spatial Photo", systemImage: "person.and.background.dotted")
            }
            .disabled(state == .running)

            // The control. Same component, same code path, but an ordinary
            // flat photo in mono — the one mode every file supports. If this
            // also renders the magenta placeholder then iOS has no renderer
            // for ImagePresentationComponent at all and the spatial modes are
            // beside the point; if it shows the picture, the renderer is there
            // and only the spatial modes are missing.
            Button {
                spatialURL = WelcomeSample.url()
                mode = .mono
                state = spatialURL == nil ? .noSample : .foundSpatialPhoto
            } label: {
                Label("Control: Flat Photo, Mono", systemImage: "photo")
            }
            .disabled(state == .running)

            switch state {
            case .idle:
                caption("ImagePresentationComponent is marked unavailable on iOS but fully exported. This calls it anyway.")
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Working…")
                }
            case .foundSpatialPhoto:
                Picker("Viewing Mode", selection: $mode) {
                    Text("Mono").tag(PrivateSpatial3DiOS.Mode.mono)
                    Text("Spatial 3D").tag(PrivateSpatial3DiOS.Mode.spatial3D)
                    Text("Spatial Stereo").tag(PrivateSpatial3DiOS.Mode.spatialStereo)
                }
                Button {
                    isPresentingScene = true
                } label: {
                    Label("Present It", systemImage: "eye")
                }
            case .failed(let message):
                caption("Failed: \(message)")
            case .noSample:
                caption("No welcome sample is bundled in this build.")
            case .noSpatialAsset:
                caption("No spatial photo found in the library.")
            }

            if PrivateSpatial3DiOS.lastViewingModeCount > 0 {
                caption("Last attach reported \(PrivateSpatial3DiOS.lastViewingModeCount) viewing modes.")
            }
        }
        .fullScreenCover(isPresented: $isPresentingScene) {
            if let spatialURL {
                SpatialProbeScene(url: spatialURL, mode: mode) {
                    isPresentingScene = false
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func probeGeneration() async {
        guard let url = WelcomeSample.url() else {
            state = .noSample
            return
        }
        state = .running
        do {
            _ = try await PrivateSpatial3DiOS.makeEntity(contentsOf: url, immersive: false)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func findSpatialPhoto() async {
        state = .running
        guard let url = await SpatialAssetLocator.firstSpatialPhotoURL() else {
            state = .noSpatialAsset
            return
        }
        spatialURL = url
        state = .foundSpatialPhoto
    }
}

// MARK: - Scene

/// Presents the component the way the visionOS path does: the entity goes into
/// the scene first, the component arrives afterwards.
private struct SpatialProbeScene: View {
    let url: URL
    let mode: PrivateSpatial3DiOS.Mode
    let onDone: () -> Void

    @State private var host = Entity()
    @State private var status = "Attaching…"

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            RealityView { content in
                content.add(host)
                // A non-AR RealityView on iOS brings no camera of its own, so
                // an entity at the origin sits inside the viewpoint.
                let camera = PerspectiveCamera()
                camera.position = [0, 0, 1]
                content.add(camera)
            }
            .ignoresSafeArea()

            HStack {
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .task {
            do {
                let size = try await PrivateSpatial3DiOS.attachPresentation(
                    contentsOf: url,
                    to: host,
                    mode: mode
                )
                // Fit the presentation into the camera's view at 1 m: a 60°
                // vertical field of view shows about 1.15 m there.
                if size.y > 0 {
                    let scale = 0.7 / size.y
                    host.scale = [scale, scale, 1]
                }
                status = PrivateSpatial3DiOS.lastDiagnostic
            } catch {
                status = "failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Locating a spatial photo

/// Finds a spatial photo in the library and spills it to a temp file, because
/// `ImagePresentationComponent(contentsOf:)` wants a URL and PhotoKit will only
/// hand over bytes.
private enum SpatialAssetLocator {
    @MainActor
    static func firstSpatialPhotoURL() async -> URL? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            PHAssetMediaSubtype.spatialMedia.rawValue
        )
        options.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let requestOptions = PHImageRequestOptions()
            requestOptions.isNetworkAccessAllowed = true
            requestOptions.version = .current
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: requestOptions
            ) { data, uti, _, _ in
                guard let data else { return continuation.resume(returning: nil) }
                let ext = (uti as String?).flatMap { UTType($0)?.preferredFilenameExtension } ?? "heic"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("spatial-probe.\(ext)")
                do {
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

#endif
