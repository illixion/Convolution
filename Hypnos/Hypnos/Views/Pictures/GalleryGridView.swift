/*
 Hypnos - Gallery Grid View

 Gallery view with lazy loading for thumbnails: uniform squares in a
 LazyVGrid, or every image at its own aspect ratio in justified rows.
 Supports multi-select mode for bulk operations.
 */

import Photos
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

struct GalleryGridView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    var onImageSelected: ((GalleryImage) -> Void)? = nil

    @State private var showBulkDeleteConfirmation = false
    @State private var quickLookImage: GalleryImage?
    /// Snapshot of the source cell's loaded thumbnail at long-press
    /// time. Seeds the QL view's initial paint so we never show the
    /// gray loading state during the pop animation.
    @State private var quickLookSeedImage: UIImage?
    @State private var cellFrames: [UUID: CGRect] = [:]
    /// Re-read on appear and whenever the app returns to the foreground: the
    /// user may have changed the permission in the Settings app, and PhotoKit
    /// publishes no notification for that.
    @State private var photosStatus: PHAuthorizationStatus = PhotosAuthorization.status
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let gallerySpace = "gallery"
    /// Rows for the original-aspect grid, kept between body passes so a scroll
    /// or selection change doesn't re-pack thousands of images.
    @State private var rowsCache = JustifiedRowsCache()

    private let gridSpacing: CGFloat = 16
    /// Preferred (and maximum) thumbnail edge. Wide windows keep cells at
    /// this size and grow the gaps; narrow windows shrink below it instead of
    /// dropping a column.
    private let preferredCellSize: CGFloat = 200
    /// Never lay out fewer than this many columns — once the window is too
    /// narrow to fit them at `preferredCellSize`, thumbnails shrink to fit.
    private let minColumns = 4

    /// Column layout plus the cell edge. Unlike the video/local grids, image
    /// cells are a fixed square *centered* in the column and capped at
    /// `preferredCellSize`, so wide windows grow the inter-cell gaps; the cap is
    /// applied here on top of the shared column resolution.
    private func gridLayout(forWidth width: CGFloat) -> (columns: [GridItem], cellSize: CGFloat) {
        let layout = GridColumnLayout.resolve(width: width,
                                              preferredCellSize: preferredCellSize,
                                              minColumns: minColumns,
                                              spacing: gridSpacing)
        return (layout.columns, min(preferredCellSize, layout.columnWidth))
    }

    var body: some View {
        content
            .onAppear { photosStatus = PhotosAuthorization.status }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                let latest = PhotosAuthorization.status
                guard latest != photosStatus else { return }
                photosStatus = latest
                // A grant made in the Settings app needs the source rebuilt.
                Task { await appModel.requestPhotosAccessAndReload() }
            }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if shouldShowLibraryState {
                PhotoLibraryStateView(
                    kind: .photos,
                    status: photosStatus,
                    filterActive: appModel.currentFilter.hasActivePhotoLibraryFilters,
                    onClearFilters: {
                        appModel.currentFilter.clearPhotoLibraryFilters()
                        Task { await appModel.loadInitialGallery() }
                    },
                    indexingMessage: PhotosLibraryIndexer.shared.blockingMessage
                ) {
                    Task {
                        await appModel.requestPhotosAccessAndReload()
                        photosStatus = PhotosAuthorization.status
                    }
                }
            } else if appModel.galleryImages.isEmpty && appModel.isLoadingGallery {
                // Loading state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Loading images...")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.galleryImages.isEmpty {
                MediaLibraryMessageView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Images Available",
                    message: "This library has nothing to show right now."
                ) {
                    LibrarySafetyNetView()
                }
            } else {
                galleryGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: gallerySpace)
        .onPreferenceChange(CellFramePreferenceKey.self) { cellFrames = $0 }
        .overlay {
            // Outer GeometryReader resolves container size on the SAME
            // render commit that the QL view is inserted — feeding it
            // in as a parameter means the QL's first paint already has
            // correct geometry (no flicker from a layout-settle pass).
            GeometryReader { geo in
                if let quickLookImage {
                    let useScalePop = !appModel.effectiveReduceMotion
                    let sourceFrame = cellFrames[quickLookImage.id]
                    QuickLook3DView(
                        image: quickLookImage,
                        sourceFrame: sourceFrame,
                        containerSize: geo.size,
                        useScalePop: useScalePop,
                        initialImage: quickLookSeedImage,
                        onDismiss: {
                            // Suppress any inherited animation context
                            // (visionOS occasionally leaves one behind
                            // after gesture recognition, especially
                            // post-swipe-dismiss). Without this, the
                            // cell's opacity flip back to 1 rides the
                            // ambient transaction and the thumbnail
                            // "flies in" instead of snapping into place.
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) {
                                self.quickLookImage = nil
                                self.quickLookSeedImage = nil
                            }
                        }
                    )
                    .zIndex(10)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if appModel.isSelectingImages {
                selectionToolbar
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if appModel.isSelectingImages {
                        appModel.exitImageSelection()
                    } else {
                        appModel.isSelectingImages = true
                    }
                } label: {
                    Text(appModel.isSelectingImages ? "Cancel" : "Select")
                }
            }
        }
        .onAppear {
            WindowGeometry.request(
                resolvedWindowScene,
                size: CGSize(width: 1200, height: 800),
                restriction: .freeform
            )
        }
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
        }
        .confirmationDialog(
            "Delete \(appModel.selectedImageIds.count) Image\(appModel.selectedImageIds.count == 1 ? "" : "s")",
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


    // MARK: - Grid

    private var galleryGrid: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    switch appModel.galleryGridStyle {
                    case .square:
                        squareGrid(width: geo.size.width)
                    case .original:
                        justifiedGrid(width: geo.size.width)
                    }
                }
                .refreshable {
                    await appModel.refreshGallery()
                }
                .onAppear {
                    if let lastId = appModel.lastViewedImageId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(scrollTarget(for: lastId, width: geo.size.width), anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    /// What to hand `scrollTo` for an image: the image itself in the square
    /// grid, or the id of the row holding it in the original-aspect grid,
    /// where cells are nested inside rows the lazy stack knows by their own id.
    private func scrollTarget(for imageId: UUID, width: CGFloat) -> UUID {
        guard appModel.galleryGridStyle == .original else { return imageId }
        let images = appModel.galleryImages
        guard let index = images.firstIndex(where: { $0.id == imageId }) else { return imageId }
        return gridRows(images: images, width: width)
            .first { $0.row.cells.contains { $0.index == index } }?.id ?? imageId
    }

    private func loadMoreIfNeeded() {
        guard appModel.hasMorePages, !appModel.isLoadingGallery else { return }
        Task { await appModel.loadNextPage() }
    }

    private func squareGrid(width: CGFloat) -> some View {
        let layout = gridLayout(forWidth: width)
        return LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
            ForEach(appModel.galleryImages) { image in
                thumbnailCell(for: image, cellSize: CGSize(width: layout.cellSize, height: layout.cellSize))
                    .id(image.id)
                    .onAppear {
                        if image == appModel.galleryImages.last {
                            loadMoreIfNeeded()
                        }
                    }
            }

            if appModel.isLoadingGallery {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .padding()
        // Animate only the column-count transition: cells
        // slide into their new positions when a column is
        // added/removed. In-band resizing (and the small-mode
        // cell shrink, where count stays at the floor) keeps
        // count stable, so it tracks the drag live with no
        // animation. Keyed on count so appending images or
        // the live resize don't trigger a transaction.
        .animation(appModel.effectiveReduceMotion ? nil : .smooth(duration: 0.3),
                   value: layout.columns.count)
    }

    /// Every image at its own aspect ratio, packed into rows that fill the
    /// width. Geometry comes from metadata (reported dimensions, else a ratio
    /// learned earlier), so the sheet is laid out before any thumbnail loads
    /// and skipped ranges of a fast flick are already the right size.
    private func justifiedGrid(width: CGFloat) -> some View {
        let images = appModel.galleryImages
        let rows = gridRows(images: images, width: width)
        return LazyVStack(alignment: .leading, spacing: gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { position, gridRow in
                HStack(spacing: gridSpacing) {
                    ForEach(gridRow.row.cells, id: \.index) { cell in
                        thumbnailCell(
                            for: images[cell.index],
                            cellSize: CGSize(width: cell.width, height: gridRow.row.height)
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: gridRow.row.height, maxHeight: gridRow.row.height, alignment: .leading)
                .onAppear {
                    // Start the next page a few rows early; row heights are
                    // known, so waiting for the very last row would show a
                    // spinner to anyone scrolling at speed.
                    if position >= rows.count - 3 { loadMoreIfNeeded() }
                }
            }

            if appModel.isLoadingGallery {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .padding()
    }

    private func gridRows(images: [GalleryImage], width: CGFloat) -> [JustifiedGridRow] {
        let inset: CGFloat = 16
        let available = max(1, width - inset * 2)
        let target = JustifiedRowLayout.targetHeight(forWidth: available,
                                                     preferred: preferredCellSize,
                                                     minPerRow: minColumns,
                                                     spacing: gridSpacing)
        // Reading `revision` makes the grid re-lay-out (debounced) when a
        // thumbnail teaches the store the true ratio of a dimensionless item.
        let key = JustifiedRowsCache.Key(count: images.count,
                                         first: images.first?.id,
                                         last: images.last?.id,
                                         width: available.rounded(),
                                         revision: MediaAspectStore.shared.revision)
        if rowsCache.key == key { return rowsCache.rows }
        let store = MediaAspectStore.shared
        let aspects = images.map { $0.reportedAspectRatio ?? store.ratio(for: $0.identity) ?? 1 }
        let rows = JustifiedRowLayout.rows(aspects: aspects, width: available, targetHeight: target, spacing: gridSpacing)
            .map { JustifiedGridRow(id: images[$0.firstIndex].id, row: $0) }
        rowsCache.key = key
        rowsCache.rows = rows
        return rows
    }

    /// Whether the grid is currently backed by the device photo library, and so
    /// should explain a permission state rather than just showing nothing.
    private var isShowingPhotoLibrary: Bool {
        appModel.imageSource is PhotosImageSource
    }

    /// Show an explanation only when there is genuinely nothing to draw.
    ///
    /// `.limited` is readable, so a limited grant with photos in it must still
    /// render the grid — testing `status != .authorized` here would have hidden
    /// a perfectly good library behind a "no photos" message.
    private var shouldShowLibraryState: Bool {
        guard isShowingPhotoLibrary else { return false }
        guard PhotosAuthorization.isReadable(photosStatus) else { return true }
        return appModel.galleryImages.isEmpty && !appModel.isLoadingGallery
    }

    @ViewBuilder
    private func thumbnailCell(for image: GalleryImage, cellSize: CGSize) -> some View {
        if appModel.isSelectingImages {
            GalleryThumbnailView(image: image, size: cellSize)
                .overlay(alignment: .topTrailing) {
                    let isSelected = image.stashId.map { appModel.selectedImageIds.contains($0) } ?? false
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(isSelected ? .accentColor : .white)
                        .shadow(radius: 2)
                        .padding(8)
                }
                .onTapGesture {
                    guard let stashId = image.stashId else { return }
                    if appModel.selectedImageIds.contains(stashId) {
                        appModel.selectedImageIds.remove(stashId)
                    } else {
                        appModel.selectedImageIds.insert(stashId)
                    }
                }
        } else {
            GalleryThumbnailView(
                image: image,
                size: cellSize,
                onTap: {
                    appModel.lastViewedImageId = image.id
                    onImageSelected?(image)
                },
                onLongPress: { thumb in
                    // Capture the cell's loaded UIImage so QL can paint
                    // it immediately at the start of the animation.
                    quickLookSeedImage = thumb
                    // QL drives its own present animation from @State,
                    // so we just install it — no withAnimation wrapper.
                    quickLookImage = image
                },
                quickLookActive: quickLookImage?.id == image.id,
                cellCoordinateSpace: gallerySpace
            )
        }
    }

    // MARK: - Selection Toolbar

    private var selectionToolbar: some View {
        HStack(spacing: 20) {
            Button {
                let allIds = Set(appModel.galleryImages.compactMap(\.stashId))
                if appModel.selectedImageIds == allIds {
                    appModel.selectedImageIds.removeAll()
                } else {
                    appModel.selectedImageIds = allIds
                }
            } label: {
                let allIds = Set(appModel.galleryImages.compactMap(\.stashId))
                Text(appModel.selectedImageIds == allIds ? "Deselect All" : "Select All")
            }

            Spacer()

            Text("\(appModel.selectedImageIds.count) selected")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            Button("Delete", role: .destructive) {
                showBulkDeleteConfirmation = true
            }
            .disabled(appModel.selectedImageIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    // MARK: - Bulk Delete

    private func bulkDelete(deleteFile: Bool) async {
        let ids = Array(appModel.selectedImageIds)
        guard !ids.isEmpty else { return }
        do {
            try await appModel.apiClient.destroyImages(ids: ids, deleteFile: deleteFile)
            appModel.removeDeletedImages(stashIds: Set(ids))
            if appModel.selectedImageIds.isEmpty {
                appModel.exitImageSelection()
            }
        } catch {}
    }

    private var resolvedWindowScene: PlatformWindowScene? {
        if let sceneDelegate {
            return sceneDelegate.windowScene
        }

        #if os(macOS)
        return nil
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        #endif
    }
}

/// One packed row of the original-aspect grid, identified by its first image
/// so the lazy stack keeps a row's identity when pages are appended below it.
struct JustifiedGridRow: Identifiable {
    let id: UUID
    let row: JustifiedRowLayout.Row
}

/// Reference-typed memo for `GalleryGridView`'s packed rows. Held in `@State`
/// but never observed: writing it during `body` must not invalidate the body.
@MainActor
final class JustifiedRowsCache {
    struct Key: Equatable {
        let count: Int
        let first: UUID?
        let last: UUID?
        let width: CGFloat
        let revision: Int
    }
    var key: Key?
    var rows: [JustifiedGridRow] = []
}
