/*
 Hypnos - Gallery Content Provider

 Feeds a picture slideshow from the app's gallery through an ImageSource
 (local files, Photos, Stash, Nextcloud) and the filter it was started with.
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
class GalleryContentProvider: RAVESlideshowContentProvider {
    let imageSource: any ImageSource
    var filter: ImageFilterCriteria?

    private var page: Int = 0

    init(imageSource: any ImageSource, filter: ImageFilterCriteria? = nil) {
        self.imageSource = imageSource
        self.filter = filter
    }

    func fetchMoreContent(_ request: RAVESlideshowFetchRequest) async throws -> [RAVESlideshowItem] {
        do {
            var fetchFilter = filter ?? ImageFilterCriteria()
            // Override sort to random for slideshow unless user has set a specific sort
            if filter == nil {
                fetchFilter.sortField = .random
            }
            fetchFilter.randomSeed = nil
            let result = try await imageSource.fetchImages(page: page, pageSize: 20, filter: fetchFilter)
            page += 1
            AppLogger.remoteViewer.info("Gallery: fetched \(result.images.count, privacy: .public) images")
            return result.images.map { image in
                RAVESlideshowItem(
                    id: String(abs(image.id.hashValue)),
                    title: nil,
                    mediaKind: .image,
                    fileExtension: image.fullSizeURL.pathExtension,
                    metadata: ["url": image.fullSizeURL.absoluteString]
                )
            }
        } catch {
            AppLogger.remoteViewer.error("Gallery fetch failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return []
        }
    }

    func loadMedia(for item: RAVESlideshowItem, maxResolution: Int) async throws -> RAVESlideshowLoadedMedia {
        guard let url = displayURL(for: item) else { throw RAVESlideshowError.noContent }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            AppLogger.remoteViewer.error("Gallery image load failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            throw error
        }
        if data.isAnimatedGIF || data.isAnimatedWebP || data.isAnimatedJXL {
            return .animatedImage(data: data, displayURL: url)
        }
        return .still(data: data, displayURL: url)
    }

    func displayURL(for item: RAVESlideshowItem) -> URL? {
        item.metadata["url"].flatMap(URL.init(string:))
    }
}
