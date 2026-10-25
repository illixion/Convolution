/*
 Hypnos - tvOS Local folder browser

 The Albums tab's view of the Local library on Apple TV: the folder tree
 under Documents/Photos or Documents/Videos (the tab's Pictures/Videos
 switch picks the root), as the visionOS/iOS `LocalFolderBrowserView` shows
 it, built for the remote instead of taps on an Up tile and breadcrumbs:

 - each folder is a page pushed on the tab's `NavigationStack`, so Menu goes
   back up a level and the tab bar's own back behaviour applies;
 - a folder's subfolders come first, then its pictures and videos, each a
   `.card` button with the standard focus lift;
 - a picture opens `TVPhotoViewerView` over the folder's pictures (left and
   right walk the folder), a video `TVVideoPlayerView`.

 Listing goes through `LocalMediaSource.folderContents(of:)`, the same file
 typing the Local source's own scan uses.
 */

#if os(tvOS)

import SwiftUI

/// A folder under one of the Local roots, as a navigation value.
struct TVLocalFolder: Hashable {
    let isVideo: Bool
    /// Folder names under the root, outermost first.
    let path: [String]

    var rootURL: URL { isVideo ? LocalMediaSource.videosDirectory : LocalMediaSource.photosDirectory }
    var url: URL { path.reduce(rootURL) { $0.appendingPathComponent($1, isDirectory: true) } }
    var name: String { path.last ?? (isVideo ? "Videos" : "Photos") }
    /// "Local / Photos / Trips / 2024".
    var breadcrumb: String { (["Local", isVideo ? "Videos" : "Photos"] + path).joined(separator: " / ") }

    func appending(_ name: String) -> TVLocalFolder {
        TVLocalFolder(isVideo: isVideo, path: path + [name])
    }
}

struct TVLocalFolderView: View {
    let folder: TVLocalFolder

    @State private var subfolders: [String] = []
    @State private var files: [LocalMediaFile] = []
    @State private var isLoading = true
    @State private var presentedPicture: TVLocalPicturePresentation?
    @State private var presentedVideo: GalleryVideo?

    private let gridSpacing: CGFloat = 40
    private let preferredCellSize: CGFloat = 280
    private let minColumns = 4

    private var pictures: [GalleryImage] {
        files.filter { $0.type == .image }.map { GalleryImage(url: $0.url, title: $0.name, source: .local) }
    }

    var body: some View {
        content
            .task(id: folder) { await load() }
            .fullScreenCover(item: $presentedPicture) { presentation in
                TVPhotoViewerView(images: presentation.images, startIndex: presentation.index)
            }
            .fullScreenCover(item: $presentedVideo) { video in
                TVVideoPlayerView(video: video, loops: true)
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if subfolders.isEmpty && files.isEmpty {
            ContentUnavailableView(
                "Nothing in \(folder.name)",
                systemImage: "folder",
                description: Text(folder.path.isEmpty
                    ? "Add \(folder.isVideo ? "videos" : "pictures") to the app's \(folder.isVideo ? "Videos" : "Photos") folder from another device to see them here."
                    : "This folder has no pictures, videos or folders.")
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
                    VStack(alignment: .leading, spacing: 24) {
                        Text(folder.breadcrumb)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                            ForEach(subfolders, id: \.self) { name in
                                NavigationLink(value: folder.appending(name)) {
                                    folderTile(name, side: layout.columnWidth)
                                }
                                .buttonStyle(.card)
                            }
                            ForEach(files) { file in
                                Button {
                                    open(file)
                                } label: {
                                    fileTile(file, side: layout.columnWidth)
                                }
                                .buttonStyle(.card)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    private func folderTile(_ name: String, side: CGFloat) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: side * 0.3))
                .foregroundStyle(.orange)
            Text(name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(width: side, height: side)
    }

    private func fileTile(_ file: LocalMediaFile, side: CGFloat) -> some View {
        MediaThumbnail(url: file.url, side: side, placeholderSymbol: file.type == .video ? "video" : "photo")
            .frame(width: side, height: side)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    if file.type == .video {
                        Image(systemName: "play.fill")
                    }
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.55))
            }
    }

    private func open(_ file: LocalMediaFile) {
        switch file.type {
        case .image:
            let pictures = pictures
            guard let index = pictures.firstIndex(where: { $0.fullSizeURL == file.url }) else { return }
            presentedPicture = TVLocalPicturePresentation(images: pictures, index: index)
        case .video:
            presentedVideo = GalleryVideo(identity: MediaIdentity.persistentKey(for: file.url),
                                          thumbnailURL: file.url, streamURL: file.url, title: file.name)
        }
    }

    private func load() async {
        isLoading = subfolders.isEmpty && files.isEmpty
        let contents = await LocalMediaSource.shared.folderContents(of: folder.url)
        subfolders = contents.folders
        files = contents.files
        isLoading = false
    }
}

/// A picture opened from a folder, with the folder's pictures to walk.
private struct TVLocalPicturePresentation: Identifiable {
    let id = UUID()
    let images: [GalleryImage]
    let index: Int
}

#endif
