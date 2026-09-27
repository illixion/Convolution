/*
 Hypnos - Library tab root (visionOS, iOS, macOS)

 The non-tvOS Library home: a hero pick over horizontally-scrolling shelves,
 pushing to `LibraryDetailView` on selection — the same `LibraryHomeViewModel`/
 `MediaServerLibrary` `Views/TV/Library` drives, laid out with ordinary
 SwiftUI navigation (`NavigationStack`) rather than tvOS's focus-engine
 shelves, since these three platforms share pointer/touch/gaze selection
 instead of a D-pad. visionOS gets `.glassBackgroundEffect()` card
 backgrounds for free from the shared shim (`Support/PlatformShims.swift`);
 iOS/macOS get the shim's real Liquid Glass.
 */

import SwiftUI

struct LibraryTabRootView: View {
    @State private var model = LibraryHomeViewModel()

    var body: some View {
        NavigationStack {
            LibraryHomeContentView(model: model)
                .navigationDestination(for: LibraryItem.self) { item in
                    LibraryDetailView(item: item)
                }
                .navigationTitle("Library")
                #if !os(tvOS) && !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        .task { await model.start() }
    }
}

struct LibraryHomeContentView: View {
    let model: LibraryHomeViewModel

    var body: some View {
        Group {
            if model.isLoading && model.home == nil {
                ProgressView("Loading Library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error, model.home == nil {
                ContentUnavailableView("Can't Load Library", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let home = model.home {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 36) {
                        if let hero = home.hero {
                            NavigationLink(value: hero) {
                                LibraryHeroView(item: hero)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(home.shelves) { shelf in
                            LibraryShelfRow(shelf: shelf)
                        }
                    }
                    .padding(.bottom, 60)
                }
                .refreshable { await model.refresh() }
            } else {
                ContentUnavailableView("No Server", systemImage: "server.rack", description: Text("Set a Jellyfin server in Settings."))
            }
        }
    }
}

/// A compact hero card: backdrop, logo/title, metadata, a one-line overview.
/// Full detail (overview in full, Play/Mark Played/Favorite, seasons/
/// episodes) lives one tap away in `LibraryDetailView` — this is the home
/// screen's "featured pick" affordance, not the detail page itself.
struct LibraryHeroView: View {
    let item: LibraryItem
    private var library: JellyfinLibrary? { LibraryService.current() }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
                .aspectRatio(16.0 / 8.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    if let year = item.year { Text(String(year)) }
                    if let genre = item.genres.first { Text(genre) }
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let url = library?.imageURL(item: item, kind: .backdrop, size: .backdropFull) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.25)) }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
        }
    }
}
