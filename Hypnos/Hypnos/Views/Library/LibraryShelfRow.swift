/*
 Hypnos - Library shelf (visionOS, iOS, macOS)

 Counterpart to `Views/TV/Library/TVLibraryShelfRow.swift`, sized for
 touch, pointer and gaze instead of the focus engine: the same split of
 landscape lockups (Continue Watching, Next Up; play on tap, show a resume
 bar and caption) and poster lockups (open the detail page, art only), laid
 out by `LibraryMetrics` so an iPhone gets a denser row than a Mac window
 or a visionOS window.
 */

import SwiftUI

/// Layout scale for the non-tvOS Library screens, from the width they
/// actually have (a narrow Mac window is laid out like a phone).
struct LibraryMetrics: Equatable {
    var width: CGFloat = 1000

    var isCompact: Bool { width < 640 }
    /// Leading/trailing inset for text and the first lockup in a row.
    var gutter: CGFloat { isCompact ? 16 : 32 }
    var poster: CGSize { isCompact ? CGSize(width: 116, height: 174) : CGSize(width: 164, height: 246) }
    var landscape: CGSize { isCompact ? CGSize(width: 250, height: 141) : CGSize(width: 320, height: 180) }
    var lockupSpacing: CGFloat { isCompact ? 12 : 20 }
    /// The hero: wide screens get a cinematic band, phones a taller card
    /// so the logo and buttons fit over the art.
    var heroHeight: CGFloat { isCompact ? min(width * 1.25, 560) : min(max(width * 0.5, 420), 680) }
}

private struct LibraryMetricsKey: EnvironmentKey {
    static let defaultValue = LibraryMetrics()
}

extension EnvironmentValues {
    var libraryMetrics: LibraryMetrics {
        get { self[LibraryMetricsKey.self] }
        set { self[LibraryMetricsKey.self] = newValue }
    }
}

extension View {
    /// Measures this view's width and publishes matching `LibraryMetrics`
    /// to everything inside it.
    func measuresLibraryMetrics() -> some View {
        modifier(LibraryMetricsReader())
    }
}

private struct LibraryMetricsReader: ViewModifier {
    @State private var metrics = LibraryMetrics()

    func body(content: Content) -> some View {
        content
            .environment(\.libraryMetrics, metrics)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if abs(width - metrics.width) > 1 { metrics = LibraryMetrics(width: width) }
            }
    }
}

struct LibraryShelfRow: View {
    let shelf: LibraryShelf
    let playback: LibraryPlayback
    @Environment(\.libraryMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, metrics.gutter)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: metrics.lockupSpacing) {
                    ForEach(shelf.items) { item in
                        switch shelf.style {
                        case .landscape:
                            Button {
                                Task { await playback.play(item) }
                            } label: {
                                LibraryLandscapeLockup(item: item, isResolving: playback.resolvingItemId == item.id)
                            }
                            .buttonStyle(.plain)
                        case .poster:
                            NavigationLink(value: item) {
                                LibraryPosterLockup(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, metrics.gutter)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }
}

struct LibraryPosterLockup: View {
    let item: LibraryItem
    @Environment(\.libraryMetrics) private var metrics

    var body: some View {
        LibraryArtwork(item: item, slot: .poster, size: .poster)
            .frame(width: metrics.poster.width, height: metrics.poster.height)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if item.userData.isPlayed { LibraryPlayedBadge().padding(8) }
            }
            .contentShape(.rect(cornerRadius: 10, style: .continuous))
            .libraryLockupHover()
            .accessibilityLabel(item.title)
    }
}

struct LibraryLandscapeLockup: View {
    let item: LibraryItem
    var isResolving = false
    @Environment(\.libraryMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryArtwork(item: item, slot: .landscape, size: LibraryImageSize(maxWidth: 720, maxHeight: nil, quality: 90))
                .frame(width: metrics.landscape.width, height: metrics.landscape.height)
                .overlay(alignment: .bottom) {
                    if let fraction = item.resumeFraction {
                        LibraryProgressBar(fraction: fraction, height: 4)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                }
                .overlay {
                    if isResolving {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .contentShape(.rect(cornerRadius: 10, style: .continuous))
                .libraryLockupHover()

            VStack(alignment: .leading, spacing: 1) {
                Text(item.seriesName ?? item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = LibraryFormat.lockupSubtitle(for: item) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: metrics.landscape.width, alignment: .leading)
        }
    }
}

struct LibraryPlayedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.black)
            .padding(5)
            .background(.white, in: Circle())
            .shadow(radius: 3)
    }
}

extension View {
    /// The platform's pointer/gaze highlight for a lockup: a lift on
    /// visionOS and iPad, nothing extra on macOS (no hover effects there).
    @ViewBuilder
    func libraryLockupHover() -> some View {
        #if os(macOS) || os(tvOS)
        self
        #else
        self.hoverEffect(.lift)
        #endif
    }
}
