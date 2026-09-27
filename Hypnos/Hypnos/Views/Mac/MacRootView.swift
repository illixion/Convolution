/*
 Hypnos - macOS root

 The Mac app's main-window root. A `NavigationSplitView` sidebar in place of
 visionOS/iOS's `TabBarOrnament` — the Mac-idiomatic shape for exactly this
 kind of "a few top-level sections, one shown at a time" navigation, the same
 way `Views/TV/TVRootView.swift` picked a plain `TabView` for its own
 platform's idiom instead of porting the ornament. Like tvOS, this shares data
 (`AppModel.galleryImages`/`galleryVideos`, `MediaContainer`) with the
 visionOS/iOS screens but reuses almost none of their views: the ornament
 chrome, gestures and RealityKit/UIKit-bound viewer machinery those build on
 are gaze/touch-shaped and not part of the seam list this pass ported (see
 `Hypnos/CLAUDE.md` "macOS").
 */

#if os(macOS)

import SwiftUI

struct MacRootView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection: MacTab?

    /// DEBUG-only, mirroring tvOS's `tvInitialTab` (`Support/
    /// UITestingConfiguration.swift`): `-UITestDefault macInitialTab=Videos`
    /// opens straight to a given sidebar section, since the auto-open hooks
    /// in `MacPicturesView`/`MacVideosView` only run once their tab's view
    /// actually exists — a tab never selected is never even instantiated.
    init() {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "macInitialTab"),
           let tab = MacTab(rawValue: raw) {
            _selection = State(initialValue: tab)
        } else {
            _selection = State(initialValue: .pictures)
        }
        #else
        _selection = State(initialValue: .pictures)
        #endif
    }

    /// Hidden until a Jellyfin server is configured — see the Library
    /// feature's decision #3, same gate tvOS/visionOS/iOS apply.
    private var visibleTabs: [MacTab] {
        MacTab.allCases.filter { $0 != .library || LibraryService.isAvailable }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleTabs, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            content
                .navigationTitle(selection?.rawValue ?? "Hypnos")
        }
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hypnosSelectTab)) { notification in
            guard let tab = notification.object as? MacTab else { return }
            selection = tab
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .pictures, nil:
            MacPicturesView()
        case .videos:
            MacVideosView()
        case .albums:
            MacAlbumsView(selection: $selection)
        case .library:
            LibraryTabRootView()
        case .settings:
            MacSettingsView()
        }
    }
}

#endif
