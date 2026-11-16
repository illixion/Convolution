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

    // MARK: Long subtitles and a title card (the "Locations in Liberty City" video)

    /// White all-caps subtitles in a band at the top; a subtitle there can
    /// stay up for ten seconds and more.
    private func subtitle(_ text: String, at time: Double, white: Double = 1, height: Double = 0.054) -> OnScreenTextFrame {
        OnScreenTextFrame(time: time, lines: [
            OnScreenTextLine(text: text, confidence: 1, box: CGRect(x: 0.2, y: 0.055, width: 0.6, height: height),
                             red: white, green: white, blue: white),
        ])
    }

    @Test func listsALongSubtitleWhileItIsStillOnScreen() {
        var builder = OnScreenCueBuilder(configuration: .init(region: .top))
        // Warm-up: a few short subtitles so the style is known.
        var t = 0.0
        for text in ["THIS IS NOT A GOOD PLACE FOR A CONTAINER CRANE", "THERE IS NO ROOM FOR CONTAINER SHIPS AND NO SPACE",
                     "AND IT ALMOST RUBS AGAINST THE OVERPASS"] {
            for _ in 0..<25 { builder.add(subtitle(text, at: t)); t += 0.2 }
        }
        let started = t
        // 14 s subtitle: after 1.5 s of it the cue is already listed, open.
        let long = "EVEN IF IT HAD TRACKS THIS LIGHT POLE WOULD PREVENT IT FROM GETTING TO THESE CONTAINERS"
        for _ in 0..<8 { builder.add(subtitle(long, at: t)); t += 0.2 }
        let listed = builder.cues.last
        #expect(listed?.text == long)
        #expect(listed?.isOpen == true)
        #expect(abs((listed?.start ?? 0) - started) < 0.01)
        let id = listed?.id
        // It keeps its id as it grows and when it closes.
        for _ in 0..<62 { builder.add(subtitle(long, at: t)); t += 0.2 }
        #expect(builder.cues.last?.id == id)
        #expect((builder.cues.last?.end ?? 0) > started + 12)
        builder.add(subtitle("ALL THE OTHER CONTAINER CRANES HAVE TRACKS", at: t)); t += 0.2
        let closed = builder.cues.first { $0.id == id }
        #expect(closed?.isOpen == false)
        #expect(abs((closed?.end ?? 0) - t + 0.2) < 0.4)
    }

    /// Seen on a headset: a 102-character subtitle read as two cues 2.8 s
    /// apart (the reading had a hole), listed under two ids and spoken twice.
    @Test func aHoleInTheReadingDoesNotSplitALongSubtitle() {
        let long = "AND SOMEHOW THE TRACKS GOT BENT UPWARDS (OBIOUSLY FOR THE JUMP BUT THEY COULD JUST PLACE THEM FLAT)"
        func run(emptyFramesInHole: Bool) -> [OnScreenTextCue] {
            var builder = OnScreenCueBuilder(configuration: .init(region: .top))
            var t = 0.0
            for text in ["THIS IS NOT A GOOD PLACE FOR A CONTAINER CRANE", "THERE IS NO ROOM FOR CONTAINER SHIPS AND NO SPACE",
                         "AND IT ALMOST RUBS AGAINST THE OVERPASS"] {
                for _ in 0..<25 { builder.add(subtitle(text, at: t)); t += 0.2 }
            }
            var seen: [Int] = []
            for _ in 0..<25 { builder.add(subtitle(long, at: t)); t += 0.2; if let id = builder.cues.last(where: { $0.text == long })?.id { seen.append(id) } }
            // 2.8 s with nothing read (or only empty frames), the subtitle still up.
            if emptyFramesInHole {
                for _ in 0..<14 { builder.add(OnScreenTextFrame(time: t, lines: [])); t += 0.2 }
            } else { t += 2.8 }
            for _ in 0..<10 { builder.add(subtitle(long, at: t)); t += 0.2; if let id = builder.cues.last(where: { $0.text == long })?.id { seen.append(id) } }
            #expect(Set(seen).count == 1, "ids \(Set(seen))")
            builder.finish()
            return builder.cues
        }
        for empty in [false, true] {
            let cues = run(emptyFramesInHole: empty)
            #expect(cues.filter { $0.text == long }.count == 1, "empty frames: \(empty), \(cues.map(\.text.count))")
        }
    }

    @Test func aFadeInIsNotListedUntilItsWordsSettle() {
        var builder = OnScreenCueBuilder(configuration: .init(region: .top))
        var t = 0.0
        for text in ["THIS IS NOT A GOOD PLACE FOR A CONTAINER CRANE", "THERE IS NO ROOM FOR CONTAINER SHIPS AND NO SPACE",
                     "AND IT ALMOST RUBS AGAINST THE OVERPASS"] {
            for _ in 0..<25 { builder.add(subtitle(text, at: t)); t += 0.2 }
        }
        let full = "IT DOESN'T HAVE ANY TRACKS TO MOVE ON"
        for partial in ["IT DOESN", "IT DOESN'T HAVE ANY", "IT DOESN'T HAVE ANY TRACKS TO"] {
            builder.add(subtitle(partial, at: t)); t += 0.2
            #expect(builder.cues.last?.text != partial)
        }
        for _ in 0..<10 { builder.add(subtitle(full, at: t)); t += 0.2 }
        #expect(builder.cues.last?.text == full)
    }

    /// An amber title card in the middle of the picture comes first and fixes
    /// the style (amber, tall) before any white subtitle has been read; the
    /// subtitles that follow are then thrown away until enough have been
    /// read to change it. They are judged again when it does.
    @Test func aTitleCardDoesNotCostTheFirstSubtitles() {
        var builder = OnScreenCueBuilder(configuration: .init(region: .top))
        var t = 0.0
        func card(_ text: String, y: Double) -> OnScreenTextLine {
            OnScreenTextLine(text: text, confidence: 1, box: CGRect(x: 0.2, y: y, width: 0.6, height: 0.09),
                             red: 0.96, green: 0.66, blue: 0.1)
        }
        for _ in 0..<12 {
            builder.add(OnScreenTextFrame(time: t, lines: [card("WRONG PLACE FOR A", y: 0.14), card("CONTAINER CRANE", y: 0.24)]))
            t += 0.2
        }
        let first = t
        // The id each subtitle was first listed under, as a narrator would see it.
        var listed: [String: Int] = [:]
        for text in ["THIS IS NOT A GOOD PLACE FOR A CONTAINER CRANE", "THERE IS NO ROOM FOR CONTAINER SHIPS AND NO SPACE",
                     "AND IT ALMOST RUBS AGAINST THE OVERPASS", "IT DOESN'T HAVE ANY TRACKS TO MOVE ON"] {
            for _ in 0..<26 {
                builder.add(subtitle(text, at: t)); t += 0.2
                for cue in builder.cues where !cue.text.contains("WRONG") && listed[cue.text] == nil { listed[cue.text] = cue.id }
            }
        }
        builder.finish()
        let texts = builder.cues.map(\.text)
        #expect(texts.first == "THIS IS NOT A GOOD PLACE FOR A CONTAINER CRANE", "\(texts)")
        #expect(abs((builder.cues.first?.start ?? 0) - first) < 0.01)
        #expect(!texts.contains { $0.contains("WRONG PLACE") })
        #expect(texts.count == 4)
        // Each was listed once, and under the id it ends with.
        #expect(listed.count == 4)
        for cue in builder.cues { #expect(listed[cue.text] == cue.id) }
    }

    /// The first 75 s of "Locations in Liberty City that make NO SENSE" as
    /// Vision read them (480p, the top 45%, 2026-11-16): an amber two-line
    /// title card, then white all-caps subtitles in a band at the top, some of
    /// them up for 14 s and one for 35 s.
    @Test func readsWhiteSubtitlesThatFollowAnAmberTitleCard() throws {
        var builder = OnScreenCueBuilder(configuration: .init(region: .top))
        var firstListed: [Int: Double] = [:]
        for frame in try frames("title-card-then-white") {
            builder.add(frame)
            for cue in builder.cues where firstListed[cue.id] == nil { firstListed[cue.id] = frame.time }
        }
        // Every cue listed while its subtitle was still on screen (a long one
        // was listed only when it went, up to 27 s after it had begun).
        // (The first one waits for the style to be judged again, which takes
        // until 8.8 s are read; the scout is that far ahead of the playhead.)
        for cue in builder.cues.dropFirst() {
            #expect(try #require(firstListed[cue.id]) < cue.start + 1.5, "\(cue.text) listed at \(firstListed[cue.id] ?? -1), starts \(cue.start)")
        }
        builder.finish()
        let texts = builder.cues.map(\.text)
        #expect(texts.first == "THIS IS NOT A GOOD PLACE FOR A CONTAINER CRANE", "\(texts)")
        #expect(!texts.contains { $0.contains("WRONG") || $0 == "CONTAINER CRANE" })
        #expect(texts.contains { $0.hasPrefix("THE STAIRS ARE ALSO BROKEN") })
        #expect(builder.cues.count >= 8 && builder.cues.count <= 9, "\(texts.count) cues")
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

@MainActor
@Suite struct OnScreenTextSpokenFormTests {
    @Test func aLineInCapitalsIsSpokenAsWordsNotSpelledOut() {
        #expect(OnScreenTextNarrator.spokenForm("SO FAR EVERYTHING MAKES SENSE") == "so far everything makes sense")
        #expect(OnScreenTextNarrator.spokenForm("THIS IS NOT A GOOD PLACE FOR A CONTAINER CRANE") == "this is not a good place for a container crane")
        #expect(OnScreenTextNarrator.spokenForm("OLD TRAIN TRACKS #1") == "old train tracks #1")
        #expect(OnScreenTextNarrator.spokenForm("DO YOU THINK THIS SHIP SANK?") == "do you think this ship sank?")
    }

    @Test func shortVowellessTokensStayAcronyms() {
        #expect(OnScreenTextNarrator.spokenForm("POOR NPCS DRIVE AROUND NYC") == "poor NPCS drive around NYC")
        #expect(OnScreenTextNarrator.spokenForm("THE TV IS ON") == "the TV is on")
    }

    @Test func aLongLineJustSpokenIsNotSpokenAgain() {
        let narrator = OnScreenTextNarrator()
        narrator.recentLines = [(text: "AND SOMEHOW THE TRACKS GOT BENT UPWARDS (OBIOUSLY FOR THE JUMP)", at: 320.5)]
        #expect(narrator.repeatsRecentLine("AND SOMEHOW THE TRACKS GOT BENT UPWARDS (OBVIOUSLY FOR THE JUMP)", at: 328.1))
        // Not a short line, not another line, not long after, not before (a seek back).
        #expect(!narrator.repeatsRecentLine("OLD TRAIN TRACKS", at: 328.1))
        #expect(!narrator.repeatsRecentLine("THESE DOORS DON'T ALIGN WITH THE TRACKS AT ALL", at: 328.1))
        #expect(!narrator.repeatsRecentLine("AND SOMEHOW THE TRACKS GOT BENT UPWARDS (OBIOUSLY FOR THE JUMP)", at: 340))
        #expect(!narrator.repeatsRecentLine("AND SOMEHOW THE TRACKS GOT BENT UPWARDS (OBIOUSLY FOR THE JUMP)", at: 300))
    }

    @Test func aLineWithLowercaseKeepsItsCapitals() {
        #expect(OnScreenTextNarrator.spokenForm("Rockstar made the NPC drive") == "Rockstar made the NPC drive")
        #expect(OnScreenTextNarrator.spokenForm("12 34") == "12 34")
    }
}
