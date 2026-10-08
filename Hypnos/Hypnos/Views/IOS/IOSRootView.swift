/*
 Hypnos - iOS root

 The one scene an iPhone or iPad gets. Everything visionOS spreads over
 separate windows is layered here instead:

 - `ContentView` (the tabbed gallery) is the base;
 - each viewer the router opens is a full-screen cover, stacked in the order it
   was opened — a RoboFrame `playVideo` arriving while a photo is open lands on
   top of the photo, exactly as a new window would have;
 - the singleton tool windows (console, GPU monitor, video adjustments) are
   sheets over whatever is showing.

 Full-screen covers rather than navigation pushes so the photo viewer's own
 horizontal swipe (previous/next) never competes with the interactive back
 swipe. Every viewer already carries a back/gallery button in its bar.
 */

#if !os(visionOS) && !os(macOS)

import RAVEUI
import SwiftUI

struct IOSRootView: View {
    let appModel: AppModel
    @State private var router = IOSWindowRouter()

    var body: some View {
        ContentView()
            .fullScreenCover(item: coverBinding(level: 0)) { _ in
                IOSCoverLevel(level: 0, appModel: appModel)
                    .environment(router)
                    .environment(appModel)
            }
            .sheet(item: Binding(
                get: { router.sheet },
                set: { router.sheet = $0 }
            )) { tool in
                IOSToolSheetView(tool: tool)
                    .environment(router)
                    .environment(appModel)
            }
            .environment(router)
            .environment(appModel)
            .handleIncomingMediaURLs(appModel: appModel)
            // RAVEUI's session bookkeeping; on iOS it only ever counts to one.
            .registerAsMainWindow()
    }

    private func coverBinding(level: Int) -> Binding<IOSWindowDestination?> {
        Binding(
            get: { router.path.count > level ? router.path[level] : nil },
            set: { newValue in
                if newValue == nil, router.path.count > level {
                    router.path.removeSubrange(level...)
                }
            }
        )
    }
}

/// One level of the cover stack: the destination at `level`, presenting the
/// next level as its own full-screen cover. Recursive, so the stack can be as
/// deep as the router's path.
private struct IOSCoverLevel: View {
    let level: Int
    let appModel: AppModel
    @Environment(IOSWindowRouter.self) private var router

    var body: some View {
        if router.path.count > level {
            let destination = router.path[level]
            IOSDestinationView(destination: destination, appModel: appModel)
                .environment(\.iosWindowToken, destination.id)
                .fullScreenCover(item: coverBinding(level: level + 1)) { _ in
                    IOSCoverLevel(level: level + 1, appModel: appModel)
                        .environment(router)
                        .environment(appModel)
                }
        }
    }

    private func coverBinding(level: Int) -> Binding<IOSWindowDestination?> {
        Binding(
            get: { router.path.count > level ? router.path[level] : nil },
            set: { newValue in
                if newValue == nil, router.path.count > level {
                    router.path.removeSubrange(level...)
                }
            }
        )
    }
}

/// The view a visionOS scene would have built for the destination's value.
/// Same wrappers, same `PhotoWindowModel`/`VideoWindowModel` lifecycles.
private struct IOSDestinationView: View {
    let destination: IOSWindowDestination
    let appModel: AppModel

    var body: some View {
        Group {
            switch destination {
            case .photo(let value):
                PhotoWindowView(windowValue: value, appModel: appModel)
            case .video(let value) where value.video.isLocalDisc:
                LocalDiscHandoffView(video: value.video)
            case .video(let value):
                VideoWindowView(windowValue: value, appModel: appModel)
            case .sharedPhoto(let item):
                SharedPhotoWindowView(item: item, appModel: appModel)
            case .remoteViewer(let value):
                RemoteViewerSceneRoot(windowValue: value, appModel: appModel)
            case .remoteAlert(let value):
                RemoteAlertWindowView(windowValue: value)
            }
        }
        .environment(appModel)
        .handleIncomingMediaURLs(appModel: appModel)
        // Viewers are dark, full-bleed surfaces on visionOS; keep them that way.
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// The singleton tool windows as sheets. Each keeps its own toolbar button
/// back to the gallery, which on iOS just closes the sheet.
private struct IOSToolSheetView: View {
    let tool: IOSToolSheet
    @Environment(IOSWindowRouter.self) private var router

    var body: some View {
        NavigationStack {
            Group {
                switch tool {
                case .console:
                    ConsoleWindowView()
                case .gpuMemory:
                    GPUMemoryMonitorView()
                case .videoAdjustments:
                    VideoAdjustmentsWindowView()
                case .filmPlayer:
                    FilmPlayerView()
                }
            }
            .navigationTitle(title)
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { router.sheet = nil }
                }
            }
        }
        .presentationDetents(tool == .videoAdjustments ? [.medium, .large] : [.large])
    }

    private var title: String {
        switch tool {
        case .console: return "Console"
        case .gpuMemory: return "GPU Memory"
        case .videoAdjustments: return "Adjustments"
        case .filmPlayer: return "Film Player"
        }
    }
}

#endif
