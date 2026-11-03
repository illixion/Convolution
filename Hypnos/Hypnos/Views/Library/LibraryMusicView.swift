import SwiftUI
import RAVEUI

struct LibraryMusicView: View {
    @State private var music = JellyfinMusicSession.shared
    @State private var search = ""

    private var visibleTracks: [JellyfinMusicItem] { search.isEmpty ? music.tracks : music.searchResults }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search artists, albums, songs", text: $search)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if !search.isEmpty {
                        Button { search = ""; music.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                    }
                }
            }
            if search.isEmpty, !music.albums.isEmpty {
                Section("Recently Added Albums") {
                    ForEach(music.albums) { album in
                        NavigationLink { JellyfinMusicAlbumView(album: album, music: music) } label: {
                            HStack(spacing: 14) {
                                MusicArtwork(item: album, music: music).frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.Name).font(.headline)
                                    Text(album.artist).foregroundStyle(.secondary)
                                    Text("\(music.tracks.filter { $0.Album == album.Name }.count) songs").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .contextMenu { Button("Play Album", systemImage: "play.fill") { play(album) } }
                    }
                }
            }
            Section(search.isEmpty ? "Songs" : "Search Results") {
                if !search.isEmpty && visibleTracks.isEmpty && !music.isLoading {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(visibleTracks) { track in
                    if track.Album == nil {
                        NavigationLink { JellyfinMusicAlbumView(album: track, music: music) } label: {
                            HStack(spacing: 12) {
                                MusicArtwork(item: track, music: music).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) { Text(track.Name).foregroundStyle(.primary); Text(track.artist).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                    } else {
                        Button { music.play(track) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.Name).foregroundStyle(.primary)
                                Text("\(track.artist) · \(track.Album ?? "")").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Music")
        .overlay {
            if music.isLoading && music.tracks.isEmpty { ProgressView() }
            else if let error = music.error { ContentUnavailableView("Music Unavailable", systemImage: "music.note", description: Text(error)) }
        }
        .task { await music.load() }
        .task(id: search) {
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { music.clearSearch(); return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await music.search(search)
        }
    }

    private func play(_ album: JellyfinMusicItem) {
        let list = music.tracks.filter { $0.Album == album.Name }
        if let first = list.first { music.play(first, from: list) }
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
                    Button { music.toggleRepeat() } label: { Image(systemName: music.repeats ? "repeat.1" : "repeat").foregroundStyle(music.repeats ? Color.accentColor : .primary) }
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

private struct JellyfinMusicAlbumView: View {
    let album: JellyfinMusicItem
    let music: JellyfinMusicSession
    private var songs: [JellyfinMusicItem] { music.tracks.filter { $0.Album == album.Name } }
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    MusicArtwork(item: album, music: music).frame(width: 130, height: 130).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(album.Name).font(.title2.bold())
                        Text(album.artist).foregroundStyle(.secondary)
                        Button { if let first = songs.first { music.play(first, from: songs) } } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                    }
                }.padding(.vertical, 8)
            }
            Section("Songs") {
                ForEach(songs) { track in Button { music.play(track, from: songs) } label: {
                    HStack { Text(track.Name); Spacer(); if let ticks = track.RunTimeTicks { Text(timeLabel(Double(ticks) / 10_000_000)).foregroundStyle(.secondary).font(.caption) } }
                }.buttonStyle(.plain) }
            }
        }
        .navigationTitle(album.Name)
    }
    private func timeLabel(_ value: Double) -> String { let s = Int(value); return "\(s / 60):\(String(format: "%02d", s % 60))" }
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
