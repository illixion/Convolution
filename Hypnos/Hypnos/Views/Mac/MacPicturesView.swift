/*
 Hypnos - macOS Pictures section

 A grid over `appModel.galleryImages` — the same source/filter/pagination the
 visionOS/iOS/tvOS Pictures screens use (see `Hypnos/CLAUDE.md` "Data Flow").
 Clicking a cell opens a real, separate window (`WindowGroup(id: "photo-
 detail", ...)` in `HypnosApp`) rather than pushing in place or presenting a
 cover — the ordinary Mac convention, and what "real multiple windows" means
 for this app on macOS.
 */

#if os(macOS)

import SwiftUI

/// The `photo-detail` window's value. Deliberately just a URL + title rather
/// than an index into `appModel.galleryImages` (nothing to resolve against on
/// window restore, and it round-trips through `Codable` with no dependency on
/// the gallery array's shape).
struct MacPhotoWindowValue: Codable, Hashable {
    let fullSizeURL: URL
    let title: String?
}

struct MacPicturesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var quickActions = MediaQuickActions()

    private let gridSpacing: CGFloat = 20
    private let preferredCellSize: CGFloat = 200
    private let minColumns = 3

    var body: some View {
        content
            .mediaQuickActions(quickActions)
            .task {
                if appModel.galleryImages.isEmpty {
                    await appModel.loadInitialGallery()
                }
                autoOpenIfRequested()
            }
    }

    /// DEBUG-only, mirroring tvOS's `tvAutoOpenPictureIndex` (`Support/
    /// UITestingConfiguration.swift`): `macAutoOpenPictureIndex=N` opens the
    /// Nth gallery image's detail window immediately, for testing the
    /// `photo-detail` window without clicking through macos-control (off
    /// limits — see the task's testing rules).
    private func autoOpenIfRequested() {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "macAutoOpenPictureIndex"),
              let index = Int(raw),
              appModel.galleryImages.indices.contains(index) else { return }
        let image = appModel.galleryImages[index]
        openWindow(id: "photo-detail", value: MacPhotoWindowValue(fullSizeURL: image.fullSizeURL, title: image.title))
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if appModel.galleryImages.isEmpty && appModel.isLoadingGallery {
            ProgressView("Loading pictures…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                        ForEach(appModel.galleryImages) { image in
                            Button {
                                open(image)
                            } label: {
                                MediaThumbnail(
                                    url: image.thumbnailURL,
                                    side: layout.columnWidth,
                                    placeholderSymbol: "photo"
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open", systemImage: "arrow.up.forward.app") { open(image) }
                                MediaQuickActionMenuItems(target: .image(image), actions: quickActions)
                            }
                            .onAppear {
                                if image == appModel.galleryImages.last, appModel.hasMorePages {
                                    Task { await appModel.loadNextPage() }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func open(_ image: GalleryImage) {
        openWindow(
            id: "photo-detail",
            value: MacPhotoWindowValue(fullSizeURL: image.fullSizeURL, title: image.title)
        )
    }
}

#endif
