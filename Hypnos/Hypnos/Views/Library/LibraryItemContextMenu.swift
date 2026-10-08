/*
 Hypnos - Library item context menu (every platform)

 The long-press (right-click on macOS, press-and-hold Select on tvOS) menu
 on a Library lockup: play it, resume or start over, jump to its details or
 its show, and toggle Watched and Favorite without opening the detail page.

 Watched/Favorite go through `JellyfinLibrary`, which bumps
 `LibraryWatchState`, so the home shelves and an open detail page reload on
 their own. A screen that keeps its own copy of the items (Browse) passes
 `onUpdated` to swap in the server's fresh copy.
 */

import SwiftUI

extension EnvironmentValues {
    /// Pushes an item's detail page onto the Library's navigation stack.
    /// Set by the Library tab roots; nil where nothing can be pushed.
    @Entry var libraryOpenDetail: ((LibraryItem) -> Void)? = nil
}

struct LibraryItemContextMenu: View {
    let item: LibraryItem
    let playback: LibraryPlayback
    /// Offer "Go to Details". Off where a tap already opens them (posters).
    var showsDetails = true
    /// Offer "Go to <show>" on an episode. Off on the show's own page.
    var showsSeries = true
    var onUpdated: ((LibraryItem) -> Void)? = nil
    @Environment(\.libraryOpenDetail) private var openDetail

    var body: some View {
        if item.isPlayable || item.kind == .series {
            Section {
                if item.userData.resumeSeconds != nil {
                    Button("Resume", systemImage: "play.fill") { Task { await playback.play(item) } }
                    Button("Start Over", systemImage: "arrow.counterclockwise") {
                        Task { await playback.play(item, fromStart: true) }
                    }
                } else {
                    Button("Play", systemImage: "play.fill") { Task { await playback.play(item) } }
                }
            }
        }
        if let openDetail {
            Section {
                if showsDetails {
                    Button("Go to Details", systemImage: "info.circle") { openDetail(item) }
                }
                if showsSeries, item.kind == .episode, let seriesId = item.seriesId {
                    Button("Go to \(item.seriesName ?? "Show")", systemImage: "tv") {
                        Task { await openSeries(seriesId) }
                    }
                }
            }
        }
        Section {
            Button(item.userData.isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                   systemImage: item.userData.isPlayed ? "checkmark.circle.fill" : "checkmark.circle") {
                Task { await update { try await $0.setPlayed(itemId: item.id, played: !item.userData.isPlayed) } }
            }
            Button(item.userData.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: item.userData.isFavorite ? "heart.slash" : "heart") {
                Task { await update { try await $0.setFavorite(itemId: item.id, favorite: !item.userData.isFavorite) } }
            }
        }
    }

    private func openSeries(_ seriesId: String) async {
        guard let library = LibraryService.current() else { return }
        do {
            openDetail?(try await library.item(id: seriesId))
        } catch {
            playback.error = error.localizedDescription
        }
    }

    private func update(_ change: (JellyfinLibrary) async throws -> Void) async {
        guard let library = LibraryService.current() else { return }
        do {
            try await change(library)
            if let onUpdated {
                onUpdated(try await library.item(id: item.id))
            }
        } catch {
            playback.error = error.localizedDescription
        }
    }
}
