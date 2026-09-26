/*
 Hypnos - Tab Navigation

 Defines the available tabs in the app.
 */

import Foundation
import RAVEUI

enum Tab: String, CaseIterable {
    case pictures = "Pictures"
    case videos = "Videos"
    case albums = "Albums"
    case library = "Library"
    case filters = "Filters"
    case windows = "Windows"
    case settings = "Settings"
    case remote = "Remote"
    case console = "Console"


    /// The case name, not the title: the titles are display copy and this app
    /// is mid-rename, so a UI test matching on "Pictures" would break on a
    /// wording change that has nothing to do with it.
    var accessibilityIdentifier: String {
        RAVEA11y.tab(String(describing: self))
    }

    var systemImage: String {
        switch self {
        case .pictures: return "photo.stack"
        case .videos: return "video"
        case .albums: return "rectangle.stack"
        case .library: return "rectangle.stack.badge.play"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .windows: return "macwindow.on.rectangle"
        case .settings: return "gearshape"
        case .remote: return "network"
        case .console: return "apple.terminal"
        }
    }
}

// `RAVETabItem` (RAVEUI's ornament tab bar protocol) is visionOS-only.
#if os(visionOS)
extension Tab: RAVETabItem {}
#else
// iOS drives its own (non-ornament) tab bar off the same `Tab` cases; it
// needs `Identifiable` and a display `title`, which RAVETabItem otherwise
// would have supplied.
extension Tab: Identifiable {
    var id: Self { self }
}

extension Tab {
    var title: String { rawValue }
}
#endif
