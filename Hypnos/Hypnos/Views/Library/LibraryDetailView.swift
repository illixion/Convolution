/*
 Hypnos - Library detail page (visionOS, iOS, macOS)

 Cross-platform counterpart to `Views/TV/Library/TVLibraryDetailView.swift`:
 same data and actions (Play/Resume, Mark Played, Favorite, season picker +
 episode list, Similar shelf), laid out as an ordinary scrolling detail page
 instead of tvOS's focus-tuned one. Playback itself is wired up in a later
 phase — the button and the resolved `PlaybackRoute` already exist so that
 phase only has to act on it.
 */

import SwiftUI

struct LibraryDetailView: View {
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
            VStack(alignment: .leading, spacing: 32) {
                header

                if effectiveItem.kind == .series {
                    seasonEpisodeSection
                }

                if !similar.isEmpty {
                    LibraryShelfRow(shelf: LibraryShelf(id: "similar", title: "More Like This", items: similar))
                }
            }
            .padding(.bottom, 60)
        }
        .task { await load() }
        .navigationTitle(effectiveItem.title)
        #if !os(macOS) && !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            backdrop
                .aspectRatio(16.0 / 7.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()

            Text(effectiveItem.title).font(.title.weight(.bold)).padding(.horizontal, 20)
            metadataRow.padding(.horizontal, 20)

            if let overview = effectiveItem.overview, !overview.isEmpty {
                Text(overview).padding(.horizontal, 20)
            }

            actionButtons.padding(.horizontal, 20)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20)
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            if let year = effectiveItem.year { Text(String(year)) }
            if let rating = effectiveItem.officialRating { Text(rating) }
            if let runtime = effectiveItem.runtimeSeconds, effectiveItem.kind != .series {
                Text(Self.runtimeFormatter.string(from: runtime) ?? "")
            }
            if !effectiveItem.genres.isEmpty { Text(effectiveItem.genres.joined(separator: ", ")) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            if effectiveItem.kind != .series {
                Button {
                    // Playback wiring is a later phase.
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
    }

    @ViewBuilder
    private var backdrop: some View {
        if let url = library?.imageURL(item: effectiveItem, kind: .backdrop, size: .backdropFull) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.25)) }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
        }
    }

    private var seasonEpisodeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                .padding(.horizontal, 20)
            }

            if isLoading && episodes.isEmpty {
                ProgressView().padding(.horizontal, 20)
            } else {
                VStack(spacing: 12) {
                    ForEach(episodes) { episode in
                        LibraryEpisodeRow(episode: episode)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

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

private struct LibraryEpisodeRow: View {
    let episode: LibraryItem
    private var library: JellyfinLibrary? { LibraryService.current() }

    var body: some View {
        Button {
            // Playback wiring: a later phase.
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottom) {
                    thumb.frame(width: 140, height: 79).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if let pct = episode.userData.playedPercentage, pct > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.3))
                                Rectangle().fill(.red).frame(width: geometry.size.width * pct / 100)
                            }
                        }
                        .frame(height: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(episode.episodeLabel ?? "").foregroundStyle(.secondary)
                        Text(episode.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        if episode.userData.isPlayed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumb: some View {
        if let url = library?.imageURL(item: episode, kind: .primary, size: .thumbnail) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.gray.opacity(0.25)) }
        } else {
            Rectangle().fill(.gray.opacity(0.25))
        }
    }
}
