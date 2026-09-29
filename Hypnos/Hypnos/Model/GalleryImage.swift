/*
 Hypnos - Gallery Image Model

 Represents an image in the gallery with thumbnail and full-size URLs.
 */

import Foundation

struct GalleryImage: Identifiable, Equatable, Hashable {
    /// Derived from `identity`, not minted per instance — see
    /// `MediaIdentity.stableID(for:)` for why that matters to the grid.
    var id: UUID { MediaIdentity.stableID(for: identity) }
    let stashId: String?
    let thumbnailURL: URL
    let fullSizeURL: URL
    let title: String?
    var rating100: Int?
    var oCounter: Int?
    /// Where this image came from.
    let source: MediaSource
    /// Original filename from server (e.g. from visual_files path), used for sharing
    let fileName: String?
    /// Stash visual file GraphQL typename (e.g. ImageFile, VideoFile)
    let visualFileType: String?
    /// Native pixel dimensions reported by the server (visual_files). Used to
    /// seed the quick look's aspect ratio before the real image loads, so the
    /// pop frame is correctly sized from the first frame instead of assuming
    /// the (possibly cropped) cell thumbnail's aspect.
    let sourceWidth: Int?
    let sourceHeight: Int?

    init(stashId: String? = nil, thumbnailURL: URL, fullSizeURL: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil, source: MediaSource = .stash, fileName: String? = nil, visualFileType: String? = nil, sourceWidth: Int? = nil, sourceHeight: Int? = nil) {
        self.stashId = stashId
        self.thumbnailURL = thumbnailURL
        self.fullSizeURL = fullSizeURL
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
        self.source = source
        self.fileName = fileName
        self.visualFileType = visualFileType
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }

    /// Convenience initializer when thumbnail and full-size are the same URL
    init(stashId: String? = nil, url: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil, source: MediaSource = .stash, fileName: String? = nil, visualFileType: String? = nil, sourceWidth: Int? = nil, sourceHeight: Int? = nil) {
        self.stashId = stashId
        self.thumbnailURL = url
        self.fullSizeURL = url
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
        self.source = source
        self.fileName = fileName
        self.visualFileType = visualFileType
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }
}

// MARK: - Identity

extension GalleryImage {
    /// Stable, source-agnostic key for this image.
    ///
    /// Computed rather than stored, unlike `GalleryVideo.identity`: an image
    /// already carries everything needed to derive one, so there is no legacy
    /// field to migrate and nothing for a producer to get wrong. A Stash image
    /// keys on its scene id; a container file keys on its container-relative
    /// path, which survives the per-launch container UUID change.
    ///
    /// Note that `ImageEnhancementTracker` does *not* use this yet — it keys on
    /// the image URL, which is correct for every source that has a stable one.
    /// A `PHAsset` has no such URL, so adopting this is part of the Photos work.
    var identity: String {
        if let stashId, !stashId.isEmpty { return stashId }
        return MediaIdentity.persistentKey(for: fullSizeURL)
    }
}

// MARK: - Aspect ratio

extension GalleryImage {
    /// Width / height as reported by the source, when it reported both.
    var reportedAspectRatio: CGFloat? {
        guard let sourceWidth, let sourceHeight, sourceWidth > 0, sourceHeight > 0 else { return nil }
        return CGFloat(sourceWidth) / CGFloat(sourceHeight)
    }
}

// MARK: - Local File URL Re-resolution

extension GalleryImage {
    /// Returns a copy with file URLs re-resolved against the current container.
    ///
    /// visionOS reassigns the app container UUID on every launch, so a persisted
    /// absolute file URL is stale by the next run. Returns self unchanged for
    /// non-container sources, and when the file cannot be found under the
    /// current container — the caller keeps whatever it had rather than being
    /// handed a URL that resolves to nothing.
    func resolvingLocalFileURL() -> GalleryImage {
        guard source.isContainerFile, fullSizeURL.isFileURL,
              let resolved = MediaIdentity.resolvingContainerURL(fullSizeURL),
              resolved != fullSizeURL else { return self }

        return GalleryImage(
            stashId: stashId,
            thumbnailURL: thumbnailURL.isFileURL
                ? (MediaIdentity.resolvingContainerURL(thumbnailURL) ?? thumbnailURL)
                : thumbnailURL,
            fullSizeURL: resolved,
            title: title,
            rating100: rating100,
            oCounter: oCounter,
            source: source,
            fileName: fileName,
            visualFileType: visualFileType,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }
}

// MARK: - Codable with Backward Compatibility

extension GalleryImage: Codable {
    enum CodingKeys: String, CodingKey {
        case stashId
        case thumbnailURL
        case fullSizeURL
        case title
        case rating100
        case oCounter
        case source
        case fileName
        case visualFileType
        case sourceWidth
        case sourceHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        stashId = try container.decodeIfPresent(String.self, forKey: .stashId)
        thumbnailURL = try container.decode(URL.self, forKey: .thumbnailURL)
        fullSizeURL = try container.decode(URL.self, forKey: .fullSizeURL)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        rating100 = try container.decodeIfPresent(Int.self, forKey: .rating100)
        oCounter = try container.decodeIfPresent(Int.self, forKey: .oCounter)

        // Decoded as a String and mapped, NOT via decodeIfPresent(MediaSource):
        // that only returns nil for a missing or null key — a key present with
        // an unrecognised raw value throws DecodingError.dataCorrupted, and the
        // throw escapes init(from:). Saved window groups decode as an array, so
        // one such element fails the whole array, and loadSavedWindowGroups()
        // wraps that in `try?` — silently wiping EVERY saved group, not just the
        // offending one. Mapping by hand makes the fallback real, so a group
        // written by a future build with a new source case still restores.
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
        source = rawSource.flatMap(MediaSource.init(rawValue:)) ?? .stash
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        visualFileType = try container.decodeIfPresent(String.self, forKey: .visualFileType)
        sourceWidth = try container.decodeIfPresent(Int.self, forKey: .sourceWidth)
        sourceHeight = try container.decodeIfPresent(Int.self, forKey: .sourceHeight)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(stashId, forKey: .stashId)
        try container.encode(thumbnailURL, forKey: .thumbnailURL)
        try container.encode(fullSizeURL, forKey: .fullSizeURL)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(rating100, forKey: .rating100)
        try container.encodeIfPresent(oCounter, forKey: .oCounter)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(visualFileType, forKey: .visualFileType)
        try container.encodeIfPresent(sourceWidth, forKey: .sourceWidth)
        try container.encodeIfPresent(sourceHeight, forKey: .sourceHeight)
    }
}

