/*
 Hypnos - macOS Videos section

 Mirrors `MacPicturesView`: a grid over `appModel.galleryVideos`, same
 source/filter/paging as every other platform, clicking a cell opens a real
 `video-detail` window (`GalleryVideo` is already `Codable`, so it is the
 window's value directly — no extra wrapper type needed).
 */

#if os(macOS)

import SwiftUI

struct MacVideosView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var quickActions = MediaQuickActions()

    private let gridSpacing: CGFloat = 20
    private let preferredCellSize: CGFloat = 240
    private let minColumns = 3

    var body: some View {
        content
            .mediaQuickActions(quickActions)
            .task {
                if appModel.galleryVideos.isEmpty {
                    await appModel.loadInitialVideos()
                }
                autoOpenIfRequested()
            }
    }

    /// DEBUG-only, mirroring `MacPicturesView.autoOpenIfRequested` /
    /// tvOS's `tvAutoPlayVideoIndex`.
    private func autoOpenIfRequested() {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "macAutoOpenVideoIndex"),
              let index = Int(raw),
              appModel.galleryVideos.indices.contains(index) else { return }
        openWindow(id: "video-detail", value: appModel.galleryVideos[index])
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if appModel.galleryVideos.isEmpty && appModel.isLoadingVideos {
            ProgressView("Loading videos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appModel.galleryVideos.isEmpty {
            ContentUnavailableView(
                "No Videos",
                systemImage: "video",
                description: Text("This library has nothing to show right now.")
            )
        } else {
            GeometryReader { geo in
                let layout = GridColumnLayout.resolve(
                    width: geo.size.width,
                    preferredCellSize: preferredCellSize,
                    minColumns: minColumns,
                    spacing: gridSpacing
                )
                let cellHeight = layout.columnWidth * 9 / 16
                ScrollView {
                    LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                        ForEach(appModel.galleryVideos) { video in
                            Button {
                                openWindow(id: "video-detail", value: video)
                            } label: {
                                MediaThumbnail(
                                    url: video.thumbnailURL,
                                    side: layout.columnWidth,
                                    placeholderSymbol: "video"
                                )
                                .frame(width: layout.columnWidth, height: cellHeight)
                                .clipped()
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Play", systemImage: "play") { openWindow(id: "video-detail", value: video) }
                                MediaQuickActionMenuItems(target: .video(video), actions: quickActions)
                            }
                            .onAppear {
                                if video == appModel.galleryVideos.last, appModel.hasMoreVideoPages {
                                    Task { await appModel.loadNextVideoPage() }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

#endif
