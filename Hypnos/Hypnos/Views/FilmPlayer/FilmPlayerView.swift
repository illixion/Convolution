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

 tvOS: picture only, no `FilmStageView`. Atmos object audio is built for
 headphone tracking (AirPods) or the AVP's own head tracking — neither
 means anything for a TV pointed at a fixed listening position, and doing
 it properly (a real speaker-array or soundbar passthrough) is out of scope
 for this port. So the tvOS branch never mounts the stage at all: nothing
 ever consumes `FilmPlayer.audio`, so a film with Atmos objects plays its
 picture silently rather than through any real or fake spatialisation. See
 Hypnos/CLAUDE.md "tvOS" for the gap.
 */

import RAVEFilm
import SwiftUI

struct FilmPlayerView: View {
    static let windowID = "film-player"

    @Bindable private var session = FilmSession.shared
    private var player: FilmPlayer { session.player }

    var body: some View {
        content
            .onAppear { session.isPlayerOpen = true }
            .onDisappear {
                player.pause()
                session.isPlayerOpen = false
            }
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
                FilmObjectMap(player: player)
                    .frame(width: 280, height: 280)
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
                FilmObjectMap(player: player).aspectRatio(1, contentMode: .fit)
            }
            Section("Tuning") { FilmTuning() }
            Section("Telemetry") { FilmTelemetry(player: player) }
        }
        .onAppear { HeadphoneHeadTracker.shared.start() }
        .onDisappear { HeadphoneHeadTracker.shared.stop() }
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
                FilmObjectMap(player: player).aspectRatio(1, contentMode: .fit)
            }
            Section("Tuning") { FilmTuning() }
            Section("Telemetry") { FilmTelemetry(player: player) }
        }
        #endif
    }
}

/// Objects seen from above, front (the screen) at the top. The dot at the
/// centre is the listener; each object's colour follows its height (blue at
/// ear level, red at the ceiling) and its size follows its level.
struct FilmObjectMap: View {
    let player: FilmPlayer

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in
                let halfWidth = CGFloat(player.roomHalfWidth)
                let halfDepth = CGFloat(player.roomHalfDepth)
                let scale = min(size.width / (2 * halfWidth), size.height / (2 * halfDepth)) * 0.9
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let room = CGRect(x: centre.x - halfWidth * scale, y: centre.y - halfDepth * scale,
                                  width: 2 * halfWidth * scale, height: 2 * halfDepth * scale)
                context.fill(Path(roundedRect: room, cornerRadius: 8), with: .color(.black.opacity(0.35)))
                context.stroke(Path(roundedRect: room, cornerRadius: 8), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                var screen = Path()
                screen.move(to: CGPoint(x: room.minX + room.width * 0.2, y: room.minY))
                screen.addLine(to: CGPoint(x: room.maxX - room.width * 0.2, y: room.minY))
                context.stroke(screen, with: .color(.primary), lineWidth: 4)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)),
                             with: .color(.primary))

                let frame = player.currentFrame
                for element in player.elements where !element.isBed {
                    let p = player.state(of: element, frame: frame).pos
                    let point = CGPoint(x: centre.x + CGFloat(p.x) * halfWidth * scale,
                                        y: centre.y - CGFloat(p.y) * halfDepth * scale)
                    let level = player.levels.indices.contains(element.channel) ? CGFloat(player.levels[element.channel]) : 0
                    let radius = 4 + min(level * 60, 18)
                    let height = player.flattenHeights ? 0 : Double(max(0, min(p.z, 1)))
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                        with: .color(Color(hue: 0.62 * (1 - height), saturation: 0.8, brightness: 1).opacity(0.35 + min(level * 8, 0.65)))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#if os(tvOS)
/// tvOS film transport: play/pause plus ±10s, all plain focusable buttons —
/// there's no drag surface for a scrub bar, and Siri Remote's play/pause
/// button is wired separately via `.onPlayPauseCommand` on the container.
struct TVFilmTransport: View {
    let player: FilmPlayer

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
        }
        .labelStyle(.iconOnly)
        .padding(24)
        .background(.ultraThinMaterial, in: Capsule())
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
