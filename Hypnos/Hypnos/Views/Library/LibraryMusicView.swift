import SwiftUI
import RAVEUI

struct LibraryMusicView: View {
    @State private var section = MusicSection.recent
    @State private var search = ""

    private var request: MusicRequest {
        MusicRequest(section: section, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 700 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Music Library").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
                        ForEach(MusicSection.allCases) { item in
                            Button { section = item; search = "" } label: {
                                Label(item.title, systemImage: item.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(section == item ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(width: 210)
                    .background(.thinMaterial)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        if geometry.size.width < 700 {
                            Picker("Music Library", selection: $section) {
                                ForEach(MusicSection.allCases) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                            }.pickerStyle(.menu)
                        } else { Text(section.title).font(.title2.bold()) }
                        Spacer(minLength: 0)
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
    @Environment(\.horizontalSizeClass) private var sizeClass

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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let container {
                    MusicCollectionHeader(item: container, preparing: preparingQueue) {
                        preparingQueue = true
                        playTask = Task {
                            await listing.playAll(using: JellyfinMusicSession.shared)
                            preparingQueue = false
                        }
                    }
                }
                ForEach(listing.groups) { group in
                    VStack(alignment: .leading, spacing: 16) {
                        if !group.items.isEmpty {
                            Text(request.search.isEmpty ? group.title : "Albums").font(.title2.bold())
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                            ForEach(group.items) { item in MusicAlbumTile(item: item) }
                        }
                    }
                }
                if !listing.songs.isEmpty {
                    Text("Songs").font(.title2.bold())
                    LazyVStack(spacing: 0) {
                        ForEach(listing.songs) { song in
                            MusicSongRow(song: song) {
                                JellyfinMusicSession.shared.play(song, from: listing.songs)
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
                    ContentUnavailableView(request.search.isEmpty ? "No Music Yet" : "No Results", systemImage: "music.note", description: Text(request.search.isEmpty ? "Music from your Jellyfin library appears here." : "Try another artist, album or song."))
                } else if listing.hasMore {
                    Button("Load More") { Task { await listing.loadMore() } }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .task(id: LibraryService.configurationKey) {
            if !request.search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            await listing.loadIfNeeded()
        }
        .onDisappear { playTask?.cancel() }
    }
}

private struct MusicAlbumTile: View {
    let item: JellyfinMusicItem
    var body: some View {
        NavigationLink { MusicDestinationView(item: item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                MusicArtwork(item: item, music: .shared)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(item.Name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let count = item.ChildCount, count > 0 {
                    Text("\(count) items").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MusicDestinationView: View {
    let item: JellyfinMusicItem
    private var request: MusicRequest {
        switch item.Type {
        case "MusicArtist": MusicRequest(section: .albums, artistID: item.id)
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
    let preparing: Bool
    let play: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            MusicArtwork(item: item, music: .shared)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 12) {
                Text(item.Name).font(.title2.bold())
                Text(item.artist).foregroundStyle(.secondary)
                if item.Type != "MusicArtist" {
                    Button(action: play) { Label(preparing ? "Preparing…" : "Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).disabled(preparing)
                }
            }
        }
    }
}

private struct MusicSongRow: View {
    let song: JellyfinMusicItem
    let play: () -> Void
    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                MusicArtwork(item: song, music: .shared)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.Name).foregroundStyle(.primary)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let ticks = song.RunTimeTicks {
                    let seconds = max(0, Int(ticks / 10_000_000))
                    Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct MusicNowPlayingView: View {
    let music: JellyfinMusicSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            if let item = music.current {
                MusicArtwork(item: item, music: music).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18)).shadow(radius: 22)
                VStack(spacing: 4) {
                    Text(item.Name).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                    Text(item.artist).foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    #if os(tvOS)
                    ProgressView(value: music.currentTime, total: max(1, music.duration))
                    #else
                    Slider(value: Binding(get: { music.currentTime }, set: { music.seek(to: $0) }), in: 0...max(1, music.duration))
                    #endif
                    HStack { Text(clock(music.currentTime)); Spacer(); Text("-\(clock(max(0, music.duration - music.currentTime)))") }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 34) {
                    Button { music.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(music.isShuffled ? Color.accentColor : .primary) }
                    Button { music.previous() } label: { Image(systemName: "backward.end.fill") }
                    Button { music.toggle() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34)) }
                    Button { music.next() } label: { Image(systemName: "forward.end.fill") }
                    Button { music.toggleRepeat() } label: { Image(systemName: "repeat").foregroundStyle(music.repeats ? Color.accentColor : .primary) }
                }.font(.title2).buttonStyle(.plain)
                if !music.queue.isEmpty {
                    List { Section("Up Next") {
                        ForEach(music.queue) { track in HStack { VStack(alignment: .leading) { Text(track.Name); Text(track.artist).font(.caption).foregroundStyle(.secondary) }; Spacer(); if track.id == music.current?.id { Image(systemName: "waveform").foregroundStyle(Color.accentColor) } } }
                    } }.listStyle(.plain).frame(maxHeight: 220)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(24)
        .navigationTitle("Now Playing")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { MusicAudioOptionsMenu(music: music) }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
    private func clock(_ seconds: Double) -> String { let s = max(0, Int(seconds)); return "\(s / 60):\(String(format: "%02d", s % 60))" }
}

struct MusicAudioOptionsMenu: View {
    let music: JellyfinMusicSession

    var body: some View {
        Menu {
            ForEach(JellyfinMusicAudioMode.allCases) { mode in
                Button {
                    music.setAudioMode(mode)
                } label: {
                    Label(mode.title, systemImage: music.audioMode == mode ? "checkmark" : mode.symbol)
                }
            }
            #if os(visionOS)
            Divider()
            Button {
                music.toggleHeadLocked()
            } label: {
                Label("Head-Locked Audio", systemImage: music.headLocked ? "checkmark" : "headphones")
            }
            #endif
        } label: {
            Image(systemName: music.audioMode.symbol)
        }
        .accessibilityLabel("Audio options: \(music.audioMode.title)")
        .help("Speaker Mode mixes with other audio. Music Mode takes audio focus and enables system playback controls.")
    }
}

struct MusicMiniPlayerView: View {
    let music: JellyfinMusicSession
    let onShowNowPlaying: () -> Void
    var width: CGFloat?

    var body: some View {
        if let current = music.current {
            VStack(spacing: 2) {
                Button(action: onShowNowPlaying) {
                    HStack(spacing: 10) {
                        MusicArtwork(item: current, music: music)
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.Name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(current.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RAVEPlayerControls(
                    state: RAVEPlayerControlState(
                        currentTime: music.currentTime,
                        duration: music.duration,
                        isPlaying: music.isPlaying,
                        isMuted: music.isMuted
                    ),
                    togglePlayback: { music.toggle() },
                    seek: { music.seek(to: $0) },
                    toggleMute: { music.toggleMute() },
                    layout: .strip,
                    navigation: RAVEPlayerNavigation(
                        previous: { music.previous() },
                        next: { music.next() }
                    ),
                    pinned: AnyView(MusicAudioOptionsMenu(music: music))
                ) { EmptyView() }
                .frame(width: width)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            #if os(visionOS)
            .glassBackgroundEffect(in: .rect(cornerRadius: 28))
            #else
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            #endif
        }
    }
}

struct MusicArtwork: View {
    let item: JellyfinMusicItem
    let music: JellyfinMusicSession
    var body: some View {
        Group {
            if let url = music.artworkURL(for: item) { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { fallback } }
            else { fallback }
        }.background(Color.gray.opacity(0.2))
    }
    private var fallback: some View { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
