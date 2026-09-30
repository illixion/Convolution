/*
 Hypnos - film player window

 The film picture and Atmos object audio keep one RAVEFilm clock. Its
 transport uses RAVEUI's RAVEPlayerControls, just like general videos and
 Raven's converted browser video. Sound tuning uses a separate window on visionOS
 and a sheet elsewhere. Mute leaves saved gain levels intact.

 visionOS uses a bottom-front ornament and offers realtime 3D. A compressed
 sample tap feeds RAVEMedia's clocked SampleBufferFrameSource; the original
 picture renderer stays primed while only its visible surface changes.
 Atmos transport, seeking and progress reporting stay with FilmPlayer.

 iOS/macOS use the AirPods tracker for the listener; Recenter is beside the
 transport when tracking is active. tvOS keeps its PHASE stage and focusable
 controls. Head tracking recentres on resume on all three platforms.
 */

import RAVEFilm
import RAVEMedia
import RAVEUI
import simd
import SwiftUI

struct FilmPlayerView: View {
    static let windowID = "film-player"

    @Bindable private var session = FilmSession.shared
    private var player: FilmPlayer { session.player }
    #if os(tvOS) || os(iOS)
    @State private var nowPlaying: FilmNowPlaying?
    #endif

    #if os(visionOS)
    @Environment(AppModel.self) private var appModel
    @State private var stereoSource: SampleBufferFrameSource?
    @State private var mountedDepthModelName: String?
    @State private var showsDepthSetup = false
    @State private var chromeOpen = false
    @State private var stereoFailure: String?
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
                #if os(visionOS)
                stopStereo()
                #endif
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
            #if os(visionOS)
            .sheet(isPresented: $showsDepthSetup) {
                DepthModelSetupSheet(onModelReady: { startStereo() })
            }
            .alert("3D unavailable", isPresented: Binding(
                get: { stereoFailure != nil }, set: { if !$0 { stereoFailure = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(stereoFailure ?? "") }
            .onChange(of: session.loadedItem?.id) { _, _ in stopStereo() }
            .onChange(of: appModel.realtimeDepthModelName) { _, name in
                if stereoSource != nil, mountedDepthModelName != name {
                    stopStereo()
                    startStereo()
                }
            }
            .task(id: stereoSource.map(ObjectIdentifier.init)) {
                guard let source = stereoSource else { return }
                while !Task.isCancelled {
                    if source.decodeFailure != nil {
                        stopStereo()
                        stereoFailure = "This video's picture could not be converted. Playback continues in 2D."
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
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
                .padding(.bottom, 180)
                .opacity(stereoSource == nil ? 1 : 0)
                // The audio stage contributes no window depth. It remains
                // mounted when only the picture changes to stereo.
                .background {
                    FilmStageView(player: player, listenerDistance: session.listenerDistance)
                        .frame(depth: 0)
                }
            if let source = stereoSource {
                RAVEExternalStereoVideoView(
                    source: source, settings: session.stereoSettings, chromeOpen: chromeOpen,
                    onUnavailable: {
                        guard stereoSource === source else { return }
                        stopStereo()
                        stereoFailure = "The 3D renderer is unavailable. Playback continues in 2D."
                    }
                )
                // Keep the picture out of the ornament's footprint. The same
                // measured separation keeps Hypnos/Raven controls reachable.
                .padding(.bottom, 180)
            }
        }
        .ornament(attachmentAnchor: .scene(.bottomFront)) {
            FilmTransport(player: player, stereoEnabled: stereoSource != nil,
                          onToggle3D: { stereoSource == nil ? startStereo() : stopStereo() },
                          onModalChanged: { chromeOpen = $0 })
                .frame(width: 640)
                .padding(.bottom, 80)
        }
        #elseif os(tvOS)
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            FilmVideoView(player: player.video)
                .background {
                    FilmPhaseStageView(player: player, headTracking: session.headTracking,
                                       recenterRequest: session.recenterRequest)
                }
            FilmTransport(player: player).frame(width: 820).padding(.bottom, 40)
        }
        .onPlayPauseCommand { player.isPlaying ? player.pause() : player.play() }
        #else
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            FilmVideoView(player: player.video)
                .background {
                    FilmStageView(player: player) { HeadphoneHeadTracker.shared.orientation }
                }
            FilmTransport(player: player).padding(16)
        }
        .onAppear { if session.headTracking { HeadphoneHeadTracker.shared.start() } }
        .onDisappear { HeadphoneHeadTracker.shared.stop() }
        .onChange(of: session.headTracking) { _, enabled in
            if enabled { HeadphoneHeadTracker.shared.start() }
            else { HeadphoneHeadTracker.shared.stop() }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { HeadphoneHeadTracker.shared.recenter() }
        }
        #endif
    }

    #if os(visionOS)
    private func startStereo() {
        guard stereoSource == nil else { return }
        guard CoreMLDepthProvider.hasAvailableModel(role: .realtime) else {
            showsDepthSetup = true
            return
        }
        let source = SampleBufferFrameSource(timebase: player.video.timebase)
        player.video.onSampleBuffer = { source.submit($0) }
        player.video.onFlush = { source.reset() }
        mountedDepthModelName = appModel.realtimeDepthModelName
        stereoSource = source
        session.stereoEnabled = true
        // Re-prime from the keyframe containing the current position. The film
        // transport keeps its play/pause intent and re-anchors Atmos with it.
        player.seek(to: player.currentTime)
    }

    private func stopStereo() {
        player.video.onSampleBuffer = nil
        player.video.onFlush = nil
        stereoSource = nil
        session.stereoEnabled = false
        mountedDepthModelName = nil
    }
    #endif
}

#if os(tvOS)
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
                Section("Objects") { FilmObjectMapPanel(player: player) }
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

/// The FilmPlayer adapter for the same controls used by general videos and
/// Raven. It samples the timebase; a scrub preview lives in the SDK controls.
struct FilmTransport: View {
    let player: FilmPlayer
    var stereoEnabled = false
    var onToggle3D: (() -> Void)?
    var onModalChanged: (Bool) -> Void = { _ in }
    @Bindable private var session = FilmSession.shared
    @State private var now = 0.0
    @State private var showsSound = false
    #if os(visionOS)
    @OpenWindowProxy private var openWindow
    #endif

    var body: some View {
        RAVEPlayerControls(
            state: RAVEPlayerControlState(currentTime: now, duration: player.duration,
                bufferedUntil: player.video.bufferedUntil, isPlaying: player.isPlaying, isMuted: player.isMuted),
            togglePlayback: { player.isPlaying ? player.pause() : player.play() },
            seek: { player.seek(to: $0) }, toggleMute: { player.isMuted.toggle() }
        ) {
            if let onToggle3D {
                Button(action: onToggle3D) {
                    Label(stereoEnabled ? "Play as 2D" : "Convert to 3D", systemImage: stereoEnabled ? "rectangle" : "view.3d")
                        .labelStyle(.iconOnly).ravePlayerControlLabel()
                }
                .help(stereoEnabled ? "Play as 2D" : "Convert to 3D")
            }
            #if os(iOS) || os(macOS)
            if session.headTracking, HeadphoneHeadTracker.shared.isTracking {
                Button { HeadphoneHeadTracker.shared.recenter() } label: {
                    Label("Recenter Audio", systemImage: "scope").labelStyle(.iconOnly).ravePlayerControlLabel()
                }
                .help("Recenter audio while facing the picture")
            }
            #elseif os(tvOS)
            if session.headTracking, player.audio != nil {
                Button { session.recenterRequest += 1 } label: {
                    Label("Recenter Audio", systemImage: "scope").labelStyle(.iconOnly).ravePlayerControlLabel()
                }
            }
            #endif
            Button {
                #if os(visionOS)
                openWindow(id: FilmAdjustmentsView.windowID)
                #else
                showsSound = true
                #endif
            } label: {
                Label("Sound and Picture", systemImage: "slider.horizontal.3").labelStyle(.iconOnly).ravePlayerControlLabel()
            }
            .help("Sound and picture adjustments")
        }
        .sheet(isPresented: $showsSound) {
            #if os(tvOS)
            TVFilmSoundSettings()
            #else
            FilmAdjustmentsView()
                .toolbar { Button("Done") { showsSound = false } }
            #endif
        }
        .onChange(of: showsSound) { _, showing in
            onModalChanged(showing)
            if !showing { session.saveSound() }
        }
        .task {
            while !Task.isCancelled {
                now = player.currentTime
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// A separate visionOS window: a sheet shares the stereo picture's depth
/// region and can be occluded by it. Other platforms present this as a sheet.
struct FilmAdjustmentsView: View {
    static let windowID = "film-adjustments"
    @Bindable private var session = FilmSession.shared

    var body: some View {
        NavigationStack {
            #if os(visionOS) || os(macOS)
            HStack(spacing: 0) {
                Form { controls }
                    .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Objects").font(.headline)
                    FilmObjectMapPanel(player: session.player)
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 820, minHeight: 520)
            .navigationTitle("Sound and Picture")
            #else
            Form {
                controls
                Section("Objects") { FilmObjectMapPanel(player: session.player) }
            }
            .navigationTitle("Sound and Picture")
            #endif
        }
        .onDisappear { session.saveSound() }
    }

    @ViewBuilder private var controls: some View {
        #if os(iOS) || os(macOS)
        Section("Head Tracking") {
            Toggle("Head Tracking", isOn: $session.headTracking)
            FilmHeadTrackingRow()
        }
        #endif
        #if os(visionOS)
        if session.stereoEnabled {
            Section("3D") {
                Slider(value: $session.stereoSettings.convergence, in: 0...1)
                Text("Convergence: higher pushes the scene back; at 1 nothing crosses the window frame.")
                    .font(.caption)
            }
        }
        #endif
        Section("Sound") { FilmTuning() }
        Section("Telemetry") { FilmTelemetry(player: session.player) }
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

#if os(iOS) || os(macOS)
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
