import AVFoundation
import Foundation
import Testing
@testable import OnScreenText

/// Kokoro for real: downloads its models (a few hundred MB, into Application
/// Support/OnScreenText/Kokoro) and speaks. Off unless `ONSCREEN_KOKORO=1`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ONSCREEN_KOKORO"] == "1"), .serialized)
struct OnScreenTextKokoroTests {
    @Test func voicesAreTheEnglishOnes() {
        #expect(OnScreenTextKokoro.voices.count >= 20)
        #expect(OnScreenTextKokoro.voices.allSatisfy { ["a", "b"].contains($0.id.prefix(1)) })
        let heart = OnScreenTextKokoro.voice(forIdentifier: "kokoro:af_heart")
        #expect(heart?.name == "Heart")
        #expect(heart?.detail == "American English · Female")
        #expect(OnScreenTextKokoro.voice(forIdentifier: "com.apple.voice.premium.en-GB.Daniel") == nil)
    }

    @Test func synthesizesALine() async throws {
        let started = Date.now
        try await OnScreenTextKokoro.shared.prepare()
        print("Kokoro ready in \(Date.now.timeIntervalSince(started)) s, \(OnScreenTextKokoro.diskSize() / 1_000_000) MB")
        #expect(OnScreenTextKokoro.isDownloaded)
        let line = Date.now
        let buffer = try await OnScreenTextKokoro.shared.synthesize("Turns out, this van is bulletproof.", voice: "bm_george", speed: 1)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        print("2.x s line synthesized in \(Date.now.timeIntervalSince(line)) s: \(seconds) s of audio")
        #expect(seconds > 1 && seconds < 5)
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(buffer.floatChannelData![0][$1])) }
        #expect(peak > 0.05)
    }

    @Test func narratorSpeaksInAKokoroVoice() async throws {
        try await OnScreenTextKokoro.shared.prepare()
        let narrator = OnScreenTextNarrator()
        narrator.settings.voiceIdentifier = "kokoro:af_heart"
        var diagnostics: [String] = []
        narrator.onDiagnostic = { diagnostics.append($0) }
        var levels: [Float] = []
        narrator.onDuck = { levels.append($0) }
        let cues = [OnScreenTextCue(start: 1, end: 3.5, text: "turns out, this van is bulletproof", id: 1)]
        let begin = Date.now
        while Date.now.timeIntervalSince(begin) < 15, levels.count < 2 {
            narrator.update(playhead: Date.now.timeIntervalSince(begin), playing: true, speed: 1, cues: cues)
            try await Task.sleep(for: .milliseconds(100))
        }
        print(diagnostics)
        #expect(diagnostics.contains("Narration: loading the Kokoro voice"))
        #expect(!diagnostics.contains { $0.contains("Kokoro voice failed") })
        #expect(diagnostics.contains { $0.contains("24000 Hz") })
        #expect(levels == [narrator.settings.duckLevel, 1])
        narrator.stop()
    }
}
