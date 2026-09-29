/*
 Hypnos - GraphQL Image Source

 ImageSource implementation that fetches images from Stash server via GraphQL.
 */

import DebugTrace
import Foundation

/// Image source that fetches from Stash GraphQL API
final class GraphQLImageSource: ImageSource, @unchecked Sendable {
    private let apiClient: StashAPIClient

    init(apiClient: StashAPIClient) {
        self.apiClient = apiClient
    }

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        try await fetchImages(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult {
        // Stash uses 1-indexed pages
        let stashPage = page + 1
        AppLogger.graphQLImage.debug("Fetching images page \(stashPage, privacy: .public), pageSize \(pageSize, privacy: .public), hasFilter: \(filter != nil, privacy: .public)")

        // Converted to 3D is a local fact with no ImageFilterType expression, so
        // it is applied by asking the server for exactly those ids. An empty set
        // means nothing qualifies — returning early rather than sending `ids: []`,
        // which the server would read as "no id restriction" and answer with the
        // whole library.
        var convertedIds: [String]?
        if filter?.showsOnlyConverted == true {
            let ids = await ConvertedMediaRegistry.stashIds(isVideo: false)
            guard !ids.isEmpty else {
                return ImageFetchResult(images: [], hasMore: false, totalCount: 0)
            }
            convertedIds = ids
        }

        let result = try await apiClient.findImages(page: stashPage, perPage: pageSize, filter: filter, ids: convertedIds)
        AppLogger.graphQLImage.debug("Got \(result.images.count, privacy: .public) images, total: \(result.count, privacy: .public)")

        let images = result.images.compactMap(Self.makeGalleryImage(from:))

        let totalPages = (result.count + pageSize - 1) / pageSize
        let hasMore = (page + 1) < totalPages

        return ImageFetchResult(
            images: images,
            hasMore: hasMore,
            totalCount: result.count
        )
    }

    /// Fetch a single image by Stash ID and map it to a `GalleryImage`.
    /// Used by the `hypnos://image?id=` callback.
    func fetchImage(id: String) async throws -> GalleryImage? {
        guard let stashImage = try await apiClient.findImage(id: id) else { return nil }
        return Self.makeGalleryImage(from: stashImage)
    }

    /// Map a raw GraphQL image to a `GalleryImage`. Shared by list fetching and
    /// the single-image `fetchImage(id:)` path so both stay in sync.
    static func makeGalleryImage(from stashImage: StashAPIClient.StashImage) -> GalleryImage? {
        guard let imageURLString = stashImage.paths.image,
              let imageURL = URL(string: imageURLString) else {
            return nil
        }

        let thumbnailURL: URL
        if let thumbString = stashImage.paths.thumbnail,
           let thumbURL = URL(string: thumbString) {
            thumbnailURL = thumbURL
        } else {
            thumbnailURL = imageURL
        }

        // Extract original filename from visual_files path
        let fileName = stashImage.visual_files?
            .compactMap { $0.path }
            .first
            .map { ($0 as NSString).lastPathComponent }

        let visualFileType = stashImage.visual_files?.first?.typename
        let firstFile = stashImage.files?.first

        return GalleryImage(
            stashId: stashImage.id,
            thumbnailURL: thumbnailURL,
            fullSizeURL: imageURL,
            title: stashImage.title,
            rating100: stashImage.rating100,
            oCounter: stashImage.o_counter,
            fileName: fileName,
            visualFileType: visualFileType,
            sourceWidth: firstFile?.width,
            sourceHeight: firstFile?.height
        )
    }
}
