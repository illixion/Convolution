/*
 Hypnos - Main tab catalog

 Which tabs the main window offers right now, and what its slideshow button
 would start. Both the visionOS tab-bar ornament and the iOS tab bar read this,
 so the two chromes cannot drift on *what* is offered — only on how it looks.
 */

import SwiftUI

@MainActor
enum MainTabCatalog {
    /// Display order of every tab, before per-state filtering.
    static let orderedTabs: [Tab] = [.pictures, .videos, .albums, .library, .remote, .filters, .windows, .console, .settings]

    /// The tabs to show for the current app state.
    static func visibleTabs(appModel: AppModel) -> [Tab] {
        orderedTabs.filter { tab in
            switch tab {
            case .library:
                // Hidden until a Jellyfin server is configured — see the
                // Library feature's decision #3.
                return FilmSession.shared.isConfigured
            case .remote:
                return appModel.enableRemoteViewer
            case .console:
                return appModel.showDebugConsole
            case .filters:
                // Nothing to filter by in a file-tree library — no tags,
                // albums or galleries. See ContentView for the redirect if
                // this tab was already open when the library changed.
                return appModel.effectiveLibrarySource.offersFilters
            case .albums:
                return appModel.effectiveLibrarySource.offersAlbums
            case .windows:
                // A window inventory only means something with several windows.
                return PlatformCapabilities.supportsMultipleWindows
            default:
                return true
            }
        }
    }

    /// Whether to offer the library switch: only with more than one source
    /// available, and only on the tabs that show one.
    static func showsLibraryToggle(appModel: AppModel, selectedTab: Tab) -> Bool {
        guard appModel.availableLibrarySources.count > 1 else { return false }
        switch selectedTab {
        case .pictures, .videos: return true
        default: return false
        }
    }

    /// What the play button would start, or nil when the current tab isn't
    /// showing anything a slideshow could run over.
    static func slideshowLaunch(appModel: AppModel, selectedTab: Tab) -> (help: String, start: () -> Void)? {
        switch selectedTab {
        case .pictures:
            // Nothing loaded yet — a slideshow would open on an empty source.
            guard !appModel.galleryImages.isEmpty else { return nil }
            return ("Slideshow of these pictures", {
                appModel.startGallerySlideshow(
                    imageSource: appModel.imageSource,
                    filter: appModel.currentFilter
                )
            })
        case .videos:
            guard !appModel.galleryVideos.isEmpty else { return nil }
            return ("Slideshow of these videos", {
                appModel.startVideoSlideshow(
                    videoSource: appModel.videoSource,
                    filter: appModel.currentVideoFilter
                )
            })
        // Albums is a browser: what a slideshow would run over is whatever
        // opening a container leaves on the Pictures or Videos tab, so the
        // button belongs there rather than here. That includes the Local
        // library's folder browser, which offers its own per-folder
        // "Play Slideshow" control in context instead.
        case .albums, .library, .filters, .windows, .settings, .remote, .console:
            return nil
        }
    }

    /// Tab selection with the app's re-tap semantics: re-tapping Albums while
    /// already there is "pop to the folder root" for its local-folder browser.
    static func select(_ tab: Tab, in windowModel: MainWindowModel) {
        if tab == .pictures || tab == .videos {
            windowModel.lastContentTab = tab
        }
        if tab == .albums && windowModel.selectedTab == .albums {
            windowModel.albumsReselected += 1
        } else {
            windowModel.selectedTab = tab
        }
    }
}
