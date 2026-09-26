/*
 Hypnos - macOS sidebar sections

 Mirrors `TVTab` (`Views/TV/TVTab.swift`): a small, platform-owned enum rather
 than an extra case on the shared `Tab`, which is keyed to `RAVEA11y`/
 `RAVETabItem` and the visionOS/iOS developer-tab rules. macOS gets the same
 five sections as tvOS (no Windows tab — the Mac already has a native window
 list via the Window menu / Mission Control; no Filters tab — nothing to
 filter by on a remote-free grid yet, same reasoning as tvOS's omission).
 */

#if os(macOS)

import SwiftUI

enum MacTab: String, CaseIterable, Identifiable {
    case pictures = "Pictures"
    case videos = "Videos"
    case albums = "Albums"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pictures: return "photo.on.rectangle.angled"
        case .videos: return "video"
        case .albums: return "square.stack"
        case .library: return "rectangle.stack.badge.play"
        case .settings: return "gearshape"
        }
    }
}

#endif
