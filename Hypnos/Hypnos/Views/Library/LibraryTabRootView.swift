/*
 Hypnos - Library tab root (visionOS, iOS, macOS)

 The non-tvOS Library home, modeled on the Apple TV app on iPhone, iPad,
 Mac and Vision Pro: a full-bleed featured hero at the top of the page
 (edge to edge, running up under the navigation bar), then shelves. Same
 `LibraryHomeViewModel`, `LibraryPlayback` and data as tvOS's
 `Views/TV/Library`; only arrangement and scale differ, and those come from
 `LibraryMetrics` (the width the tab actually has).

 The hero cycles through `LibraryHome.featured`, swipeable on touch and
 with tappable page dots everywhere. Tapping the art opens the detail page;
 Play starts the item (a series' Next Up episode).

 The load is keyed on `LibraryService.configurationKey`, so a sign-in that
 lands after the tab appeared (first launch) reloads instead of leaving a
 stale "no server" state up.
 */

import SwiftUI

struct LibraryTabRootView: View {
    @State private var model = LibraryHomeViewModel()
    @State private var playback = LibraryPlayback()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LibraryHomeContentView(model: model, playback: playback)
                .navigationDestination(for: LibraryItem.self) { item in
                    LibraryDetailView(item: item, playback: playback)
                }
                .navigationDestination(for: LibraryBrowseRequest.self) { request in
                    LibraryBrowseView(request: request)
                }
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            path.append(LibraryBrowseRequest(kind: nil))
                        } label: {
                            Label("Browse & Search", systemImage: "magnifyingglass")
                        }
                    }
                }
                #if os(iOS)
                // Transparent, not hidden: the Browse & Search button still
                // needs to be reachable, floating over the hero art the same
                // way the real Apple TV app's search icon does.
                .toolbarBackground(.hidden, for: .navigationBar)
                #elseif os(macOS)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                #endif
        }
        // Dark whatever the system appearance, like the Apple TV app: the
        // page is artwork, and a white page between backdrops glares.
        .environment(\.colorScheme, .dark)
        #if !os(visionOS)
        // On visionOS NavigationStack supplies rounded glass. A rectangular
        // backing outside it fills the transparent window corners with black.
        .background(Color.black)
        #endif
        .libraryPlayback(playback)
        .task(id: LibraryService.configurationKey) {
            await model.start()
            await openAutoOpenItemIfRequested()
        }
    }

    /// DEBUG-only counterpart to tvOS's `tvLibraryAutoOpenItemId`:
    /// `-UITestDefault libraryAutoOpenItemId=<id>` pushes that item's detail
    /// page, for screenshots without driving taps.
    private func openAutoOpenItemIfRequested() async {
        #if DEBUG
        guard path.isEmpty,
              let itemId = UserDefaults.standard.string(forKey: "libraryAutoOpenItemId"), !itemId.isEmpty,
              let library = LibraryService.current(),
              let item = try? await library.item(id: itemId)
        else { return }
        path.append(item)
        #endif
    }
}

struct LibraryHomeContentView: View {
    let model: LibraryHomeViewModel
    let playback: LibraryPlayback

    var body: some View {
        Group {
            if let home = model.home, !(home.featured.isEmpty && home.shelves.isEmpty) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 28) {
                        if !home.featured.isEmpty {
                            LibraryHeroCarousel(featured: home.featured, playback: playback)
                        }
                        ForEach(home.shelves) { shelf in
                            LibraryShelfRow(shelf: shelf, playback: playback)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .ignoresSafeArea(edges: .top)
                .refreshable { await model.refresh() }
            } else if model.home != nil {
                ContentUnavailableView("Nothing Here Yet", systemImage: "film.stack",
                                       description: Text("Movies and shows added to your Jellyfin server appear here."))
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Can't Load Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .measuresLibraryMetrics()
    }
}

/// The featured hero: backdrop edge to edge with a bottom scrim, logo,
/// facts, overview and Play/Details bottom-left, page dots bottom-right.
struct LibraryHeroCarousel: View {
    let featured: [LibraryItem]
    let playback: LibraryPlayback

    @Environment(\.libraryMetrics) private var metrics
    @State private var index = 0
    /// Restarts the auto-advance timer after a manual change.
    @State private var interaction = 0

    private var item: LibraryItem { featured[min(index, featured.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            NavigationLink(value: item) {
                LibraryArtwork(item: item, slot: .backdrop, size: .backdropFull, showsTitleOnFallback: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: metrics.heroHeight)
                    .clipped()
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.35), location: 0),
                            .init(color: .clear, location: 0.2),
                            .init(color: .clear, location: 0.45),
                            .init(color: .black.opacity(0.85), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .libraryBackdropFadesIntoWindow()
                    .id(item.id)
                    .transition(.opacity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title), details")

            VStack(alignment: .leading, spacing: 10) {
                LibraryLogo(item: item,
                            maxWidth: metrics.isCompact ? 260 : 420,
                            maxHeight: metrics.isCompact ? 100 : 140,
                            titleFont: .system(size: metrics.isCompact ? 36 : 52, weight: .heavy))
                LibraryFactsLine(item: item)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                if !metrics.isCompact, let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 12) {
                    LibraryPlayButton(item: item, playback: playback)
                    NavigationLink(value: item) {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    #if !os(visionOS)
                    .tint(.white)
                    #endif
                    Spacer(minLength: 0)
                    if featured.count > 1 {
                        LibraryPageDots(count: featured.count, index: index) { selected in
                            index = selected
                            interaction += 1
                        }
                    }
                }
                .padding(.top, 4)
                if let error = playback.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .id(item.id)
            .transition(.opacity)
            .padding(.horizontal, metrics.gutter)
            .padding(.bottom, 20)
            .environment(\.colorScheme, .dark)
        }
        .animation(.easeInOut(duration: 0.5), value: index)
        #if !os(tvOS) && !os(macOS)
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard featured.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
            step(value.translation.width < 0 ? 1 : -1)
        })
        #endif
        .task(id: "\(index)-\(interaction)") {
            guard featured.count > 1 else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            index = (index + 1) % featured.count
        }
    }

    private func step(_ delta: Int) {
        index = (index + delta + featured.count) % featured.count
        interaction += 1
    }
}

/// Play / Resume · 42 min left, prominent. For a series, starts its Next Up
/// episode (`LibraryPlayback.play`), labeled by `title` when the caller
/// knows which one.
struct LibraryPlayButton: View {
    let item: LibraryItem
    let playback: LibraryPlayback
    var title: String? = nil
    var target: LibraryItem? = nil
    var fromStart = false

    var body: some View {
        let playItem = target ?? item
        Button {
            Task { await playback.play(playItem, fromStart: fromStart) }
        } label: {
            HStack(spacing: 8) {
                if playback.resolvingItemId == playItem.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(title ?? (playItem.userData.resumeSeconds != nil ? "Resume" : "Play"))
                if title == nil, let remaining = playItem.remainingSeconds {
                    Text(LibraryFormat.remaining(remaining)).opacity(0.7)
                }
            }
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.white)
        .foregroundStyle(.black)
        .disabled(playback.isResolving)
    }
}

struct LibraryPageDots: View {
    let count: Int
    let index: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { dot in
                Button {
                    select(dot)
                } label: {
                    Circle()
                        .fill(.white.opacity(dot == index ? 0.95 : 0.4))
                        .frame(width: 7, height: 7)
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured item \(index + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select((index + 1) % count)
            case .decrement: select((index - 1 + count) % count)
            @unknown default: break
            }
        }
    }
}
