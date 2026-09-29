/*
 Hypnos - Local Folder Browser

 The Albums tab's view of the Local library: a real folder tree under
 Documents/Photos or Documents/Videos, with breadcrumbs and a way up.

 This used to be its own tab (`LocalTabView`). It moved here because a nested
 folder does not fit `MediaContainer` — that model is one filter value applied
 once, not a place you can descend into and climb back out of — so Local gets
 its own browser instead of being bent into the container shape everything
 else in Albums uses. See `MediaContainer.swift`.

 `isVideo` (passed in by `AlbumsTabView`, same flag Photos albums and Stash
 galleries/groups already key off) picks the root — Documents/Photos or
 Documents/Videos — so there is no separate "choose Photos or Videos" screen
 the way the old tab needed one: arriving here already answers that question.
 */

import DebugTrace
import SwiftUI

struct LocalFolderBrowserView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @PushWindowProxy private var pushWindow
    @OpenWindowProxy private var openWindow

    let isVideo: Bool

    /// Path components under the root, e.g. `["Wallpapers"]`. Held on the
    /// window model for the same reason `albumsShowingVideos` is: ContentView
    /// keys tab content on `selectedTab`, so view-local state would not
    /// survive a trip to another tab and back.
    private var folderPath: [String] {
        get { windowModel.localFolderPath }
        nonmutating set { windowModel.localFolderPath = newValue }
    }

    private var rootName: String { isVideo ? "Videos" : "Photos" }
    private var rootURL: URL { isVideo ? LocalMediaSource.videosDirectory : LocalMediaSource.photosDirectory }

    @State private var mediaFiles: [LocalMediaFile] = []
    @State private var subfolders: [String] = []
    @State private var isLoading = true

    private let gridSpacing: CGFloat = 16
    /// Target tile width; the column count is chosen to keep tiles near this.
    /// Tiles fill the column (fixed 150 height, width fills), so they shrink
    /// with it rather than being capped + centered like the image grid.
    private let preferredCellSize: CGFloat = 150
    /// Keep at least this many columns; narrower windows shrink the tiles.
    private let minColumns = 3

    private var currentFolderName: String {
        folderPath.last ?? rootName
    }

    private var breadcrumb: String {
        (["Local", rootName] + folderPath).joined(separator: " / ")
    }

    /// Resolved on-disk URL for the folder this view is showing.
    private var currentFolderURL: URL {
        folderPath.reduce(rootURL) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb/Path display
            VStack(alignment: .leading, spacing: 8) {
                Text(breadcrumb)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(currentFolderName)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.05))

            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Loading \(currentFolderName.lowercased())...")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let layout = GridColumnLayout.resolve(width: geo.size.width,
                                                          preferredCellSize: preferredCellSize,
                                                          minColumns: minColumns,
                                                          spacing: gridSpacing)
                    ScrollView {
                        LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                            // Up navigation tile — hidden at the root, since
                            // there is nowhere higher to go once isVideo has
                            // already picked Photos vs Videos.
                            if !folderPath.isEmpty {
                                Button {
                                    folderPath.removeLast()
                                } label: {
                                    VStack(spacing: 12) {
                                        Image(systemName: "arrow.turn.left.up")
                                            .font(.title)
                                            .foregroundColor(.accentColor)
                                        Text("Up")
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                    }
                                    .frame(height: 150)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(subfolders, id: \.self) { subfolder in
                                Button {
                                    folderPath.append(subfolder)
                                } label: {
                                    VStack(spacing: 12) {
                                        Image(systemName: "folder")
                                            .font(.title)
                                            .foregroundColor(.orange)
                                        Text(subfolder)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(height: 150)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(mediaFiles, id: \.id) { file in
                                LocalMediaThumbnailView(file: file) {
                                    openMedia(file)
                                }
                            }

                            if mediaFiles.isEmpty && subfolders.isEmpty {
                                VStack(spacing: 20) {
                                    Image(systemName: isVideo ? "video" : "photo")
                                        .font(.system(size: 48))
                                        .foregroundColor(.secondary)
                                    Text("No files or folders found")
                                        .font(.callout)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            }
                        }
                        .padding()
                        // Animate only the column-count transition (add/remove
                        // a column); in-band resizing tracks the drag live.
                        .animation(appModel.effectiveReduceMotion ? nil : .smooth(duration: 0.3),
                                   value: layout.columns.count)
                    }
                    .refreshable {
                        loadContent()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Videos can't run an image slideshow.
            if !isVideo {
                HStack {
                    Button {
                        launchFolderSlideshow()
                    } label: {
                        Label("Play Slideshow", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Slideshow of all images in this folder (recursive)")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear { loadContent() }
        .onChange(of: folderPath) { _, _ in loadContent() }
        .onChange(of: isVideo) { _, _ in
            // A path nested under Photos makes no sense under Videos.
            windowModel.localFolderPath = []
        }
        .onChange(of: windowModel.albumsReselected) { _, _ in
            if !folderPath.isEmpty {
                windowModel.localFolderPath = []
            }
        }
        .onAppear {
            WindowGeometry.request(
                resolvedWindowScene,
                size: CGSize(width: 1200, height: 800),
                restriction: .freeform
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Albums.localBrowser)
    }

    private func openMedia(_ file: LocalMediaFile) {
        if !isVideo {
            let image = GalleryImage(url: file.url, title: file.name, source: .local)
            if appModel.openMediaInNewWindows {
                appModel.enqueuePhotoWindowOpen(image)
            } else {
                pushWindow(id: "photo-detail", value: PhotoWindowValue(image: image, wasPushed: true))
            }
        } else {
            // Build the sibling list so prev/next navigates the folder's
            // videos (local videos aren't in appModel.galleryVideos).
            let siblings = mediaFiles
                .filter { $0.type == .video }
                .map { f in
                    GalleryVideo(
                        identity: MediaIdentity.persistentKey(for: f.url),
                        thumbnailURL: f.url,
                        streamURL: f.url,
                        title: f.name
                    )
                }
            let fileIdentity = MediaIdentity.persistentKey(for: file.url)
            let video = siblings.first { $0.identity == fileIdentity }
                ?? GalleryVideo(
                    identity: fileIdentity,
                    thumbnailURL: file.url,
                    streamURL: file.url,
                    title: file.name
                )
            if appModel.openMediaInNewWindows {
                openWindow(id: "video-detail", value: VideoWindowValue(video: video, galleryVideos: siblings))
            } else {
                pushWindow(id: "video-detail", value: VideoWindowValue(video: video, galleryVideos: siblings, wasPushed: true))
            }
        }
    }

    private func launchFolderSlideshow() {
        appModel.startGallerySlideshow(
            imageSource: LocalImageSource(rootURL: currentFolderURL),
            filter: nil
        )
    }

    private func loadContent() {
        isLoading = true
        let directory = currentFolderURL
        Task {
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
                AppLogger.localMedia.error("Directory does not exist: \(directory.path, privacy: .private)")
                await MainActor.run {
                    subfolders = []
                    mediaFiles = []
                    isLoading = false
                }
                return
            }

            let result = scanDirectoryContent(at: directory)

            await MainActor.run {
                subfolders = result.folders.sorted()
                mediaFiles = result.mediaItems.sorted { $0.createdDate > $1.createdDate }
                isLoading = false
            }
        }
    }

    private func scanDirectoryContent(at directory: URL) -> (folders: [String], mediaItems: [LocalMediaFile]) {
        let fileManager = FileManager.default
        var folders: [String] = []
        var mediaItems: [LocalMediaFile] = []

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            AppLogger.localMedia.warning("Failed to create enumerator for: \(directory.path, privacy: .private)")
            return (folders, mediaItems)
        }

        for case let fileURL as URL in enumerator {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") { continue }

            if isDirectory {
                folders.append(name)
            } else if let mediaFile = createMediaFile(from: fileURL) {
                mediaItems.append(mediaFile)
            }
        }

        return (folders, mediaItems)
    }

    private func createMediaFile(from url: URL) -> LocalMediaFile? {
        let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "jxl"])
        let videoExtensions = Set(["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"])

        let fileExt = url.pathExtension.lowercased()
        let isImage = imageExtensions.contains(fileExt)
        let isVideoFile = videoExtensions.contains(fileExt)

        guard isImage || isVideoFile else { return nil }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let createdDate = resourceValues?.creationDate ?? Date()
        let modifiedDate = resourceValues?.contentModificationDate ?? Date()
        let fileSize = resourceValues?.fileSize ?? 0

        return LocalMediaFile(
            id: UUID(),
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            type: isImage ? .image : .video,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            fileSize: Int64(fileSize)
        )
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

// MARK: - Thumbnail

struct LocalMediaThumbnailView: View {
    @Environment(AppModel.self) private var appModel
    let file: LocalMediaFile
    var onTap: (() -> Void)? = nil

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.secondary.opacity(0.2)

                if let loadedImage {
                    Image(platformImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                } else if isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: file.type == .image ? "photo" : "video")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        if loadFailed {
                            Text("Failed to load")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(height: 150)

            Text(file.name)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black)
        }
        .cornerRadius(12)
        .clipped()
        .contentShape(Rectangle())
        .hoverEffect(ScaleHoverEffect())
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .onTapGesture {
            guard appModel.beginMediaOpenTap() else { return }
            if !appModel.effectiveReduceMotion {
                withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                withAnimation(.easeOut(duration: 0.15).delay(0.08)) { isPressed = false }
            }
            onTap?()
        }
        .task {
            await loadThumbnail()
        }
        .onDisappear {
            loadedImage = nil
            isLoading = true
            loadFailed = false
        }
    }

    private func loadThumbnail() async {
        if let result = await ImageLoader.shared.loadThumbnailWithData(from: file.url) {
            loadedImage = cropToSquare(result.image)
        } else {
            AppLogger.views.warning("Failed to load thumbnail for local file: \(file.name, privacy: .private)")
            loadFailed = true
        }
        isLoading = false
    }

    private func cropToSquare(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let xOffset = (image.size.width - side) / 2
        let yOffset = (image.size.height - side) / 2

        let cropRect = CGRect(x: xOffset, y: yOffset, width: side, height: side)

        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
