/*
 Hypnos - tvOS Pictures tab

 A focus-engine-friendly grid over `appModel.galleryImages` — the same
 source, filter and pagination the visionOS/iOS Pictures tab uses (see
 `Hypnos/CLAUDE.md` "Data Flow"); only the presentation is tvOS-specific.
 Each cell is a plain `Button` so the standard tvOS focus lift/parallax
 comes for free from `.buttonStyle(.card)` — no custom hover/press gesture
 code, unlike `GalleryThumbnailView`'s long-press-to-QuickLook handling
 (touch-only, and QuickLook has no tvOS equivalent here — see
 `TVPhotoViewerView` instead).
 */

#if os(tvOS)

import SwiftUI

struct TVPicturesTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var presentedIndex: Int?
    @State private var quickActions = MediaQuickActions()
    /// The viewer asked for a slideshow: started once it has closed, since
    /// the slideshow is presented from the root.
    @State private var slideshowAfterViewer = false

    private let gridSpacing: CGFloat = 40
    private let preferredCellSize: CGFloat = 280
    private let minColumns = 4

    var body: some View {
        NavigationStack {
            // No navigation title: the tab bar already names the tab, and the
            // large title stuck over the cells as the grid scrolled.
            content
        }
        .fullScreenCover(item: presentedImageBinding, onDismiss: {
            if slideshowAfterViewer {
                slideshowAfterViewer = false
                startSlideshow()
            }
        }) { image in
            if let index = presentedIndex {
                TVPhotoViewerView(
                    images: appModel.galleryImages,
                    startIndex: index,
                    onLoadMore: {
                        if appModel.hasMorePages {
                            await appModel.loadNextPage()
                        }
                    },
                    onSlideshow: {
                        slideshowAfterViewer = true
                        presentedIndex = nil
                    }
                )
            }
        }
        .mediaQuickActions(quickActions)
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
            autoPresentIfRequested()
        }
    }

    /// The app's slideshow of what the grid shows (source and filter), as the
    /// tab bar's play button starts it elsewhere.
    private func startSlideshow() {
        guard !appModel.galleryImages.isEmpty else { return }
        appModel.startGallerySlideshow(imageSource: appModel.imageSource, filter: appModel.currentFilter)
    }

    /// DEBUG-only, mirroring `TVVideosTabView.autoPresentIfRequested` and
    /// `TVRootView`'s `tvInitialTab`: `tvAutoOpenPictureIndex=N` opens the
    /// Nth gallery image's fullscreen viewer immediately, since there is no
    /// other way to drive a tap into `TVPhotoViewerView` for testing it
    /// (auth, full-size decode) against the dev Stash instance.
    private func autoPresentIfRequested() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "tvAutoStartSlideshow") {
            startSlideshow()
            return
        }
        guard let raw = UserDefaults.standard.string(forKey: "tvAutoOpenPictureIndex"),
              let index = Int(raw),
              appModel.galleryImages.indices.contains(index) else { return }
        presentedIndex = index
        #endif
    }

    /// `fullScreenCover(item:)` needs an `Identifiable` binding; the viewer
    /// itself navigates by index (so left/right can walk off the end into a
    /// freshly-paged-in image), so this just wraps `presentedIndex` in the
    /// `Identifiable` shape the modifier wants.
    private var presentedImageBinding: Binding<GalleryImage?> {
        Binding(
            get: { presentedIndex.flatMap { appModel.galleryImages[safe: $0] } },
            set: { newValue in
                if newValue == nil { presentedIndex = nil }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if appModel.galleryImages.isEmpty && appModel.isLoadingGallery {
            ProgressView("Loading pictures…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appModel.galleryImages.isEmpty && appModel.effectiveLibrarySource == .photos {
            TVPhotosLibraryStateView(kind: .pictures, status: PhotosAuthorization.status) {
                Task {
                    await appModel.requestPhotosAccessAndReload()
                }
            }
        } else if appModel.galleryImages.isEmpty, let problem = appModel.stashAuthProblem {
            ContentUnavailableView {
                Label("Can't Sign In to Stash", systemImage: "key.slash")
            } description: {
                Text(problem)
            } actions: {
                Button("Try Again") { Task { await appModel.loadInitialGallery() } }
            }
        } else if appModel.galleryImages.isEmpty {
            ContentUnavailableView(
                "No Pictures",
                systemImage: "photo.on.rectangle.angled",
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
                ScrollView {
                    TVSlideshowButton(action: startSlideshow)
                        .padding(.horizontal, 40)
                        .padding(.top, 24)
                    LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                        ForEach(Array(appModel.galleryImages.enumerated()), id: \.element.id) { index, image in
                            Button {
                                presentedIndex = index
                            } label: {
                                MediaThumbnail(
                                    url: image.thumbnailURL,
                                    side: layout.columnWidth,
                                    placeholderSymbol: "photo"
                                )
                            }
                            .buttonStyle(.card)
                            .contextMenu {
                                Button("View", systemImage: "photo") { presentedIndex = index }
                                MediaQuickActionMenuItems(target: .image(image), actions: quickActions)
                            }
                            .onAppear {
                                if image == appModel.galleryImages.last, appModel.hasMorePages {
                                    Task { await appModel.loadNextPage() }
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
