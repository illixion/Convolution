/*
 Hypnos - tvOS Library tab root

 The Apple-TV-app-style Library: a full-bleed featured hero over shelves,
 pushing to a detail page. One `NavigationStack`, so the Siri Remote's Menu
 button pops a detail page for free, and one `LibraryPlayback` shared by
 every screen in the stack, so the players are presented once, here.

 The load is keyed on `LibraryService.configurationKey`: on a first launch
 the tab can appear before a sign-in finishes, and keying the task on the
 credentials reloads the moment it does, instead of leaving "no server
 configured" up until a relaunch.
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryTabView: View {
    @State private var model = LibraryHomeViewModel()
    @State private var playback = LibraryPlayback()
    @State private var path = NavigationPath()
    @State private var topShelfItemInFlight: String?

    var body: some View {
        NavigationStack(path: $path) {
            TVLibraryHomeView(model: model, playback: playback)
                .navigationDestination(for: LibraryItem.self) { item in
                    TVLibraryDetailView(item: item, playback: playback)
                }
        }
        .environment(\.libraryOpenDetail) { path.append($0) }
        .libraryPlayback(playback)
        .task(id: LibraryService.configurationKey) {
            await model.start()
            await openAutoOpenItemIfRequested()
            await openTopShelfItemIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvTopShelfLibraryPlay)) { notification in
            guard let itemID = notification.object as? String else { return }
            HypnosDefaults.store.set(itemID, forKey: "tvTopShelfPendingItemID")
            Task { await openTopShelfItemIfRequested() }
        }
        .onChange(of: LibraryWatchState.shared.revision) {
            Task { await model.refresh() }
        }
    }

    /// DEBUG-only, mirroring `tvAutoOpenPictureIndex`/`tvAutoPlayVideoIndex`
    /// (`Hypnos/CLAUDE.md` "tvOS"): `-UITestDefault
    /// tvLibraryAutoOpenItemId=<id>` pushes straight to that item's detail
    /// page. There is no remote-button injection on the tvOS simulator, so
    /// this is the only way to drive navigation into a detail page for
    /// verification.
    private func openAutoOpenItemIfRequested() async {
        #if DEBUG
        guard path.isEmpty,
              let itemId = HypnosDefaults.store.string(forKey: "tvLibraryAutoOpenItemId"),
              let library = LibraryService.current(),
              let item = try? await library.item(id: itemId)
        else { return }
        path.append(item)
        #endif
    }

    private func openTopShelfItemIfRequested() async {
        guard let itemID = HypnosDefaults.store.string(forKey: "tvTopShelfPendingItemID"),
              itemID != topShelfItemInFlight,
              let library = LibraryService.current()
        else { return }
        topShelfItemInFlight = itemID
        HypnosDefaults.store.removeObject(forKey: "tvTopShelfPendingItemID")
        defer { topShelfItemInFlight = nil }
        guard let item = try? await library.item(id: itemID) else { return }
        await playback.play(item)
    }
}

#endif
