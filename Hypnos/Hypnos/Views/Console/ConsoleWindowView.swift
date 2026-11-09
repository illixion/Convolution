/*
 Console pop-out window.

 The console itself — the OSLogStore polling, the level/category/search
 filtering, the clipboard export — is RAVEConsole now, shared with the four
 other apps. What stays here is this app's way back to its main window.
 */

import RAVEConsole
import SwiftUI

struct ConsoleWindowView: View {
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow

    var body: some View {
        // No pop-out button: this *is* the pop-out.
        RAVEConsoleScreen()
            // The way back to the gallery is only needed where this is its own
            // window; as an iOS sheet it has the sheet's Done button.
            .padding(.bottom, PlatformCapabilities.supportsMultipleWindows ? 56 : 0)   // clear the ornament
            .ornament(
                visibility: PlatformCapabilities.supportsMultipleWindows ? .visible : .hidden,
                attachmentAnchor: .scene(.bottomFront)
            ) {
                HStack(spacing: 16) {
                    Button {
                        appModel.showMainWindow(openWindow: openWindow)
                    } label: {
                        Label("Gallery", systemImage: "photo.on.rectangle")
                    }
                }
                .padding(12)
                .glassBackgroundEffect()
            }
    }
}

/// The console as a tab: the same screen, plus the button that pops it out.
struct ConsoleTabView: View {
    @OpenWindowProxy private var openWindow

    var body: some View {
        RAVEConsoleScreen { openWindow(id: HypnosSceneID.console) }
    }
}
