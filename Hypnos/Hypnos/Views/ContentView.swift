/*
 Hypnos - Content View

 Root view with tab-based content switching. visionOS hangs the tab bar off the
 window as an ornament (`TabBarOrnament`); iOS uses the system `TabView`, with
 the ornament's extra controls (library switch, slideshow) in each tab's
 navigation bar. Everything else — the first-run flow, the pending-filter
 hand-off and the window-open queues — is shared.
 */

import RAVEUI
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow
    @State private var windowModel = MainWindowModel()
    #if !os(visionOS)
    @Environment(IOSWindowRouter.self) private var router: IOSWindowRouter?
    #endif

    /// Whether this window is showing the first-run flow.
    private var showWelcome: Bool { !appModel.hasCompletedWelcome }

    var body: some View {
        ZStack {
            tabs

            // First run, over the top of everything. Not a sheet: the intro
            // screen is a photo meant to be leaned into, and a sheet on
            // visionOS is a small panel in front of the window.
            if showWelcome {
                WelcomeFlowView {
                    windowModel.selectedTab = windowModel.lastContentTab
                }
                .environment(appModel)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: windowModel.selectedTab)
        .animation(.smooth(duration: 0.35), value: showWelcome)
        // Filters has nothing to filter by in a file-tree library, and Albums
        // has nothing to browse in one with no folder browser, so each hides
        // itself in the tab bar — but if it was already open when the library
        // changed, hiding the button alone would strand this window on a
        // screen with no way back to it. Redirected here, in one place,
        // regardless of which of several controls changed the library.
        .onChange(of: appModel.effectiveLibrarySource) { _, newSource in
            let stranded = (windowModel.selectedTab == .filters && !newSource.offersFilters)
                || (windowModel.selectedTab == .albums && !newSource.offersAlbums)
            if stranded {
                windowModel.selectedTab = windowModel.lastContentTab
            }
        }
        .environment(appModel)
        .environment(windowModel)
        #if os(visionOS)
        .ornament(
            // Nothing behind the welcome flow is useful yet, and a visible tab
            // bar under it invites an escape into an empty gallery.
            visibility: showWelcome ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            contentAlignment: .top,
            ornament: {
                TabBarOrnament()
                    .environment(appModel)
                    .environment(windowModel)
            }
        )
        #endif
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        appModel.mainWindowSize = geo.size
                    }
                    .onChange(of: geo.size) { _, newSize in
                        appModel.mainWindowSize = newSize
                    }
            }
        )

        .alert(
            "Window Already Open",
            isPresented: Binding(
                get: { shouldShowDuplicatePrompt },
                set: { _ in }
            )
        ) {
            Button("Summon") {
                summonDuplicatePhotoWindow()
            }
            Button("Open Copy") {
                allowDuplicatePhotoWindowOpen()
            }
            Button("Cancel", role: .cancel) {
                appModel.cancelPendingPhotoWindowOpens()
            }
        } message: {
            Text("A window for this image is already open. You can summon it or open a copy.")
        }
        .alert(
            "Viewer Already Open",
            isPresented: Binding(
                get: { shouldShowRemoteViewerDuplicatePrompt },
                set: { _ in }
            )
        ) {
            Button("Summon") {
                summonDuplicateRemoteViewer()
            }
            Button("Open Copy") {
                allowDuplicateRemoteViewerOpen()
            }
            Button("Cancel", role: .cancel) {
                appModel.cancelPendingRemoteViewerOpens()
            }
        } message: {
            Text("A viewer with this configuration is already open. You can summon it or open a copy.")
        }
        .onAppear {
            // Only once a scene is on screen: the prompt is presented on the
            // app's own window, so asking for it before that hangs the launch.
            if appModel.usesLocalNetworkFeatures {
                LocalNetworkPermission.prewarm(reason: "gallery appeared with a LAN source configured")
            }
            consumePendingGalleryFilterIfNeeded()
            handlePhotoWindowOpenIfNeeded()
            handleVideoWindowOpenIfNeeded()
            handleRemoteViewerOpenIfNeeded()
        }
        .onChange(of: appModel.activePhotoWindowOpenRequest?.id) { _, _ in
            handlePhotoWindowOpenIfNeeded()
        }
        .onChange(of: appModel.activeVideoWindowOpenRequest?.id) { _, _ in
            handleVideoWindowOpenIfNeeded()
        }
        .onChange(of: appModel.activeRemoteViewerOpenRequest?.id) { _, _ in
            handleRemoteViewerOpenIfNeeded()
        }
        #if !os(visionOS)
        // On visionOS a tag tapped in an info sheet opens a *new* main window,
        // whose onAppear adopts the seeded filter. iOS has one gallery, so the
        // router's "show main" request is the moment to adopt it instead.
        .onChange(of: router?.mainWindowRequests) { _, _ in
            consumePendingGalleryFilterIfNeeded()
        }
        #endif
    }

    // MARK: - Tabs

    @ViewBuilder
    private func tabContent(_ tab: Tab) -> some View {
        switch tab {
        case .pictures:
            PicturesTabView()
        case .videos:
            VideosTabView()
        case .albums:
            AlbumsTabView()
        case .library:
            LibraryHomePlaceholderView()
        case .filters:
            FiltersTabView()
        case .windows:
            WindowsTabView()
        case .settings:
            SettingsTabView()
        case .remote:
            RemoteTabView()
        case .console:
            ConsoleTabView()
        }
    }

    #if os(visionOS)
    private var tabs: some View {
        Group {
            tabContent(windowModel.selectedTab)
        }
        .id(windowModel.selectedTab)
        .transition(.opacity)
    }
    #else
    /// The system tab bar. Tabs that already carry their own `NavigationStack`
    /// (Filters, Remote, Settings) are used as-is; the rest get one so they
    /// have a title bar for the library switch, slideshow and Select buttons.
    private var tabs: some View {
        TabView(selection: tabSelection) {
            ForEach(MainTabCatalog.visibleTabs(appModel: appModel)) { tab in
                SwiftUI.Tab(tab.rawValue, systemImage: tab.systemImage, value: tab) {
                    iosTabPage(tab)
                }
                .accessibilityIdentifier(tab.accessibilityIdentifier)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    @ViewBuilder
    private func iosTabPage(_ tab: Tab) -> some View {
        Group {
            switch tab {
            case .filters, .remote, .settings:
                tabContent(tab)
            default:
                NavigationStack {
                    tabContent(tab)
                        .navigationTitle(tab.rawValue)
                        #if !os(tvOS) && !os(macOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        #if !os(macOS)
                        .toolbar {
                            IOSTabToolbar(tab: tab)
                        }
                        #endif
                }
            }
        }
        // Nothing behind the welcome flow is useful yet, and a visible tab
        // bar under it invites an escape into an empty gallery. Set on the
        // page, not the TabView — tab-bar visibility is a content preference.
        // No `.tabBar` toolbar placement on macOS (this whole `#else` branch
        // is dead code there anyway — the Mac UI uses `MacRootView` instead).
        #if !os(macOS)
        .toolbarVisibility(showWelcome ? .hidden : .visible, for: .tabBar)
        #endif
    }

    /// Routed through `MainTabCatalog.select` rather than straight to the
    /// model: re-tapping Albums while already there is a "pop to the folder
    /// root" gesture for its local-folder browser, which a plain selection
    /// binding cannot see. The system tab bar does call the setter with the
    /// same value on a re-tap.
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { windowModel.selectedTab },
            set: { MainTabCatalog.select($0, in: windowModel) }
        )
    }
    #endif

    // MARK: - Pending Gallery Filter (tag-tapped from media info)

    /// If a tag was tapped in a media info sheet, this newly created main window
    /// adopts the seeded filter: switch to the right content tab and run the
    /// query. Consumed once so other/existing windows don't also react.
    private func consumePendingGalleryFilterIfNeeded() {
        guard let pending = appModel.pendingGalleryFilter else { return }
        appModel.pendingGalleryFilter = nil
        if pending.isVideo {
            windowModel.selectedTab = .videos
            windowModel.lastContentTab = .videos
            Task { await appModel.applyVideoFilter() }
        } else {
            windowModel.selectedTab = .pictures
            windowModel.lastContentTab = .pictures
            Task { await appModel.applyFilter() }
        }
    }

    // MARK: - Photo Window Duplicate Handling

    private var shouldShowDuplicatePrompt: Bool {
        guard let request = appModel.activePhotoWindowOpenRequest else { return false }
        return appModel.shouldConfirmDuplicateOpen(for: request)
    }

    private func handlePhotoWindowOpenIfNeeded() {
        guard let request = appModel.activePhotoWindowOpenRequest else { return }
        guard !appModel.shouldConfirmDuplicateOpen(for: request) else { return }

        // Same visionOS 27 parked-scene hazard as the remote viewer (see
        // handleRemoteViewerOpenIfNeeded): dismiss the parked scene and open a
        // fresh window instead of recalling the same value.
        if case .backgroundedInOtherRoom = appModel.existingWindowState(for: request.image.fullSizeURL) {
            for value in appModel.popOutWindowValues(for: request.image.fullSizeURL) {
                dismissWindow(id: "photo-detail", value: value)
            }
        }

        appModel.advancePhotoWindowOpenQueue()
        var value = PhotoWindowValue(image: request.image)
        // Group restores carry the geometry the window was saved at; the display
        // view applies it on appear.
        value.restoredSize = request.restoredSize.map(RAVECodableSize.init)
        openWindow(id: "photo-detail", value: value)
    }

    // MARK: - Video Window Opens

    /// Video windows have no duplicate-summon dialog; the queue only exists so
    /// AppModel can hand a fully-built window value to a view that owns an
    /// `openWindow` action (window-group restores).
    private func handleVideoWindowOpenIfNeeded() {
        guard let request = appModel.activeVideoWindowOpenRequest else { return }
        appModel.advanceVideoWindowOpenQueue()
        openWindow(id: "video-detail", value: request.windowValue)
    }

    private func summonDuplicatePhotoWindow() {
        guard let request = appModel.activePhotoWindowOpenRequest else { return }
        let existingValues = appModel.popOutWindowValues(for: request.image.fullSizeURL)
        if let existingValue = existingValues.first {
            openWindow(id: "photo-detail", value: existingValue)
        }
        appModel.advancePhotoWindowOpenQueue()
    }

    private func allowDuplicatePhotoWindowOpen() {
        appModel.confirmDuplicateOpen()
        handlePhotoWindowOpenIfNeeded()
    }

    // MARK: - Remote Viewer Duplicate Handling

    private var shouldShowRemoteViewerDuplicatePrompt: Bool {
        guard let request = appModel.activeRemoteViewerOpenRequest else { return false }
        return appModel.shouldConfirmDuplicateRemoteViewerOpen(for: request)
    }

    private func handleRemoteViewerOpenIfNeeded() {
        guard let request = appModel.activeRemoteViewerOpenRequest else { return }
        guard !appModel.shouldConfirmDuplicateRemoteViewerOpen(for: request) else { return }

        // Never recall a scene parked in another room by re-opening its value:
        // visionOS 27's room persistence can activate the parked scene without
        // ever re-attaching it to a placement, leaving the window permanently
        // invisible and non-interactable (reproduces with the stock Clock app;
        // see internal_docs/visionos27-invisible-window-feedback.md). Destroy
        // the parked scene and open a fresh one at the user instead —
        // re-opening alone never re-placed the window anyway (see
        // WindowGroupRestoreSheet.summonExistingWindow).
        if case .backgroundedInOtherRoom = appModel.existingRemoteViewerWindowState(for: request.configId) {
            for value in appModel.remoteViewerWindowValues(for: request.configId) {
                dismissWindow(id: "remote-viewer", value: value)
            }
        }

        appModel.advanceRemoteViewerOpenQueue()
        var value = RemoteViewerWindowValue(configId: request.configId)
        value.restoredSize = request.restoredSize.map(RAVECodableSize.init)
        openWindow(id: "remote-viewer", value: value)
    }

    private func summonDuplicateRemoteViewer() {
        guard let request = appModel.activeRemoteViewerOpenRequest else { return }
        let existingValues = appModel.remoteViewerWindowValues(for: request.configId)
        if let existingValue = existingValues.first {
            openWindow(id: "remote-viewer", value: existingValue)
        }
        appModel.advanceRemoteViewerOpenQueue()
    }

    private func allowDuplicateRemoteViewerOpen() {
        appModel.confirmDuplicateRemoteViewerOpen()
        handleRemoteViewerOpenIfNeeded()
    }
}
