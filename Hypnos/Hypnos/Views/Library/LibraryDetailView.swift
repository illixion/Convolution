/*
 Hypnos - Library detail page (visionOS, iOS, macOS)

 Counterpart to `Views/TV/Library/TVLibraryDetailView.swift`, modeled on
 the Apple TV app's product page on iPhone, iPad, Mac and Vision Pro:

 - A backdrop band edge to edge at the top, running up under the navigation
   bar. On a wide layout the logo, facts, overview and actions sit over its
   bottom-left like the hero; on a phone they stack under it, where there
   is room for them.
 - Actions: Play/Resume (a series names its Next Up episode, "Play S1 E2"),
   Start Over when there is a resume point, and Played and Favorite toggles.
 - A series then gets a season picker and a row of episode lockups that
   play on tap (asking Resume or Start Over when partly watched), then More
   Like This and an About block.
 */

import SwiftUI

struct LibraryDetailView: View {
    let item: LibraryItem
    let playback: LibraryPlayback

    @State private var detail: LibraryItem?
    @State private var nextEpisode: LibraryItem?
    @State private var seasons: [LibraryItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [LibraryItem] = []
    @State private var similar: [LibraryItem] = []
    @State private var actionError: String?
    @State private var resumeChoice: LibraryItem?

    private var shown: LibraryItem { detail ?? item }
    private var library: JellyfinLibrary? { LibraryService.current() }
    private var playTarget: LibraryItem? { shown.kind == .series ? nextEpisode : shown }

    var body: some View {
        ScrollView(.vertical) {
            LibraryDetailContent(
                shown: shown,
                playTarget: playTarget,
                playTitle: playTitle,
                seasons: seasons,
                selectedSeasonId: $selectedSeasonId,
                episodes: episodes,
                similar: similar,
                error: actionError ?? playback.error,
                playback: playback,
                onEpisode: tapEpisode,
                onTogglePlayed: { Task { await togglePlayed() } },
                onToggleFavorite: { Task { await toggleFavorite() } }
            )
        }
        .ignoresSafeArea(edges: .top)
        .measuresLibraryMetrics()
        .navigationTitle(shown.seriesName ?? shown.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task(id: LibraryService.configurationKey) { await load() }
        .onChange(of: selectedSeasonId) { _, _ in Task { await loadEpisodes() } }
        .onChange(of: playback.finishedCount) { Task { await reloadWatchState() } }
        .refreshable { await reloadWatchState() }
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

    private var playTitle: String? {
        guard shown.kind == .series else { return nil }
        guard let next = nextEpisode, let label = next.episodeLabel else { return "Play" }
        return next.userData.resumeSeconds != nil ? "Resume \(label)" : "Play \(label)"
    }

    private func tapEpisode(_ episode: LibraryItem) {
        if episode.userData.resumeSeconds != nil {
            resumeChoice = episode
        } else {
            Task { await playback.play(episode) }
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
                let initial = seasons.first { season in nextEpisode?.seasonId == season.id }
                    ?? seasons.first { $0.seasonNumber != nil && $0.seasonNumber == nextEpisode?.seasonNumber }
                    ?? seasons.first
                selectedSeasonId = initial?.id
                await loadEpisodes()
            }
            similar = (try? await library.similar(itemId: fresh.seriesId ?? fresh.id)) ?? []
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func reloadWatchState() async {
        guard let library else { return }
        detail = (try? await library.item(id: item.id)) ?? detail
        if shown.kind == .series {
            nextEpisode = (try? await library.nextUp(seriesId: shown.id)) ?? nextEpisode
            await loadEpisodes()
        }
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

/// The page body, split out so the layout reads top to bottom without the
/// loading logic in the way.
private struct LibraryDetailContent: View {
    let shown: LibraryItem
    let playTarget: LibraryItem?
    let playTitle: String?
    let seasons: [LibraryItem]
    @Binding var selectedSeasonId: String?
    let episodes: [LibraryItem]
    let similar: [LibraryItem]
    let error: String?
    let playback: LibraryPlayback
    let onEpisode: (LibraryItem) -> Void
    let onTogglePlayed: () -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.libraryMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if shown.kind == .series { seasonSection }
            if !similar.isEmpty {
                LibraryShelfRow(shelf: LibraryShelf(id: "similar", title: "More Like This", items: similar),
                                playback: playback)
            }
            about
        }
        .padding(.bottom, 40)
        // White controls over art, as in the Apple TV app; the accent blue
        // reads as a link on a dark page. Not on visionOS, whose bordered
        // buttons are glass: a white tint fills them solid and hides the icon.
        #if !os(visionOS)
        .tint(.white)
        #endif
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if metrics.isCompact {
            VStack(alignment: .leading, spacing: 16) {
                backdrop(height: metrics.width * 0.75)
                    .overlay(alignment: .bottomLeading) {
                        LibraryLogo(item: shown, maxWidth: 260, maxHeight: 96, titleFont: .system(size: 34, weight: .heavy))
                            .padding(.horizontal, metrics.gutter)
                            .padding(.bottom, 12)
                    }
                info.padding(.horizontal, metrics.gutter)
            }
        } else {
            backdrop(height: min(max(metrics.width * 0.5, 440), 640))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 14) {
                        LibraryLogo(item: shown, maxWidth: 440, maxHeight: 150, titleFont: .system(size: 52, weight: .heavy))
                        info
                    }
                    .padding(.horizontal, metrics.gutter)
                    .padding(.bottom, 24)
                    .environment(\.colorScheme, .dark)
                }
        }
    }

    private func backdrop(height: CGFloat) -> some View {
        LibraryArtwork(item: shown, slot: .backdrop, size: .backdropFull, showsTitleOnFallback: false)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.4), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(metrics.isCompact ? 0.6 : 0.88), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .libraryBackdropFadesIntoWindow()
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shown.kind == .episode {
                Text(shown.title).font(.title3.weight(.semibold))
            }
            LibraryFactsLine(item: shown)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let overview = shown.overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .lineLimit(metrics.isCompact ? 5 : 3)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            actions.padding(.top, 6)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let target = playTarget {
                LibraryPlayButton(item: shown, playback: playback, title: playTitle, target: target)
                if target.userData.resumeSeconds != nil {
                    Button {
                        Task { await playback.play(target, fromStart: true) }
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Start Over")
                }
            }
            Button(action: onTogglePlayed) {
                Label(shown.userData.isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                      systemImage: shown.userData.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(shown.userData.isPlayed ? "Mark as Unwatched" : "Mark as Watched")

            Button(action: onToggleFavorite) {
                Label(shown.userData.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: shown.userData.isFavorite ? "heart.fill" : "heart")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(shown.userData.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    // MARK: Seasons

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if seasons.count > 1 {
                    Picker("Season", selection: $selectedSeasonId) {
                        ForEach(seasons) { season in
                            Text(season.title).tag(Optional(season.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                } else {
                    Text(seasons.first?.title ?? "Episodes").font(.title3.weight(.bold))
                }
            }
            .padding(.horizontal, metrics.gutter)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: metrics.lockupSpacing) {
                    ForEach(episodes) { episode in
                        Button { onEpisode(episode) } label: {
                            LibraryEpisodeLockup(episode: episode, isResolving: playback.resolvingItemId == episode.id)
                        }
                        .buttonStyle(.plain)
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

    // MARK: About

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About").font(.title3.weight(.bold))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 48) { aboutText; aboutFacts }
                VStack(alignment: .leading, spacing: 16) { aboutText; aboutFacts }
            }
        }
        .padding(.horizontal, metrics.gutter)
    }

    private var aboutText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shown.seriesName ?? shown.title).font(.headline)
            if let overview = shown.overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutFacts: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !shown.genres.isEmpty { fact("Genre", shown.genres.joined(separator: ", ")) }
            if let year = shown.year { fact("Released", String(year)) }
            if shown.kind != .series, let runtime = shown.runtimeSeconds, runtime > 0 {
                fact("Runtime", LibraryFormat.runtime(runtime))
            }
            if let rating = shown.officialRating { fact("Rated", rating) }
            if let score = shown.communityRating { fact("Rating", String(format: "%.1f / 10", score)) }
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline)
        }
    }
}

/// An episode in a season row: still with resume bar and played badge, then
/// "EPISODE 3", title, a two-line synopsis and runtime or time left.
private struct LibraryEpisodeLockup: View {
    let episode: LibraryItem
    var isResolving = false
    @Environment(\.libraryMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryArtwork(item: episode, slot: .landscape, size: LibraryImageSize(maxWidth: 720, maxHeight: nil, quality: 90))
                .frame(width: metrics.landscape.width, height: metrics.landscape.height)
                .overlay(alignment: .bottom) {
                    if let fraction = episode.resumeFraction {
                        LibraryProgressBar(fraction: fraction, height: 4)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.userData.isPlayed { LibraryPlayedBadge().padding(8) }
                }
                .overlay { if isResolving { ProgressView().controlSize(.large) } }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .contentShape(.rect(cornerRadius: 10, style: .continuous))
                .libraryLockupHover()

            VStack(alignment: .leading, spacing: 2) {
                if let number = episode.episodeNumber {
                    Text("EPISODE \(number)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
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
            .frame(width: metrics.landscape.width, alignment: .leading)
        }
    }
}
