/*
 Hypnos - tvOS Library tab root

 The Apple-TV-app-style home screen: a hero pick, then horizontal shelves.
 Wraps everything in one `NavigationStack` so a poster/episode push and the
 Siri Remote Menu button ("back") come from `NavigationDestination`/
 `NavigationStack` for free — no custom back handling needed, unlike
 `TVPhotoViewerView`'s `.onExitCommand` (that view has no navigation stack
 to pop).
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryTabView: View {
    @State private var model = LibraryHomeViewModel()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TVLibraryHomeView(model: model)
                .navigationDestination(for: LibraryItem.self) { item in
                    TVLibraryDetailView(item: item)
                }
        }
        .task {
            await model.start()
            await openAutoOpenItemIfRequested()
        }
    }

    /// DEBUG-only, mirroring `tvAutoOpenPictureIndex`/`tvAutoPlayVideoIndex`
    /// (`Hypnos/CLAUDE.md` "tvOS"): `-UITestDefault
    /// tvLibraryAutoOpenItemId=<id>` pushes straight to that item's detail
    /// page. There is no remote-button injection on the tvOS simulator, so
    /// this is the only way to drive navigation into a detail/season/
    /// episode page for verification.
    private func openAutoOpenItemIfRequested() async {
        #if DEBUG
        guard let itemId = UserDefaults.standard.string(forKey: "tvLibraryAutoOpenItemId"),
              let library = LibraryService.current(),
              let item = try? await library.item(id: itemId)
        else { return }
        path.append(item)
        #endif
    }
}

#endif
