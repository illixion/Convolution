/*
 Hypnos - Tab Bar Ornament

 visionOS ornament-based tab navigation for Pictures, Videos, and Settings.
 */

import RAVEUI
import SwiftUI

#if os(visionOS)

struct TabBarOrnament: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel

    /// Drives the library switch's popover. A plain `@State` rather than
    /// something on `windowModel`: nothing outside this control cares, and
    /// scoping it locally is what lets the button be a genuine `Button`
    /// (see `libraryMenu` below) instead of routing through `Menu`.
    @State private var showLibraryPicker = false

    private var visibleTabs: [Tab] {
        let orderedTabs: [Tab] = [.pictures, .videos, .albums, .remote, .filters, .windows, .console, .settings]
        return orderedTabs.filter { tab in
            switch tab {
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
            default:
                return true
            }
        }
    }

    var body: some View {
        @Bindable var windowModel = windowModel
        RAVETabBar(
            tabs: visibleTabs,
            selection: $windowModel.selectedTab,
            // Routed through `select` rather than straight to the binding:
            // re-tapping Albums while already there is a "pop to the folder
            // root" gesture for its local-folder browser, which a plain
            // selection binding cannot see.
            onSelect: select
        ) {
            // Actions, not navigation: both act on the current tab rather than
            // moving between tabs, so they sit past a divider.
            if showsLibraryToggle || slideshowLaunch != nil {
                RAVETabBarDivider()
            }
            // Left of the slideshow button: which library the media tabs show.
            // Only meaningful with more than one source available — with
            // just Photos there is nothing to switch between. A dropdown
            // rather than a cycling button because a third source made
            // "tap to switch to the other one" ambiguous about where a tap
            // would land.
            if showsLibraryToggle {
                libraryMenu
            }
            if let launch = slideshowLaunch {
                RAVETabBarActionButton(
                    systemImage: "play.fill",
                    help: launch.help,
                    action: launch.start
                )
            }
        }
        .animation(.smooth(duration: 0.22), value: slideshowLaunch?.help)
        .animation(.smooth(duration: 0.22), value: appModel.effectiveLibrarySource)
    }

    /// Whether to offer the library switch: only with more than one source
    /// available, and only on the tabs that show one.
    private var showsLibraryToggle: Bool {
        guard appModel.availableLibrarySources.count > 1 else { return false }
        switch windowModel.selectedTab {
        case .pictures, .videos: return true
        default: return false
        }
    }

    /// The library switch, styled to match the other icon buttons in this
    /// bar (`RAVETabBarButtonStyle` is exposed by RAVEUI for exactly that).
    /// `availableLibrarySources` is the only thing that decides what's
    /// offered here — never how much either source currently has to show,
    /// so an empty-but-enabled Local library stays reachable to pull-to-
    /// refresh rather than disappearing until it has content.
    ///
    /// **A genuine `Button` behind a custom `.popover`, not a `Menu`.** A
    /// `Menu`'s trigger keeps a rectangular gaze-hover highlight on-device
    /// no matter what `.contentShape` it's given — confirmed after
    /// `.contentShape(.hoverEffect, Capsule())` alone still rendered
    /// rectangular in real headset testing, not just the simulator. Every
    /// other capsule in this bar is a plain `Button` with
    /// `RAVETabBarButtonStyle` + `.hoverEffect(.highlight)`
    /// (`RAVETabBarButtonStyle`/`RAVETabBarActionButton` in RAVEUI), and
    /// that combination is what actually produces the round highlight —
    /// so the trigger here is built the identical way, and the dropdown
    /// itself is a plain popover of rows instead of `Menu`'s built-in list.
    private var libraryMenu: some View {
        let current = appModel.effectiveLibrarySource
        return Button {
            showLibraryPicker = true
        } label: {
            Image(systemName: current.symbolName)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 32)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(RAVETabBarButtonStyle(isSelected: false))
        #if !os(macOS)
        .hoverEffect(.highlight)
        #endif
        .help("Library — showing \(current.displayName)")
        .accessibilityLabel("Library — showing \(current.displayName)")
        .accessibilityIdentifier(A11y.librarySwitch)
        .popover(isPresented: $showLibraryPicker) {
            libraryPickerList(current: current)
        }
    }

    /// The popover's contents: one row per available source, radio-style
    /// (checkmark on the active one), mirroring `VideoOrnamentsView.modeButton`.
    /// Sized generously rather than like a compact desktop menu — this is a
    /// gaze/pinch target in open space, not a mouse-hover list, so each row
    /// gets a full 60pt-plus tall tap area and roomy horizontal padding.
    private func libraryPickerList(current: LibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(appModel.availableLibrarySources, id: \.self) { source in
                libraryMenuItem(source, current: current)
            }
        }
        .padding(12)
        .frame(minWidth: 280, alignment: .leading)
    }

    private func libraryMenuItem(_ source: LibrarySource, current: LibrarySource) -> some View {
        Button {
            showLibraryPicker = false
            guard current != source else { return }
            appModel.librarySource = source
        } label: {
            HStack(spacing: 16) {
                Image(systemName: source.symbolName)
                    .font(.title2)
                    .frame(width: 28)
                Text(source.displayName)
                    .font(.title3)
                Spacer()
                if current == source {
                    Image(systemName: "checkmark")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityIdentifier(A11y.librarySwitchOption(source.rawValue))
    }

    /// What the play button would start, or nil when the current tab isn't
    /// showing anything a slideshow could run over.
    private var slideshowLaunch: (help: String, start: () -> Void)? {
        switch windowModel.selectedTab {
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

    private func select(_ tab: Tab) {
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

#endif
