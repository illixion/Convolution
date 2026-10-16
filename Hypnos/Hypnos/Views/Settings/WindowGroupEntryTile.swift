/*
 Hypnos - Window Group Entry Tile

 The tile used by both window-group sheets (restore and add-from-open-windows) to
 represent one saved window.

 Media windows get a thumbnail. Slideshow windows get a textual card instead:
 their content changes every few seconds, so a frame grab identifies nothing,
 whereas the profile name (picture or video slideshow) does.
 */

import SwiftUI

struct WindowGroupEntryTile: View {
    let entry: SavedWindowEntry

    /// Side length of the square tile. Matches the grid's `GridItem` minimum.
    static let side: CGFloat = 150

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumbnailURL = entry.thumbnailURL {
                    EntryThumbnail(url: thumbnailURL, badge: entry.kind == .video ? "play.fill" : nil)
                } else {
                    EntryTextCard(entry: entry)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .cornerRadius(12)
            .clipped()

            // Saved geometry. The whole point of a group is coming back to the
            // same arrangement, so it's worth showing which window is which size.
            Text(entry.sizeDescription ?? "default size")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.side)
        .contentShape(Rectangle())
    }
}

// MARK: - Thumbnail

private struct EntryThumbnail: View {
    let url: URL
    /// Overlay glyph marking a non-photo medium (e.g. a video's play triangle).
    let badge: String?

    @State private var loadedImage: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)

            if let loadedImage {
                Image(platformImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
            } else {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }

            if let badge, loadedImage != nil {
                Image(systemName: badge)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4)
            }
        }
        .task(id: url) {
            if let result = await ImageLoader.shared.loadThumbnailWithData(from: url) {
                loadedImage = Self.cropToSquare(result.image)
            }
            isLoading = false
        }
    }

    private static func cropToSquare(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let xOffset = (image.size.width - side) / 2
        let yOffset = (image.size.height - side) / 2
        let cropRect = CGRect(x: xOffset, y: yOffset, width: side, height: side)
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}

// MARK: - Textual card

private struct EntryTextCard: View {
    let entry: SavedWindowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: entry.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(entry.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let subtitle = entry.displaySubtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.secondary.opacity(0.2))
    }
}
