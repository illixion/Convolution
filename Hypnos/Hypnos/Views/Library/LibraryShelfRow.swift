/*
 Hypnos - Library shelf (visionOS, iOS, macOS)

 Cross-platform counterpart to `Views/TV/Library/TVLibraryShelfRow.swift`:
 same landscape-with-progress/poster split by `LibraryShelf.style`, ordinary
 `NavigationLink`s instead of tvOS's focus-engine cards.
 */

import SwiftUI

struct LibraryShelfRow: View {
    let shelf: LibraryShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.title)
                .font(.headline)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: item) {
                            LibraryLockup(item: item, style: shelf.style)
                        }
                        .buttonStyle(.plain)
                        #if !os(tvOS) && !os(macOS)
                        .hoverEffect(.highlight)
                        #endif
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct LibraryLockup: View {
    let item: LibraryItem
    let style: LibraryShelf.Style
    private var library: JellyfinLibrary? { LibraryService.current() }

    private var size: CGSize {
        switch style {
        case .poster: return CGSize(width: 130, height: 195)
        case .landscape: return CGSize(width: 220, height: 124)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                artwork
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if item.userData.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }

                if let pct = item.userData.playedPercentage, pct > 0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3))
                            Rectangle().fill(.red).frame(width: geometry.size.width * pct / 100)
                        }
                    }
                    .frame(height: 3)
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
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.25)) }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
                .overlay(Text(item.title).font(.caption2).padding(4))
        }
    }
}
