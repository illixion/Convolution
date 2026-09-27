/*
 Hypnos - tvOS Library home: featured hero + shelves

 Laid out like the Apple TV app's home:

 - The hero fills the screen edge to edge, behind the tab bar. Its backdrop
   runs the full screen height, so the first shelf peeks up over the
   backdrop's darkened bottom edge, telling the viewer there is more below.
 - Logo (or title), facts line, a two-line overview, Play/Resume and
   Details sit bottom-left over a left and bottom scrim, at the tvOS title-
   safe inset.
 - The hero cycles through `LibraryHome.featured` every few seconds, with
   page dots. Left from Play and right from Details step through it by
   hand; any focus change restarts the timer so it never flips an item out
   from under someone reading it.
 - Shelves below: landscape lockups (Continue Watching, Next Up) play
   straight away, as the Apple TV app's Up Next row does; poster lockups
   open the detail page.
 */

#if os(tvOS)

import SwiftUI

struct TVLibraryHomeView: View {
    let model: LibraryHomeViewModel
    let playback: LibraryPlayback

    var body: some View {
        Group {
            if let home = model.home, !(home.featured.isEmpty && home.shelves.isEmpty) {
                TVLibraryHomeContent(home: home, playback: playback)
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
    }
}

private struct TVLibraryHomeContent: View {
    let home: LibraryHome
    let playback: LibraryPlayback

    /// How much of the first shelf shows under the hero.
    private let shelfPeek: CGFloat = 250

    var body: some View {
        GeometryReader { geometry in
            let screen = geometry.size
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 64) {
                        if !home.featured.isEmpty {
                            TVLibraryHero(featured: home.featured, playback: playback,
                                          screenSize: screen, height: screen.height - shelfPeek) {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(TVLibraryHero.scrollID, anchor: .top)
                                }
                            }
                            .id(TVLibraryHero.scrollID)
                            .focusSection()
                        }
                        ForEach(home.shelves) { shelf in
                            TVLibraryShelfRow(shelf: shelf, playback: playback)
                                .focusSection()
                                .id(shelf.id)
                        }
                    }
                    .padding(.bottom, 90)
                }
                .scrollClipDisabled()
                #if DEBUG
                // `-UITestDefault tvLibraryScrollToShelf=N` scrolls to shelf
                // N: no remote-button injection on the tvOS simulator, so
                // this is how screenshots below the hero get taken.
                .task {
                    let index = UserDefaults.standard.integer(forKey: "tvLibraryScrollToShelf")
                    guard index > 0, index <= home.shelves.count else { return }
                    try? await Task.sleep(for: .seconds(1))
                    proxy.scrollTo(home.shelves[index - 1].id, anchor: .top)
                }
                #endif
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}

/// The featured carousel. Draws its own full-screen backdrop behind itself,
/// taller than the hero, so later siblings in the stack paint over its lower
/// part.
private struct TVLibraryHero: View {
    static let scrollID = "library-hero"

    let featured: [LibraryItem]
    let playback: LibraryPlayback
    let screenSize: CGSize
    let height: CGFloat
    /// Called when focus enters the hero, to bring it fully back on screen
    /// (focus alone only scrolls far enough to reveal the buttons).
    let onFocusEnter: () -> Void

    @State private var index = 0
    @State private var lastFocusChange = Date.distantPast
    @FocusState private var focus: HeroButton?

    private enum HeroButton: Hashable { case play, details }

    private var item: LibraryItem { featured[min(index, featured.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            info
                .id(item.id)
                .transition(.opacity)
            HStack(spacing: 28) {
                Button {
                    Task { await playback.play(item) }
                } label: {
                    TVPlayButtonLabel(item: item, isResolving: playback.resolvingItemId == item.id)
                }
                .focused($focus, equals: .play)

                NavigationLink(value: item) {
                    Label("Details", systemImage: "info.circle")
                }
                .focused($focus, equals: .details)

                Spacer()

                if featured.count > 1 {
                    TVPageDots(count: featured.count, index: index)
                }
            }
            .padding(.top, 10)
            if let error = playback.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 20)
        .frame(width: screenSize.width, height: height, alignment: .bottomLeading)
        .background(alignment: .top) {
            TVLibraryBackdrop(item: item)
                .frame(width: screenSize.width, height: screenSize.height)
                .id(item.id)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.6), value: index)
        .onMoveCommand(perform: handleMove)
        .onChange(of: focus) { old, new in
            lastFocusChange = .now
            if old == nil, new != nil { onFocusEnter() }
        }
        .task(id: "\(index)-\(lastFocusChange.timeIntervalSinceReferenceDate)") {
            guard featured.count > 1 else { return }
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled, playback.videoPresentation == nil, !playback.showsFilmPlayer else { return }
            index = (index + 1) % featured.count
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 18) {
            LibraryLogo(item: item, maxWidth: 660, maxHeight: 210,
                        titleFont: .system(size: 84, weight: .heavy))
            LibraryFactsLine(item: item)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    /// Left off Play goes back an item, right off Details forward. A move
    /// that also moved focus between the two buttons arrives within a few
    /// milliseconds of the focus change and is ignored.
    private func handleMove(_ direction: MoveCommandDirection) {
        guard featured.count > 1, Date.now.timeIntervalSince(lastFocusChange) > 0.2 else { return }
        switch (direction, focus) {
        case (.left, .play):
            index = (index - 1 + featured.count) % featured.count
        case (.right, .details):
            index = (index + 1) % featured.count
        default:
            return
        }
        lastFocusChange = .now
    }
}

/// Full-screen backdrop art under scrims: dark from the left (behind the
/// text), dark at the bottom (behind the shelves), and a light one at the
/// top so the tab bar stays legible over bright art.
struct TVLibraryBackdrop: View {
    let item: LibraryItem

    var body: some View {
        LibraryArtwork(item: item, slot: .backdrop, size: .backdropFull, showsTitleOnFallback: false)
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.45),
                    .init(color: .clear, location: 0.8),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.75), location: 0.78),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}

/// "Play", "Resume · 42 min left", or "Play S1 E2"-style for a series'
/// next episode once the detail page knows it.
struct TVPlayButtonLabel: View {
    let item: LibraryItem
    var title: String? = nil
    var isResolving = false

    var body: some View {
        HStack(spacing: 14) {
            if isResolving {
                ProgressView()
            } else {
                Image(systemName: "play.fill")
            }
            Text(title ?? (item.userData.resumeSeconds != nil ? "Resume" : "Play"))
            if let remaining = item.remainingSeconds, title == nil {
                Text(LibraryFormat.remaining(remaining))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct TVPageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(.white.opacity(dot == index ? 0.95 : 0.35))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Item \(index + 1) of \(count)")
    }
}

#endif
