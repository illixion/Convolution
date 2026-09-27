/*
 Hypnos - RAVEFilm's Apple TV bench (picture only)

 Plays one film's picture through FilmVideoPlayer, the same layer and
 host-clock timebase path the visionOS player uses, and asks the TV to
 switch to the film's dynamic range and frame rate. The point is an
 objective check: a TV that reports its input signal (the rooted LG C1,
 see TVLab/check-tv.sh) says whether the stream arrives as HDR10 or Dolby
 Vision, with no side-by-side judgement.

 Configured through launch arguments (the UserDefaults argument domain),
 so no server or token is built in:
   -FilmToken <key> -FilmItem <id> [-FilmServer <url>] [-FilmStart <s>]
 `TVLab/check-tv.sh` passes them. `-YouTube <id>` runs the on-device
 YouTube spike instead (YouTubeLab.swift), `-SpatialProbe 1` the spatial
 audio probe (SpatialProbe.swift), `-FilmAudio 1` the whole player with
 PHASE object audio (FilmAudioLab.swift).
 */

import AVFoundation
import AVKit
import RAVEFilm
import SwiftUI

@main
struct FilmLabTVApp: App {
    var body: some Scene {
        WindowGroup {
            if UserDefaults.standard.bool(forKey: "SpatialProbe") {
                SpatialProbeView()
            } else if UserDefaults.standard.bool(forKey: "FilmAudio") {
                FilmAudioLabView()
            } else if let id = UserDefaults.standard.string(forKey: "YouTube") {
                YouTubeLabView(videoID: id)
            } else {
                LabView()
            }
        }
    }
}

struct LabView: View {
    @State private var video = FilmVideoPlayer()
    @State private var report = "Starting…"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FilmVideoView(player: video)
                .ignoresSafeArea()
            Text(report)
                .font(.caption2.monospaced())
                .padding(12)
                .background(.black.opacity(0.5))
                .padding(40)
        }
        .task { await run() }
    }

    private func run() async {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "FilmToken"), let item = defaults.string(forKey: "FilmItem") else {
            say("Launch with -FilmToken <key> -FilmItem <id> (see TVLab/run-tv.sh)")
            return
        }
        let server = URL(string: defaults.string(forKey: "FilmServer") ?? "https://servo.akita-city.ts.net/jellyfin")!
        await video.load(FilmServerClient(baseURL: server, token: token, itemID: item), startAt: defaults.double(forKey: "FilmStart"))
        guard let format = video.format else {
            say("Load failed: \(video.status)")
            return
        }
        say("Loaded: \(video.formatSummary), \(video.frameRate.map { String(format: "%.3f fps", $0) } ?? "? fps")")

        // FilmVideoView states the display criteria to its window (Match
        // Content); give the TV its mode switch before playing.
        let switches = NotificationCenter.default.notifications(named: .AVDisplayManagerModeSwitchStart)
        let started = Task { for await _ in switches { say("Display mode switch started"); break } }
        try? await Task.sleep(for: .seconds(1))
        if let manager = keyWindow?.avDisplayManager {
            while manager.isDisplayModeSwitchInProgress { try? await Task.sleep(for: .milliseconds(100)) }
            say("Criteria: \(manager.preferredDisplayCriteria.map { "\($0)" } ?? "none"), matching=\(manager.isDisplayCriteriaMatchingEnabled)")
        }
        started.cancel()

        video.play()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            say(String(format: "t=%.1f %@ seg=%d ahead=%.1f", video.currentTime, video.status,
                       video.currentSegment, video.bufferedUntil - video.currentTime))
        }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.windows.first
    }

    private func say(_ line: String) {
        print("FilmLabTV: \(line)")
        report = line
    }
}
