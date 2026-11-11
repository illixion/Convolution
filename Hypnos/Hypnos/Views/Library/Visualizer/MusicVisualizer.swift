/*
 Hypnos - Music visualizer.

 iTunes's Visualizer: a full-window view that plays along with the music. Where it opens depends on the
 device. iOS covers the screen with it (`fullScreenCover`), a Mac gets a window of its own (it can go full
 screen), and Vision Pro gets a flat window and a volumetric one, the same covers in real depth.

 It is built to take more effects. `MusicVisualizerEffect` is the list; the window, its controls, the picker and
 the saved choice treat it as a list already, so a new effect is one more case and one more branch in
 `MusicVisualizerEffectView`. Album Art (Cover Flow of the current queue) is the first.
 */

#if !os(tvOS)

import SwiftUI

// MARK: - Effects

enum MusicVisualizerEffect: String, CaseIterable, Identifiable {
    /// The albums of the queue as Cover Flow.
    case albumArt

    var id: Self { self }

    var title: String {
        switch self {
        case .albumArt: "Album Art"
        }
    }

    var symbol: String {
        switch self {
        case .albumArt: "square.stack.3d.down.right"
        }
    }

    private static let key = "jellyfinMusic.visualizer.effect"

    static var saved: MusicVisualizerEffect {
        HypnosDefaults.store.string(forKey: key).flatMap(MusicVisualizerEffect.init(rawValue:)) ?? .albumArt
    }

    func save() { HypnosDefaults.store.set(rawValue, forKey: Self.key) }
}

/// What an effect is given to draw. Everything is of the playing queue; an effect keeps no state a window closing
/// could lose.
struct MusicVisualizerContext {
    let music: JellyfinMusicSession
    let entries: [MusicCoverFlowEntry]
    /// Which entry is playing.
    let current: Int?
    /// Which entry the effect has brought to the front (a listener can wander off the playing one).
    let focus: Binding<Int>
    /// Drawn in real depth, in a volumetric window.
    let spatial: Bool
}

/// The picture for an effect.
struct MusicVisualizerEffectView: View {
    let effect: MusicVisualizerEffect
    let context: MusicVisualizerContext

    var body: some View {
        switch effect {
        case .albumArt:
            #if os(visionOS)
            if context.spatial {
                CoverFlowSpatialView(music: context.music, entries: context.entries, current: context.current, focus: context.focus)
            } else {
                CoverFlowView(music: context.music, entries: context.entries, current: context.current, focus: context.focus)
            }
            #else
            CoverFlowView(music: context.music, entries: context.entries, current: context.current, focus: context.focus)
            #endif
        }
    }
}

// MARK: - The screen

struct MusicVisualizerView: View {
    enum Presentation {
        /// Covering the screen (iOS): has a Done button.
        case cover
        /// A window of its own (macOS, visionOS): the window has its own way to close.
        case window
        /// A volumetric window (visionOS): the effect in depth, controls on an ornament-like bar.
        case volume
    }

    static let windowID = HypnosSceneID.id("music-visualizer")
    static let volumeID = HypnosSceneID.id("music-visualizer-volume")

    #if os(macOS) || os(visionOS)
    /// Open the visualizer where this device keeps it: a window, or on Vision Pro the form it was last left in.
    static func open(using openWindow: WindowOpenAction) {
        #if os(visionOS)
        openWindow(id: HypnosDefaults.store.bool(forKey: "jellyfinMusic.visualizer.volume") ? volumeID : windowID)
        #else
        openWindow(id: windowID)
        #endif
    }
    #endif

    let presentation: Presentation
    var close: () -> Void = {}

    @State private var music = JellyfinMusicSession.shared
    @State private var effect = MusicVisualizerEffect.saved
    @State private var focus = 0
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS) || os(visionOS)
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow
    #endif

    private var entries: [MusicCoverFlowEntry] { MusicCoverFlowEntry.entries(from: music.queue) }

    var body: some View {
        let entries = entries
        let current = MusicCoverFlowEntry.index(of: music.currentIndex, in: entries)
        ZStack {
            if presentation != .volume { background }
            if music.current != nil, !entries.isEmpty {
                MusicVisualizerEffectView(effect: effect, context: MusicVisualizerContext(
                    music: music, entries: entries, current: current, focus: $focus, spatial: presentation == .volume))
                    .transition(.opacity)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note", description: Text("Play a song and its album art appears here."))
                    .foregroundStyle(.white.opacity(0.8))
                    .transition(.opacity)
            }
            chrome(entries: entries, current: current)
        }
        .animation(.smooth(duration: 0.4), value: music.current == nil)
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { revealChrome() })
        #if os(macOS)
        .onContinuousHover { phase in if case .active = phase { revealChrome() } }
        #endif
        .musicNamesOpenLibrary(dismiss: presentation == .cover ? close : nil, reveal: revealLibrary)
        .onAppear { revealChrome() }
        .onChange(of: music.isPlaying) { _, playing in if !playing { chromeVisible = true } }
        .onDisappear { hideTask?.cancel() }
    }

    @ViewBuilder
    private var background: some View {
        #if os(visionOS)
        // The window's own glass: the room shows through and the cards stand in it.
        Color.clear.glassBackgroundEffect(in: .rect(cornerRadius: 32))
        #else
        ZStack {
            Color.black
            RadialGradient(colors: [Color(white: 0.16), .black], center: .init(x: 0.5, y: 0.4), startRadius: 20, endRadius: 700)
        }
        .ignoresSafeArea()
        #endif
    }

    // MARK: Controls

    /// The controls fade out after a few seconds so the cards have the room, and come back on a tap or a move.
    private func chrome(entries: [MusicCoverFlowEntry], current: Int?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if presentation == .cover {
                    Button("Done", action: close).buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                effectPicker
                #if os(visionOS)
                spatialToggle
                #endif
            }
            .padding(.horizontal, 20).padding(.top, presentation == .cover ? 8 : 16)
            Spacer(minLength: 0)
            if music.current != nil {
                MusicVisualizerTransport(music: music)
                    .padding(.horizontal, 20).padding(.bottom, presentation == .volume ? 28 : 18)
            }
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .animation(.easeInOut(duration: 0.3), value: chromeVisible)
    }

    private var effectPicker: some View {
        Menu {
            Picker("Visualizer", selection: Binding(get: { effect }, set: { effect = $0; $0.save() })) {
                ForEach(MusicVisualizerEffect.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
        } label: {
            Label(effect.title, systemImage: effect.symbol)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .accessibilityLabel("Visualizer effect: \(effect.title)")
    }

    #if os(visionOS)
    /// Between the flat window and the volume: the same covers, on glass or standing in the room.
    private var spatialToggle: some View {
        Button {
            let toVolume = presentation != .volume
            HypnosDefaults.store.set(toVolume, forKey: "jellyfinMusic.visualizer.volume")
            openWindow(id: toVolume ? Self.volumeID : Self.windowID)
            dismissWindow(id: toVolume ? Self.windowID : Self.volumeID)
        } label: {
            Label(presentation == .volume ? "Flat" : "3D", systemImage: presentation == .volume ? "rectangle" : "cube")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(presentation == .volume ? "Show flat" : "Show in 3D")
    }
    #endif

    private func revealChrome() {
        chromeVisible = true
        hideTask?.cancel()
        #if DEBUG
        if MusicDebugLaunch.keepsChromeUp { return }
        #endif
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled, music.isPlaying else { return }
            chromeVisible = false
        }
    }

    private func revealLibrary() {
        #if os(macOS) || os(visionOS)
        MusicNavigator.shared.revealLibrary(openWindow: openWindow)
        #endif
    }
}

// MARK: - The transport

/// The bar under the cards: previous, play or pause, next, the song (flick it to skip), the queue and the volume.
private struct MusicVisualizerTransport: View {
    let music: JellyfinMusicSession
    @State private var showsQueue = false
    @State private var showsVolume = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showsSong: true)
            bar(showsSong: false)
        }
        .padding(.horizontal, 26).padding(.vertical, 12)
        .background { capsule }
    }

    private func bar(showsSong: Bool) -> some View {
        HStack(spacing: 22) {
            Button { music.previous() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button { music.toggle() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
            Button { music.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
            if showsSong { song }
            Button { showsQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel("Up Next")
                .popover(isPresented: $showsQueue) { MusicUpNextList(music: music).frame(width: 340, height: 420) }
            Button { showsVolume.toggle() } label: { Image(systemName: music.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                .accessibilityLabel("Volume")
                .popover(isPresented: $showsVolume) { volume }
        }
        .buttonStyle(.plain)
        .font(.title2)
    }

    /// The song, its artist and its progress, in one pill: the title block flicks to the next or previous song.
    private var song: some View {
        HStack(spacing: 10) {
            if let current = music.current {
                MusicArtwork(item: current, music: music)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 5) {
                MusicTrackLabels(music: music, style: .bar)
                MusicProgressLine(music: music)
            }
        }
        .padding(8)
        .frame(width: 320)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { music.volume }, set: { music.setVolume($0) }), in: 0...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            Toggle("Mute", isOn: Binding(get: { music.isMuted }, set: { _ in music.toggleMute() }))
            Divider()
            MusicSoundCheckControl(music: music)
        }
        .padding(18)
        .frame(width: 290)
    }

    @ViewBuilder
    private var capsule: some View {
        #if os(visionOS)
        Color.clear.glassBackgroundEffect(in: Capsule())
        #else
        Capsule().fill(.regularMaterial)
        #endif
    }
}

/// How far into the song, as a thin line. The only thing here that reads the clock, so only it redraws each second.
private struct MusicProgressLine: View {
    let music: JellyfinMusicSession

    var body: some View {
        let fraction = CGFloat(min(1, max(0, music.currentTime / max(1, music.duration))))
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.9)).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 1), value: fraction)
        .accessibilityHidden(true)
    }
}

#endif
