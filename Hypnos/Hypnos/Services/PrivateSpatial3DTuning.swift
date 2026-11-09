//
//  PrivateSpatial3DTuning.swift
//  Hypnos
//
//  Sideload-only (GitHub) build feature: compiled out entirely unless the
//  HYPNOS_PRIVATE_API compilation condition is set (Configuration/Hypnos.xcconfig,
//  `PRIVATE_API_CONDITION`). An App Store build must never define it: everything
//  here reaches RealityKit and CoreRE through symbols and defaults keys that no
//  public header declares.
//

#if HYPNOS_PRIVATE_API && os(visionOS)
// visionOS only: the accessors bind to symbols of the visionOS
// RealityFoundation binary.

import Darwin
import DebugTrace
import Foundation
import Observation
import RealityKit

// MARK: - What this file is
//
// Two independent levers on how `ImagePresentationComponent` (IPC) draws a
// RealityKit 3D picture, found in the visionOS 27.2 (24N120) binaries:
//
// 1. **Stored IPC properties** with ABI-exported accessors in RealityFoundation
//    (and listed in the SDK's .tbd) that the public interface hides:
//    `mxiRenderTwoPass`, `spatial3DCollapseStrength`,
//    `enableSpatial3DDepthPatching`, `shouldLockMeshToImageAspectRatio`,
//    `mxiSceneRepositionMode`. They are per component, so they can differ per
//    window — that is what the Raw Splat 3D option uses.
//
// 2. **CoreRE renderer overrides.** CoreRE's MXI renderer (the gaussian-splat
//    "MXI" scene IPC builds) reads ~60 tuning keys through `re::Defaults`,
//    whose lookup is `[NSUserDefaults standardUserDefaults]
//    objectForKey:@"com.apple.re.<key>"`, then the bare key — no internal-build
//    gate. The standard search list includes the app's own registration domain,
//    so registering a key there reaches the renderer, in this process only, and
//    nothing is ever written to disk (a build without this file inherits no
//    leftovers). They are process-wide, not per window.
//
//    When each key is read decides when a change shows (`RendererKnob.Scope`):
//      * `MXIManager::reloadDebugOverrides` reads most of them once, when the
//        manager is created — and, if `MXIDefaultsUpdateEveryFrame` was present
//        at that point, again on every update. The store registers that key at
//        launch, before anything RealityKit starts, so these apply live.
//      * `MXIComponent`'s initializer reads three: they apply the next time a
//        picture enters 3D.
//      * `MediaDefaults::ipcOverridesEnabled` caches `ipc.mxi.enableOverrides`
//        in a function-local static, and the GraphicsFeatureFlags depth-patch
//        flags sit behind dispatch_once: those need a relaunch.
//
// MARK: Calling convention (important)
//
// The @_silgen_name accessors MUST be declared inside an extension. A global
// @_silgen_name func passes every parameter in the ordinary argument registers,
// but Swift's method convention passes `self` in x20 (swiftself). Declared
// globally they compile and link, then silently read and write the wrong
// memory (verified on the visionOS 27 simulator: a setter left the value
// unchanged, a getter returned 1.18e-35).
//
// MARK: Resilient enum properties
//
// `mxiSceneRepositionMode` is a resilient two-case enum, passed indirectly: the
// setter takes it @in (an address), the getter returns it @out (into a buffer
// whose address arrives in x8, reproduced by returning a 64-byte struct, which
// Swift returns indirectly). A direct-value declaration crashes.
//
// MARK: Weak linking
//
// The app's deployment target is visionOS 26.0 and most of these symbols are
// 27-only; a missing non-weak symbol is a dyld failure at launch. Every
// accessor is `@_weakLinked` and each call is preceded by a `dlsym` check
// (`PrivateIPCSymbol.isAvailable`), so on an OS without one the knob is hidden
// instead of crashing.
//
// MARK: Deliberately excluded
//
//   * `mxiTuningOverrides` ([String: Any]) is not a plain stored property: a
//     write reads back empty and repeated access returns a corrupt Dictionary.
//   * `isUserInteractionEnabled`, `cornerRadiusInPoints`,
//     `enableSpecularAndFresnelEffects`, `enableForceUpdateWhenInactive`: no
//     visible effect on device (visionOS 27.0, 2026-08-04).
//   * `MXIComponent.TreatmentsControl` and `REImagePresentationComponent*` C
//     functions: unreachable (no MXIComponent in the app's Scene; no way to get
//     a `__ComponentRef`). The renderer overrides below reach most of the same
//     fields (headbox, blur-out, treatments) from the other side.

// MARK: - IPC accessors

/// Mangled names of the IPC accessors, without the leading underscore (the form
/// `dlsym` takes).
enum PrivateIPCSymbol {
    static let collapseStrengthSet = "$s17RealityFoundation26ImagePresentationComponentV25spatial3DCollapseStrengthSfvs"
    static let renderTwoPassSet = "$s17RealityFoundation26ImagePresentationComponentV16mxiRenderTwoPassSbvs"
    static let depthPatchingSet = "$s17RealityFoundation26ImagePresentationComponentV28enableSpatial3DDepthPatchingSbvs"
    static let lockMeshAspectSet = "$s17RealityFoundation26ImagePresentationComponentV016shouldLockMeshToC11AspectRatioSbvs"
    static let repositionModeSet = "$s17RealityFoundation26ImagePresentationComponentV22mxiSceneRepositionModeAA12MXIComponentV08MXIScenehI0Ovs"

    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    /// Whether the running OS exports `symbol`. The getter of each property is
    /// exported alongside its setter, so the setter stands for both.
    @MainActor
    static func isAvailable(_ symbol: String) -> Bool {
        if let known = cache[symbol] { return known }
        let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil  // RTLD_DEFAULT
        cache[symbol] = found
        return found
    }
}

/// Buffer for an `@out` return: 64 bytes, so Swift returns it indirectly via x8
/// like the resilient-enum getter. Only the first byte is meaningful.
private struct PrivateOutBuffer64 {
    var a = 0, b = 0, c = 0, d = 0, e = 0, f = 0, g = 0, h = 0
}

extension ImagePresentationComponent {
    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV25spatial3DCollapseStrengthSfvg")
    fileprivate func __privateGetCollapseStrength() -> Float
    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV25spatial3DCollapseStrengthSfvs")
    fileprivate mutating func __privateSetCollapseStrength(_ newValue: Float)

    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV16mxiRenderTwoPassSbvg")
    fileprivate func __privateGetRenderTwoPass() -> Bool
    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV16mxiRenderTwoPassSbvs")
    fileprivate mutating func __privateSetRenderTwoPass(_ newValue: Bool)

    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV28enableSpatial3DDepthPatchingSbvg")
    fileprivate func __privateGetDepthPatching() -> Bool
    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV28enableSpatial3DDepthPatchingSbvs")
    fileprivate mutating func __privateSetDepthPatching(_ newValue: Bool)

    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV016shouldLockMeshToC11AspectRatioSbvg")
    fileprivate func __privateGetLockMeshAspect() -> Bool
    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV016shouldLockMeshToC11AspectRatioSbvs")
    fileprivate mutating func __privateSetLockMeshAspect(_ newValue: Bool)

    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV22mxiSceneRepositionModeAA12MXIComponentV08MXIScenehI0Ovg")
    fileprivate func __privateGetSceneRepositionModeOut() -> PrivateOutBuffer64
    @_weakLinked @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV22mxiSceneRepositionModeAA12MXIComponentV08MXIScenehI0Ovs")
    fileprivate mutating func __privateSetSceneRepositionModeIn(_ value: UnsafeRawPointer)

    fileprivate var privateSceneRepositionModeRaw: UInt8 {
        withUnsafeBytes(of: __privateGetSceneRepositionModeOut()) { $0[0] }
    }

    fileprivate mutating func privateSetSceneRepositionMode(_ mode: PrivateSceneRepositionMode) {
        var raw = mode.rawValue
        withUnsafeBytes(of: &raw) { __privateSetSceneRepositionModeIn($0.baseAddress!) }
    }
}

/// `MXIComponent.MXISceneRepositionMode`. Confirmed on device (visionOS 27.0):
/// the names read backwards. `alignToViewDepth` is the stock value (immersive
/// zooms toward the subject and follows the head), `alignToHeadPosition` gives
/// the static pre-27 portal.
enum PrivateSceneRepositionMode: UInt8, Codable, CaseIterable, Identifiable {
    case alignToViewDepth = 0
    case alignToHeadPosition = 1

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .alignToViewDepth: "Follow Head (stock)"
        case .alignToHeadPosition: "Static Portal"
        }
    }
}

// MARK: - Settings

/// Per-component overrides. `nil` leaves RealityKit's value alone, so the
/// default value is a guaranteed no-op.
struct PrivateSpatial3DSettings: Codable, Equatable {
    /// Every RealityKit 3D picture, not just Raw Splat windows.
    var renderTwoPass: Bool?
    var collapseStrength: Float?
    var depthPatching: Bool?
    var lockMeshToImageAspect: Bool?
    var sceneRepositionMode: PrivateSceneRepositionMode?

    var isNoOp: Bool { self == PrivateSpatial3DSettings() }
}

/// One CoreRE renderer override (`com.apple.re.<key>`).
struct RendererKnob: Identifiable {
    enum Kind {
        case toggle
        case slider(ClosedRange<Double>)
        case integer(ClosedRange<Int>)
    }

    /// When a change reaches the picture on screen.
    enum Scope {
        case live, next3D, relaunch

        var note: String {
            switch self {
            case .live: ""
            case .next3D: "Applies the next time a picture enters 3D."
            case .relaunch: "Applies after relaunching the app."
            }
        }
    }

    let key: String
    let title: String
    let kind: Kind
    var scope: Scope = .live
    var caption: String = ""

    var id: String { key }

    /// Value seeded when the override is first switched on. Stock values are
    /// not readable (CoreRE holds an override as an optional and merges it at
    /// use), so this is a neutral starting point, not the system's value.
    var seed: Double {
        switch kind {
        case .toggle: 1
        case .slider(let r): min(max(1, r.lowerBound), r.upperBound)
        case .integer(let r): Double(min(max(1, r.lowerBound), r.upperBound))
        }
    }
}

struct RendererKnobGroup: Identifiable {
    let title: String
    let footer: String
    let knobs: [RendererKnob]
    var id: String { title }
}

enum RendererKnobCatalog {
    /// What the 27.2 renderer reads, grouped by what it changes. Keys, types and
    /// read sites are from CoreRE (24N120); captions say what is known, and a
    /// knob nobody has looked at on device says so.
    static let groups: [RendererKnobGroup] = [
        RendererKnobGroup(
            title: "Off-Axis Blur & Headbox",
            footer: "The headbox is the region the picture is calibrated for. Stepping outside it blurs the scene out, which is what hides the splats from a side angle. Turn on Log Renderer State to see the headbox values the renderer is using.",
            knobs: [
                RendererKnob(key: "mxi.disableBlurOut", title: "Disable Blur-Out", kind: .toggle,
                             caption: "Zeroes the blur-out radius, so the picture stays sharp from any angle."),
                RendererKnob(key: "mxi.headboxShape", title: "Headbox Shape", kind: .integer(0...3)),
                RendererKnob(key: "mxi.headboxMinimumRadius", title: "Minimum Radius (m)", kind: .slider(0...2)),
                RendererKnob(key: "mxi.headboxMinimumForwardDistance", title: "Minimum Forward Distance (m)", kind: .slider(0...3)),
                RendererKnob(key: "mxi.headboxMinimumBackwardDistance", title: "Minimum Backward Distance (m)", kind: .slider(0...3)),
                RendererKnob(key: "mxi.headboxMaxDisparity", title: "Max Disparity", kind: .slider(0...0.2)),
                RendererKnob(key: "mxi.headboxMaxErrorMarginInPixels", title: "Max Error Margin (px)", kind: .integer(0...64)),
                RendererKnob(key: "mxi.headboxEnableAdaptiveScaling", title: "Adaptive Scene Scaling", kind: .toggle,
                             caption: "Scales the scene to keep it inside the headbox; off keeps its size fixed."),
                RendererKnob(key: "mxi.headboxShearStrength", title: "Shear Strength", kind: .slider(0...2)),
                RendererKnob(key: "mxi.headboxDynamicShearStrength", title: "Dynamic Shear Strength", kind: .slider(0...2)),
            ]
        ),
        RendererKnobGroup(
            title: "Rendering",
            footer: "Two-Pass is the same switch as Raw Splat 3D, for every picture at once.",
            knobs: [
                RendererKnob(key: "MXIEnableTwoPass", title: "Two-Pass Rendering", kind: .toggle),
                RendererKnob(key: "MXIDoReprojection", title: "Reprojection", kind: .toggle,
                             caption: "Re-renders the splats as the head moves instead of warping the last frame."),
                RendererKnob(key: "mxi.enableReprojection", title: "Reprojection (component)", kind: .toggle, scope: .next3D),
                RendererKnob(key: "MXIKeepReprojectingThreshold", title: "Keep-Reprojecting Threshold", kind: .slider(0...1)),
                RendererKnob(key: "MXIFramesPerRender", title: "Frames per Render", kind: .integer(1...8)),
                RendererKnob(key: "MXIResolutionScale", title: "Resolution Scale", kind: .slider(0.25...2)),
                RendererKnob(key: "MXIUseProxyRendering", title: "Proxy Rendering", kind: .toggle),
                RendererKnob(key: "MXIExpandedRegionMultiplier", title: "Expanded Region Multiplier", kind: .slider(0...4)),
                RendererKnob(key: "MXINearPlaneSizeScalar", title: "Near Plane Size Scalar", kind: .slider(0...4)),
                RendererKnob(key: "MXIWidthSegmentsOverride", title: "Mesh Width Segments", kind: .integer(1...256)),
                RendererKnob(key: "MXIHeightSegmentsOverride", title: "Mesh Height Segments", kind: .integer(1...256)),
                RendererKnob(key: "MXIDepthEdgeThreshold", title: "Depth Edge Threshold", kind: .slider(0...1)),
                RendererKnob(key: "MXIVertexMotionThreshold", title: "Vertex Motion Threshold", kind: .slider(0...1)),
                RendererKnob(key: "mxi.forceDisocclusionMode", title: "Force Disocclusion Mode", kind: .toggle),
                RendererKnob(key: "mxi.collapseStrength", title: "Collapse Strength", kind: .slider(0...1),
                             caption: "Flattens the depth. Same effect as the per-picture Collapse Strength above."),
                RendererKnob(key: "mxi.collapseOffset", title: "Collapse Offset", kind: .slider(-1...1)),
                RendererKnob(key: "mxi.immersiveMinDepth", title: "Immersive Minimum Depth (m)", kind: .slider(0...5)),
            ]
        ),
        RendererKnobGroup(
            title: "Billboarding",
            footer: "How far the scene turns to face you as you move around it.",
            knobs: [
                RendererKnob(key: "MXIEnableBillboard", title: "Billboarding", kind: .toggle),
                RendererKnob(key: "MXIBillboardPolicy", title: "Policy", kind: .integer(0...3)),
                RendererKnob(key: "MXIBillboardPolicyAbsoluteMaxAllowedAngle", title: "Absolute Max Angle", kind: .slider(0...180)),
                RendererKnob(key: "MXIBillboardPolicyRelativeMaxAllowedAngle", title: "Relative Max Angle", kind: .slider(0...180)),
                RendererKnob(key: "MXIBillboardActivationFunction", title: "Activation Function", kind: .integer(0...3)),
                RendererKnob(key: "MXIBillboardActivationFunctionSmoothPlusScale", title: "Smooth-Plus Scale", kind: .slider(0...10)),
            ]
        ),
        RendererKnobGroup(
            title: "Edge Treatments",
            footer: "The fades, glow and colour spill drawn around the scene's edges and near plane.",
            knobs: [
                RendererKnob(key: "mxi.enableTreatments", title: "Treatments", kind: .toggle, scope: .next3D),
                RendererKnob(key: "MXITreatmentNearFalloffBegin", title: "Near Falloff Begin", kind: .slider(0...2)),
                RendererKnob(key: "MXITreatmentNearFalloffEnd", title: "Near Falloff End", kind: .slider(0...2)),
                RendererKnob(key: "MXITreatmentNearFalloffCornerRadius", title: "Near Falloff Corner Radius", kind: .slider(0...1)),
                RendererKnob(key: "MXITreatmentNearFalloffStepFunction", title: "Near Falloff Step Function", kind: .integer(0...3)),
                RendererKnob(key: "MXITreatmentCompositingMixBegin", title: "Compositing Mix Begin", kind: .slider(0...2)),
                RendererKnob(key: "MXITreatmentCompositingMixEnd", title: "Compositing Mix End", kind: .slider(0...2)),
                RendererKnob(key: "MXITreatmentCompositingMixCornerRadius", title: "Compositing Mix Corner Radius", kind: .slider(0...1)),
                RendererKnob(key: "MXITreatmentCompositingMixStepFunction", title: "Compositing Mix Step Function", kind: .integer(0...3)),
                RendererKnob(key: "MXITreatmentSpillFalloffBegin", title: "Spill Falloff Begin", kind: .slider(0...2)),
                RendererKnob(key: "MXITreatmentSpillFalloffEnd", title: "Spill Falloff End", kind: .slider(0...2)),
                RendererKnob(key: "MXITreatmentSpillFalloffCornerRadius", title: "Spill Falloff Corner Radius", kind: .slider(0...1)),
                RendererKnob(key: "MXITreatmentSpillFalloffStepFunction", title: "Spill Falloff Step Function", kind: .integer(0...3)),
                RendererKnob(key: "MXITreatmentSpillColorSampleMode", title: "Spill Colour Sample Mode", kind: .integer(0...3)),
                RendererKnob(key: "MXITreatmentEnableGlowrayStarburstMitigation", title: "Glowray Starburst Mitigation", kind: .toggle),
                RendererKnob(key: "MXITreatmentPrebakedGlowrayOnly", title: "Prebaked Glowray Only", kind: .toggle),
                RendererKnob(key: "MXITreatmentSceneRepositionMode", title: "Treatment Reposition Mode", kind: .integer(0...1)),
                RendererKnob(key: "mxi.treatmentMaskEdge", title: "Treatment Mask Edge", kind: .slider(0...1)),
            ]
        ),
        RendererKnobGroup(
            title: "Portal Layout",
            footer: "Where and how large the portal and immersive proxies are drawn. Applies after relaunching the app.",
            knobs: [
                RendererKnob(key: "ipc.mxi.portal.proxyDistance", title: "Portal Distance (m)", kind: .slider(0...5), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.portal.proxyWidth", title: "Portal Width (m)", kind: .slider(0...5), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.portal.proxyHeight", title: "Portal Height (m)", kind: .slider(0...5), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.portal.nearPlaneSizeScalar", title: "Portal Near Plane Scalar", kind: .slider(0...4), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.portal.sceneTargetVerticalFoVVisibleRegion", title: "Portal Visible Vertical FoV", kind: .slider(0...180), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersive.proxyDistance", title: "Immersive Distance (m)", kind: .slider(0...10), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersive.proxyWidth", title: "Immersive Width (m)", kind: .slider(0...10), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersive.proxyHeight", title: "Immersive Height (m)", kind: .slider(0...10), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersive.nearPlaneSizeScalar", title: "Immersive Near Plane Scalar", kind: .slider(0...4), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersive.sceneTargetVerticalFoVVisibleRegion", title: "Immersive Visible Vertical FoV", kind: .slider(0...180), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersiveFOV", title: "Immersive FoV", kind: .slider(0...180), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersiveScalingMode", title: "Immersive Scaling Mode", kind: .integer(0...3), scope: .relaunch),
                RendererKnob(key: "ipc.mxi.immersiveModeScalingPreset", title: "Immersive Scaling Preset", kind: .integer(0...3), scope: .relaunch),
                RendererKnob(key: "enableMXIDepthPatch", title: "Depth Patch (renderer)", kind: .toggle, scope: .relaunch),
                RendererKnob(key: "forceDepthPatchAllMXIs", title: "Force Depth Patch on All", kind: .toggle, scope: .relaunch),
                RendererKnob(key: "mxi.enableStencilPrepass", title: "Stencil Prepass", kind: .toggle, scope: .relaunch),
            ]
        ),
        RendererKnobGroup(
            title: "Diagnostics",
            footer: "Log Renderer State prints the headbox and scene-scale values every frame (subsystem com.apple.re, category MXI): build-and-sign --log-all captures them.",
            knobs: [
                RendererKnob(key: "mxi.enablePerFrameDebugLog", title: "Log Renderer State", kind: .toggle),
                RendererKnob(key: "mxi.enableAABBVisualizer", title: "Show Bounding Boxes", kind: .toggle),
                RendererKnob(key: "MXIDebugTintNearFarRectangles", title: "Tint Near/Far Rectangles", kind: .toggle),
                RendererKnob(key: "mxi.enableDynamicWeightMap", title: "Dynamic Weight Map", kind: .toggle, scope: .next3D),
                RendererKnob(key: "mxi.enableDynamicWeightMapViz", title: "Show Dynamic Weight Map", kind: .toggle),
                RendererKnob(key: "mxi.dynamicWeightMapScale", title: "Dynamic Weight Map Scale", kind: .slider(0...4)),
                RendererKnob(key: "mxi.enableBinaryMask", title: "Binary Mask", kind: .toggle),
                RendererKnob(key: "mxi.binaryMaskSplitDepth", title: "Binary Mask Split Depth", kind: .slider(0...10)),
                RendererKnob(key: "mxi.debugBinaryMaskViz", title: "Binary Mask Visualisation", kind: .integer(0...4)),
                RendererKnob(key: "mxi.AABBdilateRatio", title: "Bounding Box Dilate Ratio", kind: .slider(0...4)),
            ]
        ),
    ]

    static let byKey: [String: RendererKnob] = Dictionary(
        uniqueKeysWithValues: groups.flatMap(\.knobs).map { ($0.key, $0) }
    )
}

// MARK: - Store

@MainActor
@Observable
final class PrivateSpatial3DTuningStore {
    static let shared = PrivateSpatial3DTuningStore()

    private static let enabledKey = "privateSpatial3DTuningEnabled"
    private static let settingsKey = "privateSpatial3DTuningSettings"
    private static let rendererKey = "privateSpatial3DRendererOverrides"
    private static let defaultsPrefix = "com.apple.re."

    /// Master switch for the Settings overrides. Off by default. Raw Splat 3D
    /// works whether or not it is on: that is a viewing mode, not a tweak.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            HypnosDefaults.store.set(isEnabled, forKey: Self.enabledKey)
            changed()
        }
    }

    var settings: PrivateSpatial3DSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) {
                HypnosDefaults.store.set(data, forKey: Self.settingsKey)
            }
            changed()
        }
    }

    /// Renderer overrides by CoreRE key (bools as 0/1). A missing key is
    /// "leave the renderer's value alone".
    var rendererOverrides: [String: Double] {
        didSet {
            guard rendererOverrides != oldValue else { return }
            if let data = try? JSONEncoder().encode(rendererOverrides) {
                HypnosDefaults.store.set(data, forKey: Self.rendererKey)
            }
            scheduleRendererInstall()
        }
    }

    /// Bumped whenever a component knob changes so open viewers re-apply.
    private(set) var revision = 0

    /// Relaunch-scoped overrides as they were registered at launch, to say in
    /// Settings that a relaunch is pending.
    private(set) var launchRelaunchOverrides: [String: Double] = [:]

    private var installTask: Task<Void, Never>?

    private init() {
        let store = HypnosDefaults.store
        isEnabled = store.bool(forKey: Self.enabledKey)
        settings = store.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(PrivateSpatial3DSettings.self, from: $0) }
            ?? PrivateSpatial3DSettings()
        rendererOverrides = store.data(forKey: Self.rendererKey)
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) }
            ?? [:]
    }

    /// Register the renderer overrides before anything RealityKit starts, so
    /// `MXIManager` sees `MXIDefaultsUpdateEveryFrame` when it is created and the
    /// once-per-process keys are in place. Call from `HypnosApp.init`.
    static func installAtLaunch() {
        let store = shared
        store.installRendererDefaults()
        store.launchRelaunchOverrides = store.activeRendererOverrides.filter {
            RendererKnobCatalog.byKey[$0.key]?.scope == .relaunch
        }
    }

    var activeRendererOverrides: [String: Double] {
        isEnabled ? rendererOverrides : [:]
    }

    var needsRelaunch: Bool {
        activeRendererOverrides.filter { RendererKnobCatalog.byKey[$0.key]?.scope == .relaunch }
            != launchRelaunchOverrides
    }

    func reset() {
        settings = PrivateSpatial3DSettings()
        rendererOverrides = [:]
    }

    private func changed() {
        revision &+= 1
        scheduleRendererInstall()
    }

    /// Debounced: a slider drag would otherwise replace the registration domain
    /// (and post a defaults-changed notification) on every step.
    private func scheduleRendererInstall() {
        installTask?.cancel()
        installTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.installRendererDefaults()
        }
    }

    /// Replace every `com.apple.re.*` key in the registration domain with the
    /// active overrides. The registration domain is in memory only: nothing
    /// here outlives the process.
    private func installRendererDefaults() {
        let defaults = UserDefaults.standard
        let name = UserDefaults.registrationDomain
        var domain = defaults.volatileDomain(forName: name).filter { !$0.key.hasPrefix(Self.defaultsPrefix) }

        let overrides = activeRendererOverrides
        for (key, value) in overrides {
            guard let knob = RendererKnobCatalog.byKey[key] else { continue }
            let object: Any = switch knob.kind {
            case .toggle: value != 0
            case .slider: Float(value)
            case .integer: Int(value)
            }
            domain[Self.defaultsPrefix + key] = object
        }
        // Gates every ipc.mxi.* layout key.
        if overrides.keys.contains(where: { $0.hasPrefix("ipc.mxi.") }) {
            domain[Self.defaultsPrefix + "ipc.mxi.enableOverrides"] = 1
        }
        // Makes MXIManager re-read its overrides every update, which is what
        // lets the live knobs live. Only while there is something to read.
        if !overrides.isEmpty {
            domain[Self.defaultsPrefix + "MXIDefaultsUpdateEveryFrame"] = true
        }
        defaults.setVolatileDomain(domain, forName: name)
        AppLogger.photoWindow.debug("Private spatial-3D renderer overrides installed: \(overrides.count, privacy: .public)"
        )
    }

    // MARK: Component knobs

    /// Which component knobs this OS has, for Settings to show.
    var availableComponentKnobs: Set<WritableKeyPath<PrivateSpatial3DSettings, Bool?>> {
        var set: Set<WritableKeyPath<PrivateSpatial3DSettings, Bool?>> = []
        if PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.renderTwoPassSet) { set.insert(\.renderTwoPass) }
        if PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.depthPatchingSet) { set.insert(\.depthPatching) }
        if PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.lockMeshAspectSet) { set.insert(\.lockMeshToImageAspect) }
        return set
    }

    var isRawSplatAvailable: Bool {
        PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.renderTwoPassSet)
    }

    /// Apply the overrides to `component`. `rawSplat` forces two-pass off for
    /// this one component whatever the settings say. Returns whether anything
    /// changed, so callers re-publish the component only then.
    @discardableResult
    func apply(to component: inout ImagePresentationComponent, rawSplat: Bool) -> Bool {
        var changed = false
        let s = isEnabled ? settings : PrivateSpatial3DSettings()

        if PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.renderTwoPassSet) {
            // With no override the target is the stock value (on), so leaving
            // Raw Splat on a component that keeps its Spatial3DImage turns
            // two-pass back on instead of leaving it off.
            let target = rawSplat ? false : (s.renderTwoPass ?? true)
            if component.__privateGetRenderTwoPass() != target {
                component.__privateSetRenderTwoPass(target); changed = true
            }
        }
        if let v = s.collapseStrength,
           PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.collapseStrengthSet),
           component.__privateGetCollapseStrength() != v {
            component.__privateSetCollapseStrength(v); changed = true
        }
        if let v = s.depthPatching,
           PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.depthPatchingSet),
           component.__privateGetDepthPatching() != v {
            component.__privateSetDepthPatching(v); changed = true
        }
        if let v = s.lockMeshToImageAspect,
           PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.lockMeshAspectSet),
           component.__privateGetLockMeshAspect() != v {
            component.__privateSetLockMeshAspect(v); changed = true
        }
        if let v = s.sceneRepositionMode,
           PrivateIPCSymbol.isAvailable(PrivateIPCSymbol.repositionModeSet),
           component.privateSceneRepositionModeRaw != v.rawValue {
            component.privateSetSceneRepositionMode(v); changed = true
        }
        return changed
    }
}

// MARK: - Photo window hooks

extension PhotoWindowModel {
    private var rawSplatNudgeReason: String { "rawSplat-\(ObjectIdentifier(self).hashValue)" }

    /// Re-apply the private knobs to this window's component. Called from
    /// `updateExperimentalSpatial3DTuning()`, which runs wherever the component
    /// is created or its viewing mode changes (the immersive transition is
    /// suspected of re-asserting its own values, so once at creation is not
    /// enough).
    func applyPrivateSpatial3DTuning() {
        // The off-axis calibration nudge exists for two-pass's blur; on the raw
        // splat it has nothing to fix and visibly glitches it.
        let twoPassOff = isRawSplatMode
            || (PrivateSpatial3DTuningStore.shared.isEnabled
                && PrivateSpatial3DTuningStore.shared.settings.renderTwoPass == false)
        WindowSizeNudge.setSuppressed(twoPassOff && is3DMode, reason: rawSplatNudgeReason)

        guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
        guard PrivateSpatial3DTuningStore.shared.apply(to: &ipc, rawSplat: isRawSplatMode) else { return }
        contentEntity.components.set(ipc)
        AppLogger.photoWindow.debug("Applied private spatial-3D tuning (rawSplat \(self.isRawSplatMode, privacy: .public))"
        )
    }

    func releaseRawSplatNudgeSuppression() {
        WindowSizeNudge.setSuppressed(false, reason: rawSplatNudgeReason)
    }

    /// Raw Splat 3D: RealityKit 3D with two-pass rendering off, so the scene is
    /// drawn as its gaussian splats and stays sharp when seen from the side.
    /// `immersive` picks the viewing mode, as the two RealityKit 3D items do.
    func toggleRawSplat(immersive: Bool) async {
        let mode: ImagePresentationComponent.ViewingMode = immersive ? .spatial3DImmersive : .spatial3D
        if isRawSplatMode && desiredViewingMode == mode {
            isRawSplatMode = false
            await switchToViewingMode(.mono)
            applyPrivateSpatial3DTuning()
            return
        }
        isRawSplatMode = true
        if desiredViewingMode == mode, is3DMode {
            applyPrivateSpatial3DTuning()
        } else {
            await switchToViewingMode(mode)
            applyPrivateSpatial3DTuning()
        }
    }
}

#endif
