/*
 Hypnos - tvOS Albums tab

 Browses the containers of whichever library is in force — Photos albums/
 smart albums or Stash galleries/groups — the same `MediaContainer` list
 `AlbumsTabView` shows on visionOS/iOS (see `Hypnos/CLAUDE.md` "Albums Tab").
 Opening one calls the same `AppModel.applyContainer(_:isVideo:)`, so paging,
 sort and the rest of the filter are the grid's, not a second pipeline; this
 view just also switches the tab selection to Pictures/Videos afterward,
 the job the visionOS/iOS chrome does by switching `MainWindowModel`'s tab.

 Local doesn't fit the container shape (a folder nests), so while browsing
 Local the tab shows the folder tree instead (`TVLocalFolderView`), each
 folder a page pushed on this tab's navigation stack.
 */

#if os(tvOS)

import RAVEUI
import SwiftUI

struct TVAlbumsTabView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedTab: TVTab
    @State private var isVideo = false

    private let gridSpacing: CGFloat = 40
    private let preferredCellSize: CGFloat = 280
    private let minColumns = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Kind", selection: $isVideo) {
                    Text("Pictures").tag(false)
                    Text("Videos").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)
                .padding(.top, 24)

                content
            }
            // No title on tvOS, like Pictures and Videos: the tab bar names the tab, and
            // tvOS pins a large title over the grid as it scrolls.
            .raveScreenTitle("Albums")
            .navigationDestination(for: TVLocalFolder.self) { folder in
                TVLocalFolderView(folder: folder)
            }
        }
        .task(id: isVideo) {
            guard appModel.effectiveLibrarySource != .local else { return }
            await appModel.loadMediaContainers(isVideo: isVideo)
        }
    }

    @ViewBuilder
    private var content: some View {
        if appModel.effectiveLibrarySource == .local {
            TVLocalFolderView(folder: TVLocalFolder(isVideo: isVideo, path: []))
        } else if appModel.mediaContainers.isEmpty {
            ContentUnavailableView(
                "No \(containerKind.pluralTitle)",
                systemImage: containerKind.symbolName
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
                        ForEach(appModel.mediaContainers) { container in
                            Button {
                                appModel.applyContainer(container, isVideo: isVideo)
                                selectedTab = isVideo ? .videos : .pictures
                            } label: {
                                VStack(spacing: 8) {
                                    MediaThumbnail(
                                        url: container.coverURL,
                                        side: layout.columnWidth,
                                        placeholderSymbol: container.kind.symbolName
                                    )
                                    Text(container.name)
                                        .lineLimit(1)
                                    Text("\(container.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.card)
                            .contextMenu {
                                Button("Play Slideshow", systemImage: "play") {
                                    appModel.startContainerSlideshow(container, isVideo: isVideo)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    private var containerKind: MediaContainer.Kind {
        .inLibrary(appModel.effectiveLibrarySource, isVideo: isVideo)
    }
}

#endif
