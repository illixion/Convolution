/*
 Hypnos - Video Gallery View

 Grid view for browsing videos with lazy loading.
 Supports multi-select mode for bulk operations.
 */

import Photos
import SwiftUI

struct VideoGalleryView: View {
    @Environment(AppModel.self) private var appModel
    @PushWindowProxy private var pushWindow
    @OpenWindowProxy private var openWindow

    @State private var showBulkDeleteConfirmation = false
    @State private var quickLookVideo: GalleryVideo?
    /// Snapshot of the source cell's loaded thumbnail when Quick Look was
    /// chosen from its menu.
    /// Seeds the quick look's poster so the pop never starts on an empty frame.
    @State private var quickLookSeedImage: UIImage?
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var quickActions = MediaQuickActions()
    private let gallerySpace = "videoGallery"

    private let gridSpacing: CGFloat = 16
    /// Target cell width; the column count is chosen to keep cells near this.
    /// Video cells fill the column (16:9 via `.aspectRatio`), so they shrink
    /// with it rather than being capped + centered like the image grid.
    private let preferredCellSize: CGFloat = 250
    /// Keep at least this many columns; narrower windows shrink the cells.
    private let minColumns = 3

    /// Re-read on appear and on foreground: a permission changed in the
    /// Settings app produces no PhotoKit notification.
    @State private var photosStatus: PHAuthorizationStatus = PhotosAuthorization.status
    @Environment(\.scenePhase) private var scenePhase

    /// Whether the grid is backed by the device photo library, and so should
    /// explain a permission state rather than pointing at Stash settings.
    private var isShowingPhotoLibrary: Bool {
        appModel.videoSource is PhotosVideoSource
    }

    /// See `GalleryGridView.shouldShowLibraryState` — `.limited` is readable, so
    /// a limited grant containing videos must still render the grid.
    private var shouldShowLibraryState: Bool {
        guard isShowingPhotoLibrary else { return false }
        guard PhotosAuthorization.isReadable(photosStatus) else { return true }
        return appModel.galleryVideos.isEmpty && !appModel.isLoadingVideos
    }

    var body: some View {
        content
            .onAppear { photosStatus = PhotosAuthorization.status }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                let latest = PhotosAuthorization.status
                guard latest != photosStatus else { return }
                photosStatus = latest
                Task { await appModel.requestPhotosAccessAndReload() }
            }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if appModel.galleryVideos.isEmpty && appModel.isLoadingVideos {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Loading videos...")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shouldShowLibraryState {
                PhotoLibraryStateView(
                    kind: .videos,
                    status: photosStatus,
                    filterActive: appModel.currentVideoFilter.hasActivePhotoLibraryFilters,
                    onClearFilters: {
                        appModel.currentVideoFilter.clearPhotoLibraryFilters()
                        Task { await appModel.loadInitialVideos() }
                    },
                    indexingMessage: PhotosLibraryIndexer.shared.blockingMessage
                ) {
                    Task {
                        await appModel.requestPhotosAccessAndReload()
                        photosStatus = PhotosAuthorization.status
                    }
                }
            } else if appModel.galleryVideos.isEmpty {
                MediaLibraryMessageView(
                    icon: "video.slash",
                    title: "No Videos Available",
                    message: "This library has nothing to show right now."
                ) {
                    LibrarySafetyNetView()
                }
            } else {
                GeometryReader { geo in
                    let layout = GridColumnLayout.resolve(width: geo.size.width,
                                                          preferredCellSize: preferredCellSize,
                                                          minColumns: minColumns,
                                                          spacing: gridSpacing)
                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                            ForEach(appModel.galleryVideos) { video in
                                thumbnailCell(for: video)
                                    .id(video.id)
                                    .onAppear {
                                        if video == appModel.galleryVideos.last && appModel.hasMoreVideoPages {
                                            Task {
                                                await appModel.loadNextVideoPage()
                                            }
                                        }
                                        prefetchThumbnails(around: video)
                                    }
                            }

                            if appModel.isLoadingVideos {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            }
                        }
                        .padding()
                        // Animate only the column-count transition (add/remove a
                        // column); in-band resizing tracks the drag live.
                        .animation(appModel.effectiveReduceMotion ? nil : .smooth(duration: 0.3),
                                   value: layout.columns.count)
                    }
                    .refreshable {
                        await appModel.refreshVideos()
                    }
                    .onAppear {
                        if let lastViewedId = appModel.lastViewedVideoId {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(lastViewedId, anchor: .center)
                                }
                            }
                        }
                    }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: gallerySpace)
        .onPreferenceChange(CellFramePreferenceKey.self) { cellFrames = $0 }
        .overlay {
            // Outer GeometryReader resolves container size on the same render
            // commit the quick look is inserted, so its first paint already
            // has correct geometry (no layout-settle flicker).
            GeometryReader { geo in
                if let quickLookVideo {
                    let useScalePop = !appModel.effectiveReduceMotion
                    let sourceFrame = cellFrames[quickLookVideo.id]
                    VideoQuickLookView(
                        video: quickLookVideo,
                        sourceFrame: sourceFrame,
                        containerSize: geo.size,
                        useScalePop: useScalePop,
                        initialImage: quickLookSeedImage,
                        onOpenFull: { video in
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) {
                                self.quickLookVideo = nil
                                self.quickLookSeedImage = nil
                            }
                            openVideoDetail(video)
                        },
                        onDismiss: {
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) {
                                self.quickLookVideo = nil
                                self.quickLookSeedImage = nil
                            }
                        }
                    )
                    .zIndex(10)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if appModel.isSelectingVideos {
                selectionToolbar
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if appModel.isSelectingVideos {
                        appModel.exitVideoSelection()
                    } else {
                        appModel.isSelectingVideos = true
                    }
                } label: {
                    Text(appModel.isSelectingVideos ? "Cancel" : "Select")
                }
            }
        }
        .task {
            if appModel.galleryVideos.isEmpty {
                await appModel.loadInitialVideos()
            }
        }
        .mediaQuickActions(quickActions)
        .confirmationDialog(
            "Delete \(appModel.selectedVideoIds.count) Video\(appModel.selectedVideoIds.count == 1 ? "" : "s")",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Stash", role: .destructive) {
                Task { await bulkDelete(deleteFile: false) }
            }
            Button("Delete Files from Disk", role: .destructive) {
                Task { await bulkDelete(deleteFile: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func thumbnailCell(for video: GalleryVideo) -> some View {
        if appModel.isSelectingVideos {
            VideoThumbnailView(video: video)
                .overlay(alignment: .topTrailing) {
                    let isSelected = video.stashId.map { appModel.selectedVideoIds.contains($0) } ?? false
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(isSelected ? .accentColor : .white)
                        .shadow(radius: 2)
                        .padding(8)
                }
                .onTapGesture {
                    // Selection feeds the bulk `destroyScenes` call, so it is
                    // Stash-scoped by nature: a video with no scene id has
                    // nothing on the server to delete. Same guard the image
                    // grid already applies.
                    guard let sid = video.stashId else { return }
                    if appModel.selectedVideoIds.contains(sid) {
                        appModel.selectedVideoIds.remove(sid)
                    } else {
                        appModel.selectedVideoIds.insert(sid)
                    }
                }
        } else {
            VideoThumbnailView(
                video: video,
                onTap: {
                    openVideoDetail(video)
                },
                onQuickLook: { thumb in
                    quickLookSeedImage = thumb
                    quickLookVideo = video
                },
                contextMenuItems: { quickLook in
                    AnyView(contextMenu(for: video, quickLook: quickLook))
                },
                quickLookActive: quickLookVideo?.id == video.id,
                cellCoordinateSpace: gallerySpace
            )
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for video: GalleryVideo, quickLook: @escaping () -> Void) -> some View {
        Section {
            Button("Play", systemImage: "play") { openVideoDetail(video) }
            if PlatformCapabilities.supportsMultipleWindows {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                    appModel.lastViewedVideoId = video.id
                    openWindow(id: "video-detail", value: VideoWindowValue(video: video))
                }
            }
            Button("Quick Look", systemImage: "eye", action: quickLook)
        }
        MediaQuickActionMenuItems(target: .video(video), actions: quickActions) {
            guard let stashId = video.stashId else { return }
            appModel.isSelectingVideos = true
            appModel.selectedVideoIds.insert(stashId)
        }
    }

    // MARK: - Selection Toolbar

    private var selectionToolbar: some View {
        HStack(spacing: 20) {
            Button {
                let allIds = Set(appModel.galleryVideos.compactMap(\.stashId))
                if appModel.selectedVideoIds == allIds {
                    appModel.selectedVideoIds.removeAll()
                } else {
                    appModel.selectedVideoIds = allIds
                }
            } label: {
                let allIds = Set(appModel.galleryVideos.compactMap(\.stashId))
                Text(appModel.selectedVideoIds == allIds ? "Deselect All" : "Select All")
            }

            Spacer()

            Text("\(appModel.selectedVideoIds.count) selected")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            Button("Delete", role: .destructive) {
                showBulkDeleteConfirmation = true
            }
            .disabled(appModel.selectedVideoIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    // MARK: - Bulk Delete

    private func bulkDelete(deleteFile: Bool) async {
        let ids = Array(appModel.selectedVideoIds)
        guard !ids.isEmpty else { return }
        do {
            try await appModel.apiClient.destroyScenes(ids: ids, deleteFile: deleteFile)
            appModel.removeDeletedVideos(stashIds: Set(ids))
            if appModel.selectedVideoIds.isEmpty {
                appModel.exitVideoSelection()
            }
        } catch {}
    }

    // MARK: - Helpers

    private func prefetchThumbnails(around video: GalleryVideo) {
        guard let index = appModel.galleryVideos.firstIndex(where: { $0.id == video.id }) else { return }
        let videos = appModel.galleryVideos
        // Modest look-ahead: every visible cell calls this, so a large window
        // already covers a wide range. Actual concurrency is bounded downstream
        // (ThumbnailGenerator's 4-wide decode gate + per-URL fetch dedupe), so
        // these tasks mostly coalesce or wait rather than stampede.
        let prefetchCount = 6
        let endIndex = min(index + prefetchCount, videos.count)
        guard endIndex > index + 1 else { return }

        let upcoming = videos[(index + 1)..<endIndex]
        for upcoming in upcoming {
            let url = upcoming.thumbnailURL
            Task.detached(priority: .utility) {
                if await ThumbnailCache.shared.isCached(for: url) { return }
                _ = await ImageLoader.shared.loadRemoteThumbnailCached(
                    from: url,
                    maxSize: VideoThumbnailView.thumbnailMaxSize,
                    crop: VideoThumbnailView.cropTo16x9
                )
            }
        }
    }

    private func openVideoDetail(_ video: GalleryVideo) {
        appModel.lastViewedVideoId = video.id
        if appModel.openMediaInNewWindows {
            openWindow(id: "video-detail", value: VideoWindowValue(video: video))
        } else {
            pushWindow(id: "video-detail", value: VideoWindowValue(video: video, wasPushed: true))
        }
    }
}
