/*
 Hypnos - RAVEFilm's Apple TV bench, with object audio

 The whole film player on the Apple TV: `FilmPlayer` (picture and Atmos
 objects on one clock) with the objects rendered through
 `FilmPhaseStageView`, the PHASE stage the Hypnos tvOS player uses. Same
 launch arguments as the picture-only bench, plus `-FilmAudio 1`; nothing
 is persisted, so it can point at the dev Jellyfin without touching the
 installed Hypnos's settings. Play/Pause on the remote toggles playback,
 Select recentres, Up/Down turns head tracking on/off. The stage also
 recentres whenever playback resumes.

 The console prints the audio status and the clock report (render rate,
 drift, resident segments, underruns) every few seconds.
 */

import AVFoundation
import RAVEFilm
import SwiftUI

struct FilmAudioLabView: View {
    @State private var player = FilmPlayer()
    @State private var headTracking = true
    @State private var recenters = 0
    @State private var nowPlaying: FilmNowPlaying?
    @State private var report = "Starting…"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            FilmVideoView(player: player.video)
                .ignoresSafeArea()
                .background {
                    FilmPhaseStageView(player: player, headTracking: headTracking, recenterRequest: recenters)
                }
            FilmObjectMapPanel(player: player)
                .frame(width: 760)
                .padding(60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Button {
                recenters += 1
                print("FilmAudioLab: recenter \(recenters)")
            } label: {
                Text(report).font(.caption2.monospaced()).multilineTextAlignment(.leading)
            }
            .padding(40)
        }
        .onPlayPauseCommand {
            player.isPlaying ? player.pause() : player.play()
            print("FilmAudioLab: \(player.isPlaying ? "play" : "pause")")
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: headTracking = true
            case .down: headTracking = false
            default: return
            }
            print("FilmAudioLab: head tracking \(headTracking ? "on" : "off")")
        }
        .task { await run() }
    }

    private func run() async {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "FilmToken"), let item = defaults.string(forKey: "FilmItem"),
              let server = defaults.string(forKey: "FilmServer").flatMap(URL.init(string:)) else {
            say("Launch with -FilmAudio 1 -FilmServer <url> -FilmToken <key> -FilmItem <id>")
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            say("Audio session: \(error.localizedDescription)")
        }
        player.reverbDB = -12
        let nowPlaying = FilmNowPlaying(player: player, title: "Film Lab")
        nowPlaying.onCommand = { [player] name in
            print("FilmAudioLab: remote command \(name) → isPlaying \(player.isPlaying)")
        }
        nowPlaying.activate()
        Task {
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
                print("FilmAudioLab: route change \(note.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "?") → \(outputs)")
            }
        }
        Task {
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                print("FilmAudioLab: interruption \(note.userInfo ?? [:])")
            }
        }
        self.nowPlaying = nowPlaying
        await player.load(FilmServerClient(baseURL: server, token: token, itemID: item), startAt: defaults.double(forKey: "FilmStart"))
        say("Loaded: \(player.video.formatSummary); audio \(player.audioStatus); \(player.elements.count) elements")
        try? await Task.sleep(for: .seconds(2))
        player.play()
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            tick += 1
            let line = String(format: "t=%.1f %@ | %@ | %@ | latency %.0f ms, skew %@ | head tracking %@, %d recenters",
                              player.currentTime, player.status, player.audioStatus, player.clockReport,
                              player.outputLatency * 1000,
                              player.scheduledSkewMs.map { String(format: "%+.0f ms", $0) } ?? "—",
                              headTracking ? "on" : "off", recenters)
            report = line
            if tick % 5 == 0 { print("FilmAudioLab: \(line)") }
        }
    }

    private func say(_ line: String) {
        print("FilmAudioLab: \(line)")
        report = line
    }
}
