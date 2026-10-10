/*
 Hypnos - Albums Tab

 Browses the containers of whichever library is in force: Photos albums and smart
 albums, Stash galleries, or — a different shape entirely — the Local library's
 folder tree.

 Opening a Photos or Stash container applies it as a filter and moves to the
 Pictures or Videos grid, so there is no second content pipeline for those —
 the whole existing path does the work, including paging, sort and the rest of
 the filter. See `MediaContainer`. Local doesn't fit that shape (a folder nests
 and a filter value doesn't), so it gets its own browser, `LocalFolderBrowserView`,
 in place of the container grid below.
 */

import SwiftUI

import RAVEUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

struct AlbumsTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel

    /// Which media kind the browser is showing. Deliberately not
    /// `lastContentTab` — a browser should say what it is listing rather than
    /// inheriting it invisibly from wherever the user last was — but it does
    /// have to outlive the view, so it lives on the window model.
    private var isVideo: Bool { windowModel.albumsShowingVideos }
    @State private var query = ""

    private let gridSpacing: CGFloat = 20
    private let preferredCellSize: CGFloat = 200
    private let minColumns = 3

    private var isPhotosLibrary: Bool {
        appModel.effectiveLibrarySource == .photos
    }

    /// Whether to render `LocalFolderBrowserView` instead of the container
    /// grid below — see the header comment for why Local doesn't share it.
    private var isLocalLibrary: Bool {
        appModel.effectiveLibrarySource == .local
    }

    private var kindSelection: Binding<Bool> {
        Binding(
            get: { windowModel.albumsShowingVideos },
            set: { windowModel.albumsShowingVideos = $0 }
        )
    }

    /// What this library calls the thing being browsed.
    private var containerKind: MediaContainer.Kind {
        .inLibrary(appModel.effectiveLibrarySource, isVideo: isVideo)
    }

    private var containerTitle: String { containerKind.pluralTitle }
    private var containerNoun: String { containerTitle.lowercased() }

    private var filteredContainers: [MediaContainer] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return appModel.mediaContainers }
        return appModel.mediaContainers.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLocalLibrary {
                LocalFolderBrowserView(isVideo: isVideo)
            } else {
                content
            }
        }
        .task(id: taskKey) {
            guard !isLocalLibrary else { return }
            await appModel.loadMediaContainers(isVideo: isVideo)
        }
    }

    /// Reloads on anything that changes what should be listed. The index
    /// generation is only part of it under Photos — it bumps regardless of the
    /// library in force, and refetching a server's galleries because the local
    /// photo index moved would be noise.
    private var taskKey: String {
        let indexGeneration = isPhotosLibrary ? PhotosLibraryIndexer.shared.generation : 0
        return "\(appModel.effectiveLibrarySource.rawValue)-\(isVideo)-\(indexGeneration)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Label(appModel.effectiveLibrarySource.displayName,
                  systemImage: appModel.effectiveLibrarySource.symbolName)
                .font(.headline)

            Picker("Showing", selection: kindSelection) {
                // Stash calls its image collections "galleries", so the
                // false side reads "Images" there; both Photos and Local
                // keep their literal folder/album name.
                Text(appModel.effectiveLibrarySource == .stash ? "Images" : "Photos").tag(false)
                Text("Videos").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()

            // Local's browser has no search of its own — a folder tree is
            // searched by looking inside it, not by name.
            if !isLocalLibrary && appModel.mediaContainers.count > 8 {
                TextField("Search", text: $query)
                    .textFieldTapTarget()
                    .roundedTextFieldStyle()
                    .autocorrectionDisabled()
                    .frame(maxWidth: 280)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appModel.isLoadingMediaContainers && appModel.mediaContainers.isEmpty {
            MediaLibraryMessageView(icon: "rectangle.stack",
                                    title: "Loading \(containerTitle)",
                                    message: "Reading your \(containerNoun).")
        } else if appModel.mediaContainers.isEmpty {
            emptyState
        } else if filteredContainers.isEmpty {
            MediaLibraryMessageView(icon: "magnifyingglass",
                                    title: "No Matches",
                                    message: "No \(containerNoun) match \"\(query)\".")
        } else {
            grid
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isPhotosLibrary, let indexing = PhotosLibraryIndexer.shared.blockingMessage {
            MediaLibraryMessageView(icon: "hourglass",
                                    title: "Indexing Your Library",
                                    message: indexing)
        } else {
            MediaLibraryMessageView(
                icon: "rectangle.stack",
                title: "No \(containerTitle)",
                message: isPhotosLibrary
                    ? "No albums contain \(isVideo ? "videos" : "photos") yet."
                    : "This server has no \(containerNoun)."
            )
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let layout = GridColumnLayout.resolve(width: geo.size.width - 48,
                                                 preferredCellSize: preferredCellSize,
                                                 minColumns: minColumns,
                                                 spacing: gridSpacing)
            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                    // First, and only when nothing is being searched for: the
                    // way *out* of a container. Every photo app has this card,
                    // and it beats making the back button do double duty or
                    // hoping the user discovers that re-tapping an applied
                    // album deselects it.
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AllMediaCard(
                            title: allTitle,
                            symbol: isVideo ? "film.stack" : "photo.stack",
                            side: layout.columnWidth,
                            isApplied: !hasAppliedContainer
                        ) {
                            showAll()
                        }
                    }
                    ForEach(filteredContainers) { container in
                        MediaContainerCard(
                            container: container,
                            side: layout.columnWidth,
                            isApplied: appModel.isContainerApplied(container, isVideo: isVideo)
                        ) {
                            open(container)
                        }
                        .contextMenu {
                            Button(isVideo ? "Show Videos" : "Show Pictures", systemImage: "square.grid.2x2") {
                                open(container)
                            }
                            Button("Play Slideshow", systemImage: "play") {
                                appModel.startContainerSlideshow(container, isVideo: isVideo)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }

    private var allTitle: String {
        if isVideo { return "All Videos" }
        return isPhotosLibrary ? "All Photos" : "All Images"
    }

    /// Whether any container is currently narrowing this media kind.
    private var hasAppliedContainer: Bool {
        appModel.mediaContainers.contains { appModel.isContainerApplied($0, isVideo: isVideo) }
    }

    private func showAll() {
        appModel.clearAppliedContainer(isVideo: isVideo)
        navigate()
    }

    private func open(_ container: MediaContainer) {
        appModel.applyContainer(container, isVideo: isVideo)
        navigate()
    }

    private func navigate() {
        let destination: Tab = isVideo ? .videos : .pictures
        windowModel.lastContentTab = destination
        windowModel.selectedTab = destination
    }
}

// MARK: - Card

struct MediaContainerCard: View {
    let container: MediaContainer
    let side: CGFloat
    let isApplied: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                cover
                Text(container.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(container.kind.isSecondary ? .secondary : .primary)
                Text("\(container.count) item\(container.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        .hoverEffect(.lift)
        #endif
    }

    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            MediaThumbnail(url: container.coverURL,
                           side: side,
                           placeholderSymbol: container.kind.symbolName)
            if isApplied {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .background(Circle().fill(.white))
                    .padding(8)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isApplied ? Color.accentColor : .clear, lineWidth: 3)
        }
    }
}

// MARK: - All card

/// The "no container" entry: everything of this media kind.
struct AllMediaCard: View {
    let title: String
    let symbol: String
    let side: CGFloat
    let isApplied: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    MediaThumbnail(url: nil, side: side, placeholderSymbol: symbol)
                    if isApplied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.white))
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isApplied ? Color.accentColor : .clear, lineWidth: 3)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Everything")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        .hoverEffect(.lift)
        #endif
    }
}
