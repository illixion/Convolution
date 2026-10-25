/*
 Hypnos - macOS menu bar commands

 The `.commands` this app's macOS scene attaches to the main-window
 `WindowGroup`. The Library menu's tab items go through `NotificationCenter`
 rather than a shared `@State` selection, because `.commands` closures have no
 access to a specific window's view state (they belong to the app, not one
 scene instance): every gallery window (`ContentView`) follows them. Play/Pause
 acts on the video window that is key, through its focused scene value. Its keys
 (space, the arrows) are the video window's own (`VideoWindowView`): as menu
 shortcuts they would also take keys typed into a text field.
 */

#if os(macOS)

import SwiftUI

extension Notification.Name {
    static let hypnosSelectTab = Notification.Name("Hypnos.selectTab")
}

extension FocusedValues {
    /// The key video window's player.
    @Entry var videoWindowModel: VideoWindowModel?
}

struct HypnosCommands: Commands {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.videoWindowModel) private var video

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Library") {
            ForEach(MainTabCatalog.visibleTabs(appModel: appModel)) { tab in
                Button(tab.rawValue) {
                    NotificationCenter.default.post(name: .hypnosSelectTab, object: tab)
                }
            }
        }

        CommandMenu("Playback") {
            Button(video?.isPaused == false ? "Pause" : "Play") {
                video?.togglePlayPause()
            }
            .disabled(video == nil)

            Button("Back 10 Seconds") {
                video?.seek(by: -10)
            }
            .disabled(video == nil)

            Button("Forward 10 Seconds") {
                video?.seek(by: 10)
            }
            .disabled(video == nil)

            Divider()

            Button(video?.isMuted == true ? "Unmute" : "Mute") {
                video?.toggleMute()
            }
            .disabled(video == nil)
        }
    }
}

#endif
