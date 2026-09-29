/*
 Hypnos - Gallery Content Provider

 SlideshowContentProvider implementation that fetches content from
 the app's gallery via ImageSource protocol (local files, GraphQL, etc.)
 */

import CoreGraphics
import DebugTrace
import RAVESlideshow
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

@MainActor
class GalleryContentProvider: SlideshowContentProvider, RAVESlideshowContentProvider {
    let imageSource: any ImageSource
    var filter: ImageFilterCriteria?

    private var page: Int = 0
    /// URL mapping for gallery posts (RemotePost._id → fullSizeURL)
    private var galleryURLMap: [Int: URL] = [:]

    init(imageSource: any ImageSource, filter: ImageFilterCriteria? = nil) {
        self.imageSource = imageSource
        self.filter = filter
    }

    func fetchMoreContent(
        tagQuery: String,
        ratioRange: String?,
        blockedPosts: Set<Int>,
        blockedTags: Set<String>
    ) async -> [RemotePost] {
        do {
            var fetchFilter = filter ?? ImageFilterCriteria()
            // Override sort to random for slideshow unless user has set a specific sort
            if filter == nil {
                fetchFilter.sortField = .random
            }
            fetchFilter.randomSeed = nil
            let result = try await imageSource.fetchImages(page: page, pageSize: 20, filter: fetchFilter)
            page += 1

            let posts = result.images.map { image in
                RemotePost(
                    _id: abs(image.id.hashValue),
                    file_ext: image.fullSizeURL.pathExtension,
                    tags: [],
                    rating: nil, image_width: nil, image_height: nil,
                    fav_count: nil, md5: nil, parent_id: nil,
                    score: nil, ratio: nil, path: image.fullSizeURL.absoluteString,
                    duration: nil
                )
            }
            // Store the URL mapping so prefetch/display can resolve them
            for (image, post) in zip(result.images, posts) {
                galleryURLMap[post._id] = image.fullSizeURL
            }
            AppLogger.remoteViewer.info("Gallery: fetched \(posts.count, privacy: .public) images")
            return posts
        } catch {
            AppLogger.remoteViewer.error("Gallery fetch failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return []
        }
    }

    func downloadImage(for post: RemotePost, maxResolution: Int) async -> DownloadedMedia? {
        guard let imageURL = resolveImageURL(for: post) else { return nil }

        let maxDim = CGFloat(maxResolution)
        return await Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                // Skip downsampling for animated formats — see
                // RemoteContentProvider.downloadImage for rationale.
                let effectiveMax: CGFloat = (data.isAnimatedGIF || data.isAnimatedWebP || data.isAnimatedJXL) ? 0 : maxDim
                guard let image = MetalImageRenderer.downsampledImage(from: data, maxDimension: effectiveMax) else {
                    return nil
                }
                return .still(image: image, data: data)
            } catch {
                AppLogger.remoteViewer.error("Gallery image load failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                return nil
            }
        }.value
    }

    func resolveImageURL(for post: RemotePost) -> URL? {
        galleryURLMap[post._id]
    }

    func onPostDisplayed(_ post: RemotePost) async {
        // No server-side history for gallery mode
    }

    func resetPagination() {
        page = 0
        galleryURLMap.removeAll()
    }

    func fetchMoreContent(_ request: RAVESlideshowFetchRequest) async throws -> [RAVESlideshowItem] {
        let posts = await fetchMoreContent(
            tagQuery: "",
            ratioRange: nil,
            blockedPosts: [],
            blockedTags: request.excludedTags
        )
        return posts.map { post in
            RAVESlideshowItem(
                id: String(post._id),
                title: nil,
                mediaKind: .image,
                fileExtension: post.file_ext,
                tags: Set(post.tags),
                metadata: [
                    "legacyID": String(post._id),
                    "url": resolveImageURL(for: post)?.absoluteString ?? ""
                ]
            )
        }
    }

    func loadMedia(for item: RAVESlideshowItem, maxResolution: Int) async throws -> RAVESlideshowLoadedMedia {
        guard let id = Int(item.id) else { throw RAVESlideshowError.noContent }
        let post = RemotePost(
            _id: id,
            file_ext: item.fileExtension,
            tags: Array(item.tags),
            rating: nil,
            image_width: nil,
            image_height: nil,
            fav_count: nil,
            md5: nil,
            parent_id: nil,
            score: nil,
            ratio: nil,
            path: item.metadata["url"],
            duration: nil
        )
        guard let media = await downloadImage(for: post, maxResolution: maxResolution) else {
            throw RAVESlideshowError.noContent
        }
        switch media {
        case let .still(_, data):
            let url = resolveImageURL(for: post)
            if data.isAnimatedGIF || data.isAnimatedWebP || data.isAnimatedJXL {
                return .animatedImage(data: data, displayURL: url ?? URL(fileURLWithPath: "/"))
            }
            return .still(data: data, displayURL: url ?? URL(fileURLWithPath: "/"))
        case let .video(url):
            return .video(url: url, hlsURL: nil)
        }
    }

    func displayURL(for item: RAVESlideshowItem) -> URL? {
        item.metadata["url"].flatMap(URL.init(string:))
    }
}
