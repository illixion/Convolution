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

    var id: String { rawValue }

    /// Raw values predate the names and stay as they are: they're persisted.
    var label: String {
        switch self {
        case .mono: return "2D"
        case .spatial3D: return "RealityKit 3D"
        case .spatial3DImmersive: return "RealityKit 3D (Immersive)"
        case .diorama: return "Diorama"
        case .aiDepth: return "AI 3D"
        }
    }
}
