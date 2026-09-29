//
//  PrivateSpatial3DiOS.swift
//  Hypnos
//
//  GitHub-only build feature. Compiled out entirely unless the
//  HYPNOS_PRIVATE_API compilation condition is set (see
//  scripts/build-signing.conf). App Store builds must never define it: the
//  code below calls API that Apple marks unavailable on this platform.
//

#if HYPNOS_PRIVATE_API && !os(visionOS)

import DebugTrace
import Foundation
import RealityKit

// MARK: - Why this file exists
//
// `ImagePresentationComponent` — RealityKit's 2D→spatial-3D converter and
// presenter, the thing the whole Spatial 3D feature is built on — is declared
// `@available(iOS, unavailable)`. That reads like "does not exist on iPhone",
// and it is the reason `PlatformShims.swift` gives iOS a null object instead.
//
// It is not true at the binary level. Every symbol of the type is exported by
// the iOS build of RealityFoundation and listed in the SDK's own .tbd — 165 of
// them, including `Spatial3DImage.init(contentsOf:)`, `generate()`,
// `init(spatial3DImage:)` and the `ViewingMode` cases. The iPhone plainly runs
// this code already: the Lock Screen's spatial wallpaper and the Photos app's
// spatial scenes are the same conversion, presented with motion parallax
// instead of stereo. What is missing is permission to compile against it, not
// the implementation.
//
// MARK: How the availability is laundered
//
// Swift allows an unavailable declaration to *use* unavailable API — an
// `@available(iOS, unavailable)` function body sees the real type. It just
// cannot be called from available code. So each entry point is written twice:
// once as an unavailable definition that does the work, and once as an
// available `@_silgen_name` declaration bound to the same symbol. The linker
// joins them. No symbol beyond RealityFoundation's own published exports is
// referenced, and nothing here is reachable unless the build defines
// HYPNOS_PRIVATE_API.
//
// MARK: What this actually bought — nothing, and that is the finding
//
// Measured on an iPhone 15 Pro Max, iOS 26. The laundering works: everything
// below compiles, links and runs. The platform then declines in two separate
// places, and between them there is nothing left.
//
//   * **Generation is entitlement-gated.** `Spatial3DImage.generate()` fails
//     with `Missing entitlement: com.apple.modelmanager.inference`. That is an
//     Apple-private entitlement; no third-party profile carries it, and
//     signing it in anyway fails the *install* — `CoreDeviceError 3002` out of
//     `MICodeSigningVerifier`, before the app ever runs.
//
//   * **Presentation has no renderer.** `init(contentsOf:)` on a photo that is
//     already spatial succeeds without touching the model service: it parses
//     the file, reports `mono, spatialStereo, spatialStereoImmersive`, and
//     computes a correct `presentationScreenSize` (0.46 × 1.00 m for a
//     portrait capture). Attached to an entity already in a scene, RealityKit
//     draws the component's screen geometry — right aspect, right rounded
//     corners — filled with the **magenta placeholder material**. Asking for
//     `spatialStereo` silently yields `viewingMode == .mono`, and *mono draws
//     the placeholder too*. Mono is the case that is just "put the picture on
//     the quad", so this is not a missing stereo path; there is no content
//     render path at all on iOS.
//
// So the Lock Screen's spatial wallpaper is not reachable this way. Whatever
// draws it is not this component, or not this component's public geometry.
//
// The one runtime hazard worth remembering if this is ever revisited: reading
// the component **back off** an entity — `entity.components[…​.self]` — jumps
// to address 0 and kills the process with a CODESIGNING / Invalid Page fault.
// `components.set` is fine; it is the read-back that is unbacked. Everything
// here therefore reports out of band (see `lastDiagnostic`) rather than
// consulting the entity.
//
// Kept rather than deleted because the negative result is the expensive part:
// without it the obvious next idea is to try exactly this again.

enum PrivateSpatial3DiOS {

    /// Builds an entity presenting `url` as a generated spatial 3D scene.
    ///
    /// Returns an `Entity` rather than the component itself because the
    /// component's type cannot be named in available code — the entity is the
    /// narrowest handle that crosses the availability boundary.
    @MainActor
    static func makeEntity(contentsOf url: URL, immersive: Bool) async throws -> Entity {
        try await hypnosMakeSpatial3DEntity(url, immersive)
    }


    /// Which of the file's own views to present.
    enum Mode: Int {
        case mono = 0
        case spatial3D = 1
        case spatialStereo = 2
    }

    /// Attaches a presentation of a file that is **already** spatial — a
    /// stereo HEIC shot on an iPhone 15 Pro or later, or one imported from
    /// Vision Pro — to an entity that is **already in a scene**.
    ///
    /// Distinct from `makeEntity(contentsOf:immersive:)` on purpose: that one
    /// asks the system to *generate* depth, which on iOS is refused for want
    /// of `com.apple.modelmanager.inference`. This one only asks it to present
    /// views the file already carries, so it never reaches the model service.
    ///
    /// The entity must be in a scene before this is called. Setting the
    /// component on a loose entity logs `setupRENetworkCallbacks failed -
    /// scene count is zero` and renders garbage — the same order the visionOS
    /// path uses in `QuickLook3DView`, where `content.add(entity)` happens in
    /// the RealityView's make closure and the component arrives later.
    ///
    /// - Returns: the presentation's size in metres, or zero if the platform
    ///   has not laid it out yet.
    @MainActor
    @discardableResult
    static func attachPresentation(
        contentsOf url: URL,
        to entity: Entity,
        mode: Mode
    ) async throws -> SIMD2<Float> {
        try await hypnosAttachPresentation(url, entity, mode.rawValue)
    }

    /// Viewing modes reported for the most recent entity built above — the
    /// cheapest signal that the file had something spatial in it.
    ///
    /// Reported out of band rather than read back off the entity because
    /// reading it back means `entity.components[ImagePresentationComponent
    /// .self]`, and **that subscript is not backed at runtime on iOS**: it
    /// needs the component's `__coreComponentType` accessor, which the
    /// weakly-linked RealityFoundation resolves to null, so the call jumps to
    /// address 0 and the process dies with a CODESIGNING / Invalid Page fault
    /// (verified on iOS 26, iPhone 15 Pro Max). Everything else used here —
    /// both initialisers, `availableViewingModes` on the value,
    /// `components.set` — is backed. Do not reintroduce a read-back.
    @MainActor
    private(set) static var lastViewingModeCount = 0

    /// What the last attach reported, phrased for the probe's status line.
    /// On screen rather than only in os_log: device console streaming drops
    /// out the moment the app is killed or relaunched by hand, and this is
    /// the one line the whole investigation turns on.
    @MainActor
    private(set) static var lastDiagnostic = ""
}

/// Set from the laundered code below, which cannot hand an unavailable type
/// across the boundary but can perfectly well write an `Int`.
@MainActor
func hypnosRecordSpatial3DModeCount(_ count: Int) {
    PrivateSpatial3DiOS.setLastViewingModeCount(count)
}

extension PrivateSpatial3DiOS {
    @MainActor
    fileprivate static func setLastViewingModeCount(_ count: Int) {
        lastViewingModeCount = count
    }

    @MainActor
    fileprivate static func setLastDiagnostic(_ text: String) {
        lastDiagnostic = text
    }
}

/// Set from the laundered code below, for the same reason as the count.
@MainActor
func hypnosRecordSpatial3DDiagnostic(_ text: String) {
    PrivateSpatial3DiOS.setLastDiagnostic(text)
}

// MARK: - Laundered definitions
//
// Every reference is spelled `RealityKit.ImagePresentationComponent`.
// The app declares a null object of the same name for iOS in
// `PlatformShims.swift`, and an unqualified mention resolves to *that* — it
// compiles, generates nothing, and fails silently. Keep the qualification.

@available(iOS, unavailable)
@MainActor
@_silgen_name("hypnos_ios_make_spatial3d_entity")
private func makeSpatial3DEntityImpl(_ url: URL, _ immersive: Bool) async throws -> Entity {
    let image = try await RealityKit.ImagePresentationComponent.Spatial3DImage(contentsOf: url)
    try await image.generate()
    var component = RealityKit.ImagePresentationComponent(spatial3DImage: image)
    component.desiredViewingMode = immersive ? .spatial3DImmersive : .spatial3D
    let modes = component.availableViewingModes.count
    let entity = Entity()
    entity.components.set(component)
    hypnosRecordSpatial3DModeCount(modes)
    AppLogger.photoWindow.info("iOS spatial 3D generated — modes: \(modes, privacy: .public)")
    return entity
}

@available(iOS, unavailable)
@MainActor
@_silgen_name("hypnos_ios_attach_presentation")
private func attachPresentationImpl(_ url: URL, _ entity: Entity, _ mode: Int) async throws -> SIMD2<Float> {
    var component = try await RealityKit.ImagePresentationComponent(contentsOf: url)
    let modes = component.availableViewingModes
    let desired: RealityKit.ImagePresentationComponent.ViewingMode
    switch mode {
    case 2: desired = .spatialStereo
    case 1: desired = .spatial3D
    default: desired = .mono
    }
    // Asking for a mode the file cannot serve is how you get a blank slab.
    component.desiredViewingMode = modes.contains(desired) ? desired : .mono
    entity.components.set(component)
    hypnosRecordSpatial3DModeCount(modes.count)
    // `viewingMode` is what the system settled on, which need not be what
    // was asked for — a silent fall back to mono is the difference between
    // "this mode has no renderer here" and "nothing renders here at all".
    let available = modes.map(hypnosModeName).sorted().joined(separator: ",")
    let size = component.presentationScreenSize
    hypnosRecordSpatial3DDiagnostic(
        "available: \(available)\ndesired: \(hypnosModeName(component.desiredViewingMode))\neffective: \(hypnosModeName(component.viewingMode))\nsize: \(size.x) x \(size.y)"
    )
    AppLogger.photoWindow.info(
        "iOS spatial presentation — available: \(available, privacy: .public) desired: \(hypnosModeName(component.desiredViewingMode), privacy: .public) effective: \(hypnosModeName(component.viewingMode), privacy: .public) size: \(size.x, privacy: .public)x\(size.y, privacy: .public)"
    )
    return size
}

@available(iOS, unavailable)
private func hypnosModeName(_ mode: RealityKit.ImagePresentationComponent.ViewingMode) -> String {
    switch mode {
    case .mono: return "mono"
    case .spatial3D: return "spatial3D"
    case .spatial3DImmersive: return "spatial3DImmersive"
    case .spatialStereo: return "spatialStereo"
    case .spatialStereoImmersive: return "spatialStereoImmersive"
    default: return "unknown"
    }
}

// MARK: - Available bridges
//
// Same symbols, declared without the unavailability so ordinary code can call
// them. Bodies live above.

@MainActor
@_silgen_name("hypnos_ios_make_spatial3d_entity")
private func hypnosMakeSpatial3DEntity(_ url: URL, _ immersive: Bool) async throws -> Entity

@MainActor
@_silgen_name("hypnos_ios_attach_presentation")
private func hypnosAttachPresentation(_ url: URL, _ entity: Entity, _ mode: Int) async throws -> SIMD2<Float>

#endif
