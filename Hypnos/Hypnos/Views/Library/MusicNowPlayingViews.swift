/*
 Hypnos - Music section: Now Playing, the mini player, lyrics and the audio options.

 Browsing owns no playback clock (see `MusicListing`); only these views read it, and only the transport and the
 lyrics pane read it every second.
 */

import RAVEMedia
import SwiftUI
import RAVEUI

struct MusicNowPlayingView: View {
    let music: JellyfinMusicSession
    @Environment(\.dismiss) private var dismiss
    @State private var pane = Pane.upNext
    @State private var actions = MusicActions()
    #if os(macOS) || os(visionOS)
    @OpenWindowProxy private var openWindow
    #endif
    #if os(iOS)
    #if DEBUG
    @State private var showsVisualizer = MusicDebugLaunch.opensVisualizer
    #else
    @State private var showsVisualizer = false
    #endif
    #endif

    private enum Pane: String, CaseIterable, Identifiable {
        case upNext = "Up Next", lyrics = "Lyrics"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 20) {
            if let item = music.current {
                // The cover dissolves into the next one rather than swapping under the title.
                ZStack {
                    MusicArtwork(item: item, music: music)
                        .id(item.id)
                        .transition(.opacity)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 18)).shadow(radius: 22)
                .animation(.smooth(duration: 0.4), value: item.id)
                MusicTrackLabels(music: music, style: .nowPlaying)
                HStack(spacing: 28) {
                    let favorite = MusicUserState.shared.isFavorite(item)
                    Button { Task { await MusicUserState.shared.toggleFavorite(item) } } label: {
                        Image(systemName: favorite ? "heart.fill" : "heart").foregroundStyle(favorite ? .pink : .primary)
                    }
                    .accessibilityLabel(favorite ? "Remove from Favorites" : "Favorite")
                    MusicStarsMenu(item: item).labelStyle(.iconOnly)
                    Menu { MusicItemMenu(item: item) } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More")
                }
                .buttonStyle(.plain).font(.title3)
                VStack(spacing: 4) {
                    #if os(tvOS)
                    ProgressView(value: music.currentTime, total: max(1, music.duration))
                    #else
                    Slider(value: Binding(get: { music.currentTime }, set: { music.seek(to: $0) }), in: 0...max(1, music.duration))
                    #endif
                    HStack {
                        Text(JellyfinMusicItem.clock(music.currentTime)); Spacer()
                        Text("-\(JellyfinMusicItem.clock(max(0, music.duration - music.currentTime)))")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 34) {
                    Button { music.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(music.isShuffled ? Color.accentColor : .primary) }
                        .accessibilityLabel(music.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On")
                    Button { music.previous() } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Previous")
                    Button { music.toggle() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34)) }
                        .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
                    Button { music.next() } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("Next")
                    Button { music.toggleRepeat() } label: {
                        Image(systemName: music.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(music.repeats ? Color.accentColor : .primary)
                    }
                    .accessibilityLabel("Repeat")
                    .accessibilityValue(music.repeatMode == .off ? "Off" : music.repeatMode == .all ? "All" : "One")
                    Button { music.stop(); dismiss() } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop Playback")
                }.font(.title2).buttonStyle(.plain)
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                Group {
                    switch pane {
                    case .upNext: MusicUpNextList(music: music, actions: actions)
                    case .lyrics: MusicLyricsView(music: music)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .navigationTitle("Now Playing")
        // The library is dark whatever the system is; a sheet doesn't inherit that, so its own background would
        // be white behind white text.
        .preferredColorScheme(.dark)
        .musicActionHost(actions, bottomInset: 24)
        .musicNamesOpenLibrary(dismiss: { dismiss() })
        #if os(iOS)
        .fullScreenCover(isPresented: $showsVisualizer) {
            MusicVisualizerView(presentation: .cover, close: { showsVisualizer = false })
        }
        #endif
        .toolbar {
            #if os(macOS) || os(visionOS)
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: MusicMiniPlayerWindowView.windowID) } label: { Image(systemName: "pip.enter") }
                    .accessibilityLabel("Open Mini Player")
            }
            #endif
            #if !os(tvOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    #if os(iOS)
                    showsVisualizer = true
                    #else
                    MusicVisualizerView.open(using: openWindow)
                    #endif
                } label: { Image(systemName: "sparkles") }
                    .accessibilityLabel("Visualizer")
            }
            #endif
            ToolbarItem(placement: .primaryAction) { MusicAudioOptionsMenu(music: music) }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

/// The queue: tap to jump, drag (or the menu) to reorder, swipe to remove, and a menu to clear what is after
/// the playing song or keep the queue as a playlist.
struct MusicUpNextList: View {
    let music: JellyfinMusicSession
    /// Where "Save as Playlist" goes; nil hides it (the host has no playlist sheet).
    var actions: MusicActions?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                let remaining = max(0, music.queue.count - (music.currentIndex ?? -1) - 1)
                Text(remaining == 0 ? "Nothing Up Next" : "\(remaining) Up Next").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Clear Up Next", systemImage: "text.badge.minus", role: .destructive) { music.clearUpNext() }
                        .disabled(remaining == 0 && !music.hasRandomRefill)
                    if let actions {
                        Button("Save as Playlist…", systemImage: "text.badge.plus") { actions.saveQueueAsPlaylist() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Queue options")
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(music.queue.enumerated()), id: \.offset) { index, track in
                    let isCurrent = index == music.currentIndex
                    HStack {
                        VStack(alignment: .leading) {
                            Text(track.Name).foregroundStyle(isCurrent ? Color.accentColor : .primary).lineLimit(1)
                            MusicArtistLine(item: track).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isCurrent {
                            Image(systemName: music.isPlaying ? "waveform" : "pause.fill").foregroundStyle(Color.accentColor)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    // A tap plays the row; its artist is a link of its own, which a Button around it would swallow.
                    .contentShape(Rectangle())
                    .onTapGesture { music.jump(to: index) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(track.Name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Play") { music.jump(to: index) }
                    .id(index)
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { music.jump(to: index) }
                        if index > 0 { Button("Move Up", systemImage: "arrow.up") { music.moveInQueue(from: index, to: index - 1) } }
                        if index + 1 < music.queue.count { Button("Move Down", systemImage: "arrow.down") { music.moveInQueue(from: index, to: index + 1) } }
                        if !isCurrent { Button("Remove", systemImage: "minus.circle", role: .destructive) { music.removeFromQueue(at: index) } }
                        MusicGoToItems(item: track)
                    }
                }
                #if !os(tvOS)
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    music.moveInQueue(from: from, to: destination > from ? destination - 1 : destination)
                }
                .onDelete { offsets in offsets.sorted(by: >).forEach { music.removeFromQueue(at: $0) } }
                #endif
            }
            .listStyle(.plain)
            .onAppear { if let index = music.currentIndex { proxy.scrollTo(index, anchor: .center) } }
        }
    }
}

// MARK: - Lyrics

struct MusicLyricsView: View {
    let music: JellyfinMusicSession
    private enum Phase { case loading, none, loaded(MusicLyrics), failed(String) }
    @State private var phase = Phase.loading

    /// Which screen of the pane is showing, for the animation between them.
    private var phaseKey: Int {
        switch phase { case .loading: 0; case .none: 1; case .failed: 2; case .loaded: 3 }
    }

    var body: some View {
        Group {
            switch phase {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
            case .none:
                ContentUnavailableView("No Lyrics", systemImage: "quote.bubble",
                    description: Text("Jellyfin has no lyrics for this song. Put a .lrc file beside it, or add a lyrics plugin."))
                    .transition(.opacity)
            case .failed(let message):
                ContentUnavailableView("Lyrics Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                    .transition(.opacity)
            case .loaded(let lyrics): MusicLyricsLines(lyrics: lyrics, music: music).transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: phaseKey)
        .task(id: music.current?.id) {
            guard let id = music.current?.id else { return }
            phase = .loading
            guard let library = LibraryService.current() else { phase = .none; return }
            do {
                if let lyrics = try await library.musicLyrics(id: id) { phase = .loaded(lyrics) } else { phase = .none }
            } catch is CancellationError {
            } catch { phase = .failed(error.localizedDescription) }
        }
    }
}

private struct MusicLyricsLines: View {
    let lyrics: MusicLyrics
    let music: JellyfinMusicSession
    /// The playhead as of the last clock tick, so word highlighting can run between ticks.
    @State private var anchor = (time: 0.0, date: Date())

    private var activeIndex: Int? {
        guard lyrics.isSynced else { return nil }
        let time = music.currentTime + 0.25
        return lyrics.lines.lastIndex { ($0.start ?? .infinity) <= time }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lyrics.lines) { line in
                        let active = line.id == activeIndex
                        row(line, active: active)
                            .id(line.id)
                            .onTapGesture { if let start = line.start { music.seek(to: start) } }
                    }
                }
                .padding(.vertical, 24).padding(.horizontal, 8)
            }
            .onChange(of: activeIndex) { _, index in
                if let index { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(index, anchor: .center) } }
            }
        }
        .onChange(of: music.currentTime) { _, time in anchor = (time, Date()) }
    }

    @ViewBuilder
    private func row(_ line: MusicLyricLine, active: Bool) -> some View {
        if active, !line.cues.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let time = music.isPlaying ? anchor.time + context.date.timeIntervalSince(anchor.date) : anchor.time
                Text(Self.attributed(line, time: time)).font(.title3.bold())
            }
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(active ? .title3.bold() : .title3)
                .foregroundStyle(active || !lyrics.isSynced ? Color.primary : Color.secondary)
        }
    }

    /// The words already sung in the primary colour, the rest dimmed.
    private static func attributed(_ line: MusicLyricLine, time: Double) -> AttributedString {
        let characters = Array(line.text)
        var result = AttributedString()
        var cursor = 0
        func append(_ range: Range<Int>, sung: Bool) {
            let lower = max(0, min(range.lowerBound, characters.count)), upper = max(lower, min(range.upperBound, characters.count))
            guard lower < upper else { return }
            var piece = AttributedString(String(characters[lower..<upper]))
            piece.foregroundColor = sung ? .primary : .secondary
            result += piece
        }
        for cue in line.cues.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if cue.range.lowerBound > cursor { append(cursor..<cue.range.lowerBound, sung: true) }
            append(cue.range, sung: time >= cue.start)
            cursor = max(cursor, cue.range.upperBound)
        }
        append(cursor..<characters.count, sung: time >= (line.cues.last?.end ?? 0))
        return result
    }
}

// MARK: - Audio options and the mini player

struct MusicAudioOptionsMenu: View {
    let music: JellyfinMusicSession
    @Bindable private var eq = AudioEQ.shared
    @State private var showsEQEditor = false

    var body: some View {
        Menu {
            ForEach(JellyfinMusicAudioMode.allCases) { mode in
                Button {
                    music.setAudioMode(mode)
                } label: {
                    Label(mode.title, systemImage: music.audioMode == mode ? "checkmark" : mode.symbol)
                }
            }
            Divider()
            Toggle("Sound Check", systemImage: "speaker.wave.2", isOn: Binding(get: { music.soundCheck }, set: { music.setSoundCheck($0) }))
            Divider()
            Toggle("Equalizer", systemImage: "slider.vertical.3", isOn: Binding(get: { eq.settings.enabled }, set: { eq.setEnabled($0) }))
            Menu("Equalizer Preset") {
                ForEach(EQPreset.builtIns + eq.customPresets) { preset in
                    Toggle(preset.name, isOn: Binding(get: { eq.matches(preset) }, set: { _ in eq.apply(preset) }))
                }
            }
            #if !os(tvOS)
            Button { showsEQEditor = true } label: { Label("Edit Equalizer…", systemImage: "slider.horizontal.3") }
            #endif
            // Why the equalizer isn't shaping this song, when it isn't (a stream it couldn't read).
            if let note = AudioEQ.explanation(for: music.eqResult) { Text(note) }
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
        .onAppear { eq.reloadPresets() }
        #if !os(tvOS)
        .sheet(isPresented: $showsEQEditor, onDismiss: { eq.reloadPresets() }) { AudioEQEditorSheet() }
        #endif
    }
}

/// The library's compact mini player: RAVEUI's `RAVEMiniPlayerBar` around the music session's transport strip.
struct MusicMiniPlayerView: View {
    let current: JellyfinMusicItem
    let music: JellyfinMusicSession
    let onShowNowPlaying: () -> Void
    var width: CGFloat?

    var body: some View {
        RAVEMiniPlayerBar(accessibilityTitle: "Now Playing, \(current.Name), \(current.artist)", open: onShowNowPlaying) {
            MusicArtwork(item: current, music: music)
        } labels: {
            MusicTrackLabels(music: music, style: .bar)
        } controls: {
            MusicTransportStrip(music: music, width: width)
        }
        .allowsHitTesting(music.current != nil)
    }
}

/// The video player's transport strip, driving the music session: seek, previous, play/pause, next, and the
/// volume popover with Sound Check. The library's mini player and the Mini Player window share it.
struct MusicTransportStrip: View {
    let music: JellyfinMusicSession
    var width: CGFloat?

    var body: some View {
        RAVEPlayerControls(
            state: RAVEPlayerControlState(
                currentTime: music.currentTime,
                duration: music.duration,
                isPlaying: music.isPlaying,
                isMuted: music.isMuted,
                volume: music.volume
            ),
            togglePlayback: { music.toggle() },
            seek: { music.seek(to: $0) },
            toggleMute: { music.toggleMute() },
            layout: .strip,
            setVolume: { music.setVolume($0) },
            navigation: RAVEPlayerNavigation(
                previous: { music.previous() },
                next: { music.next() }
            ),
            pinned: AnyView(MusicMiniPlayerOptions(music: music)),
            volumeAccessory: AnyView(MusicSoundCheckControl(music: music))
        ) { EmptyView() }
        .frame(width: width)
    }
}

private struct MusicMiniPlayerOptions: View {
    let music: JellyfinMusicSession
    #if os(macOS) || os(visionOS)
    @OpenWindowProxy private var openWindow
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
        // An iPhone's bar is too narrow for the whole row beside the transport: one menu holds it.
        if sizeClass == .compact { compact } else { row }
        #else
        row
        #endif
    }

    private var row: some View {
        HStack(spacing: 16) {
            #if os(macOS) || os(visionOS)
            Button { openWindow(id: MusicMiniPlayerWindowView.windowID) } label: { Image(systemName: "pip.enter") }
                .accessibilityLabel("Open Mini Player")
            Button { MusicVisualizerView.open(using: openWindow) } label: { Image(systemName: "sparkles") }
                .accessibilityLabel("Visualizer")
            #endif
            Button { music.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(music.isShuffled ? Color.accentColor : .primary)
            }
            .accessibilityLabel(music.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On")
            MusicAudioOptionsMenu(music: music)
            Button { music.stop() } label: { Image(systemName: "stop.fill") }
                .accessibilityLabel("Stop Playback")
        }
    }

    #if os(iOS)
    private var compact: some View {
        Menu {
            Button(music.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On", systemImage: "shuffle") { music.toggleShuffle() }
            Picker("Audio", selection: Binding(get: { music.audioMode }, set: { music.setAudioMode($0) })) {
                ForEach(JellyfinMusicAudioMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Toggle("Sound Check", systemImage: "speaker.wave.2", isOn: Binding(get: { music.soundCheck }, set: { music.setSoundCheck($0) }))
            Button("Stop", systemImage: "stop.fill", role: .destructive) { music.stop() }
        } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Player options")
    }
    #endif
}

/// Sound Check, with what the server measured for the playing song, so a library without loudness data says so.
struct MusicSoundCheckControl: View {
    let music: JellyfinMusicSession

    private var caption: String {
        guard music.soundCheck else { return "Even out song volume with Jellyfin's loudness scan." }
        guard music.current != nil else { return "Applies to the next song." }
        guard let gain = music.currentGainDB else {
            return "No loudness data for this song. Turn on the library's loudness scan and run Audio Normalization in Jellyfin."
        }
        let text = "This song: \(String(format: "%+.1f", gain)) dB"
        return gain > 0 ? text + ". A quiet song stays as it is." : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Sound Check", isOn: Binding(get: { music.soundCheck }, set: { music.setSoundCheck($0) }))
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 240, alignment: .leading)
    }
}

/// A cover. It comes from `MusicArtworkStore`, so one already seen is there on the first frame, and one that is
/// not fades in over the placeholder when it arrives.
struct MusicArtwork: View {
    let item: JellyfinMusicItem
    let music: JellyfinMusicSession
    /// Pixels wide to ask the server for; the mini player window is big enough to want more than a grid tile.
    var maxWidth = 360
    @State private var image: MusicImage?

    init(item: JellyfinMusicItem, music: JellyfinMusicSession, maxWidth: Int = 360) {
        self.item = item
        self.music = music
        self.maxWidth = maxWidth
        let url = music.artworkURL(for: item, maxWidth: maxWidth)
        _image = State(initialValue: url.flatMap { MusicArtworkStore.shared.cachedImage(for: $0) })
    }

    private var url: URL? { music.artworkURL(for: item, maxWidth: maxWidth) }

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            fallback
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = MusicArtworkStore.shared.cachedImage(for: url) { image = cached; return }
            // Another item on a reused view must not keep showing the last one's cover while this one loads.
            image = nil
            let loaded = await MusicArtworkStore.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.28)) { image = loaded }
        }
    }

    private var fallback: some View {
        Image(systemName: item.Type == "MusicArtist" ? "music.mic" : item.Type == "MusicGenre" ? "guitars" : item.Type == "Playlist" ? "music.note.list" : "music.note")
            .font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
