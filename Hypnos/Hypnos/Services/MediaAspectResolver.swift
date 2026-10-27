/*
 Hypnos - Media Aspect Resolver

 Finds the aspect ratio of gallery images whose source reported no
 dimensions, before the original-aspect grid places them.

 It loads each image's thumbnail through the same call the grid cell uses, so
 the bitmap is already in `ThumbnailCache` when the cell appears, and records
 the measured ratio in `MediaAspectStore`. Images are resolved in order, a
 chunk at a time; each finished chunk is published once so the grid reveals
 it in a single layout pass instead of one reflow per thumbnail.
 */

import Foundation
import SwiftUI

enum MediaAspectResolver {
    /// Thumbnails fetched at once. The fetch gate behind them allows 6.
    private static let concurrency = 6
    /// Images revealed per layout pass: about two screens of rows.
    private static let chunkSize = 24

    /// Images the grid cannot place yet.
    @MainActor
    static func unresolved(in images: [GalleryImage]) -> [GalleryImage] {
        let store = MediaAspectStore.shared
        return images.filter { $0.reportedAspectRatio == nil && !store.isResolved($0.identity) }
    }

    /// Measures `images` in order, publishing after each chunk. Stops quietly
    /// when cancelled; what was measured stays recorded.
    @MainActor
    static func resolve(_ images: [GalleryImage]) async {
        let store = MediaAspectStore.shared
        var start = 0
        while start < images.count, !Task.isCancelled {
            let chunk = Array(images[start..<min(start + chunkSize, images.count)])
            start += chunkSize
            await withTaskGroup(of: (String, CGFloat?).self) { group in
                var iterator = chunk.makeIterator()
                func addNext() {
                    guard let image = iterator.next() else { return }
                    group.addTask { (image.identity, await measure(image)) }
                }
                for _ in 0..<concurrency { addNext() }
                while let (identity, ratio) = await group.next() {
                    if let ratio {
                        store.record(ratio: ratio, for: identity, notify: false)
                    } else if !Task.isCancelled {
                        store.markUnmeasurable(identity)
                    }
                    addNext()
                }
            }
            // Published even when cancelled, so ratios recorded quietly in a
            // cut-short chunk are not left unseen by the grid.
            store.publish()
            if Task.isCancelled { return }
        }
    }

    /// Width / height of the thumbnail the cell will show, or nil on failure.
    private static func measure(_ image: GalleryImage) async -> CGFloat? {
        let bitmap: UIImage?
        if image.thumbnailURL.isFileURL {
            bitmap = await ImageLoader.shared.loadThumbnailWithData(from: image.thumbnailURL)?.image
        } else {
            bitmap = await ImageLoader.shared.loadRemoteThumbnailCached(from: image.thumbnailURL,
                                                                        maxSize: GalleryThumbnailView.thumbnailMaxSize)
        }
        guard let bitmap, bitmap.size.height > 0 else { return nil }
        return bitmap.size.width / bitmap.size.height
    }
}
