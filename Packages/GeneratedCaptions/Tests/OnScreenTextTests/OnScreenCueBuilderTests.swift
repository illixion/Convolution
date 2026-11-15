import CoreGraphics
import Foundation
import Testing
@testable import OnScreenText

/// The cue builder against what Vision actually read from two narration-free
/// YouTube videos (720p, the lower 45% of each frame, 5 frames a second,
/// `.accurate`; 2026-11-15). Each fixture row is one line read from one frame:
/// time, confidence, box (whole-picture fractions, origin top-left), fill
/// colour (0-255) and text.
@Suite struct OnScreenCueBuilderTests {
    private func frames(_ name: String) throws -> [OnScreenTextFrame] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "tsv", subdirectory: "Fixtures"))
        var byTime: [Int: [OnScreenTextLine]] = [:]
        for row in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let f = row.split(separator: "\t", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 10, let t = Double(f[0]) else { continue }
            let line = OnScreenTextLine(text: f[9], confidence: Float(f[1])!,
                box: CGRect(x: Double(f[2])!, y: Double(f[3])!, width: Double(f[4])!, height: Double(f[5])!),
                red: Double(f[6])! / 255, green: Double(f[7])! / 255, blue: Double(f[8])! / 255)
            byTime[Int((t * 5).rounded()), default: []].append(line)
        }
        let last = byTime.keys.max() ?? 0
        // Every sampled frame, the ones with nothing read included.
        return (0...last).map { OnScreenTextFrame(time: Double($0) / 5, lines: byTime[$0] ?? []) }
    }

    private func cues(_ name: String) throws -> [OnScreenTextCue] {
        var builder = OnScreenCueBuilder()
        for frame in try frames(name) { builder.add(frame) }
        builder.finish()
        return builder.cues
    }

    /// A creator's amber subtitles over Cyberpunk 2077, whose own grey
    /// "Songbird: …" / "V: …" subtitles sit just below them.
    @Test func keepsTheCreatorsColouredSubtitlesAndDropsTheGamesGreyOnes() throws {
        let cues = try cues("amber-creator-grey-game")
        let texts = cues.map(\.text)
        #expect(cues.count >= 37 && cues.count <= 41, "\(cues.count) cues")
        #expect(!texts.contains { $0.contains("Songbird:") || $0.contains("Thinkin") || $0.hasPrefix("V:") })
        #expect(texts.contains("turns out, this van is bulletproof"))
        // The one green subtitle is still theirs.
        #expect(texts.contains { $0.hasPrefix("if you exit the car now it's a softlock") })
        // Two lines, the second faded in later: one cue, not two.
        #expect(texts.filter { $0.hasPrefix("so the van is bulletproof") }.count == 1)
        #expect(texts.last == "so what do you think? leave your comments below")
        #expect(texts.filter { $0.hasPrefix("so what do you think") }.count == 1)
    }

    /// White subtitles fading in and out over Terraria, with item tooltips and
    /// HUD text elsewhere in the picture.
    @Test func readsFadingWhiteSubtitlesIntoWholeCues() throws {
        let cues = try cues("white-fading")
        let texts = cues.map(\.text)
        #expect(cues.count >= 26 && cues.count <= 29, "\(cues.count) cues")
        #expect(texts.first == "Look, this isn't as stupid of an idea as it sounds.")
        #expect(texts.contains("I'll save some orichalcum so we can make an orichalcum anvil once we have the regular one."))
        // Starts on the first frame the faded-in text is readable.
        let first = try #require(cues.first)
        #expect(abs(first.start - 6.4) < 0.01)
        #expect(!texts.contains { $0.contains("increased") })
    }

    @Test func restartingDropsLaterCuesAndKeepsEarlierOnes() throws {
        var builder = OnScreenCueBuilder()
        for frame in try frames("white-fading") where frame.time < 40 { builder.add(frame) }
        builder.finish()
        let before = builder.cues.count
        builder.restart(at: 25)
        #expect(builder.cues.count < before)
        #expect(builder.cues.allSatisfy { $0.end <= 25 })
    }

    @Test func similarityIsCaseInsensitiveEditDistance() {
        #expect(OnScreenCueBuilder.similarity("Turns out", "turns out") == 1)
        #expect(OnScreenCueBuilder.similarity("abc", "") == 0)
        #expect(abs(OnScreenCueBuilder.similarity("kitten", "sitting") - (1 - 3.0 / 7)) < 1e-9)
    }

    @Test func medoidPrefersTheConsensusReading() {
        let readings = ["it wasn't there in v2.31", "It wasnt there in v2.31", "it wasn't there in v2.31",
                        "t wasn't there in v2.3'", "it wasn't there in v2.31"]
        #expect(OnScreenCueBuilder.medoid(readings) == "it wasn't there in v2.31")
    }
}
