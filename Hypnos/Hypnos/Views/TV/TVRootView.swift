/*
 Hypnos - tvOS root

 The Apple TV app's single scene root (see `HypnosApp`). A plain SwiftUI
 `TabView` on tvOS already renders as the platform's top tab bar — no
 ornament, no custom chrome needed to get that shape, unlike visionOS/iOS.

 Deliberately not a port of `ContentView`: that view's tabs, ornament and
 gestures are all touch/gaze-shaped (see `Hypnos/CLAUDE.md` "tvOS" for what's
 excluded and why). This is a fresh, small root built for a Siri Remote:
 tabs for Pictures, Videos, Albums, Filters (Stash and Photos only),
 Library and Settings, no developer tabs, no Windows tab (nothing to
 summon — tvOS has one scene).

 Filter changes apply as the Filters tab is left, as elsewhere: whichever
 grid's filter changed reloads.
 */

#if os(tvOS)

import RAVEConsole
import SwiftUI

struct TVRootView: View {
    let appModel: AppModel
    @State private var selectedTab: TVTab
    /// Pictures or Videos, whichever was browsed last: what Filters edits first.
    @State private var lastContentTab: TVTab = .pictures
    /// Both filters as they were when Filters opened, to reload only the
    /// grid whose filter changed.
    @State private var filtersOnOpen: (pictures: ImageFilterCriteria, videos: SceneFilterCriteria)?

    init(appModel: AppModel) {
        self.appModel = appModel
        // DEBUG-only: reuses the existing `-UITestDefault key=value` launch
        // argument (Support/UITestingConfiguration.swift), which already
        // lands in UserDefaults before this view is built. There is no
        // XCUITest driving tvOS yet (HypnosUITests stays visionOS-only) and
        // simctl has no remote-button injection of its own, so this is what
        // let screenshots of every tab get taken at all —
        // `-UITestDefault tvInitialTab=Videos` opens straight to Videos.
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "tvInitialTab"),
           let tab = TVTab(rawValue: raw) {
            _selectedTab = State(initialValue: tab)
        } else {
            _selectedTab = State(initialValue: .pictures)
        }
        #else
        _selectedTab = State(initialValue: .pictures)
        #endif
    }

    /// Hidden until a Jellyfin server is configured — see the Library
    /// feature's decision #3, same gate `MainTabCatalog` applies on
    /// visionOS/iOS.
    private var visibleTabs: [TVTab] {
        TVTab.allCases.filter { tab in
            switch tab {
            case .library: LibraryService.isAvailable
            case .filters: appModel.effectiveLibrarySource.offersFilters
            case .console: appModel.showDebugConsole
            default: true
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(visibleTabs) { tab in
                SwiftUI.Tab(tab.rawValue, systemImage: tab.systemImage, value: tab) {
                    tabContent(tab)
                }
            }
        }
        .environment(appModel)
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
        }
        .onChange(of: selectedTab, initial: true) { old, new in
            if new == .pictures || new == .videos { lastContentTab = new }
            if new == .filters {
                filtersOnOpen = (appModel.currentFilter, appModel.currentVideoFilter)
            } else if old == .filters, let opened = filtersOnOpen {
                filtersOnOpen = nil
                applyFilterChanges(since: opened)
            }
        }
    }

    /// Leaving Filters: reload the grids whose filter changed there.
    private func applyFilterChanges(since opened: (pictures: ImageFilterCriteria, videos: SceneFilterCriteria)) {
        let picturesChanged = appModel.currentFilter != opened.pictures
        let videosChanged = appModel.currentVideoFilter != opened.videos
        guard picturesChanged || videosChanged else { return }
        Task {
            if picturesChanged { await appModel.loadInitialGallery() }
            if videosChanged { await appModel.loadInitialVideos() }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TVTab) -> some View {
        switch tab {
        case .pictures:
            TVPicturesTabView()
        case .videos:
            TVVideosTabView()
        case .albums:
            TVAlbumsTabView(selectedTab: $selectedTab)
        case .filters:
            TVFiltersTabView(startsWithVideos: lastContentTab == .videos)
        case .library:
            TVLibraryTabView()
        #if HYPNOS_YOUTUBE
        case .youtube:
            YouTubeTabView()
        #endif
        case .settings:
            TVSettingsView()
        case .console:
            RAVEConsoleScreen()
        }
    }
}

#endif
