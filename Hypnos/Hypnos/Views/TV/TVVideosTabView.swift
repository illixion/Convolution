/*
 Hypnos - tvOS Videos tab

 Mirrors `TVPicturesTabView`: a focus-friendly grid over
 `appModel.galleryVideos`, same source/filter/paging as the visionOS/iOS
 Videos tab, tapping a cell opens `TVVideoPlayerView` fullscreen.
 */

#if os(tvOS)

import SwiftUI

struct TVVideosTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var presentedVideo: GalleryVideo?
    @State private var quickActions = MediaQuickActions()

    private let gridSpacing: CGFloat = 40
    private let preferredCellSize: CGFloat = 320
    private let minColumns = 3

    var body: some View {
        NavigationStack {
            // No navigation title: the tab bar already names the tab, and the
            // large title stuck over the cells as the grid scrolled.
            content
        }
        .fullScreenCover(item: $presentedVideo) { video in
            TVVideoPlayerView(video: video, loops: true)
        }
        .mediaQuickActions(quickActions)
        .task {
            if appModel.galleryVideos.isEmpty {
                await appModel.loadInitialVideos()
            }
            autoPresentIfRequested()
        }
    }

    /// The app's video slideshow of what the grid shows.
    private func startSlideshow() {
        guard !appModel.galleryVideos.isEmpty else { return }
        appModel.startVideoSlideshow(videoSource: appModel.videoSource, filter: appModel.currentVideoFilter)
    }

    /// DEBUG-only, reusing the same `-UITestDefault key=value` mechanism as
    /// `tvInitialTab` (`TVRootView`): `tvAutoPlayVideoIndex=N` opens the Nth
    /// gallery video's player immediately. tvOS has no XCUITest and `simctl`
    /// has no remote-button injection, so there is no other way to drive a
    /// tap into `TVVideoPlayerView` for testing its codec-probe /
    /// auth / HLS-transcode-fallback path against the dev Stash instance.
    private func autoPresentIfRequested() {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "tvAutoPlayVideoIndex"),
              let index = Int(raw),
              appModel.galleryVideos.indices.contains(index) else { return }
        presentedVideo = appModel.galleryVideos[index]
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if appModel.galleryVideos.isEmpty && appModel.isLoadingVideos {
            ProgressView("Loading videos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appModel.galleryVideos.isEmpty && appModel.effectiveLibrarySource == .photos {
            TVPhotosLibraryStateView(kind: .videos, status: PhotosAuthorization.status) {
                Task {
                    await appModel.requestPhotosAccessAndReload()
                }
            }
        } else if appModel.galleryVideos.isEmpty, let problem = appModel.stashAuthProblem {
            ContentUnavailableView {
                Label("Can't Sign In to Stash", systemImage: "key.slash")
            } description: {
                Text(problem)
            } actions: {
                Button("Try Again") { Task { await appModel.loadInitialVideos() } }
            }
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
                // 16:9 cells rather than the pictures grid's square ones —
                // a video's own poster aspect, and it reads as "video" at a
                // glance from across the room.
                let cellHeight = layout.columnWidth * 9 / 16
                ScrollView {
                    TVSlideshowButton(action: startSlideshow)
                        .padding(.horizontal, 40)
                        .padding(.top, 24)
                    LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                        ForEach(appModel.galleryVideos) { video in
                            Button {
                                presentedVideo = video
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    MediaThumbnail(
                                        url: video.thumbnailURL,
                                        side: layout.columnWidth,
                                        placeholderSymbol: "video"
                                    )
                                    .frame(width: layout.columnWidth, height: cellHeight)
                                    .clipped()
                                }
                            }
                            .buttonStyle(.card)
                            .contextMenu {
                                Button("Play", systemImage: "play") { presentedVideo = video }
                                MediaQuickActionMenuItems(target: .video(video), actions: quickActions)
                            }
                            .onAppear {
                                if video == appModel.galleryVideos.last, appModel.hasMoreVideoPages {
                                    Task { await appModel.loadNextVideoPage() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                }
                // Play/Pause anywhere in the grid starts the slideshow.
                .onPlayPauseCommand(perform: startSlideshow)
            }
        }
    }
}

#endif
