/*
 Hypnos - iOS tab toolbar

 The controls the visionOS tab-bar ornament carries past its divider — the
 library switch and the slideshow button — placed in a tab's navigation bar on
 iOS, and in the window's toolbar on macOS. What is offered comes from
 `MainTabCatalog`, the same source the ornament reads, so the platforms agree
 on when each control appears.
 */

#if !os(visionOS)

import SwiftUI

struct IOSTabToolbar: ToolbarContent {
    let tab: Tab
    @Environment(AppModel.self) private var appModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: Self.leading) {
            if MainTabCatalog.showsLibraryToggle(appModel: appModel, selectedTab: tab) {
                libraryMenu
            }
        }
        ToolbarItemGroup(placement: Self.trailing) {
            if let launch = MainTabCatalog.slideshowLaunch(appModel: appModel, selectedTab: tab) {
                Button(action: launch.start) {
                    Label(launch.help, systemImage: "play.fill")
                }
                .help(launch.help)
            }
        }
    }

    #if os(macOS)
    private static let leading = ToolbarItemPlacement.navigation
    private static let trailing = ToolbarItemPlacement.primaryAction
    #else
    private static let leading = ToolbarItemPlacement.topBarLeading
    private static let trailing = ToolbarItemPlacement.topBarTrailing
    #endif

    /// Which library the media tabs show. A menu of radio rows, like the
    /// ornament's popover.
    private var libraryMenu: some View {
        let current = appModel.effectiveLibrarySource
        return Menu {
            ForEach(appModel.availableLibrarySources, id: \.self) { source in
                Button {
                    guard current != source else { return }
                    appModel.librarySource = source
                } label: {
                    if current == source {
                        Label(source.displayName, systemImage: "checkmark")
                    } else {
                        Label(source.displayName, systemImage: source.symbolName)
                    }
                }
                .accessibilityIdentifier(A11y.librarySwitchOption(source.rawValue))
            }
        } label: {
            Label("Library — showing \(current.displayName)", systemImage: current.symbolName)
        }
        .accessibilityIdentifier(A11y.librarySwitch)
    }
}

#endif
