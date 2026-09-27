/*
 Hypnos - Library feature: shared building blocks

 The pieces every platform's Library screens are assembled from, so tvOS's
 10-foot layout and the visionOS/iOS/macOS layouts differ only in
 arrangement and scale, never in what an item's metadata line says or how
 its artwork falls back:

 - `LibraryImage`: artwork through `ImageLoader` (memory + disk cache, the
   same path every other remote image in the app takes), so shelves and the
   hero carousel don't refetch on every appearance the way `AsyncImage` does.
 - `LibraryArtwork`: an item's art for one slot, with a per-kind fallback
   chain and a tinted title card when the server has none.
 - `LibraryLogo`: the title treatment, the logo image when there is one,
   the title in type otherwise.
 - `LibraryFormat`: the "2021 · Action · 1 hr 42 min · PG-13" line, runtimes
   and "42 min left".
 - `LibraryProgressBar`: the resume bar on lockups and episode rows.
 */

import SwiftUI

// MARK: - Images

/// One remote image, cached. Shows `placeholder` until the image arrives
/// (and for good if it never does); fades the image in once loaded.
///
/// Always takes exactly the size it is offered: the image is drawn in an
/// overlay on a clear view, so a fill-mode image's natural width never
/// widens the layout around it (a full-bleed hero would otherwise push the
/// whole page off the side of a phone).
struct LibraryImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// Where a fit-mode image (a logo) sits in the space it is offered.
    var alignment: Alignment = .center
    /// Whether `placeholder` shows while the image is loading, or only once
    /// it has failed (or there is no URL). A logo turns this off, so its
    /// text stand-in doesn't flash up before the real logo arrives.
    var placeholderWhileLoading = true
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: PlatformImage?
    @State private var loadedURL: URL?
    @State private var failedURL: URL?

    var body: some View {
        Color.clear
            .overlay(alignment: alignment) {
                if let image, loadedURL == url {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else if placeholderWhileLoading || url == nil || failedURL == url {
                    placeholder()
                }
            }
            .clipped()
        .animation(.easeOut(duration: 0.25), value: loadedURL)
        .task(id: url) {
            guard let url else { return }
            let loaded = try? await ImageLoader.shared.loadImage(from: url)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedURL = loaded == nil ? nil : url
            failedURL = loaded == nil ? url : nil
        }
    }
}

/// Which art a slot shows, most wanted first.
enum LibraryArtworkSlot {
    /// Portrait key art.
    case poster
    /// 16:9 art for landscape lockups: an episode's still, else a thumb or
    /// backdrop.
    case landscape
    /// Full-bleed background.
    case backdrop

    func kinds(for item: LibraryItem) -> [LibraryImageKind] {
        switch self {
        case .poster: return [.primary]
        case .landscape:
            // An episode's Primary *is* its still; a movie's is a poster.
            return item.kind == .episode ? [.primary, .thumb, .backdrop] : [.thumb, .backdrop]
        case .backdrop: return [.backdrop, .thumb]
        }
    }
}

/// An item's art for `slot` at `size`, falling back through the slot's
/// kinds, then to a card tinted from the item id with the title on it.
struct LibraryArtwork: View {
    let item: LibraryItem
    let slot: LibraryArtworkSlot
    var size: LibraryImageSize = .thumbnail
    /// Title text on the fallback card; off for a backdrop, which has its
    /// own logo/title drawn over it.
    var showsTitleOnFallback = true

    private var url: URL? {
        guard let library = LibraryService.current() else { return nil }
        for kind in slot.kinds(for: item) {
            if let url = library.imageURL(item: item, kind: kind, size: size) { return url }
        }
        return nil
    }

    var body: some View {
        LibraryImage(url: url) {
            LibraryFallbackCard(item: item, showsTitle: showsTitleOnFallback)
        }
    }
}

/// Stand-in art: a dark gradient tinted per item (stable across launches,
/// so a shelf of art-less items doesn't read as one grey smear).
struct LibraryFallbackCard: View {
    let item: LibraryItem
    var showsTitle = true

    var body: some View {
        LinearGradient(colors: [Self.tint(for: item.seriesId ?? item.id).opacity(0.55), .black.opacity(0.85)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if showsTitle {
                    Text(item.seriesName ?? item.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(8)
                }
            }
    }

    private static func tint(for id: String) -> Color {
        // FNV-1a: String.hashValue is seeded per launch.
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.6)
    }
}

/// The item's logo, or its title set in type when there is no logo (or it
/// fails to load). Anchored leading, like the Apple TV app's.
struct LibraryLogo: View {
    let item: LibraryItem
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var titleFont: Font

    private var logoURL: URL? {
        LibraryService.current()?.imageURL(item: item, kind: .logo,
                                           size: LibraryImageSize(maxWidth: Int(maxWidth * 2), maxHeight: nil, quality: 96))
    }

    var body: some View {
        LibraryImage(url: logoURL, contentMode: .fit, alignment: .bottomLeading, placeholderWhileLoading: false) {
            Text(item.seriesName ?? item.title)
                .font(titleFont)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: maxWidth, alignment: .bottomLeading)
        }
        .frame(width: maxWidth, height: maxHeight)
        .shadow(color: .black.opacity(0.4), radius: 12)
    }
}

extension View {
    /// On visionOS, fades a backdrop's lower edge out to transparent so it
    /// melts into the window's glass; the black bottom scrim the other
    /// platforms end on would stop in a hard line there. A no-op elsewhere.
    @ViewBuilder
    func libraryBackdropFadesIntoWindow() -> some View {
        #if os(visionOS)
        self.mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.7),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        #else
        self
        #endif
    }
}

// MARK: - Text

enum LibraryFormat {
    /// "1 hr 42 min", "42 min".
    static func runtime(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "42 min left".
    static func remaining(_ seconds: Double) -> String {
        "\(runtime(seconds)) left"
    }

    /// The facts line under a title: kind-appropriate, never empty strings.
    static func facts(for item: LibraryItem) -> [String] {
        var facts: [String] = []
        switch item.kind {
        case .episode:
            if let label = item.episodeLabel { facts.append(label) }
        case .series:
            facts.append("TV Show")
        default:
            break
        }
        if let year = item.year { facts.append(String(year)) }
        facts.append(contentsOf: item.genres.prefix(2))
        if item.kind != .series, let seconds = item.runtimeSeconds, seconds > 0 {
            facts.append(runtime(seconds))
        }
        if let rating = item.officialRating, !rating.isEmpty { facts.append(rating) }
        return facts
    }

    /// The caption under a landscape lockup: what to watch and how far in.
    static func lockupSubtitle(for item: LibraryItem) -> String? {
        var parts: [String] = []
        if let label = item.episodeLabel { parts.append(label) }
        if let remaining = item.remainingSeconds {
            parts.append(Self.remaining(remaining))
        } else if item.kind == .episode, item.title != item.seriesName {
            parts.append(item.title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// `LibraryFormat.facts` as one dot-separated line.
struct LibraryFactsLine: View {
    let item: LibraryItem

    var body: some View {
        Text(LibraryFormat.facts(for: item).joined(separator: " · "))
            .lineLimit(1)
    }
}

// MARK: - Progress

/// A thin resume bar: white fill on a translucent track.
struct LibraryProgressBar: View {
    /// 0...1.
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.3))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: height)
    }
}

extension LibraryItem {
    /// Resume progress as 0...1, or nil when there is nothing to resume.
    var resumeFraction: Double? {
        guard userData.resumeSeconds != nil else { return nil }
        if let pct = userData.playedPercentage { return pct / 100 }
        guard let resume = userData.resumeSeconds, let runtimeSeconds, runtimeSeconds > 0 else { return nil }
        return resume / runtimeSeconds
    }
}
