/*
 Hypnos - tvOS root

 The Apple TV app's single scene root (see `HypnosApp`). A plain SwiftUI
 `TabView` on tvOS already renders as the platform's top tab bar — no
 ornament, no custom chrome needed to get that shape, unlike visionOS/iOS.

 Deliberately not a port of `ContentView`: that view's tabs, ornament and
 gestures are all touch/gaze-shaped (see `Hypnos/CLAUDE.md` "tvOS" for what's
 excluded and why). This is a fresh, small root built for a Siri Remote:
 five tabs (Pictures, Videos, Albums, Library, Settings), no developer tabs,
 no Windows tab (nothing to summon — tvOS has one scene), no Filters tab
 (nothing there to filter by yet on a remote-driven grid).
 */

#if os(tvOS)

import SwiftUI

struct TVRootView: View {
    let appModel: AppModel
    @State private var selectedTab: TVTab

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
        TVTab.allCases.filter { $0 != .library || FilmSession.shared.isConfigured }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(visibleTabs) { tab in
                tabContent(tab)
                    .tag(tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                    }
            }
        }
        .environment(appModel)
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
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
        case .library:
            TVLibraryTabView()
        case .settings:
            TVSettingsView()
        }
    }
}

#endif
