/*
 Hypnos - Music section: going to an album or an artist from wherever its name is shown.

 Any album or artist name in the Music section is a link, as in iTunes: a row's artist and album, a tile's artist,
 an album's header, Now Playing, the Up Next list, the Mini Player, Cover Flow. Where a screen is inside the
 library's navigation stack (`\.musicOpen`, set by `LibraryTabRootView`) the link pushes onto it. Where it is
 not (the Now Playing sheet, the Mini Player and visualizer windows) it asks `MusicNavigator`, which the library
 answers by showing the Music section and pushing the item.
 */

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - What a name stands for

/// An artist as a song or album names it: the name to show, and the artist item behind it when the server gave an id.
struct MusicNameRef: Hashable, Sendable {
    let name: String
    let id: String?
}

extension JellyfinMusicItem {
    /// Who to show for a song or album, each name with its artist id. A song shows its own artists (a
    /// compilation's tracks differ from the album's artist); an album shows its album artists.
    var artistRefs: [MusicNameRef] {
        func refs(_ pairs: [JellyfinMusicNameID]?) -> [MusicNameRef] { (pairs ?? []).map { MusicNameRef(name: $0.Name, id: $0.Id) } }
        if isSong {
            let own = refs(ArtistItems)
            if !own.isEmpty { return own }
            if let names = Artists, !names.isEmpty {
                // The ids the server gave for the album's artists cover a name list that lacks its own.
                let known = Dictionary((AlbumArtists ?? []).compactMap { pair in pair.Id.map { (pair.Name, $0) } }, uniquingKeysWith: { first, _ in first })
                return names.map { MusicNameRef(name: $0, id: known[$0]) }
            }
        }
        let album = refs(AlbumArtists)
        if !album.isEmpty { return album }
        let own = refs(ArtistItems)
        if !own.isEmpty { return own }
        return [MusicNameRef(name: AlbumArtist ?? Artists?.first ?? "Unknown Artist", id: nil)]
    }

    /// The album a song sits on, as something to open; nil when the server didn't say which.
    func albumReference() -> JellyfinMusicItem? {
        guard isSong || self.Type == "MusicAlbum" else { return nil }
        let id = isSong ? AlbumId : Id
        guard let id else { return nil }
        return .reference(id: id, name: Album ?? (isSong ? "Album" : Name), type: "MusicAlbum", artist: AlbumArtist)
    }

    /// An artist from a name on this item, as something to open.
    static func artistReference(_ ref: MusicNameRef) -> JellyfinMusicItem? {
        guard let id = ref.id else { return nil }
        return .reference(id: id, name: ref.name, type: "MusicArtist")
    }
}

// MARK: - Navigation

/// A request to show an album, artist, playlist or genre in the library, from somewhere outside the library's
/// own navigation stack. The library takes it (`LibraryTabRootView`), switches to the Music section and pushes it.
@MainActor @Observable
final class MusicNavigator {
    static let shared = MusicNavigator()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let item: JellyfinMusicItem
    }

    private(set) var request: Request?
    /// How many main windows are on screen, so a link in the Mini Player knows whether one has to be opened.
    private(set) var mainWindows = 0

    func show(_ item: JellyfinMusicItem) { request = Request(item: item) }

    /// The pending request, once: whichever library takes it clears it for the others.
    func take() -> Request? {
        defer { request = nil }
        return request
    }

    func mainWindowAppeared() { mainWindows += 1 }
    func mainWindowDisappeared() { mainWindows = max(0, mainWindows - 1) }
}

#if os(macOS) || os(visionOS)
extension MusicNavigator {
    /// Bring the library forward for a name tapped in a window beside it (the Mini Player, the visualizer): a
    /// main window comes to the front, or one opens when there is none. visionOS has no way to raise a given
    /// window, so there a name tapped with the library open navigates it where it is.
    func revealLibrary(openWindow: WindowOpenAction) {
        guard mainWindows > 0 else {
            openWindow(id: HypnosSceneID.main, value: UUID())
            return
        }
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.hasPrefix(HypnosSceneID.main) ?? false) }?.makeKeyAndOrderFront(nil)
        #endif
    }
}
#endif

extension View {
    /// Makes the album and artist names inside this view open in the library. For a screen that is not inside the
    /// library's navigation stack: Now Playing (a sheet), the Mini Player and the visualizer (windows).
    /// `dismiss` closes the screen first, where it covers the library; `reveal` brings the library forward.
    func musicNamesOpenLibrary(dismiss: (() -> Void)? = nil, reveal: (() -> Void)? = nil) -> some View {
        environment(\.musicOpen) { item in
            dismiss?()
            MusicNavigator.shared.show(item)
            reveal?()
        }
    }
}

// MARK: - Link views

/// A name that opens its album or artist. Plain text where it leads nowhere (no id, or no screen to open it in).
struct MusicLinkText: View {
    let text: String
    /// Builds what to open. Called on tap, so a list of rows builds nothing until someone taps.
    let target: () -> JellyfinMusicItem?
    /// Whether there is anything to open; a name without an id is shown but dead.
    var isLive = true
    @Environment(\.musicOpen) private var open
    @State private var hovering = false

    var body: some View {
        if isLive, let open {
            Button {
                if let item = target() { open(item) }
            } label: {
                Text(text)
                    .underline(hovering)
                    .lineLimit(1)
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(MusicLinkButtonStyle())
            #if !os(tvOS)
            .onHover { hovering = $0 }
            #endif
            #if os(visionOS) || os(iOS)
            .hoverEffect(.highlight)
            #endif
            .accessibilityAddTraits(.isLink)
            .accessibilityHint("Opens \(text)")
            .animation(.easeOut(duration: 0.12), value: hovering)
        } else {
            Text(text).lineLimit(1)
        }
    }
}

/// Dims while pressed and otherwise takes the text style of where it sits, so a link reads as the line it is in.
struct MusicLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The artists of a song or album as links separated by commas ("Daft Punk, Pharrell Williams").
struct MusicArtistLine: View {
    let item: JellyfinMusicItem

    var body: some View {
        let refs = item.artistRefs
        HStack(spacing: 0) {
            ForEach(Array(refs.enumerated()), id: \.offset) { index, ref in
                MusicLinkText(text: ref.name, target: { JellyfinMusicItem.artistReference(ref) }, isLive: ref.id != nil)
                if index < refs.count - 1 { Text(", ").lineLimit(1) }
            }
        }
    }
}

/// A song's album as a link.
struct MusicAlbumLink: View {
    let item: JellyfinMusicItem
    var fallback = ""

    var body: some View {
        if let album = item.Album, !album.isEmpty {
            MusicLinkText(text: album, target: { item.albumReference() }, isLive: item.isSong ? item.AlbumId != nil : true)
        } else if !fallback.isEmpty {
            Text(fallback)
        }
    }
}

/// "Artist · Album" with each name its own link: the subtitle under a song's title.
struct MusicSongSubtitle: View {
    let song: JellyfinMusicItem
    var showsAlbum = true

    var body: some View {
        HStack(spacing: 0) {
            MusicArtistLine(item: song)
            if showsAlbum, let album = song.Album, !album.isEmpty {
                Text(" · ").lineLimit(1)
                MusicAlbumLink(item: song)
            }
        }
        .layoutPriority(0)
    }
}
