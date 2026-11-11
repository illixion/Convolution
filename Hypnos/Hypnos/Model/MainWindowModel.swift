/*
 Hypnos - Main Window Model

 Per-window navigation state for the main app window. Each instance of the
 main WindowGroup gets its own model so that tab selection does not clone
 across multiple open main windows.
 */

import SwiftUI

@MainActor
@Observable
class MainWindowModel {
    // DEBUG-only, mirroring tvOS's `tvInitialTab`
    // (`Support/UITestingConfiguration.swift`): `-UITestDefault
    // mainInitialTab=Library` opens straight to a given tab, since there's
    // no remote-button-style shortcut into a specific visionOS/iOS/macOS
    // tab otherwise.
    var selectedTab: Tab = {
        #if DEBUG
        if let raw = HypnosDefaults.store.string(forKey: "mainInitialTab"), let tab = Tab(rawValue: raw) {
            return tab
        }
        #endif
        return .pictures
    }()

    /// Tracks the last content tab (pictures or videos) for filter context
    var lastContentTab: Tab = .pictures

    /// Incremented when the Albums tab is tapped while already on Albums —
    /// its local-folder browser (`LocalFolderBrowserView`) treats that as
    /// "pop back to the root of whichever tree I'm in" the way a Files app
    /// would.
    var albumsReselected: Int = 0

    /// Folder `LocalFolderBrowserView` is currently showing, as path
    /// components *relative to* Documents/Photos or Documents/Videos
    /// (whichever `isVideo` selects) — e.g. `["Wallpapers"]`. Empty means
    /// that root itself.
    ///
    /// Lives here rather than in the browser's own state because ContentView
    /// keys tab content on `selectedTab`, so view-local state would reset on
    /// every trip to another tab and back.
    var localFolderPath: [String] = []

    /// Whether the Albums tab is browsing video containers rather than image
    /// ones. Here for the same reason `localFolderPath` is: ContentView keys tab
    /// content on `selectedTab`, so the browser is destroyed on every tab switch
    /// and view-local state would reset. That mattered as soon as Stash groups
    /// existed — open a group, press back, and the browser returned showing
    /// galleries instead of the groups you came from.
    var albumsShowingVideos: Bool = false

    /// The Library tab's place: Movies & TV or Music, and what is pushed onto its stack. Here for the same reason
    /// as the two above: leaving the tab destroys its views, and coming back should find the album that was open.
    #if DEBUG
    var libraryShowsMusic: Bool = MusicDebugLaunch.showsMusic
    #else
    var libraryShowsMusic: Bool = false
    #endif
    var libraryPath = NavigationPath()
}
