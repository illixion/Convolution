/*
 Hypnos - tvOS Library shelf: a horizontally-scrolling row of lockups

 Landscape thumbnails with a progress bar for Continue Watching/Next Up,
 poster lockups everywhere else — `LibraryShelf.style` picks which.
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryShelfRow: View {
    let shelf: LibraryShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(shelf.title)
                .font(.title3.weight(.semibold))
                .padding(.leading, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 40) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: item) {
                            TVLibraryLockup(item: item, style: shelf.style)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
            }
        }
    }
}

/// One poster or landscape-thumb card, with the item's title beneath it and
/// (for a landscape/in-progress lockup) a resume-position progress bar.
struct TVLibraryLockup: View {
    let item: LibraryItem
    let style: LibraryShelf.Style

    private var library: JellyfinLibrary? { LibraryService.current() }

    private var size: CGSize {
        switch style {
        case .poster: return CGSize(width: 220, height: 330)
        case .landscape: return CGSize(width: 380, height: 214)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                artwork
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if item.userData.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }

                if let pct = item.userData.playedPercentage, pct > 0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3))
                            Rectangle().fill(.red).frame(width: geometry.size.width * pct / 100)
                        }
                    }
                    .frame(height: 4)
                }
            }

            Text(displayTitle)
                .font(.caption)
                .lineLimit(1)
                .frame(width: size.width, alignment: .leading)
        }
    }

    private var displayTitle: String {
        if let label = item.episodeLabel {
            return "\(item.seriesName ?? item.title) · \(label)"
        }
        return item.title
    }

    @ViewBuilder
    private var artwork: some View {
        let kind: LibraryImageKind = style == .landscape ? .thumb : .primary
        if let url = library?.imageURL(item: item, kind: kind, size: .thumbnail) ?? library?.imageURL(item: item, kind: .primary, size: .thumbnail) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.25))
            }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
                .overlay(Text(item.title).font(.caption2).padding(4))
        }
    }
}

#endif
