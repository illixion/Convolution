/*
 Hypnos - Pictures Tab View

 Container view for the Pictures tab.
 Pictures open via pushWindow (gallery is backgrounded and restored on dismiss)
 or via openWindow when "Open media in new windows" is enabled.
 */

import SwiftUI

struct PicturesTabView: View {
    @Environment(AppModel.self) private var appModel
    @PushWindowProxy private var pushWindow
    
    var body: some View {
        VStack(spacing: 0) {
            AppliedContainerBanner(isVideo: false)
            GalleryGridView(onImageSelected: { image in
                if appModel.openMediaInNewWindows {
                    appModel.enqueuePhotoWindowOpen(image)
                } else {
                    pushWindow(id: "photo-detail", value: PhotoWindowValue(image: image, wasPushed: true))
                }
            })
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if DEBUG
        // `-UITestDefault autoStartSlideshow=1`: the toolbar's slideshow of
        // what the tab shows, once it has loaded (read once).
        .task(id: appModel.galleryImages.isEmpty) {
            guard UserDefaults.standard.bool(forKey: "autoStartSlideshow"),
                  let launch = MainTabCatalog.slideshowLaunch(appModel: appModel, selectedTab: .pictures) else { return }
            UserDefaults.standard.removeObject(forKey: "autoStartSlideshow")
            launch.start()
        }
        // `-UITestDefault autoOpenImageIndex=<n>`: that picture opens once
        // the grid has it (read once). tvOS has `tvAutoOpenPictureIndex`.
        .task(id: appModel.galleryImages.count) {
            guard let index = UserDefaults.standard.object(forKey: "autoOpenImageIndex") as? Int,
                  appModel.galleryImages.indices.contains(index) else { return }
            UserDefaults.standard.removeObject(forKey: "autoOpenImageIndex")
            appModel.enqueuePhotoWindowOpen(appModel.galleryImages[index])
        }
        #endif
    }
}
