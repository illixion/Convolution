/*
 Hypnos - Welcome Sample

 The bundled sample photo, and the control that converts it to spatial 3D.

 Two views over one model, because the welcome panel puts the picture down the
 left side and the words and controls down the right — so the image and its
 switch are laid out separately and cannot be one view.

 **Flat is a plain SwiftUI image; only 3D mounts RealityKit.** That mirrors what
 the photo viewer does, and it is also the fix for two things the first version
 got wrong on device: a `RealityView` floats its contents about 15cm proud of
 the window plane (a zero-depth slab still gets placed in the middle of the
 window's depth region), and a `RealityView` draws nothing behind its content,
 so the photo appeared to hover with the tab underneath showing through. A flat
 `Image` has neither problem, and nothing about RealityKit is touched until the
 user actually asks for 3D.

 The conversion is the real pipeline — the same `Spatial3DImage.generate()` the
 viewer runs — rather than a crossfade between two baked images. A canned
 before/after is the one thing a first-run screen must not do, since the app has
 to reproduce the result on the user's own photos; watching depth build at this
 device's actual speed is the honest version of the pitch.
 */

import DebugTrace
import RealityKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

@MainActor
@Observable
final class WelcomeSampleModel {

    enum Stage: Equatable {
        /// Decoding the flat preview.
        case loading
        /// Showing the flat photo, ready to convert.
        case flat
        /// `generate()` in flight; RealityKit is mounted.
        case converting
        /// Generated; the control is a flat/3D switch.
        case ready
        /// No sample bundled, or it could not be read.
        case unavailable
    }

    private(set) var stage: Stage = .loading
    /// Which way the switch is thrown once `stage == .ready`.
    var showing3D = true
    /// Set while a generated component exists, so the flat side of the switch
    /// can unmount RealityKit without discarding the work.
    private(set) var hasGenerated = false
    private(set) var flatImage: UIImage?
    private(set) var aspectRatio: CGFloat = 3.0 / 4.0

    /// True when RealityKit should be on screen rather than the flat image.
    var isShowingRealityKit: Bool {
        stage == .converting || (stage == .ready && showing3D)
    }

    let entity = Entity()
    private var spatial3DImage: ImagePresentationComponent.Spatial3DImage?

    /// Decodes the flat preview. Cheap, and touches nothing 3D.
    func loadFlatImage() async {
        guard stage == .loading else { return }
        guard let url = WelcomeSample.url() else {
            stage = .unavailable
            return
        }
        // Same downsampling path the grids use, so the sample costs about what
        // one thumbnail costs rather than decoding 2800px for a 500pt slot.
        flatImage = await ImageLoader.shared.loadThumbnail(from: url, maxSize: 1600)
        if let flatImage, flatImage.size.height > 0 {
            aspectRatio = flatImage.size.width / flatImage.size.height
        }
        stage = flatImage == nil ? .unavailable : .flat
    }

    /// Builds the presentation component and generates the depth scene.
    ///
    /// Called from inside the `RealityView` make closure: `generate()` needs its
    /// target attached to a scene, and the component has to exist before
    /// anything tries to scale it.
    func prepareAndGenerate() async {
        guard stage == .converting else { return }
        guard let url = WelcomeSample.url() else {
            stage = .unavailable
            return
        }

        do {
            if spatial3DImage == nil {
                let image = try await ImagePresentationComponent.Spatial3DImage(contentsOf: url)
                var component = ImagePresentationComponent(spatial3DImage: image)
                // Set before generating so the build-in has something to
                // animate into — the ordering the photo viewer relies on.
                component.desiredViewingMode = .spatial3D
                entity.components.set(component)
                spatial3DImage = image
            }
            guard let spatial3DImage else { return }
            try await spatial3DImage.generate()
            hasGenerated = true
            showing3D = true
            stage = .ready
        } catch {
            AppLogger.settings.error("Welcome sample conversion failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            // Back to flat rather than to an error state: a failed demo should
            // still show the photograph.
            stage = .flat
        }
    }

    func beginConversion() {
        guard stage == .flat else { return }
        stage = .converting
    }

    /// Applies the switch position to the live component.
    func applyViewingMode() {
        guard stage == .ready, hasGenerated else { return }
        guard var component = entity.components[ImagePresentationComponent.self] else { return }
        let mode: ImagePresentationComponent.ViewingMode = showing3D ? .spatial3D : .mono
        guard component.viewingMode != mode else { return }
        component.desiredViewingMode = mode
        entity.components.set(component)
    }

    /// Scales the presentation to fit the space the view gave it, in meters.
    ///
    /// `min` on both axes, so spatial 3D — whose presentation is wider than the
    /// flat image's — letterboxes inside the slot instead of overflowing it. The
    /// first version also drove the container's `.aspectRatio` from the 3D
    /// ratio, which widened the box and pushed content out of frame.
    func fit(in boundsInMeters: BoundingBox) {
        guard let component = entity.components[ImagePresentationComponent.self] else { return }
        let screen = component.presentationScreenSize
        guard screen.x > 0, screen.y > 0 else { return }
        let scale = min(boundsInMeters.extents.x / screen.x,
                        boundsInMeters.extents.y / screen.y)
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }
}

// MARK: - Picture

/// The sample photograph, flat or in spatial 3D, filling whatever it is given.
struct WelcomeSampleImage: View {
    let model: WelcomeSampleModel

    /// How far back the RealityKit slab is pushed to sit on the panel's plane.
    ///
    /// Same problem and same shape as `Pseudo3DVideoPlayerView`'s
    /// `videoPlaneZRecess`: a front-aligned zero-depth slab measures several
    /// centimetres proud of the chrome on device. Tunable in one place.
    private let planeZRecess: CGFloat = 90

    var body: some View {
        ZStack {
            // A dark mat, so letterboxing on either side of a portrait photo
            // reads as framing rather than as a gap.
            Color.black.opacity(0.35)

            switch model.stage {
            case .loading:
                ProgressView()
            case .unavailable:
                MissingSampleCard()
            default:
                #if os(visionOS)
                if model.isShowingRealityKit {
                    spatialImage
                } else if let image = model.flatImage {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                #else
                // No RealityKit path on iOS — the sample stays flat; the
                // Convert control never enters `.converting`/`.ready` (see
                // WelcomeSampleControls) so `isShowingRealityKit` never asks
                // for it anyway.
                if let image = model.flatImage {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                #endif
            }
        }
        .task { await model.loadFlatImage() }
    }

    #if os(visionOS)
    private var spatialImage: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                await model.prepareAndGenerate()
                if model.entity.parent == nil {
                    content.add(model.entity)
                }
                model.fit(in: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
            } update: { content in
                model.fit(in: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
            }
        }
        .frame(depth: 0, alignment: .front)
        .offset(z: -planeZRecess)
        .overlay {
            if model.stage == .converting {
                ProgressView()
            }
        }
    }
    #endif
}

// MARK: - Control

/// The convert button, and afterwards the flat/3D switch.
struct WelcomeSampleControls: View {
    let model: WelcomeSampleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.stage {
            case .loading:
                EmptyView()

            case .flat:
                if PlatformCapabilities.supportsSpatial3D {
                    Button {
                        model.beginConversion()
                    } label: {
                        Label("Convert to 3D", systemImage: "cube.transparent")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier(A11y.Welcome.sampleConvert)
                } else {
                    Text("Spatial 3D conversion is available on Apple Vision Pro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .converting:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Building depth…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11y.Welcome.sampleProgress)

            case .ready:
                Picker("Viewing mode", selection: Binding(
                    get: { model.showing3D },
                    set: { model.showing3D = $0; model.applyViewingMode() }
                )) {
                    Text("Flat").tag(false)
                    Text("Spatial 3D").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                .accessibilityIdentifier(A11y.Welcome.sampleModePicker)

                Text("Lean in — the depth is real, not a parallax trick.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .unavailable:
                EmptyView()
            }
        }
        .animation(.smooth(duration: 0.25), value: model.stage)
    }
}

/// Shown in place of the photo when no sample is bundled, so a missing asset
/// reads as intentional rather than broken.
struct MissingSampleCard: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Any flat photo becomes a window you can look into.")
                .font(.title3)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
