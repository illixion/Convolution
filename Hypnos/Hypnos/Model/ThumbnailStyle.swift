/*
 Hypnos - Thumbnail Style

 Rendering style for gallery thumbnails. Persisted in UserDefaults via
 AppModel; forced to `.flat` at use sites when Reduce Motion is on.
 */

import Foundation

enum ThumbnailStyle: String, CaseIterable, Identifiable {
    case flat
    case diorama
    /// One 3D tile per thumbnail, displaced by the real-time depth model's
    /// map (`DepthTileView`). Falls back to `.diorama` while no model is
    /// installed.
    case depth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Flat"
        case .diorama: return "Diorama"
        case .depth: return "3D Depth"
        }
    }
}
