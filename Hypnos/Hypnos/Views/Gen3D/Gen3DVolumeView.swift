//
//  Gen3DVolumeView.swift
//  Hypnos
//
//  Sideload/dev-only (HYPNOS_GEN3D), visionOS: a picture turned into a model by
//  Gen3DServer, in a volume of its own. Sized and turned with the same rules as
//  every RAVE app's 3D windows (`RAVEVolumeFit`, `RAVEModelTurn`): life size by
//  default, clamped (and saying so) when it won't fit; drag it round or step it
//  with the ornament's buttons.
//

#if HYPNOS_GEN3D && os(visionOS)

import RAVEUI
import RealityKit
import SwiftUI

/// The scene's value: which picture to make a model of. A fresh id per opening
/// so each is its own window.
struct Gen3DWindowValue: Identifiable, Codable, Hashable {
    let id: UUID
    var image: GalleryImage

    init(image: GalleryImage) {
        self.id = UUID()
        self.image = image
    }

    static func == (a: Gen3DWindowValue, b: Gen3DWindowValue) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Gen3DVolumeView: View {
    let value: Gen3DWindowValue

    @State private var generator = Gen3DGenerator()
    @State private var size = RAVEModelSize.life
    @State private var fit: RAVEVolumeFit?
    @State private var model: Entity?
    @State private var loadFailure: String?
    @State private var yaw: Float = 0

    var body: some View {
        // Read here, not only in `update`, so a model that `make` loaded causes
        // a fit pass (see AnythingUSDZ's VolumePreview).
        let current = model
        return GeometryReader3D { proxy in
            RealityView { content in
                // The model arrives later; `update` adds it once the generator is ready.
            } update: { content in
                guard let current else { return }
                if current.parent == nil { content.add(current) }
                place(current, in: content, proxy: proxy)
            }
            .raveModelTurnGesture(yaw: $yaw)
        }
        .overlay { statusOverlay }
        .ornament(attachmentAnchor: .scene(.bottomFront), contentAlignment: .top) {
            if model != nil {
                HStack(spacing: 14) {
                    RAVEModelTurnControls(yaw: $yaw)
                    Divider().frame(height: 28)
                    RAVEModelSizePicker(size: $size, fit: fit)
                }
                .padding(12)
                .glassBackgroundEffect()
            }
        }
        .task { await generator.run(for: value.image) }
        .task(id: generator.phase) {
            guard case .ready(let url) = generator.phase, model == nil else { return }
            do {
                let entity = try await Entity(contentsOf: url)
                RAVEModelTurn.makeTurnable(entity)
                model = entity
            } catch {
                loadFailure = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        if let loadFailure {
            ContentUnavailableView("RealityKit Couldn't Open It", systemImage: "exclamationmark.triangle",
                                   description: Text(loadFailure))
        } else if model == nil {
            switch generator.phase {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Generate It", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await generator.run(for: value.image) } }
                }
            case .generating(let stage, let fraction):
                VStack(spacing: 10) {
                    if let fraction { ProgressView(value: fraction) { Text(Self.label(stage)) }.frame(width: 260) }
                    else { ProgressView { Text(Self.label(stage)) } }
                    Text("Takes about two minutes. You can close this and come back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24).glassBackgroundEffect()
            default:
                ProgressView { Text(Self.label(nil, phase: generator.phase)) }
                    .padding(24).glassBackgroundEffect()
            }
        }
    }

    private static func label(_ stage: String?, phase: Gen3DGenerator.Phase = .idle) -> String {
        switch phase {
        case .loadingPicture: return "Loading the picture…"
        case .uploading: return "Sending it to the server…"
        case .downloading: return "Downloading the model…"
        case .converting: return "Preparing it for RealityKit…"
        case .ready: return "Opening…"
        default: break
        }
        switch stage {
        case "queued": return "Waiting for the server…"
        case "generate": return "Generating the 3D model…"
        case "export": return "Building the mesh and textures…"
        case .some(let other): return other.capitalized + "…"
        case nil: return "Working…"
        }
    }

    /// Turns the model, then sizes it and stands it on the volume's floor.
    private func place(_ entity: Entity, in content: RealityViewContent, proxy: GeometryProxy3D) {
        let volume = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
        let result = RAVEVolumeFit.apply(to: entity, in: volume, size: size, anchor: .footprintCenter, yaw: yaw)
        if result != fit { Task { fit = result } }
    }
}

#endif
