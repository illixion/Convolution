/*
 Hypnos - film player window

 The film's picture with its Atmos objects as spatial sources around it
 (RAVEFilm's `FilmVideoView` and `FilmStageView`, driven by one
 `FilmPlayer`). On visionOS it is its own window: the sound stage is
 anchored to the window, so the screen is the front wall of the room
 wherever the window goes, and the transport sits in an ornament with
 tuning left in Settings. On iOS the same window id opens it as a tool
 sheet (`IOSWindowRouter`), with AirPods head tracking and tuning below the
 picture.

 tvOS: the objects play through RAVEFilm's `FilmPhaseStageView` (PHASE)
 rather than RealityKit's stage, because PHASE is what the system gives
 AirPods head tracking and the listener's personalized spatial audio
 profile to (the app is signed with the head-pose and profile-access
 entitlements). It renders binaural, which is right for AirPods and, as
 heard on a HomePod mini stereo pair, for HomePods too. The listener faces
 the TV; the Sound panel off the transport sets the room, reverb, bass,
 head tracking and the picture's offset, saved between launches. Recenter
 (transport and Sound panel) makes the way the wearer faces the front, and
 the stage recentres by itself whenever playback resumes. The objects
 button overlays RAVEFilm's `FilmObjectMapPanel` (top and front views,
 overhead count). iOS's AirPods
 tracker recentres on resume the same way.
 */

import RAVEFilm
import simd
import SwiftUI

struct FilmPlayerView: View {
    static let windowID = "film-player"

    @Bindable private var session = FilmSession.shared
    private var player: FilmPlayer { session.player }
    #if os(tvOS) || os(iOS)
    @State private var nowPlaying: FilmNowPlaying?
    #endif

    var body: some View {
        content
            .onAppear {
                session.isPlayerOpen = true
                #if os(tvOS) || os(iOS)
                // Claim Now Playing so the remote's and AirPods' play/pause
                // reach this player (see RAVEFilm's FilmNowPlaying).
                AudioSessionConfig.configureFilmPlayback()
                let nowPlaying = FilmNowPlaying(player: player, title: session.loadedItem?.name ?? "Film")
                nowPlaying.activate()
                self.nowPlaying = nowPlaying
                #endif
            }
            .onDisappear {
                player.pause()
                session.isPlayerOpen = false
                session.saveSound()
                #if os(tvOS) || os(iOS)
                nowPlaying?.deactivate()
                nowPlaying = nil
                AudioSessionConfig.configureMixedPlayback()
                #endif
            }
            #if os(tvOS) || os(iOS)
            .onChange(of: session.loadedItem?.name) { _, name in
                if let name { nowPlaying?.setTitle(name) }
            }
            #endif
            // Library-feature progress sync for the Atmos/FilmPlayer route —
            // a no-op unless the item currently loaded came from the Library
            // tab (i.e. `session.loadedItem`'s id is a real Jellyfin item;
            // `FilmPlayer`'s own `currentTime`/`duration`/`isPlaying` are
            // plain `@Observable` properties with no publisher, so this
            // polls rather than subscribes — see `LibraryPlaybackCoordinator`'s
            // header comment for the equivalent generic-player version).
            .task(id: session.loadedItem?.id) {
                await reportFilmPlaybackProgress()
            }
    }

    private func reportFilmPlaybackProgress() async {
        guard let itemId = session.loadedItem?.id, let library = LibraryService.current() else { return }
        var started = false
        var lastPosition: Double = 0
        defer {
            if started {
                Task { await library.reportPlaybackStopped(itemId: itemId, positionSeconds: lastPosition) }
            }
        }
        while !Task.isCancelled {
            let position = player.currentTime
            if !started, position > 0 {
                started = true
                await library.reportPlaybackStarted(itemId: itemId, positionSeconds: position)
            } else if started {
                await library.reportPlaybackProgress(itemId: itemId, positionSeconds: position, isPaused: !player.isPlaying)
            }
            lastPosition = position
            try? await Task.sleep(for: .seconds(10))
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(visionOS)
        ZStack {
            FilmVideoView(player: player.video)
                // Draws nothing; it places the sound sources around the window.
                // A RealityView takes the window's whole depth by default, and a
                // ZStack then parks its 2D siblings at the front of that depth,
                // ~15cm proud of the glass (the pseudo-3D player hit the same
                // thing). Flattened behind the picture, the stage adds no depth
                // and its origin is the glass itself, where the room is measured
                // from.
                .background {
                    FilmStageView(player: player, listenerDistance: session.listenerDistance)
                        .frame(depth: 0)
                }
            if session.showMap {
                FilmObjectMapPanel(player: player)
                    .frame(width: 520)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            FilmTransport(player: player)
                .padding()
                .frame(width: 640)
                .glassBackgroundEffect()
        }
        #elseif os(tvOS)
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            FilmVideoView(player: player.video)
                .background {
                    FilmPhaseStageView(player: player, headTracking: session.headTracking,
                                       recenterRequest: session.recenterRequest)
                }
            if session.showMap {
                FilmObjectMapPanel(player: player)
                    .frame(width: 760)
                    .padding(60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            TVFilmTransport(player: player)
                .padding(.bottom, 40)
        }
        .onPlayPauseCommand {
            player.isPlaying ? player.pause() : player.play()
        }
        #elseif os(iOS)
        Form {
            Section(session.loadedItem?.name ?? "") {
                ZStack {
                    FilmStageView(player: player) { HeadphoneHeadTracker.shared.orientation }
                    FilmVideoView(player: player.video)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .listRowInsets(EdgeInsets())
                FilmTransport(player: player)
            }
            Section("Head Tracking") { FilmHeadTrackingRow() }
            Section("Objects") {
                FilmObjectMapPanel(player: player)
            }
            Section("Tuning") { FilmTuning() }
            Section("Telemetry") { FilmTelemetry(player: player) }
        }
        .onAppear { HeadphoneHeadTracker.shared.start() }
        .onDisappear { HeadphoneHeadTracker.shared.stop() }
        // Someone who paused and turned away comes back facing the picture.
        .onChange(of: player.isPlaying) { _, playing in
            if playing { HeadphoneHeadTracker.shared.recenter() }
        }
        #else
        // macOS: picture plus Atmos object audio, same as iOS, but without
        // AirPods head tracking (`HeadphoneHeadTracker` is iOS-only — there's
        // no Mac equivalent API). `FilmStageView`'s `listenerOrientation`
        // defaults to identity, which is exactly "no tracking": the sound
        // stage stays fixed relative to the picture instead of turning with
        // the listener's head. RAVEFilm's `FilmStageView` already documents
        // itself as supporting this ("iOS and macOS: a virtual camera").
        Form {
            Section(session.loadedItem?.name ?? "") {
                ZStack {
                    FilmStageView(player: player)
                    FilmVideoView(player: player.video)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .listRowInsets(EdgeInsets())
                FilmTransport(player: player)
            }
            Section("Objects") {
                FilmObjectMapPanel(player: player)
            }
            Section("Tuning") { FilmTuning() }
            Section("Telemetry") { FilmTelemetry(player: player) }
        }
        #endif
    }
}

#if os(tvOS)
/// tvOS film transport: play/pause plus ±10s, all plain focusable buttons —
/// there's no drag surface for a scrub bar, and Siri Remote's play/pause
/// button is wired separately via `.onPlayPauseCommand` on the container.
struct TVFilmTransport: View {
    let player: FilmPlayer
    @Bindable private var session = FilmSession.shared
    @State private var showsSound = false

    var body: some View {
        HStack(spacing: 24) {
            Button { player.seek(to: player.currentTime - 10) } label: {
                Label("−10s", systemImage: "gobackward.10")
            }
            Button {
                player.isPlaying ? player.pause() : player.play()
            } label: {
                Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { player.seek(to: player.currentTime + 10) } label: {
                Label("+10s", systemImage: "goforward.10")
            }
            if player.audio != nil {
                if session.headTracking {
                    Button { session.recenterRequest += 1 } label: {
                        Label("Recenter", systemImage: "scope")
                    }
                }
                Button { showsSound = true } label: {
                    Label("Sound", systemImage: "speaker.wave.2")
                }
                Button { session.showMap.toggle() } label: {
                    Label(session.showMap ? "Hide Objects" : "Show Objects", systemImage: "circle.grid.cross")
                }
            }
        }
        .labelStyle(.iconOnly)
        .padding(24)
        .background(.ultraThinMaterial, in: Capsule())
        .sheet(isPresented: $showsSound) { TVFilmSoundSettings() }
    }
}

/// The object audio's tuning with the remote: pickers and steps instead of
/// the other platforms' sliders. Every change applies live and is saved.
struct TVFilmSoundSettings: View {
    @Bindable private var session = FilmSession.shared

    /// Room dimensions (half-width, half-depth, ceiling above the ears).
    private enum RoomSize: String, CaseIterable, Identifiable {
        case small = "Small", medium = "Medium", large = "Large"
        var id: String { rawValue }
        var dimensions: SIMD3<Float> {
            switch self {
            case .small: SIMD3(1.5, 1.8, 1.2)
            case .medium: SIMD3(2.0, 2.5, 1.6)
            case .large: SIMD3(3.0, 3.5, 2.2)
            }
        }
    }

    private static let reverbLevels: [(title: String, db: Float)] = [
        ("Off", -40), ("Low", -24), ("Medium", -12), ("High", -6), ("Very High", -2),
    ]
    private static let bassLevels: [Float] = [-12, -6, -3, 0, 3, 6]

    var body: some View {
        @Bindable var player = session.player
        NavigationStack {
            Form {
                Section {
                    Picker("Room", selection: $player.reverbPreset) {
                        ForEach(RAVEReverbPreset.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Reverb", selection: $player.reverbDB) {
                        ForEach(Self.reverbLevels, id: \.db) { Text($0.title).tag($0.db) }
                        if !Self.reverbLevels.contains(where: { $0.db == player.reverbDB }) {
                            Text(String(format: "%.0f dB", player.reverbDB)).tag(player.reverbDB)
                        }
                    }
                    Picker("Room Size", selection: roomSize) {
                        ForEach(RoomSize.allCases) { Text($0.rawValue).tag(Optional($0)) }
                        if roomSize.wrappedValue == nil { Text("Custom").tag(RoomSize?.none) }
                    }
                } footer: {
                    Text("The room the film's sound plays in: its reverb and how far away its speakers seem.")
                }
                Section {
                    Picker("Bass", selection: $player.lfeGainDB) {
                        ForEach(Self.bassLevels, id: \.self) { Text(String(format: "%+.0f dB", $0)).tag($0) }
                        if !Self.bassLevels.contains(player.lfeGainDB) {
                            Text(String(format: "%+.0f dB", player.lfeGainDB)).tag(player.lfeGainDB)
                        }
                    }
                    Toggle("Head Tracking", isOn: $session.headTracking)
                    Button("Recenter") { session.recenterRequest += 1 }
                        .disabled(!session.headTracking)
                } footer: {
                    Text("Head tracking keeps the sound at the TV as you turn your head, on AirPods that support it. Recenter while facing the TV if the sound drifts to one side; it also recentres whenever you resume playback.")
                }
                Section {
                    LabeledContent("Picture Offset", value: String(format: "%+.0f ms", player.avOffsetMs))
                    HStack {
                        Button("Earlier") { player.avOffsetMs -= 10 }
                        Button("Later") { player.avOffsetMs += 10 }
                        Button("Reset") { player.avOffsetMs = 0 }
                    }
                } footer: {
                    Text("Moves the picture against the sound if speech looks out of step.")
                }
            }
            .navigationTitle("Sound")
        }
        .onChange(of: player.reverbPreset) { session.saveSound() }
        .onChange(of: player.reverbDB) { session.saveSound() }
        .onChange(of: player.lfeGainDB) { session.saveSound() }
        .onChange(of: player.avOffsetMs) { session.saveSound() }
        .onChange(of: session.headTracking) { session.saveSound() }
    }

    private var roomSize: Binding<RoomSize?> {
        let player = session.player
        return Binding {
            let current = SIMD3(player.roomHalfWidth, player.roomHalfDepth, player.roomHeight)
            return RoomSize.allCases.first { simd_length($0.dimensions - current) < 0.01 }
        } set: { size in
            guard let size else { return }
            player.roomHalfWidth = size.dimensions.x
            player.roomHalfDepth = size.dimensions.y
            player.roomHeight = size.dimensions.z
            session.saveSound()
        }
    }
}
#endif

struct FilmTransport: View {
    let player: FilmPlayer
    /// Scrubber position while dragging; nil follows playback.
    @State private var scrubSeconds: Double?
    @State private var now = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    player.isPlaying ? player.pause() : player.play()
                } label: {
                    Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { player.seek(to: player.currentTime - 10) } label: {
                    Label("−10s", systemImage: "gobackward.10")
                }
                Button { player.seek(to: player.currentTime + 10) } label: {
                    Label("+10s", systemImage: "goforward.10")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            #if !os(tvOS)
            // Seeks on release, so a drag across a film is one seek, not hundreds.
            // tvOS has no drag surface for this — the ±10s buttons above are
            // its only seek control (this view isn't used by the tvOS film
            // player anyway; see TVFilmPlayerView).
            Slider(
                value: Binding(get: { scrubSeconds ?? now }, set: { scrubSeconds = $0 }),
                in: 0 ... max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubSeconds {
                        player.seek(to: target)
                        scrubSeconds = nil
                    }
                }
            )
            #endif
            Text("\(Self.clock(scrubSeconds ?? now)) / \(Self.clock(player.duration))")
                .font(.caption.monospaced())
        }
        .task {
            // The timebase isn't observable; sample it for the scrubber.
            while !Task.isCancelled {
                now = player.currentTime
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

struct FilmTuning: View {
    @Bindable private var session = FilmSession.shared

    var body: some View {
        @Bindable var player = session.player
        Group {
            slider("Master", value: $player.masterGainDB, in: -24 ... 12, unit: "dB")
            slider("LFE", value: $player.lfeGainDB, in: -24 ... 10, unit: "dB")
            slider("Reverb", value: $player.reverbDB, in: -40 ... 0, unit: "dB")
            slider("Room half-width", value: $player.roomHalfWidth, in: 0.5 ... 5, unit: "m")
            slider("Room half-depth", value: $player.roomHalfDepth, in: 0.5 ... 5, unit: "m")
            slider("Ceiling above ears", value: $player.roomHeight, in: 0 ... 3, unit: "m")
            #if os(visionOS)
            slider("You, in front of the window", value: $session.listenerDistance, in: 0.3 ... 4, unit: "m")
            Toggle("Show object map", isOn: $session.showMap)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Picture offset: %+.0f ms", player.avOffsetMs)).font(.caption)
                #if !os(tvOS)
                Slider(value: $player.avOffsetMs, in: -300 ... 300, step: 10)
                #endif
            }
            Toggle("Flatten heights (A/B vs no height)", isOn: $player.flattenHeights)
        }
    }

    // Not reachable on tvOS — this view is only built from the visionOS
    // ornament section and the iOS Form tool sheet, never the tvOS film
    // player (see TVFilmPlayerView) — but `Slider` still has to typecheck
    // for a tvOS build of the module.
    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(String(format: "%.1f", value.wrappedValue)) \(unit)").font(.caption)
            #if !os(tvOS)
            Slider(value: value, in: range)
            #endif
        }
    }
}

#if os(iOS)
/// Status, Recenter and latency prediction for the AirPods head tracking.
struct FilmHeadTrackingRow: View {
    @Bindable private var tracker = HeadphoneHeadTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tracker.status)
                    Text(String(format: "yaw %+.0f°  pitch %+.0f°", tracker.yawDegrees, tracker.pitchDegrees))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Recenter") { tracker.recenter() }
                    .buttonStyle(.bordered)
                    .disabled(!tracker.isTracking)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Prediction: \(Int(tracker.predictionMs)) ms (route reports \(Int(tracker.reportedLatencyMs)) ms)")
                    .font(.caption)
                HStack {
                    Slider(value: $tracker.predictionMs, in: 0 ... 400, step: 10)
                    Button("Default") { tracker.useReportedLatency() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}
#endif

struct FilmTelemetry: View {
    let player: FilmPlayer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                Text(player.video.formatSummary)
                Text(String(format: "Video: %@ · segment %d · last seek %.0f ms",
                            player.video.status, player.video.currentSegment, player.video.lastSeekLatency * 1000))
                Text("Audio: \(player.audioStatus) · \(player.clockReport)")
                Text(String(format: "Output latency %.0f ms · skew %@", player.outputLatency * 1000,
                            player.scheduledSkewMs.map { String(format: "%+.0f ms", $0) } ?? "—"))
            }
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
            .selectableText()
        }
    }
}
