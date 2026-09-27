/*
 Hypnos - tvOS Library detail page

 Laid out like an Apple TV app product page:

 - The backdrop fills the screen and stays put; the page scrolls over it,
   and it darkens as the page scrolls so shelves further down stay legible.
 - The first screen is the item itself: logo or title, facts line,
   overview, and the action row bottom-left. Play/Resume (for a series,
   "Play S1 E2" for its Next Up episode), Start Over when there is a resume
   point, and round Played and Favorite toggles.
 - Below, for a series: season buttons (focusing one switches to it, as on
   the Apple TV app) over a row of episode lockups that play on select.
   Then More Like This, then an About block.

 No navigation title: the logo is the title, and a nav bar would sit on
 top of the art.
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryDetailView: View {
    let item: LibraryItem
    let playback: LibraryPlayback

    @State private var detail: LibraryItem?
    @State private var nextEpisode: LibraryItem?
    @State private var seasons: [LibraryItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [LibraryItem] = []
    @State private var similar: [LibraryItem] = []
    @State private var actionError: String?
    @State private var scrollOffset: CGFloat = 0
    @State private var resumeChoice: LibraryItem?
    @FocusState private var focus: Action?

    private enum Action: Hashable { case play, startOver, played, favorite }

    private var shown: LibraryItem { detail ?? item }
    private var library: JellyfinLibrary? { LibraryService.current() }
    /// What Play actually starts: the item, or a series' next episode.
    private var playTarget: LibraryItem? { shown.kind == .series ? nextEpisode : shown }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                TVLibraryBackdrop(item: shown)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(Color.black.opacity(min(scrollOffset / 500, 1) * 0.7))

                ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 70) {
                        hero
                            .frame(height: geometry.size.height - 120, alignment: .bottomLeading)
                            .focusSection()

                        if shown.kind == .series {
                            seasonsSection.focusSection().id("seasons")
                        }
                        if !similar.isEmpty {
                            TVLibraryShelfRow(shelf: LibraryShelf(id: "similar", title: "More Like This", items: similar),
                                              playback: playback)
                                .focusSection()
                        }
                        about
                    }
                    .padding(.bottom, 90)
                }
                .scrollClipDisabled()
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    scrollOffset = max(offset, 0)
                }
                #if DEBUG
                // Same hook as the home screen's: `tvLibraryScrollToShelf=1`
                // scrolls to the season/episode rows for a screenshot.
                .onChange(of: episodes.isEmpty) { _, empty in
                    guard !empty, UserDefaults.standard.integer(forKey: "tvLibraryScrollToShelf") > 0 else { return }
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        proxy.scrollTo("seasons", anchor: .top)
                    }
                }
                #endif
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focus, .play)
        .task(id: LibraryService.configurationKey) { await load() }
        .onChange(of: playback.finishedCount) {
            Task { await reloadWatchState() }
        }
        .confirmationDialog(resumeChoice.map { $0.episodeLabel ?? $0.title } ?? "",
                            isPresented: Binding(get: { resumeChoice != nil }, set: { if !$0 { resumeChoice = nil } }),
                            titleVisibility: .visible) {
            if let episode = resumeChoice {
                Button("Resume") { Task { await playback.play(episode) } }
                Button("Start Over") { Task { await playback.play(episode, fromStart: true) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - First screen

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            LibraryLogo(item: shown, maxWidth: 700, maxHeight: 230, titleFont: .system(size: 84, weight: .heavy))
            if shown.kind == .episode {
                Text(shown.title)
                    .font(.title3.weight(.semibold))
            }
            LibraryFactsLine(item: shown)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            if let overview = shown.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(4)
                    .frame(maxWidth: 940, alignment: .leading)
            }
            actions.padding(.top, 12)
            if let error = actionError ?? playback.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 90)
    }

    private var actions: some View {
        HStack(spacing: 28) {
            Button {
                if let target = playTarget { Task { await playback.play(target) } }
            } label: {
                TVPlayButtonLabel(item: playTarget ?? shown, title: playTitle,
                                  isResolving: playback.resolvingItemId == playTarget?.id)
            }
            .focused($focus, equals: .play)
            .disabled(playTarget == nil)

            if let target = playTarget, target.userData.resumeSeconds != nil {
                Button {
                    Task { await playback.play(target, fromStart: true) }
                } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .focused($focus, equals: .startOver)
            }

            Button {
                Task { await togglePlayed() }
            } label: {
                Image(systemName: shown.userData.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonBorderShape(.circle)
            .focused($focus, equals: .played)
            .accessibilityLabel(shown.userData.isPlayed ? "Mark as Unwatched" : "Mark as Watched")

            Button {
                Task { await toggleFavorite() }
            } label: {
                Image(systemName: shown.userData.isFavorite ? "heart.fill" : "heart")
            }
            .buttonBorderShape(.circle)
            .focused($focus, equals: .favorite)
            .accessibilityLabel(shown.userData.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    /// A series names the episode Play will start; a movie or an episode
    /// uses the default Play/Resume label.
    private var playTitle: String? {
        guard shown.kind == .series else { return nil }
        guard let next = nextEpisode, let label = next.episodeLabel else { return "Play" }
        return next.userData.resumeSeconds != nil ? "Resume \(label)" : "Play \(label)"
    }

    // MARK: - Seasons and episodes

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: 26) {
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(seasons) { season in
                            TVSeasonButton(title: season.title, isSelected: season.id == selectedSeasonId) {
                                selectSeason(season.id)
                            }
                        }
                    }
                    .padding(.horizontal, 90)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .focusSection()
            } else {
                Text(seasons.first?.title ?? "Episodes")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 90)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) {
                    ForEach(episodes) { episode in
                        Button {
                            if episode.userData.resumeSeconds != nil {
                                resumeChoice = episode
                            } else {
                                Task { await playback.play(episode) }
                            }
                        } label: {
                            TVEpisodeLockup(episode: episode, isResolving: playback.resolvingItemId == episode.id)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 90)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .focusSection()
        }
    }

    // MARK: - About

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("About")
                .font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(shown.seriesName ?? shown.title).font(.headline)
                    if let overview = shown.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    if !shown.genres.isEmpty { aboutFact("Genre", shown.genres.joined(separator: ", ")) }
                    if let year = shown.year { aboutFact("Released", String(year)) }
                    if shown.kind != .series, let runtime = shown.runtimeSeconds, runtime > 0 {
                        aboutFact("Runtime", LibraryFormat.runtime(runtime))
                    }
                    if let rating = shown.officialRating { aboutFact("Rated", rating) }
                    if let score = shown.communityRating {
                        aboutFact("Rating", String(format: "%.1f / 10", score))
                    }
                }
            }
        }
        .padding(.horizontal, 90)
    }

    private func aboutFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let library else { return }
        do {
            let fresh = try await library.item(id: item.id)
            detail = fresh
            if fresh.kind == .series {
                async let next = library.nextUp(seriesId: fresh.id)
                seasons = try await library.seasons(seriesId: fresh.id)
                nextEpisode = try await next
                let initial = seasons.first { $0.seasonNumber == nextEpisode?.seasonNumber && $0.seasonNumber != nil }
                    ?? seasons.first { season in nextEpisode?.seasonId == season.id }
                    ?? seasons.first
                selectedSeasonId = initial?.id
                await loadEpisodes()
            }
            similar = (try? await library.similar(itemId: fresh.seriesId ?? fresh.id)) ?? []
        } catch {
            actionError = error.localizedDescription
        }
        #if DEBUG
        // Mirrors `tvLibraryAutoOpenItemId` (`TVLibraryTabView`): with no
        // remote-button injection on the tvOS simulator, this is the only
        // way to drive a press of Play for verification.
        if UserDefaults.standard.bool(forKey: "tvLibraryAutoPlay"), let target = playTarget {
            await playback.play(target)
        }
        #endif
    }

    /// After playback: resume points, played state and Next Up all moved.
    private func reloadWatchState() async {
        guard let library else { return }
        detail = (try? await library.item(id: item.id)) ?? detail
        if shown.kind == .series {
            nextEpisode = (try? await library.nextUp(seriesId: shown.id)) ?? nextEpisode
            await loadEpisodes()
        }
    }

    private func selectSeason(_ id: String) {
        guard id != selectedSeasonId else { return }
        selectedSeasonId = id
        Task { await loadEpisodes() }
    }

    private func loadEpisodes() async {
        guard let library, let seasonId = selectedSeasonId else { return }
        if let loaded = try? await library.episodes(seasonId: seasonId), seasonId == selectedSeasonId {
            episodes = loaded
        }
    }

    private func togglePlayed() async {
        guard let library else { return }
        do {
            try await library.setPlayed(itemId: shown.id, played: !shown.userData.isPlayed)
            await reloadWatchState()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func toggleFavorite() async {
        guard let library else { return }
        do {
            try await library.setFavorite(itemId: shown.id, favorite: !shown.userData.isFavorite)
            detail = try await library.item(id: shown.id)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// A season tab: selects on focus, like the Apple TV app's season row.
private struct TVSeasonButton: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: select) {
            Text(title)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected || isFocused ? .primary : .secondary)
        }
        .buttonStyle(.borderless)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { select() }
        }
    }
}

/// An episode in a season row: still with resume bar, then "EPISODE 3",
/// title, a two-line synopsis and the runtime or time left.
private struct TVEpisodeLockup: View {
    let episode: LibraryItem
    var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryArtwork(item: episode, slot: .landscape, size: LibraryImageSize(maxWidth: 960, maxHeight: nil, quality: 90))
                .frame(width: TVLandscapeLockup.size.width, height: TVLandscapeLockup.size.height)
                .overlay(alignment: .bottom) {
                    if let fraction = episode.resumeFraction {
                        LibraryProgressBar(fraction: fraction, height: 6)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 16)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.userData.isPlayed { TVPlayedBadge().padding(12) }
                }
                .overlay { if isResolving { ProgressView() } }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .hoverEffect(.highlight)

            VStack(alignment: .leading, spacing: 4) {
                if let number = episode.episodeNumber {
                    Text("EPISODE \(number)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(episode.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
                if let remaining = episode.remainingSeconds {
                    Text(LibraryFormat.remaining(remaining)).font(.caption2).foregroundStyle(.secondary)
                } else if let runtime = episode.runtimeSeconds, runtime > 0 {
                    Text(LibraryFormat.runtime(runtime)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: TVLandscapeLockup.size.width, alignment: .leading)
        }
    }
}

#endif
