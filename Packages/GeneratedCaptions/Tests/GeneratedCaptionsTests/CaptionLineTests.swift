import Foundation
import Testing
@testable import GeneratedCaptions

/// How recognized words become lines. Finals arrive a word to a run with a
/// leading space; a volatile guess arrives as one run whose first word has
/// none, which used to give "Sentence ends here.and another begins".
@Suite struct CaptionLineTests {
    private func word(_ text: String, _ start: Double, _ end: Double, speaker: Int? = nil) -> RAVEGeneratedCaption {
        .init(start: start, end: end, text: text, speaker: speaker)
    }

    /// Words one after another, 0.3 s each, the first without a leading space.
    private func speech(_ text: String, from start: Double = 0) -> [RAVEGeneratedCaption] {
        text.split(separator: " ").enumerated().map { index, piece in
            let begin = start + Double(index) * 0.3
            return word((index == 0 ? "" : " ") + piece, begin, begin + 0.28)
        }
    }

    @Test func joinPutsASpaceWhereNeitherSideHasOne() {
        #expect(CaptionWorker.join("Sentence ends here.", "and another begins") == "Sentence ends here. and another begins")
        #expect(CaptionWorker.join("Today", " we") == "Today we")
        #expect(CaptionWorker.join("it", ",") == "it,")
        #expect(CaptionWorker.join("end", "…") == "end…")
        #expect(CaptionWorker.join("(see", "this)") == "(see this)")
        #expect(CaptionWorker.join("これは", "ペンです") == "これはペンです")
    }

    @Test func aVolatileGuessStartingBareDoesNotGlueToTheSentenceBefore() {
        let final = speech("Sentence ends here.")
        let guess = CaptionWorker.timedWords("and another begins", from: 1.0, through: 2.5)
        let lines = CaptionWorker.lines(from: final + guess)
        #expect(lines.count == 1)
        #expect(lines[0].text == "Sentence ends here. and another begins")
    }

    @Test func aLineStartsWithoutTheRunsLeadingSpace() {
        let lines = CaptionWorker.lines(from: [word(" Hello", 0, 0.4), word(" there.", 0.4, 0.8)])
        #expect(lines.map(\.text) == ["Hello there."])
    }

    @Test func linesBreakAfterASentenceButAShortOneKeepsTheNext() {
        let long = speech("Today we are talking about memory pressure.", from: 0)
        let next = speech("It ends here and another begins.", from: 3)
        #expect(CaptionWorker.lines(from: long + next).map(\.text) == [
            "Today we are talking about memory pressure.", "It ends here and another begins.",
        ])
        let okay = [word("Okay.", 0, 0.4)] + speech("So let me explain.", from: 0.5).map { var w = $0; w.text = " " + w.text.trimmingCharacters(in: .whitespaces); return w }
        #expect(CaptionWorker.lines(from: okay).map(\.text) == ["Okay. So let me explain."])
    }

    @Test func aPauseOrAnotherSpeakerBreaksTheLine() {
        let lines = CaptionWorker.lines(from: [word("One", 0, 0.3), word(" two", 0.3, 0.6), word(" three", 2.0, 2.3)])
        #expect(lines.map(\.text) == ["One two", "three"])
        let speakers = CaptionWorker.lines(from: [word("One", 0, 0.3, speaker: 1), word(" two", 0.3, 0.6, speaker: 2)])
        #expect(speakers.map(\.text) == ["One", "two"])
    }

    @Test func aLongSentenceIsCutEvenlyAtItsCommaNotLeavingAWordAlone() {
        let text = "We opened three videos on the headset yesterday afternoon, closed them all, and the app was still using two gigabytes of memory"
        let lines = CaptionWorker.lines(from: speech(text))
        #expect(lines.count >= 2)
        #expect(lines.map(\.text).joined(separator: " ") == text)
        #expect(lines.allSatisfy { $0.text.split(separator: " ").count >= 4 })
        #expect(lines.allSatisfy { $0.end - $0.start < 4.5 })
        #expect(lines[0].text.hasSuffix(","), "cut at a comma: \(lines.map(\.text))")
    }

    /// Lines anchor to the speech: dropping the oldest words (the window's
    /// 60 s edge) must not move any later line.
    @Test func prunedWordsDoNotMoveLaterLines() {
        let all = speech("First sentence goes right here and runs on a while longer. ", from: 0)
            + speech("Second one follows after it ends, and it is long enough to be cut into two lines.", from: 6)
        let full = CaptionWorker.lines(from: all)
        let pruned = CaptionWorker.lines(from: Array(all.dropFirst(3)))
        #expect(Array(full.dropFirst(1)).map(\.text) == Array(pruned.dropFirst(1)).map(\.text))
    }

    @Test func aVolatileGuessIsPacedAtSpeechSpeedNotStretchedOverItsRange() {
        // The guess's range runs on to wherever audio has been fed (12.11 s),
        // well past where "the headset, it ends here" is spoken.
        let words = CaptionWorker.timedWords("the headset, it ends here", from: 3.84, through: 12.11)
        #expect(words.map(\.text).joined() == "the headset, it ends here")
        #expect(words.first?.start == 3.84)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 && $0.start < $0.end })
        #expect((words.last?.end ?? 99) < 3.84 + 3)
        // Squeezed only when the range is shorter than the pace.
        let tight = CaptionWorker.timedWords("the headset, it ends here", from: 3.84, through: 4.84)
        #expect((tight.last?.end ?? 99) <= 4.84 + 1e-9)
        // One word, or text without spaces, stays one piece with its own range.
        #expect(CaptionWorker.timedWords(" Today", from: 1.44, through: 1.9).count == 1)
        #expect(CaptionWorker.timedWords("これはペンです", from: 0, through: 2).count == 1)
    }
}
