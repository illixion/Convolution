/*
 Hypnos - Videos Tab View

 Container view for the Videos tab.
 Videos open via pushWindow (gallery is backgrounded and restored on dismiss)
 or via openWindow when "Open media in new windows" is enabled.
 */

import SwiftUI

struct VideosTabView: View {
    @Environment(AppModel.self) private var appModel
    #if DEBUG
    @OpenWindowProxy private var openWindow
    #endif

    var body: some View {
        VStack(spacing: 0) {
            AppliedContainerBanner(isVideo: true)
            VideoGalleryView()
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if DEBUG
        // `-UITestDefault autoStartSlideshow=1`: the toolbar's slideshow of
        // what the tab shows, once it has loaded (read once).
        .task(id: appModel.galleryVideos.isEmpty) {
            guard UserDefaults.standard.bool(forKey: "autoStartSlideshow"),
                  let launch = MainTabCatalog.slideshowLaunch(appModel: appModel, selectedTab: .videos) else { return }
            UserDefaults.standard.removeObject(forKey: "autoStartSlideshow")
            launch.start()
        }
        // `-UITestDefault autoOpenVideoIndex=<n>`: that video opens once
        // the grid has it (read once). tvOS has `tvAutoPlayVideoIndex`.
        .task(id: appModel.galleryVideos.count) {
            guard let index = UserDefaults.standard.object(forKey: "autoOpenVideoIndex") as? Int,
                  appModel.galleryVideos.indices.contains(index) else { return }
            UserDefaults.standard.removeObject(forKey: "autoOpenVideoIndex")
            openWindow(id: "video-detail", value: VideoWindowValue(video: appModel.galleryVideos[index],
                                                                   galleryVideos: appModel.galleryVideos))
        }
        #endif
    }
}
