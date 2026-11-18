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

    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow

    @State private var generator = Gen3DGenerator()
    @State private var size = Gen3DSize.life
    @State private var fit: Gen3DFit?
    @State private var engine = Gen3DConfig.engine
    @State private var engines: [String] = []
    @State private var loadedURL: URL?
    @State private var lightEntity: Entity?
    @AppStorage(Gen3DConfig.lightingKey, store: HypnosDefaults.store) private var lightingRaw = Gen3DLighting.natural.rawValue
    private var lighting: Gen3DLighting { Gen3DLighting(rawValue: lightingRaw) ?? .natural }
    @State private var model: Entity?
    @State private var loadFailure: String?
    @State private var yaw: Float = 0
    /// Decor mode: no control panel, baseplate or system overlays. Double-tap the
    /// model to bring them back (or switch them on again in Settings).
    @AppStorage(Gen3DConfig.decorKey, store: HypnosDefaults.store) private var decor = false

    var body: some View {
        // Read here, not only in `update`, so a model that `make` loaded causes
        // a fit pass (see AnythingUSDZ's VolumePreview).
        let current = model
        return GeometryReader3D { proxy in
            RealityView { content in
                // The model arrives later; `update` adds it once the generator is ready.
                // One light source, an even sky, that the model is lit by when asked.
                if let environment = try? await EnvironmentResource(equirectangular: Gen3DLighting.sky) {
                    let light = Entity()
                    light.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0))
                    content.add(light)
                    lightEntity = light
                }
            } update: { content in
                guard let current else { return }
                if current.parent == nil { content.add(current) }
                place(current, in: content, proxy: proxy)
                applyLighting(to: current)
                applyHoverEffect(to: current)
            }
            .raveModelTurnGesture(yaw: $yaw)
            .gesture(TapGesture(count: 2).targetedToAnyEntity().onEnded { _ in decor.toggle() })
        }
        .overlay { statusOverlay }
        .volumeBaseplateVisibility(decor ? .hidden : .automatic)
        .persistentSystemOverlays(decor ? .hidden : .automatic)
        .ornament(attachmentAnchor: .scene(.topFront), contentAlignment: .bottom) {
            if !decor {
                HStack(spacing: 14) {
                    // Every utility window has a way back to the app's main window.
                    PlayerHomeButton(title: "Gallery", help: "Show the app's home screen") {
                        appModel.showMainWindow(openWindow: openWindow)
                    }
                    if model != nil {
                        Divider().frame(height: 28)
                        controls
                    }
                }
                .padding(12)
                .glassBackgroundEffect()
            }
        }
        .task(id: engine) { await generator.run(for: value.image, engine: engine) }
        .task { engines = (try? await Gen3DClient().engines()) ?? [] }
        .task(id: generator.phase) {
            guard case .ready(let url) = generator.phase, url != loadedURL else { return }
            do {
                let entity = try await Entity(contentsOf: url)
                RAVEModelTurn.makeTurnable(entity)
                // Swap, not stack: the previous engine's model leaves the scene.
                model?.removeFromParent()
                model = entity
                loadedURL = url
                loadFailure = nil
            } catch is CancellationError {
                // The phase changed under it; the next run of this task loads it.
            } catch {
                guard !Task.isCancelled else { return }
                loadFailure = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 14) {
            RAVEModelTurnControls(yaw: $yaw)
            Divider().frame(height: 28)
            Gen3DSizePicker(size: $size, fit: fit)
            Divider().frame(height: 28)
            Picker("Lighting", selection: $lightingRaw) {
                ForEach(Gen3DLighting.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if engines.count > 1 {
                Divider().frame(height: 28)
                Picker("Engine", selection: $engine) {
                    ForEach(engines, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            if generator.isWorking {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        if model == nil, let loadFailure {
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

    /// The gaze highlight is for a model being handled; as decor it stays off.
    /// (The entity keeps its input target, so a drag still turns it and a
    /// double-tap still brings the controls back.)
    private func applyHoverEffect(to entity: Entity) {
        if decor {
            if entity.components[HoverEffectComponent.self] != nil { entity.components.remove(HoverEffectComponent.self) }
        } else if entity.components[HoverEffectComponent.self] == nil {
            entity.components.set(HoverEffectComponent())
        }
    }

    /// Lights the model from the even sky, or leaves it to the volume's own light.
    private func applyLighting(to entity: Entity) {
        guard let light = lightEntity else { return }
        if let exponent = lighting.exponent {
            light.components.set(ImageBasedLightComponent(
                source: light.components[ImageBasedLightComponent.self]?.source ?? .none,
                intensityExponent: exponent))
            if entity.components[ImageBasedLightReceiverComponent.self] == nil {
                entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
            }
        } else if entity.components[ImageBasedLightReceiverComponent.self] != nil {
            entity.components.remove(ImageBasedLightReceiverComponent.self)
        }
    }

    /// Turns the model, then sizes it and stands it on the volume's floor.
    private func place(_ entity: Entity, in content: RealityViewContent, proxy: GeometryProxy3D) {
        let volume = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
        let result = Gen3DFit.apply(to: entity, in: volume, size: size, yaw: yaw)
        if result != fit { Task { fit = result } }
    }
}

/// How the model is lit. A generated model is often dark under the volume's own
/// light; the others light it from an even sky, brighter each step.
enum Gen3DLighting: String, CaseIterable, Identifiable {
    case natural, bright, brighter, brightest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .natural: return "Natural light"
        case .bright: return "Bright"
        case .brighter: return "Brighter"
        case .brightest: return "Brightest"
        }
    }

    /// `nil` leaves the volume's light alone.
    var exponent: Float? {
        switch self {
        case .natural: return nil
        case .bright: return 0.8
        case .brighter: return 1.6
        case .brightest: return 2.4
        }
    }

    /// A soft grey sky, lighter overhead, as an equirectangular picture.
    static let sky: CGImage = {
        let size = CGSize(width: 512, height: 256)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.85, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        return context.makeImage()!
    }()
}

/// How big to draw the model. Multiples of its real size, up to what the volume
/// holds: make the window bigger to unlock the larger ones.
enum Gen3DSize: String, CaseIterable, Identifiable {
    case half, life, double, triple, quadruple, fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .half: return "50%"
        case .life: return "Life size"
        case .double: return "2×"
        case .triple: return "3×"
        case .quadruple: return "4×"
        case .fit: return "Fill window"
        }
    }

    /// `nil` fills the volume.
    var scale: Float? {
        switch self {
        case .half: return 0.5
        case .life: return 1
        case .double: return 2
        case .triple: return 3
        case .quadruple: return 4
        case .fit: return nil
        }
    }
}

struct Gen3DFit: Equatable {
    var scale: Float
    var clamped: Bool
    var drawnHeight: Float

    /// Fits each axis to its own side of the volume. (RAVEVolumeFit compares the
    /// model's larger footprint side with the volume's smaller one, which leaves
    /// a wide model in a wide, shallow volume small, with empty space around it.)
    @MainActor
    static func apply(to entity: Entity, in volume: BoundingBox, size: Gen3DSize, yaw: Float) -> Gen3DFit {
        entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        entity.scale = .one
        entity.position = .zero
        var space = volume
        if let parent = entity.parent {
            let a = parent.convert(position: volume.min, from: nil)
            let b = parent.convert(position: volume.max, from: nil)
            space = BoundingBox(min: min(a, b), max: max(a, b))
        }
        let model = entity.visualBounds(relativeTo: entity.parent)
        let e = model.extents, v = space.extents
        let fitting = min(v.y / max(e.y, 0.01), v.x / max(e.x, 0.01), v.z / max(e.z, 0.01))
        let wanted = size.scale ?? fitting
        let scale = min(wanted, fitting)
        let center = (model.min + model.max) / 2
        entity.scale = SIMD3(repeating: scale)
        entity.position = SIMD3(
            (space.min.x + space.max.x) / 2 - center.x * scale,
            space.min.y - model.min.y * scale,
            (space.min.z + space.max.z) / 2 - center.z * scale)
        return Gen3DFit(scale: scale, clamped: wanted > fitting * 1.01, drawnHeight: e.y * scale)
    }
}

struct Gen3DSizePicker: View {
    @Binding var size: Gen3DSize
    var fit: Gen3DFit?

    var body: some View {
        HStack(spacing: 8) {
            Picker("Size", selection: $size) {
                ForEach(Gen3DSize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if let fit {
                Text(fit.drawnHeight >= 1 ? String(format: "%.2f m", fit.drawnHeight) : String(format: "%.0f cm", fit.drawnHeight * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(fit.clamped ? Color.orange : Color.secondary)
                    .help(fit.clamped ? "The window is too small for this size: make it bigger." : "How tall the model is being drawn.")
            }
        }
    }
}

#endif
