/*
 Hypnos - Library browse & search (visionOS, iOS, macOS)

 The library-wide counterpart to the home screen's shelves: a plain grid of
 every movie/show, filterable by kind and searchable, for when what's wanted
 isn't already on Continue Watching / Next Up / Recently Added. Reuses the
 same `LibraryPosterLockup` cell the shelves use and lands on the same
 `LibraryDetailView` destination — this view adds no new navigation target,
 just a second way to get an item onto the existing `NavigationPath`.
 */

import SwiftUI

/// Pushed onto `LibraryTabRootView`'s `NavigationPath` to open the browse
/// grid, optionally pre-filtered to one kind.
struct LibraryBrowseRequest: Hashable {
    var kind: LibraryItemKind?
}

@MainActor
@Observable
final class LibraryBrowseViewModel {
    private(set) var items: [LibraryItem] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?

    var kind: LibraryItemKind?
    var searchText = ""

    private let pageSize = 50
    private var library: JellyfinLibrary?
    /// Guards against a slow page landing after `kind`/`searchText` changed
    /// and a newer load already started.
    private var loadToken = UUID()

    func start(kind: LibraryItemKind?) async {
        self.kind = kind
        library = LibraryService.current()
        await reload()
    }

    /// Restarts from page 0 — call when `kind` or `searchText` changes.
    func reload() async {
        let token = UUID()
        loadToken = token
        items = []
        hasMore = true
        error = nil
        await loadNextPage(token: token)
    }

    func loadNextPage() async {
        await loadNextPage(token: loadToken)
    }

    private func loadNextPage(token: UUID) async {
        guard let library, hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        do {
            let page: [LibraryItem]
            if query.isEmpty {
                page = try await library.browse(kind: kind, startIndex: items.count, limit: pageSize)
            } else {
                // The server-side search endpoint isn't paginated; one call
                // replaces the whole result set rather than appending pages.
                page = try await library.search(query)
            }
            guard token == loadToken else { return }
            if query.isEmpty {
                items.append(contentsOf: page)
                hasMore = page.count == pageSize
            } else {
                items = page
                hasMore = false
            }
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            guard token == loadToken else { return }
            self.error = error.localizedDescription
        }
    }
}

struct LibraryBrowseView: View {
    let request: LibraryBrowseRequest

    @State private var model = LibraryBrowseViewModel()
    /// Cancelled and replaced on every keystroke so only the last one, after
    /// a pause, actually reloads.
    @State private var searchDebounce: Task<Void, Never>?
    @Environment(\.libraryMetrics) private var metrics

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: metrics.poster.width), spacing: metrics.lockupSpacing)]
    }

    var body: some View {
        Group {
            if model.items.isEmpty, model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty, let error = model.error {
                ContentUnavailableView {
                    Label("Can't Load Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.reload() } }
                }
            } else if model.items.isEmpty, !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.items.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "film.stack",
                                       description: Text("Movies and shows added to your Jellyfin server appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: metrics.lockupSpacing) {
                        ForEach(model.items) { item in
                            NavigationLink(value: item) {
                                LibraryPosterLockup(item: item)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                guard item == model.items.last else { return }
                                Task { await model.loadNextPage() }
                            }
                        }
                    }
                    .padding(metrics.gutter)
                }
            }
        }
        .measuresLibraryMetrics()
        .navigationTitle(request.kind == .movie ? "Movies" : request.kind == .series ? "Shows" : "Browse")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Kind", selection: $model.kind) {
                    Text("All").tag(LibraryItemKind?.none)
                    Text("Movies").tag(LibraryItemKind?.some(.movie))
                    Text("Shows").tag(LibraryItemKind?.some(.series))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
        }
        .searchable(text: $model.searchText, prompt: "Search movies and shows")
        .task { await model.start(kind: request.kind) }
        .onChange(of: model.kind) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: model.searchText) { _, _ in
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.reload()
            }
        }
    }
}
