import AVFoundation
import Foundation
import Testing
@testable import OnScreenText

/// The reader and narrator against a real video, through AVPlayer and Vision.
/// Off unless `ONSCREEN_FIXTURE` names an H.264 video with burned-in
/// subtitles whose first two minutes hold "turns out" (the Cyberpunk clip
/// the prototype used: `ffmpeg -t 120 -i jvo617JThCQ.mp4 -c:v libx264 …`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ONSCREEN_FIXTURE"] != nil))
struct OnScreenTextReaderIntegrationTests {
    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition(), Date.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func readsAheadOfAPausedPlayerThenFollowsASeek() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ONSCREEN_FIXTURE"]!)
        let player = AVPlayer(url: url)
        player.isMuted = true
        await waitUntil(10) { player.currentItem?.status == .readyToPlay }
        let reader = OnScreenTextReader()
        var diagnostics: [String] = []
        reader.onDiagnostic = { diagnostics.append($0) }
        reader.bind(player: player)
        let started = Date.now
        reader.start()

        // Paused at 0: it reads up to its lead and waits there.
        await waitUntil(120) { reader.readAheadSeconds >= 7.5 }
        print("read 8 s ahead in \(Date.now.timeIntervalSince(started)) s; \(diagnostics)")
        #expect(reader.readAheadSeconds >= 7.5)
        // Within a second of 0.4: a frame read slowly (a busy machine) can
        // cost the first samples of a fade-in.
        #expect(reader.cues.contains { $0.text.contains("Killing Moon") && abs($0.start - 0.4) < 1.0 })
        #expect(reader.error == nil)

        // A seek: reading starts again there.
        await player.seek(to: CMTime(seconds: 10, preferredTimescale: 600))
        await waitUntil(30) { reader.cues.contains { $0.text.hasPrefix("turns out") } }
        let turnsOut = reader.cues.first { $0.text.hasPrefix("turns out") }
        print("cues after seek:", reader.cues.map { String(format: "%.1f %@", $0.start, $0.text) })
        #expect(turnsOut.map { abs($0.start - 10.8) < 0.5 } == true)
        reader.stop()
    }

    @Test func narratorSpeaksADueCueAndDucksTheVideo() async throws {
        let narrator = OnScreenTextNarrator()
        var levels: [Float] = []
        narrator.onDuck = { levels.append($0) }
        let cues = [OnScreenTextCue(start: 0.5, end: 3, text: "turns out, this van is bulletproof", id: 1)]
        let begin = Date.now
        // Drive it as a player would: 10 Hz, playing at 1x from 0.
        while Date.now.timeIntervalSince(begin) < 8, levels.count < 2 {
            narrator.update(playhead: Date.now.timeIntervalSince(begin), playing: true, speed: 1, cues: cues)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(levels.first == narrator.settings.duckLevel)
        #expect(levels.last == 1)
        narrator.stop()
    }
}
