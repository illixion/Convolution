/*
 Hypnos - tvOS Library shelf: a horizontally scrolling row of lockups

 Lockups are `.borderless` buttons, the tvOS system lockup: the artwork
 lifts and tilts with focus (`.hoverEffect(.highlight)`) and the caption
 under it slides clear, with no custom focus drawing.

 - `.landscape` shelves (Continue Watching, Next Up) show 16:9 art with a
   resume bar and a two-line caption, and play on select.
 - `.poster` shelves show 2:3 key art with no caption (the art carries the
   title, as on the Apple TV app) and open the detail page.
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryShelfRow: View {
    let shelf: LibraryShelf
    let playback: LibraryPlayback
    /// Focus binding for the shelf's first lockup, so a neighbour can send focus here.
    var firstItemFocus: FocusState<Bool>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(shelf.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.leading, 90)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) {
                    ForEach(shelf.items) { item in
                        lockup(item)
                            .modifier(FirstItemFocus(binding: item.id == shelf.items.first?.id ? firstItemFocus : nil))
                    }
                }
                .padding(.horizontal, 90)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func lockup(_ item: LibraryItem) -> some View {
        switch shelf.style {
        case .landscape:
            Button {
                Task { await playback.play(item) }
            } label: {
                TVLandscapeLockup(item: item, isResolving: playback.resolvingItemId == item.id)
            }
            .buttonStyle(.borderless)
            .contextMenu { LibraryItemContextMenu(item: item, playback: playback) }
        case .poster:
            NavigationLink(value: item) {
                TVPosterLockup(item: item)
            }
            .buttonStyle(.borderless)
            .contextMenu { LibraryItemContextMenu(item: item, playback: playback, showsDetails: false) }
        }
    }
}

private struct FirstItemFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}

struct TVPosterLockup: View {
    let item: LibraryItem
    static let size = CGSize(width: 260, height: 390)

    var body: some View {
        LibraryArtwork(item: item, slot: .poster, size: .poster)
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if item.userData.isPlayed {
                    TVPlayedBadge().padding(12)
                }
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(item.title)
    }
}

struct TVLandscapeLockup: View {
    let item: LibraryItem
    var isResolving = false
    static let size = CGSize(width: 480, height: 270)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryArtwork(item: item, slot: .landscape, size: LibraryImageSize(maxWidth: 960, maxHeight: nil, quality: 90))
                .frame(width: Self.size.width, height: Self.size.height)
                .overlay(alignment: .bottom) {
                    if let fraction = item.resumeFraction {
                        LibraryProgressBar(fraction: fraction, height: 6)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 16)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                }
                .overlay {
                    if isResolving { ProgressView() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .hoverEffect(.highlight)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.seriesName ?? item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = LibraryFormat.lockupSubtitle(for: item) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Self.size.width, alignment: .leading)
        }
    }
}

/// The played checkmark on a lockup's corner.
struct TVPlayedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .padding(8)
            .background(.white, in: Circle())
            .shadow(radius: 4)
    }
}

#endif
