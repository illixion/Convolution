/*
 Hypnos - Music section: the Mini Player window.

 iTunes's mini player, laid out as Longwave's audio panel is: the cover edge to edge at the top, the song under
 it, and the same transport strip the library's mini player uses. It is a window of its own, so a Mac or a
 Vision Pro can park it beside other work while the library window is somewhere else; it follows the one
 `JellyfinMusicSession`, so it and the library's mini player never disagree.
 */

#if os(macOS) || os(visionOS)

import SwiftUI
import RAVEUI

struct MusicMiniPlayerWindowView: View {
    static let windowID = "music-mini-player"
    static let width: CGFloat = 340

    @State private var music = JellyfinMusicSession.shared
    @State private var actions = MusicActions()
    @State private var showsQueue = false

    var body: some View {
        Group {
            if let current = music.current { panel(current) } else { idle }
        }
        .frame(width: Self.width)
        .musicActionHost(actions, bottomInset: 16)
        #if os(visionOS)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
        #else
        .containerBackground(.regularMaterial, for: .window)
        #endif
        .animation(.smooth(duration: 0.25), value: music.current?.id)
    }

    private func panel(_ current: JellyfinMusicItem) -> some View {
        RAVEMiniPlayerPanel(width: Self.width, title: current.Name, subtitle: current.artist, detail: current.Album) {
            MusicArtwork(item: current, music: music, maxWidth: 720)
                .id(current.id)
                .transition(.opacity)
        } actions: {
            actionRow(current)
        } transport: {
            MusicTransportStrip(music: music)
        }
    }

    private func actionRow(_ current: JellyfinMusicItem) -> some View {
        HStack(spacing: 26) {
            let favorite = MusicUserState.shared.isFavorite(current)
            Button { Task { await MusicUserState.shared.toggleFavorite(current, actions: actions) } } label: {
                Image(systemName: favorite ? "heart.fill" : "heart").foregroundStyle(favorite ? .pink : .primary)
            }
            .accessibilityLabel(favorite ? "Remove from Favorites" : "Favorite")
            MusicStarsMenu(item: current).labelStyle(.iconOnly)
            Button { showsQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel("Up Next")
                .popover(isPresented: $showsQueue) {
                    MusicUpNextList(music: music, actions: actions)
                        .frame(width: 340, height: 420)
                }
            Menu { MusicItemMenu(item: current) } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    private var idle: some View {
        RAVEMiniPlayerPlaceholder(width: Self.width, message: "Play a song from your Jellyfin library.")
    }
}

#endif
