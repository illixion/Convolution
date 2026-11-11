/*
 Hypnos - Music visualizer: one album as a card.

 The cover with the album and its artist under it, on a pane of glass: what Cover Flow shows for each album of the
 queue. The flat view lays these out itself; the visionOS volume stands each one in the room as a view attachment,
 so the glass is the system's. Everything is sized from the width of the artwork, so one card serves both.
 */

#if !os(tvOS)

import SwiftUI

struct CoverCard: View {
    let item: JellyfinMusicItem
    let music: JellyfinMusicSession
    /// The width of the artwork in points; the card is a little wider and a good deal taller.
    let side: CGFloat

    /// The card's size for artwork `side` points wide, which is what lays it out before it is drawn.
    static func size(side: CGFloat) -> CGSize { CGSize(width: side * 1.12, height: side * 1.42) }

    private var corner: CGFloat { side * 0.12 }

    var body: some View {
        VStack(spacing: side * 0.05) {
            MusicArtwork(item: item, music: music, maxWidth: 512)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous))
            VStack(spacing: side * 0.01) {
                Text(item.Album ?? item.Name)
                    .font(.system(size: side * 0.085, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(item.artist)
                    .font(.system(size: side * 0.07))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(side * 0.06)
        .frame(width: Self.size(side: side).width, height: Self.size(side: side).height)
        .background { glass }
    }

    /// Glass. On visionOS the real thing. Elsewhere a pane that looks like it: a Material would be sampled flat
    /// behind a card that Cover Flow then turns in 3D, so the pane is a tint and an edge instead.
    @ViewBuilder
    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        #if os(visionOS)
        Color.clear.glassBackgroundEffect(in: shape)
        #else
        // A dark base first, so a card turned behind this one is hidden by it rather than showing through.
        shape
            .fill(Color(white: 0.11))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 1))
        #endif
    }
}

#endif
