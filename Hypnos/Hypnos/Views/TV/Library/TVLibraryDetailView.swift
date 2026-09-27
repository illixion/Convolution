/*
 Hypnos - tvOS Library detail page

 Backdrop, logo/title, metadata, overview, Play/Resume, Mark Played,
 Favorite. A series additionally gets a season picker + episode list
 (thumb, S×E, title, runtime, progress/played state, synopsis) in place of
 the plain Play row. Playback itself (what "Play" actually does) is wired up
 in a later phase — the button and the resolved `PlaybackRoute` already
 exist so that phase only has to act on it.
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryDetailView: View {
    let item: LibraryItem

    @State private var detail: LibraryItem?
    @State private var seasons: [LibraryItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [LibraryItem] = []
    @State private var similar: [LibraryItem] = []
    @State private var isLoading = true
    @State private var error: String?

    private var library: JellyfinLibrary? { LibraryService.current() }

    private var effectiveItem: LibraryItem { detail ?? item }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 50) {
                header
                    .focusSection()

                if effectiveItem.kind == .series {
                    seasonEpisodeSection
                        .focusSection()
                }

                if !similar.isEmpty {
                    TVLibraryShelfRow(shelf: LibraryShelf(id: "similar", title: "More Like This", items: similar))
                        .focusSection()
                }
            }
            .padding(.bottom, 80)
        }
        .task { await load() }
        .navigationTitle(effectiveItem.title)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack(alignment: .bottomLeading) {
                backdrop
                    .aspectRatio(16.0 / 6.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom))

                VStack(alignment: .leading, spacing: 8) {
                    Text(effectiveItem.title).font(.system(size: 40, weight: .bold))
                    metadataRow
                }
                .padding(40)
            }

            if let overview = effectiveItem.overview, !overview.isEmpty {
                Text(overview).font(.body).frame(maxWidth: 900, alignment: .leading).padding(.horizontal, 60)
            }

            HStack(spacing: 24) {
                if effectiveItem.kind != .series {
                    Button {
                        // Playback wiring: a later phase.
                    } label: {
                        Label(effectiveItem.userData.playedPercentage.map { _ in "Resume" } ?? "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    Task { await togglePlayed() }
                } label: {
                    Label(effectiveItem.userData.isPlayed ? "Mark Unplayed" : "Mark Played",
                          systemImage: effectiveItem.userData.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Label(effectiveItem.userData.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: effectiveItem.userData.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 60)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 60)
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 10) {
            if let year = effectiveItem.year { Text(String(year)) }
            if let rating = effectiveItem.officialRating { Text(rating) }
            if let runtime = effectiveItem.runtimeSeconds, effectiveItem.kind != .series {
                Text(Self.runtimeFormatter.string(from: runtime) ?? "")
            }
            if !effectiveItem.genres.isEmpty { Text(effectiveItem.genres.joined(separator: ", ")) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let url = library?.imageURL(item: effectiveItem, kind: .backdrop, size: .backdropFull) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.25)) }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
        }
    }

    // MARK: - Seasons/episodes

    private var seasonEpisodeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if seasons.count > 1 {
                Picker("Season", selection: Binding(
                    get: { selectedSeasonId ?? seasons.first?.id },
                    set: { newValue in
                        selectedSeasonId = newValue
                        Task { await loadEpisodes() }
                    }
                )) {
                    ForEach(seasons) { season in
                        Text(season.title).tag(Optional(season.id))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 60)
            }

            if isLoading && episodes.isEmpty {
                ProgressView().padding(.horizontal, 60)
            } else {
                VStack(spacing: 16) {
                    ForEach(episodes) { episode in
                        TVLibraryEpisodeRow(episode: episode)
                    }
                }
                .padding(.horizontal, 60)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let library else {
            error = "No Jellyfin server configured."
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await library.item(id: item.id)
            if effectiveItem.kind == .series {
                seasons = try await library.seasons(seriesId: item.id)
                selectedSeasonId = seasons.first?.id
                await loadEpisodes()
            }
            similar = try await library.similar(itemId: item.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let library, let seasonId = selectedSeasonId else { return }
        do {
            episodes = try await library.episodes(seasonId: seasonId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func togglePlayed() async {
        guard let library else { return }
        do {
            try await library.setPlayed(itemId: item.id, played: !effectiveItem.userData.isPlayed)
            detail = try await library.item(id: item.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggleFavorite() async {
        guard let library else { return }
        do {
            try await library.setFavorite(itemId: item.id, favorite: !effectiveItem.userData.isFavorite)
            detail = try await library.item(id: item.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static let runtimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()
}

/// One row in a series' episode list: thumb, S×E + title, runtime,
/// progress/played state, a one-line synopsis.
private struct TVLibraryEpisodeRow: View {
    let episode: LibraryItem
    private var library: JellyfinLibrary? { LibraryService.current() }

    var body: some View {
        Button {
            // Playback wiring: a later phase.
        } label: {
            HStack(alignment: .top, spacing: 20) {
                ZStack(alignment: .bottom) {
                    thumb.frame(width: 220, height: 124).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if let pct = episode.userData.playedPercentage, pct > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.3))
                                Rectangle().fill(.red).frame(width: geometry.size.width * pct / 100)
                            }
                        }
                        .frame(height: 4)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(episode.episodeLabel ?? "").foregroundStyle(.secondary)
                        Text(episode.title).font(.headline)
                        Spacer()
                        if episode.userData.isPlayed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        if let runtime = episode.runtimeSeconds {
                            Text(Self.runtimeFormatter.string(from: runtime) ?? "").foregroundStyle(.secondary)
                        }
                    }
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(16)
        }
        .buttonStyle(.card)
    }

    @ViewBuilder
    private var thumb: some View {
        if let url = library?.imageURL(item: episode, kind: .primary, size: .thumbnail) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.25)) }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
        }
    }

    private static let runtimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.minute]
        return formatter
    }()
}

#endif
