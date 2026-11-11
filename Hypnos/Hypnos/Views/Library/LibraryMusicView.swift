import SwiftUI
import RAVEUI

struct LibraryMusicView: View {
    #if DEBUG
    @State private var section = MusicDebugLaunch.section ?? MusicSection.recent
    @State private var sort: MusicSort? = MusicDebugLaunch.sort
    #else
    @State private var section = MusicSection.recent
    @State private var sort: MusicSort?
    #endif
    @State private var descending: Bool?
    /// Dealt afresh each time Random is picked or "Shuffle Again" is pressed; see `MusicRequest.shuffleSeed`.
    @State private var shuffleSeed = 0
    @State private var search = ""
    @State private var actions = MusicActions()
    #if DEBUG && (os(macOS) || os(visionOS))
    @OpenWindowProxy private var openWindow
    #endif
    @Environment(\.musicOpen) private var open

    private var request: MusicRequest {
        MusicRequest(section: section, sort: sort, descending: descending, search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                     shuffleSeed: shuffleSeed)
    }

    private func select(_ item: MusicSection) {
        section = item
        (sort, descending) = MusicSortPreference.load(for: MusicRequest(section: item))
        shuffleSeed = 0
        search = ""
    }

    private func save() { MusicSortPreference.save(sort: sort, descending: descending, for: request) }

    /// Pick an order from the menu: the order starts in its own direction, and picking it again changes nothing.
    private func pickSort(_ chosen: MusicSort) {
        guard chosen != request.effectiveSort else { return }
        sort = chosen
        descending = nil
        // Each pick of Random is a new shuffle.
        shuffleSeed = chosen == .random ? Int.random(in: 1...Int.max) : 0
        save()
    }

    /// Click a column header: another column sorts by it, the sorted column flips its direction.
    private func clickColumn(_ chosen: MusicSort) {
        if chosen == request.effectiveSort { descending = !request.isDescending }
        else { pickSort(chosen); return }
        save()
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
                    header(compact: geometry.size.width < 700)
                    // The lists under it are swapped for each section and order; they cross-fade in place.
                    MusicCollectionView(request: request, onSort: columnSort)
                }
            }
        }
        .navigationTitle("Music")
        .musicActionHost(actions)
        .navigationDestination(for: JellyfinMusicItem.self) { MusicDestinationView(item: $0) }
        .task(id: LibraryService.configurationKey) { MusicSearchStore.shared.prepare(onlyIfCached: true) }
        #if DEBUG
        .task {
            // Playing first: pushing the album leaves this view, which cancels the task.
            if await MusicDebugLaunch.autoPlayIfRequested() {
                #if os(macOS) || os(visionOS)
                if MusicDebugLaunch.opensVisualizer { MusicVisualizerView.open(using: openWindow) }
                #endif
            }
            if let album = await MusicDebugLaunch.albumToOpen() { open?(album) }
        }
        #endif
        .onChange(of: search) { _, text in
            if !text.isEmpty { MusicSearchStore.shared.prepare() }
        }
    }

    /// The title (or, narrow, the section picker), the order and the search. Narrow, the search drops to a row of its
    /// own: all three side by side wrap their words letter by letter.
    @ViewBuilder
    private func header(compact: Bool) -> some View {
        let sortControl = MusicSortControl(request: request, pick: pickSort,
                                           setDescending: { descending = $0; save() },
                                           dealAgain: { shuffleSeed = Int.random(in: 1...Int.max) })
        let sectionTitle = Group {
            if compact {
                Picker("Music Library", selection: Binding(get: { section }, set: { select($0) })) {
                    ForEach(MusicSection.library + MusicSection.collections) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            } else {
                Text(section.title).font(.title2.bold()).contentTransition(.opacity).animation(.smooth(duration: 0.2), value: section)
            }
        }
        if compact {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    sectionTitle
                    Spacer(minLength: 0)
                    if request.search.isEmpty { sortControl }
                }
                HStack(spacing: 8) { searchField(maxWidth: .infinity) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        } else {
            HStack(spacing: 12) {
                sectionTitle
                Spacer(minLength: 0)
                if request.search.isEmpty { sortControl }
                searchField(maxWidth: 260)
            }
            .padding(20)
        }
    }

    /// What a click on a column header does; nil where the screen has no table.
    private var columnSort: ((MusicSort) -> Void)? {
        request.sorts.isEmpty ? nil : { chosen in clickColumn(chosen) }
    }

    @ViewBuilder
    private func searchField(maxWidth: CGFloat) -> some View {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search Music", text: $search)
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .frame(maxWidth: maxWidth)
        if !search.isEmpty {
            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
        }
    }

    private func sidebarGroup(_ title: String, _ sections: [MusicSection]) -> some View {
        // One container, so a modifier on the group (the gap above Collections) lands on the group once.
        VStack(alignment: .leading, spacing: 4) {
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
        .animation(.smooth(duration: 0.2), value: section)
    }
}

/// Every ForEach emits one stable row or tile. Playback time is observed only
/// by the transport, never by this catalog view.
///
/// A new request (another section, another order, another search) swaps the listing in place: the scroll view and
/// an album's header stay, the list under them cross-fades to the new one and the view returns to the top.
private struct MusicCollectionView: View {
    let request: MusicRequest
    let container: JellyfinMusicItem?
    /// A click on a column header of the songs table; nil where the list has no sortable columns.
    var onSort: ((MusicSort) -> Void)?
    @State private var width: CGFloat = 0
    @State private var listing: MusicListing
    @State private var playTask: Task<Void, Never>?
    @State private var preparingQueue = false
    @State private var editingPlaylist = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.musicActions) private var actions
    private static let topID = "music-top"

    init(request: MusicRequest, container: JellyfinMusicItem? = nil, onSort: ((MusicSort) -> Void)? = nil) {
        self.request = request
        self.container = container
        self.onSort = onSort
        _listing = State(initialValue: MusicCatalog.shared.listing(for: request))
    }

    private var columns: [GridItem] {
        #if os(iOS)
        if sizeClass == .compact { return [GridItem(.flexible()), GridItem(.flexible())] }
        #endif
        return [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 24, alignment: .top)]
    }

    private var isPlaylist: Bool { container?.Type == "Playlist" }

    /// Songs go in a table (title, artist, album, plays, time) once the window is wide enough and the list is one
    /// of the library's own, not the inside of an album.
    private var usesColumns: Bool {
        width >= 760 && request.isTopLevel && request.section.listsSongs && request.search.isEmpty && !editingPlaylist
    }

    /// The loaded songs under their headers. An album with more than one disc is listed disc by disc, in its own order.
    private var songSections: [MusicSongGroup] {
        if !listing.songGroups.isEmpty { return listing.songGroups }
        let rows = Array(listing.songs.enumerated()).map { (position: $0.offset, song: $0.element) }
        guard request.albumID != nil, request.effectiveSort == .listOrder,
              Set(rows.map { $0.song.ParentIndexNumber ?? 1 }).count > 1 else {
            return [MusicSongGroup(id: "all", title: nil, rows: rows)]
        }
        let discs = Dictionary(grouping: rows) { $0.song.ParentIndexNumber ?? 1 }.sorted { $0.key < $1.key }
        return (request.isDescending ? Array(discs.reversed()) : discs)
            .map { MusicSongGroup(id: "disc-\($0.key)", title: "Disc \($0.key)", rows: $0.value) }
    }

    private var loadKey: String {
        "\(LibraryService.configurationKey)|\(request.search.isEmpty ? 0 : MusicSearchStore.shared.generation)|\(listing.request.hashValue)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let container {
                        MusicCollectionHeader(item: container, songs: listing.songs, complete: !listing.hasMore && !listing.isLoading,
                                              preparing: preparingQueue, editing: $editingPlaylist,
                                              canArrange: request.effectiveSort == .listOrder && !request.isDescending,
                                              play: { startPlayback(shuffled: false) },
                                              shuffle: { startPlayback(shuffled: true) })
                    }
                    ZStack(alignment: .top) {
                        content
                            .id(listing.request)
                            .transition(.opacity)
                    }
                    .animation(.smooth(duration: 0.28), value: listing.request)
                }
                .id(Self.topID)
                .padding(24)
                .padding(.bottom, 24)
            }
            .onChange(of: listing.request) { proxy.scrollTo(Self.topID, anchor: .top) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: request) { _, new in
            listing = MusicCatalog.shared.listing(for: new)
            // Rearranging only makes sense in the playlist's own order.
            if new.effectiveSort != .listOrder || new.isDescending { editingPlaylist = false }
        }
        .task(id: loadKey) {
            if !request.search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(MusicSearchStore.shared.isReady ? 120 : 300)) } catch { return }
                // A new index arrived while results were showing: ask it again.
                await listing.refresh()
            } else {
                await listing.loadIfNeeded()
            }
        }
        .onChange(of: actions?.revision) { Task { await listing.refresh() } }
        .onDisappear { playTask?.cancel() }
    }

    /// The lists: shuffle, albums by section, songs by section, and what stands in for them while there is nothing.
    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
            if container == nil, request.section != .genres, request.section != .playlists {
                Button { startPlayback(shuffled: true) } label: {
                    Label(preparingQueue ? "Preparing…" : "Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(preparingQueue)
                .accessibilityLabel("Shuffle \(request.search.isEmpty ? request.section.title : "search results")")
            }
            if !request.search.isEmpty, case .building(let progress) = MusicSearchStore.shared.state {
                Label("Indexing your music for typo-tolerant search… \(Int(progress * 100))%", systemImage: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(listing.groups) { group in
                VStack(alignment: .leading, spacing: 16) {
                    if !group.items.isEmpty {
                        Text(group.title).font(.title2.bold())
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(group.items) { item in MusicAlbumTile(item: item).transition(.opacity) }
                    }
                }
                .transition(.opacity)
            }
            if !listing.songs.isEmpty {
                Section {
                    if request.albumID == nil, !listing.albums.isEmpty { Text("Songs").font(.title2.bold()) }
                    LazyVStack(spacing: 0) {
                        ForEach(songSections) { group in
                            if let title = group.title {
                                if request.albumID != nil {
                                    Text(title).font(.headline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                                } else {
                                    Text(title).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18).padding(.bottom, 4)
                                }
                            }
                            ForEach(group.rows, id: \.position) { row in
                                MusicSongRow(song: row.song, position: row.position, list: listing.songs,
                                             showsTrackNumber: request.albumID != nil,
                                             columns: usesColumns,
                                             editing: editingPlaylist ? playlistEditing(row.song, position: row.position) : nil)
                                    .transition(.opacity)
                            }
                        }
                    }
                } header: {
                    if usesColumns {
                        MusicSongColumnHeader(sort: request.effectiveSort, descending: request.isDescending, onSort: onSort)
                    }
                }
            }
            if let error = listing.error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await listing.loadMore() } }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else if listing.isLoading {
                ProgressView().frame(maxWidth: .infinity).transition(.opacity)
            } else if listing.items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: request.section.symbol, description: Text(emptyDescription))
                    .transition(.opacity)
            } else if listing.hasMore {
                Button("Load More") { Task { await listing.loadMore() } }
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        // What arrives (a page, the end of a load, an error) fades in rather than appearing.
        .animation(.smooth(duration: 0.3), value: listing.revision)
        .animation(.smooth(duration: 0.25), value: listing.isLoading)
        .animation(.smooth(duration: 0.25), value: listing.error)
        .animation(.smooth(duration: 0.25), value: editingPlaylist)
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
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: item) {
                VStack(alignment: .leading, spacing: 6) {
                    MusicArtwork(item: item, music: .shared)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: item.Type == "MusicArtist" ? 200 : 10))
                    Text(item.Name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            subtitle
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .contextMenu { MusicItemMenu(item: item) }
    }

    /// The artist and year under an album: the artist is a link, since the tile itself opens the album.
    @ViewBuilder
    private var subtitle: some View {
        switch item.Type {
        case "MusicArtist", "MusicGenre": EmptyView()
        case "Playlist": if let count = item.ChildCount { Text("\(count) songs").lineLimit(1) }
        default:
            HStack(spacing: 0) {
                MusicArtistLine(item: item)
                if let year = item.ProductionYear { Text(" · \(String(year))").lineLimit(1) }
            }
        }
    }
}

/// An album, artist, playlist or genre: its header and what it holds, in an order the listener can change.
struct MusicDestinationView: View {
    let item: JellyfinMusicItem
    @State private var sort: MusicSort?
    @State private var descending: Bool?
    @State private var shuffleSeed = 0

    init(item: JellyfinMusicItem) {
        self.item = item
        // The order this kind of screen was last left in, so there is no second load when it is applied.
        let (sort, descending) = MusicSortPreference.load(for: Self.baseRequest(for: item))
        _sort = State(initialValue: sort)
        _descending = State(initialValue: descending)
    }

    private static func baseRequest(for item: JellyfinMusicItem) -> MusicRequest {
        switch item.Type {
        case "MusicArtist": MusicRequest(section: .albums, artistID: item.id)
        case "MusicGenre": MusicRequest(section: .albums, genreID: item.id)
        case "Playlist": MusicRequest(section: .songs, playlistID: item.id)
        default: MusicRequest(section: .songs, albumID: item.id)
        }
    }

    private var request: MusicRequest {
        var request = Self.baseRequest(for: item)
        request.sort = sort; request.descending = descending; request.shuffleSeed = shuffleSeed
        return request
    }

    private func save() { MusicSortPreference.save(sort: sort, descending: descending, for: request) }

    var body: some View {
        let request = request
        MusicCollectionView(request: request, container: item, onSort: nil)
            .navigationTitle(item.Name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicSortControl(request: request, pick: { chosen in
                    guard chosen != request.effectiveSort else { return }
                    sort = chosen; descending = nil
                    shuffleSeed = chosen == .random ? Int.random(in: 1...Int.max) : 0
                    save()
                }, setDescending: { descending = $0; save() }, dealAgain: { shuffleSeed = Int.random(in: 1...Int.max) })
            }
        }
    }
}

private struct MusicCollectionHeader: View {
    let item: JellyfinMusicItem
    let songs: [JellyfinMusicItem]
    /// Every song has loaded, so the running time is the whole album's.
    let complete: Bool
    let preparing: Bool
    @Binding var editing: Bool
    /// A playlist can only be rearranged in its own order; sorted any other way, Edit is withheld.
    var canArrange = true
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
    private var canArrangePlaylist: Bool { isPlaylist && canArrange && (LibraryService.current()?.hasUserSession ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                MusicArtwork(item: shown, music: .shared)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: item.Type == "MusicArtist" ? 70 : 12))
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.Name).font(.title2.bold())
                    if item.Type == "MusicAlbum" { MusicArtistLine(item: shown).foregroundStyle(.secondary) }
                    if let facts { Text(facts).font(.subheadline).foregroundStyle(.secondary).transition(.opacity).contentTransition(.opacity) }
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
                    .transition(.opacity)
            }
        }
        // The year, the genre and the biography arrive after the header does; they fade in and the header settles.
        .animation(.smooth(duration: 0.3), value: shown.Overview)
        .animation(.smooth(duration: 0.3), value: facts)
        .animation(.smooth(duration: 0.25), value: showsFullBio)
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

/// The order each screen was last left in, as iTunes keeps a view's sort: a section's, or the kind of item the
/// screen is inside (every album opens in the order the last one was left in).
enum MusicSortPreference {
    private static let key = "jellyfinMusic.sortOrder"

    static func load(for request: MusicRequest) -> (MusicSort?, Bool?) {
        guard let saved = HypnosDefaults.store.dictionary(forKey: key)?[request.sortKey] as? String else { return (nil, nil) }
        let parts = saved.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let sort = MusicSort(rawValue: parts.first ?? "").flatMap { request.sorts.contains($0) ? $0 : nil }
        let descending = parts.count > 1 ? (parts[1] == "desc" ? true : parts[1] == "asc" ? false : nil) : nil
        return (sort, descending)
    }

    static func save(sort: MusicSort?, descending: Bool?, for request: MusicRequest) {
        var all = HypnosDefaults.store.dictionary(forKey: key) ?? [:]
        all[request.sortKey] = "\(sort?.rawValue ?? "")|\(descending.map { $0 ? "desc" : "asc" } ?? "")"
        HypnosDefaults.store.set(all, forKey: key)
    }
}

/// The sort menu every Music list has: the orders on offer, the direction, and for Random a button to deal again.
struct MusicSortControl: View {
    let request: MusicRequest
    let pick: (MusicSort) -> Void
    let setDescending: (Bool) -> Void
    let dealAgain: () -> Void

    private var sortBinding: Binding<MusicSort?> {
        Binding(get: { request.effectiveSort }, set: { if let value = $0 { pick(value) } })
    }

    var body: some View {
        let effective = request.effectiveSort
        HStack(spacing: 10) {
            // Random is for flicking through: one tap deals a new set, wherever you are in the list.
            if effective == .random {
                Button(action: dealAgain) { Label("Shuffle Again", systemImage: "arrow.triangle.2.circlepath") }
                    .labelStyle(.iconOnly)
                    .help("Shuffle again")
                    .transition(.scale.combined(with: .opacity))
            }
            Menu {
                Picker("Sort By", selection: sortBinding) {
                    ForEach(request.sorts) { Label($0.label(in: request), systemImage: $0.symbol).tag(MusicSort?.some($0)) }
                }
                if effective?.hasDirection == true {
                    Picker("Order", selection: Binding(get: { request.isDescending }, set: { setDescending($0) })) {
                        Label("Ascending", systemImage: "arrow.up").tag(false)
                        Label("Descending", systemImage: "arrow.down").tag(true)
                    }
                }
                if effective == .random {
                    Button("Shuffle Again", systemImage: "dice", action: dealAgain)
                }
            } label: {
                Label(effective?.label(in: request) ?? "Sort",
                      systemImage: effective == .random ? "dice" : request.isDescending ? "arrow.down" : "arrow.up")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityLabel("Sort by \(effective?.label(in: request) ?? "default")\(effective?.hasDirection == true ? (request.isDescending ? ", descending" : ", ascending") : "")")
        }
        .opacity(request.sorts.isEmpty ? 0 : 1)
        .disabled(request.sorts.isEmpty)
        .animation(.smooth(duration: 0.2), value: effective == .random)
    }
}
