/*
 Hypnos - Media Thumbnail

 A square thumbnail for any media URL the app can resolve.

 One view for every place a small preview is needed — filter chips, filter option
 rows, album covers — because `ImageLoader.loadThumbnail(from:)` already handles
 all three URL shapes involved: a synthetic `photos-asset:///` URL, a container
 file, and a server thumbnail. A per-source thumbnail view would be describing a
 difference that does not survive contact with the loader.

 **Decoded thumbnails are cached in memory, and read synchronously on the first
 render.** That is not an optimization, it is what stops a visible flash.
 `ContentView` keys tab content on `selectedTab`, so every tab switch destroys
 and rebuilds the whole view tree; each thumbnail's `@State` goes with it and
 every cover reloads from nothing. A grid of placeholder tiles appearing and then
 filling in, over the tab crossfade, is exactly the "light flash" that leaving an
 album produced. Loading in a `.task` cannot fix it either — a task runs *after*
 the first frame, so even a warm cache would paint one placeholder frame. Reading
 the cache in `init` means a revisited grid draws its covers immediately.

 With no URL and no placeholder symbol it renders nothing at all, so a chip for a
 dimension that has no covers lays out exactly as it would without one.
 */

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

/// Process-wide cache of decoded thumbnails.
///
/// `NSCache` is thread-safe and evicts under memory pressure on its own, which
/// is why this can be read from a `View.init` with no isolation of its own.
/// Keyed by size as well as URL, since the same asset is drawn at chip size and
/// at cover size and the small one would look soft scaled up.
final class MediaThumbnailCache: @unchecked Sendable {
    static let shared = MediaThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Enough for several screenfuls at a couple of sizes. Images here are
        // already downsampled, so this is a small budget in bytes.
        cache.countLimit = 512
        // The count alone let ~1000 px tiles add up to gigabytes on a big
        // grid; bound the decoded bytes too (NSCache evicts past either).
        #if os(tvOS)
        cache.totalCostLimit = 128 * 1024 * 1024
        #else
        cache.totalCostLimit = 384 * 1024 * 1024
        #endif
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private func key(_ url: URL, _ side: CGFloat) -> NSString {
        "\(url.absoluteString)|\(Int(side.rounded()))" as NSString
    }

    func image(for url: URL, side: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, side))
    }

    func store(_ image: UIImage, for url: URL, side: CGFloat) {
        let pixels = image.cgImage.map { $0.width * $0.height }
            ?? Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: key(url, side), cost: pixels * 4)
    }
}

struct MediaThumbnail: View {
    let url: URL?
    let side: CGFloat
    /// Drawn when there is no image. Nil means render nothing rather than an
    /// empty tile.
    var placeholderSymbol: String?

    @State private var image: UIImage?

    init(url: URL?, side: CGFloat, placeholderSymbol: String? = nil) {
        self.url = url
        self.side = side
        self.placeholderSymbol = placeholderSymbol
        // Synchronous, so a rebuilt view's first frame already has the cover.
        _image = State(initialValue: url.flatMap {
            MediaThumbnailCache.shared.image(for: $0, side: side)
        })
    }

    private var cornerRadius: CGFloat {
        side <= 48 ? 6 : 12
    }

    var body: some View {
        if url == nil && placeholderSymbol == nil {
            EmptyView()
        } else {
            tile
                .task(id: url) { await load() }
        }
    }

    private var tile: some View {
        ZStack {
            // Deliberately dark rather than a light grey: a grid of empty tiles
            // is the first thing drawn when a browser is revisited, and a light
            // fill there reads as a flash against the window's glass.
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.black.opacity(0.25))

            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if let placeholderSymbol {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: max(16, side * 0.28)))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // Fades a cover in when one does have to be loaded, rather than
        // snapping from placeholder to image.
        .animation(.easeOut(duration: 0.2), value: image != nil)
    }

    private func load() async {
        guard let url else { return }
        if let cached = MediaThumbnailCache.shared.image(for: url, side: side) {
            image = cached
            return
        }
        // Not cleared first: on a URL change the previous cover is a better
        // thing to show than an empty tile until the new one arrives.
        guard let loaded = await ImageLoader.shared.loadThumbnail(from: url, maxSize: side * 3) else {
            return
        }
        MediaThumbnailCache.shared.store(loaded, for: url, side: side)
        image = loaded
    }
}
