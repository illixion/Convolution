import SwiftUI
import RAVEUI

struct LibraryMusicView: View {
    @State private var section = MusicSection.recent
    @State private var sort: MusicSort?
    @State private var search = ""
    @State private var actions = MusicActions()

    private var request: MusicRequest {
        MusicRequest(section: section, sort: sort, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func select(_ item: MusicSection) {
        section = item
        sort = nil
        search = ""
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 700 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            sidebarGroup("Music Library", MusicSection.library)
                            sidebarGroup("Collections", MusicSection.collections).padding(.top, 14)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 20)
                    }
                    .frame(width: 240, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(.thinMaterial)
                    .clipped()
                    Divider()
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        if geometry.size.width < 700 {
                            Picker("Music Library", selection: Binding(get: { section }, set: { select($0) })) {
                                ForEach(MusicSection.library + MusicSection.collections) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                            }.pickerStyle(.menu)
                        } else { Text(section.title).font(.title2.bold()) }
                        Spacer(minLength: 0)
                        if !section.sorts.isEmpty, request.search.isEmpty {
                            Menu {
                                Picker("Sort By", selection: $sort) {
                                    Text("Default").tag(MusicSort?.none)
                                    ForEach(section.sorts) { Text($0.title).tag(MusicSort?.some($0)) }
                                }
                            } label: { Label(sort?.title ?? "Sort", systemImage: "arrow.up.arrow.down") }
                        }
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search Music", text: $search)
                            .autocorrectionDisabled()
                            #if os(iOS) || os(visionOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .frame(maxWidth: 260)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }
                    .padding(20)
                    MusicCollectionView(request: request)
                        .id(request)
                }
            }
        }
        .navigationTitle("Music")
        .environment(\.musicActions, actions)
        .task(id: LibraryService.configurationKey) { await actions.prepare() }
        .sheet(item: $actions.playlistRequest) { MusicPlaylistPickerSheet(request: $0, actions: actions) }
        .sheet(item: $actions.infoItem) { MusicInfoEditorSheet(item: $0, actions: actions) }
        .overlay(alignment: .bottom) {
            if let notice = actions.notice {
                Text(notice)
                    .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 96)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: actions.notice)
    }

    @ViewBuilder
    private func sidebarGroup(_ title: String, _ sections: [MusicSection]) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
        ForEach(sections) { item in
            Button { select(item) } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.symbol)
                        .frame(width: 24, height: 24)
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(section == item ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
        }
    }
}

/// Every ForEach emits one stable row or tile. Playback time is observed only
/// by the transport, never by this catalog view.
private struct MusicCollectionView: View {
    let request: MusicRequest
    let container: JellyfinMusicItem?
    @State private var listing: MusicListing
    @State private var playTask: Task<Void, Never>?
    @State private var preparingQueue = false
    @State private var editingPlaylist = false
    @State private var opened: JellyfinMusicItem?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.musicActions) private var actions

    init(request: MusicRequest, container: JellyfinMusicItem? = nil) {
        self.request = request
        self.container = container
        _listing = State(initialValue: MusicCatalog.shared.listing(for: request))
    }

    private var columns: [GridItem] {
        #if os(iOS)
        if sizeClass == .compact { return [GridItem(.flexible()), GridItem(.flexible())] }
        #endif
        return [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 24, alignment: .top)]
    }

    private var isPlaylist: Bool { container?.Type == "Playlist" }

    /// An album with more than one disc is listed disc by disc.
    private var songGroups: [(title: String?, rows: [(position: Int, song: JellyfinMusicItem)])] {
        let rows = Array(listing.songs.enumerated()).map { (position: $0.offset, song: $0.element) }
        guard request.albumID != nil, Set(rows.map { $0.song.ParentIndexNumber ?? 1 }).count > 1 else { return [(nil, rows)] }
        return Dictionary(grouping: rows) { $0.song.ParentIndexNumber ?? 1 }
            .sorted { $0.key < $1.key }
            .map { ("Disc \($0.key)", $0.value) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let container {
                    MusicCollectionHeader(item: container, songs: listing.songs, complete: !listing.hasMore && !listing.isLoading,
                                          preparing: preparingQueue, editing: $editingPlaylist,
                                          play: { startPlayback(shuffled: false) },
                                          shuffle: { startPlayback(shuffled: true) })
                } else if request.section != .genres, request.section != .playlists {
                    Button { startPlayback(shuffled: true) } label: {
                        Label(preparingQueue ? "Preparing…" : "Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preparingQueue)
                    .accessibilityLabel("Shuffle \(request.search.isEmpty ? request.section.title : "search results")")
                }
                ForEach(listing.groups) { group in
                    VStack(alignment: .leading, spacing: 16) {
                        if !group.items.isEmpty {
                            Text(group.title).font(.title2.bold())
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                            ForEach(group.items) { item in MusicAlbumTile(item: item) }
                        }
                    }
                }
                if !listing.songs.isEmpty {
                    if request.albumID == nil { Text("Songs").font(.title2.bold()) }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songGroups.enumerated()), id: \.offset) { _, group in
                            if let title = group.title { Text(title).font(.headline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12) }
                            ForEach(group.rows, id: \.position) { row in
                                MusicSongRow(song: row.song, position: row.position, list: listing.songs,
                                             showsTrackNumber: request.albumID != nil,
                                             editing: editingPlaylist ? playlistEditing(row.song, position: row.position) : nil)
                            }
                        }
                    }
                }
                if let error = listing.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await listing.loadMore() } }
                } else if listing.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if listing.items.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: request.section.symbol, description: Text(emptyDescription))
                } else if listing.hasMore {
                    Button("Load More") { Task { await listing.loadMore() } }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .environment(\.musicOpen) { opened = $0 }
        .navigationDestination(item: $opened) { MusicDestinationView(item: $0) }
        .task(id: LibraryService.configurationKey) {
            if !request.search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            await listing.loadIfNeeded()
        }
        .onChange(of: actions?.revision) { Task { await listing.refresh() } }
        .onDisappear { playTask?.cancel() }
    }

    private var emptyTitle: String {
        if !request.search.isEmpty { return "No Results" }
        switch request.section {
        case .favorites: return "No Favorite Songs"
        case .recentlyPlayed, .mostPlayed: return "Nothing Played Yet"
        case .playlists: return "No Playlists"
        default: return "No Music Yet"
        }
    }

    private var emptyDescription: String {
        if !request.search.isEmpty { return "Try another artist, album or song." }
        switch request.section {
        case .favorites: return "Choose Favorite from a song's menu and it appears here."
        case .recentlyPlayed, .mostPlayed: return "Songs you listen to through half their length appear here."
        case .playlists: return "Use Add to Playlist on a song or album to make one."
        default: return "Music from your Jellyfin library appears here."
        }
    }

    private func startPlayback(shuffled: Bool) {
        guard !preparingQueue else { return }
        preparingQueue = true
        playTask = Task {
            defer { preparingQueue = false }
            if shuffled { await listing.shuffle(using: .shared) }
            else { await listing.playAll(using: .shared) }
        }
    }

    // MARK: Playlist arranging

    private func playlistEditing(_ song: JellyfinMusicItem, position: Int) -> MusicPlaylistEditing? {
        guard let container, isPlaylist, let entry = song.PlaylistItemId else { return nil }
        let last = listing.songs.count - 1
        return MusicPlaylistEditing(
            remove: { changePlaylist(container) { try await $0.removeFromMusicPlaylist(id: container.id, entryIDs: [entry]) } },
            moveUp: position > 0 ? { changePlaylist(container) { try await $0.moveMusicPlaylistItem(playlistID: container.id, entryID: entry, to: position - 1) } } : nil,
            moveDown: position < last ? { changePlaylist(container) { try await $0.moveMusicPlaylistItem(playlistID: container.id, entryID: entry, to: position + 1) } } : nil)
    }

    private func changePlaylist(_ playlist: JellyfinMusicItem, _ change: @escaping @Sendable (JellyfinLibrary) async throws -> Void) {
        Task {
            guard let library = LibraryService.current() else { return }
            do {
                try await change(library)
                MusicCatalog.shared.invalidate { $0.playlistID == playlist.id || $0.section == .playlists }
                await listing.refresh()
            } catch { actions?.post(error.localizedDescription) }
        }
    }
}

private struct MusicAlbumTile: View {
    let item: JellyfinMusicItem
    var body: some View {
        NavigationLink { MusicDestinationView(item: item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                MusicArtwork(item: item, music: .shared)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: item.Type == "MusicArtist" ? 200 : 10))
                Text(item.Name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { MusicItemMenu(item: item) }
    }

    private var subtitle: String? {
        switch item.Type {
        case "MusicArtist", "MusicGenre": nil
        case "Playlist": item.ChildCount.map { "\($0) songs" }
        default: [item.artist, item.ProductionYear.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

private struct MusicDestinationView: View {
    let item: JellyfinMusicItem
    private var request: MusicRequest {
        switch item.Type {
        case "MusicArtist": MusicRequest(section: .albums, artistID: item.id)
        case "MusicGenre": MusicRequest(section: .albums, genreID: item.id)
        case "Playlist": MusicRequest(section: .songs, playlistID: item.id)
        default: MusicRequest(section: .songs, albumID: item.id)
        }
    }
    var body: some View {
        MusicCollectionView(request: request, container: item)
            .navigationTitle(item.Name)
    }
}

private struct MusicCollectionHeader: View {
    let item: JellyfinMusicItem
    let songs: [JellyfinMusicItem]
    /// Every song has loaded, so the running time is the whole album's.
    let complete: Bool
    let preparing: Bool
    @Binding var editing: Bool
    let play: () -> Void
    let shuffle: () -> Void
    @State private var detail: JellyfinMusicItem?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var showsFullBio = false
    @Environment(\.musicActions) private var actions
    @Environment(\.dismiss) private var dismiss

    private var shown: JellyfinMusicItem { detail ?? item }
    private var isPlaylist: Bool { item.Type == "Playlist" }
    private var canArrangePlaylist: Bool { isPlaylist && (LibraryService.current()?.hasUserSession ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                MusicArtwork(item: shown, music: .shared)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: item.Type == "MusicArtist" ? 70 : 12))
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.Name).font(.title2.bold())
                    if item.Type == "MusicAlbum" { Text(shown.artist).foregroundStyle(.secondary) }
                    if let facts { Text(facts).font(.subheadline).foregroundStyle(.secondary) }
                    if let quality = songs.first?.quality, item.Type == "MusicAlbum", quality.isLossless {
                        Label(quality.badge, systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if item.Type == "MusicAlbum" || isPlaylist {
                            Button(action: play) { Label(preparing ? "Preparing…" : "Play", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                        }
                        if item.Type == "MusicAlbum" || isPlaylist {
                            Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }.buttonStyle(.bordered)
                        } else {
                            Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }.buttonStyle(.borderedProminent)
                        }
                        if canArrangePlaylist {
                            Button(editing ? "Done" : "Edit") { editing.toggle() }.buttonStyle(.bordered)
                        }
                        Menu {
                            MusicItemMenu(item: shown)
                            if isPlaylist, LibraryService.current()?.hasUserSession == true {
                                Section {
                                    Button("Rename…", systemImage: "pencil") { newName = item.Name; renaming = true }
                                    Button("Delete Playlist", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("More")
                    }
                    .disabled(preparing)
                }
            }
            if let overview = shown.Overview, !overview.isEmpty {
                Text(overview).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(showsFullBio ? nil : 4)
                    .onTapGesture { showsFullBio.toggle() }
            }
        }
        .task(id: item.id) {
            guard !isPlaylist, let library = LibraryService.current() else { return }
            detail = try? await library.musicItem(id: item.id)
        }
        .onChange(of: actions?.revision) {
            Task { if let library = LibraryService.current() { detail = try? await library.musicItem(id: item.id) } }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(item.Name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { Task { await deletePlaylist() } }
        } message: { Text("The songs stay in your library.") }
    }

    private var facts: String? {
        var parts: [String] = []
        if let year = shown.ProductionYear { parts.append(String(year)) }
        if let genre = shown.Genres?.first { parts.append(genre) }
        if item.Type == "MusicAlbum" || isPlaylist {
            let count = shown.ChildCount ?? (songs.isEmpty ? nil : songs.count)
            if let count { parts.append("\(count) song\(count == 1 ? "" : "s")") }
            if complete, !songs.isEmpty {
                let minutes = Int((songs.reduce(0) { $0 + $1.seconds } / 60).rounded())
                parts.append(minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func rename() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let library = LibraryService.current() else { return }
        do {
            try await library.renameMusicPlaylist(id: item.id, name: name)
            actions?.libraryChanged()
            actions?.post("Renamed to “\(name)”")
        } catch { actions?.post(error.localizedDescription) }
    }

    private func deletePlaylist() async {
        guard let library = LibraryService.current() else { return }
        do {
            try await library.deleteMusicPlaylist(id: item.id)
            actions?.libraryChanged()
            actions?.post("Deleted “\(item.Name)”")
            dismiss()
        } catch { actions?.post(error.localizedDescription) }
    }
}
