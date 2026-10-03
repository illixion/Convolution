/*
 Hypnos - Local Media Source

 Scans the app's Documents folder for local images and videos.
 Files appear in the Files app under "On My Apple Vision Pro" > "Convolution".
 */

import DebugTrace
import Foundation
import UniformTypeIdentifiers

/// Represents a local media file
struct LocalMediaFile: Identifiable {
    let id: UUID
    let url: URL
    let name: String
    let type: LocalMediaType
    let createdDate: Date
    let modifiedDate: Date
    let fileSize: Int64

    enum LocalMediaType {
        case image
        case video
    }
}

/// Service for managing local media files in the app's Documents folder
actor LocalMediaSource {
    static let shared = LocalMediaSource()

    // Supported file types
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "jxl"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"
    ]

    private static let imageMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/heif", "image/gif",
        "image/webp", "image/bmp", "image/tiff", "image/jxl"
    ]

    private static let videoMIMETypes: Set<String> = [
        "video/mp4", "video/x-m4v", "video/quicktime", "video/x-matroska",
        "video/webm", "video/x-msvideo", "video/x-ms-wmv", "video/x-flv", "video/3gpp"
    ]

    /// Get the Documents folder URL where users can add files
    var documentsDirectory: URL { Self.documentsDirectory }

    /// Static counterparts of the same three URLs, for callers that need them
    /// synchronously without an actor hop — `AppModel.makeSources` in
    /// particular, which is itself a plain `static func`.
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// The Local library's image root. Kept separate from `videosDirectory`
    /// so Pictures and Videos browse independent trees, mirroring how Photos
    /// and Stash never mix media kinds either.
    static var photosDirectory: URL {
        documentsDirectory.appendingPathComponent("Photos", isDirectory: true)
    }

    static var videosDirectory: URL {
        documentsDirectory.appendingPathComponent("Videos", isDirectory: true)
    }

    /// Create subdirectories for organizing imports and placeholder file
    func ensureDirectoriesExist() {
        let fileManager = FileManager.default
        let photosDir = Self.photosDirectory
        let videosDir = Self.videosDirectory

        try? fileManager.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)

        // Create placeholder file so the folder shows up in Files app
        createPlaceholderFileIfNeeded()
    }

    /// Create a placeholder file to ensure the folder appears in the Files app
    private func createPlaceholderFileIfNeeded() {
        let placeholderURL = documentsDirectory.appendingPathComponent("Place media files here.txt")
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: placeholderURL.path) else { return }

        let placeholderContent = """
        Hypnos - Local Media Import

        Add your photos and videos to this folder to view them in the app.

        Supported formats:
        - Photos: JPG, PNG, HEIC, GIF, WebP, BMP, TIFF, JXL
        - Videos: MP4, MOV, MKV, WebM, AVI

        You can organize files into the Photos and Videos subfolders,
        or place them directly here.

        To import stereoscopic 3D videos, use the Stash server integration
        with appropriate tags (e.g., "stereoscopic", "SBS", "OU").
        """

        try? placeholderContent.write(to: placeholderURL, atomically: true, encoding: .utf8)
    }

    /// Scan for all local media files
    func scanAllMedia() -> [LocalMediaFile] {
        ensureDirectoriesExist()
        return scanDirectory(documentsDirectory, recursive: true)
    }

    /// Scan for local images
    func scanImages() -> [LocalMediaFile] {
        scanAllMedia().filter { $0.type == .image }
    }

    /// Scan for local images recursively under a specific folder
    func scanImages(under root: URL) -> [LocalMediaFile] {
        scanDirectory(root, recursive: true).filter { $0.type == .image }
    }

    /// Scan for local videos
    func scanVideos() -> [LocalMediaFile] {
        scanAllMedia().filter { $0.type == .video }
    }

    /// Scan for local videos recursively under a specific folder
    func scanVideos(under root: URL) -> [LocalMediaFile] {
        scanDirectory(root, recursive: true).filter { $0.type == .video }
    }

    /// Scan a directory for media files
    private func scanDirectory(_ directory: URL, recursive: Bool) -> [LocalMediaFile] {
        let fileManager = FileManager.default
        var mediaFiles: [LocalMediaFile] = []

        AppLogger.localMedia.debug("Scanning directory: \(directory.path, privacy: .private)")

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .contentTypeKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            AppLogger.localMedia.error("Failed to create enumerator for directory")
            return []
        }

        for case let fileURL as URL in enumerator {
            if let mediaFile = createMediaFile(from: fileURL) {
                mediaFiles.append(mediaFile)
            }
        }

        AppLogger.localMedia.info("Found \(mediaFiles.count, privacy: .public) media files")

        // Sort by creation date (newest first), falling back to modification date
        return mediaFiles.sorted { $0.createdDate > $1.createdDate }
    }

    /// Create a LocalMediaFile from a URL
    private func createMediaFile(from url: URL) -> LocalMediaFile? {
        // Get resource values
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .contentTypeKey
        ]

        guard let resourceValues = try? url.resourceValues(forKeys: resourceKeys) else {
            return nil
        }

        // Skip directories
        if resourceValues.isDirectory == true {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        let type: LocalMediaFile.LocalMediaType

        // Determine type by extension first
        if Self.imageExtensions.contains(ext) {
            type = .image
        } else if Self.videoExtensions.contains(ext) {
            type = .video
        } else {
            // Try content type as fallback
            if let contentType = resourceValues.contentType {
                if contentType.conforms(to: .image) {
                    type = .image
                } else if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                    type = .video
                } else {
                    return nil
                }
            } else if let uti = UTType(filenameExtension: ext) {
                if uti.conforms(to: .image) {
                    type = .image
                } else if uti.conforms(to: .movie) || uti.conforms(to: .video) {
                    type = .video
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }

        let createdDate = resourceValues.creationDate ?? resourceValues.contentModificationDate ?? Date()
        let modifiedDate = resourceValues.contentModificationDate ?? Date()
        let fileSize = Int64(resourceValues.fileSize ?? 0)

        let mediaFile = LocalMediaFile(
            id: UUID(),
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            type: type,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            fileSize: fileSize
        )

        AppLogger.localMedia.debug("Found \(type == .image ? "image" : "video", privacy: .public): \(url.lastPathComponent, privacy: .private)")

        return mediaFile
    }
}

// MARK: - Image Source Conformance

/// ImageSource implementation for local files
final class LocalImageSource: ImageSource, @unchecked Sendable {
    /// Optional folder root. When non-nil, scans recursively from this folder.
    /// When nil, scans the entire Documents directory.
    let rootURL: URL?

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL
    }

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        AppLogger.localMedia.debug("Fetching images page \(page, privacy: .public), pageSize \(pageSize, privacy: .public)")

        let allImages: [LocalMediaFile]
        if let rootURL {
            allImages = await LocalMediaSource.shared.scanImages(under: rootURL)
        } else {
            allImages = await LocalMediaSource.shared.scanImages()
        }
        AppLogger.localMedia.debug("Total images found: \(allImages.count, privacy: .public)")

        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, allImages.count)

        guard startIndex < allImages.count else {
            AppLogger.localMedia.debug("No more images (startIndex \(startIndex, privacy: .public) >= count \(allImages.count, privacy: .public))")
            return ImageFetchResult(images: [], hasMore: false, totalCount: allImages.count)
        }

        let pageImages = Array(allImages[startIndex..<endIndex])

        let galleryImages = pageImages.map { file in
            GalleryImage(
                thumbnailURL: file.url,
                fullSizeURL: file.url,
                title: file.name,
                source: .local
            )
        }

        AppLogger.localMedia.debug("Returning \(galleryImages.count, privacy: .public) images for page \(page, privacy: .public)")

        return ImageFetchResult(
            images: galleryImages,
            hasMore: endIndex < allImages.count,
            totalCount: allImages.count
        )
    }
}

// MARK: - Video Source Conformance

/// VideoSource implementation for local files
final class LocalVideoSource: VideoSource, @unchecked Sendable {
    /// Optional folder root, mirroring `LocalImageSource`. When non-nil, scans
    /// recursively from this folder — which is what a slideshow launched from
    /// inside a Videos subfolder needs.
    let rootURL: URL?

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL
    }

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        let allVideos: [LocalMediaFile]
        if let rootURL {
            allVideos = await LocalMediaSource.shared.scanVideos(under: rootURL)
        } else {
            allVideos = await LocalMediaSource.shared.scanVideos()
        }

        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, allVideos.count)

        guard startIndex < allVideos.count else {
            return VideoFetchResult(videos: [], hasMore: false, totalCount: allVideos.count)
        }

        let pageVideos = Array(allVideos[startIndex..<endIndex])

        let galleryVideos = pageVideos.map { file in
            GalleryVideo(
                // Container-relative, not the absolute URL: the container UUID
                // changes every launch, so an absolute key orphaned this
                // video's depth cache and 3D settings on every relaunch.
                identity: MediaIdentity.persistentKey(for: file.url),
                thumbnailURL: file.url, // Will use video frame as thumbnail
                streamURL: file.url,
                title: file.name,
                duration: nil, // Could extract with AVAsset if needed
                isStereoscopic: false,
                stereoscopicFormat: nil,
                sourceWidth: nil,
                sourceHeight: nil,
                eyesReversed: false
            )
        }

        return VideoFetchResult(
            videos: galleryVideos,
            hasMore: endIndex < allVideos.count,
            totalCount: allVideos.count
        )
    }
}
