/*
 Hypnos - tvOS Library home: hero + shelves

 Full-bleed hero (backdrop, title logo or text, metadata row, overview,
 Play/Resume) over vertically-scrolling shelves (Continue Watching/Next Up
 as landscape thumbs with progress, Recently Added/genres/collections as
 poster lockups) — modeled on the Apple TV app, per the Library feature's
 design brief.
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryHomeView: View {
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
                    VStack(spacing: 60) {
                        if let hero = home.hero {
                            TVLibraryHeroView(item: hero)
                                .focusSection()
                        }
                        ForEach(home.shelves) { shelf in
                            TVLibraryShelfRow(shelf: shelf)
                                .focusSection()
                        }
                    }
                    .padding(.bottom, 80)
                }
                .refreshable { await model.refresh() }
            } else {
                ContentUnavailableView("No Server", systemImage: "server.rack", description: Text("Set a Jellyfin server in Settings."))
            }
        }
    }
}

/// The full-bleed hero: backdrop art behind a bottom-anchored info panel
/// (logo or title, year · rating · runtime · genre, overview, Play).
private struct TVLibraryHeroView: View {
    let item: LibraryItem

    private var library: JellyfinLibrary? { LibraryService.current() }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            libraryImage(kind: .backdrop, size: .backdropFull)
                .aspectRatio(16.0 / 7.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                )

            VStack(alignment: .leading, spacing: 14) {
                if let logoURL = library?.imageURL(item: item, kind: .logo, size: .thumbnail) {
                    AsyncImage(url: logoURL) { image in
                        image.resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 100, alignment: .leading)
                    } placeholder: { EmptyView() }
                    .frame(maxWidth: 480, alignment: .leading)
                } else {
                    Text(item.title)
                        .font(.system(size: 48, weight: .bold))
                }

                HStack(spacing: 10) {
                    if let year = item.year { Text(String(year)) }
                    if let rating = item.officialRating { Text(rating) }
                    if let runtime = item.runtimeSeconds { Text(Self.runtimeFormatter.string(from: runtime) ?? "") }
                    if let genre = item.genres.first { Text(genre) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.body)
                        .lineLimit(3)
                        .frame(maxWidth: 900, alignment: .leading)
                }

                Button {
                    // Playback wiring is a later phase; the button and its
                    // resolved route already exist so that phase only needs
                    // to act on it.
                } label: {
                    Label(item.userData.playedPercentage.map { _ in "Resume" } ?? "Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(60)
        }
    }

    @ViewBuilder
    private func libraryImage(kind: LibraryImageKind, size: LibraryImageSize) -> some View {
        if let url = library?.imageURL(item: item, kind: kind, size: size) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.25))
            }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
        }
    }

    private static let runtimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()
}

#endif
