/*
 Hypnos - Default Image Viewing Mode

 Enum mirroring the photo viewer's 3D menu options. Persisted in
 UserDefaults via AppModel and applied when opening a photo that has
 no per-image remembered viewing mode.
 */

import Foundation

enum DefaultImageViewingMode: String, CaseIterable, Identifiable {
    case mono
    case spatial3D
    case spatial3DImmersive
    case diorama
    case aiDepth
    /// Raw Splat 3D (two-pass MXI rendering off), sideload builds only
    /// (`HYPNOS_PRIVATE_API`). A build without it reads these as the stock
    /// RealityKit modes (`resolvedForBuild`), so a synced or restored setting
    /// still means 3D there.
    case rawSplat3D
    case rawSplat3DImmersive

    var id: String { rawValue }

    /// Any RealityKit 3D mode, stock or Raw Splat.
    var is3D: Bool {
        switch self {
        case .spatial3D, .spatial3DImmersive, .rawSplat3D, .rawSplat3DImmersive: true
        case .mono, .diorama, .aiDepth: false
        }
    }

    var isImmersive3D: Bool { self == .spatial3DImmersive || self == .rawSplat3DImmersive }

    var isRawSplat: Bool { self == .rawSplat3D || self == .rawSplat3DImmersive }

    /// Whether this build and OS can show Raw Splat 3D.
    @MainActor static var isRawSplatAvailable: Bool {
        #if HYPNOS_PRIVATE_API && os(visionOS)
        PrivateSpatial3DTuningStore.shared.isRawSplatAvailable
        #else
        false
        #endif
    }

    /// The modes Settings offers.
    @MainActor static var selectable: [DefaultImageViewingMode] {
        allCases.filter { !$0.isRawSplat || isRawSplatAvailable }
    }

    /// This mode as this build can apply it: Raw Splat falls back to the
    /// stock RealityKit mode where it is unavailable.
    @MainActor var resolvedForBuild: DefaultImageViewingMode {
        guard isRawSplat, !Self.isRawSplatAvailable else { return self }
        return self == .rawSplat3D ? .spatial3D : .spatial3DImmersive
    }

    /// Raw values predate the names and stay as they are: they're persisted.
    var label: String {
        switch self {
        case .mono: return "2D"
        case .spatial3D: return "RealityKit 3D"
        case .spatial3DImmersive: return "RealityKit 3D (Immersive)"
        case .diorama: return "Diorama"
        case .aiDepth: return "AI 3D"
        case .rawSplat3D: return "Raw Splat 3D"
        case .rawSplat3DImmersive: return "Raw Splat 3D (Immersive)"
        }
    }
}
