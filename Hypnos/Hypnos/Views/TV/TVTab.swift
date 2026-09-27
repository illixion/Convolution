/*
 Hypnos - tvOS top tab bar

 The tvOS root is a completely separate UI from the visionOS ornament and the
 iOS `TabView` — see `Hypnos/CLAUDE.md` "tvOS". This is its own small tab
 enum rather than an extra case on the shared `Tab` (Model/Tab.swift):
 that type is keyed to `RAVEA11y`/`RAVETabItem` and to the visionOS/iOS
 ornament's developer-tab visibility rules (Remote, Console), none of which
 tvOS needs — Settings, Console and Remote are folded into one Settings tab
 here, and there is no Filters or Windows tab at all (no multi-window
 concept on tvOS, and nothing yet to filter Photos/Stash by on a 10-foot
 remote-driven grid).
 */

import Foundation

enum TVTab: String, CaseIterable, Identifiable {
    case pictures = "Pictures"
    case videos = "Videos"
    case albums = "Albums"
    case library = "Library"
    case settings = "Settings"
    /// Only while Settings → Developer → Show Debug Console is on.
    case console = "Console"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pictures: return "photo.stack"
        case .videos: return "video"
        case .albums: return "rectangle.stack"
        case .library: return "rectangle.stack.badge.play"
        case .settings: return "gearshape"
        case .console: return "terminal"
        }
    }
}
