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
    private let music = JellyfinMusicSession.shared

    private var repeatTitle: String {
        switch music.repeatMode {
        case .off: "Repeat All"
        case .all: "Repeat One"
        case .one: "Turn Repeat Off"
        }
    }

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

        // Music is one session for the whole app, so these act on it from any window. The shortcuts carry
        // Option so they leave editing keys (Command-arrows in a text field) alone.
        CommandMenu("Music") {
            Button(music.isPlaying ? "Pause" : "Play") { music.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next") { music.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous") { music.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button(music.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On") { music.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button(repeatTitle) { music.toggleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Volume Up") { music.setVolume(music.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { music.setVolume(music.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Mini Player") { openWindow(id: MusicMiniPlayerWindowView.windowID) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
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
