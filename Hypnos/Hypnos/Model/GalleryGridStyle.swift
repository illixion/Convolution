/*
 Hypnos - Gallery Grid Style

 How the Pictures grid arranges its cells. Persisted in UserDefaults via
 AppModel.
 */

import Foundation

enum GalleryGridStyle: String, CaseIterable, Identifiable {
    /// Uniform square cells, each showing a center crop.
    case square
    /// Every image at its own aspect ratio, packed into rows that fill the
    /// window width (`JustifiedRowLayout`).
    case original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: return "Square"
        case .original: return "Original Aspect Ratio"
        }
    }
}
