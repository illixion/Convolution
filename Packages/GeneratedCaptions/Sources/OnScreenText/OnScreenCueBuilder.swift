/*
 On-screen text: frames in, cues out.

 What was read from successive frames becomes subtitle cues in four steps,
 tuned on two narration-free YouTube videos (2026-11-15, prototype numbers in
 the Hypnos memory `burned-in-subtitle-narration`):

 1. Candidate lines: centred on the region, mostly letters, confident.
 2. The video's subtitle style: the colour family (neutral, or the dominant
    channel) with the most lines, and the median height of its lines. Lines
    far from that height are someone else's (a game's HUD, its own smaller
    subtitles). When the subtitles are coloured, plain white or grey lines are
    rejected outright: that is what keeps a game's own "Songbird: …" lines,
    drawn just under a creator's amber ones, out. A "Name:" prefix in another
    colour is rejected for the same reason.
 3. Frames whose kept text is alike (edit-distance ratio over 0.6, a dropped
    frame or two allowed) form one cue; its text is the reading most like the
    others (OCR noise such as "Em Da but…" on one frame loses the vote).
 4. Clean-up: a cue shorter than ~0.5 s is noise; the same text split by a
    short gap is one cue; a cue that is only the first line of the next one
    (two-line subtitles whose second line fades in later) folds into it.

 Incremental: frames arrive in time order as the reader works ahead, and the
 finished cues are revised only near their end, while the next frames could
 still extend or merge them.
 */

import Foundation

public struct OnScreenCueBuilder: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var region: OnScreenTextRegion
        /// Seconds between the frames the reader samples.
        public var sampleInterval: Double
        public init(region: OnScreenTextRegion = .bottom, sampleInterval: Double = 0.2) {
            self.region = region; self.sampleInterval = sampleInterval
        }
    }

    public private(set) var configuration: Configuration
    /// Finished and still-revisable cues, in time order.
    public private(set) var cues: [OnScreenTextCue] = []
    /// Media time up to which frames have been read: cues ending well before
    /// it are final.
    public private(set) var readThrough: Double = 0

    private var style = StyleStatistics()
    /// Frames held until the style has enough lines to judge by.
    private var warmup: [OnScreenTextFrame] = []
    private var open: OpenCue?
    private var nextID = 1

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Starts again at a new place (a seek), keeping what was learned about
    /// the video's subtitle style and the cues before `time`.
    public mutating func restart(at time: Double) {
        cues.removeAll { $0.end > time - 0.25 }
        open = nil
        warmup = []
        readThrough = time
    }

    public mutating func add(_ frame: OnScreenTextFrame) {
        readThrough = max(readThrough, frame.time + configuration.sampleInterval)
        let candidates = frame.lines.filter(isCandidate)
        for line in candidates { style.add(line) }
        let current = OnScreenTextFrame(time: frame.time, lines: candidates)
        // Hold frames until the style has enough lines to judge by, but not
        // forever: a video with little text is judged with what there is.
        if !style.isReady, warmup.count < 40 {
            warmup.append(current)
            return
        }
        let held = warmup
        warmup = []
        for frame in held { consume(frame) }
        consume(current)
    }

    /// Ends the current run (the reader reached the end of the video).
    public mutating func finish() {
        let held = warmup
        warmup = []
        for frame in held { consume(frame) }
        closeOpenCue()
    }

    // MARK: Steps

    private func isCandidate(_ line: OnScreenTextLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 4, line.confidence >= 0.5 else { return false }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard Double(letters) / Double(text.unicodeScalars.count) > 0.6 else { return false }
        let region = configuration.region
        guard line.box.midY >= region.top, line.box.midY <= region.bottom else { return false }
        return abs(line.box.midX - region.centerX) < 0.06
    }

    private static let speakerPrefix = try! NSRegularExpression(pattern: #"^\W{0,2}[A-Z][\w ]{0,14}[:;.]\s"#)

    private func isSubtitle(_ line: OnScreenTextLine) -> Bool {
        guard let dominant = style.dominantFamily, let height = style.medianHeight else { return true }
        guard abs(log(line.height / height)) <= 0.45 else { return false }
        let family = ColorFamily(line)
        if family != dominant {
            let range = NSRange(line.text.startIndex..., in: line.text)
            if Self.speakerPrefix.firstMatch(in: line.text, range: range) != nil { return false }
            if dominant != .neutral, family == .neutral { return false }
        }
        return true
    }

    private mutating func consume(_ frame: OnScreenTextFrame) {
        // Top to bottom, as the lines are read.
        let kept = frame.lines.filter(isSubtitle).sorted { $0.box.midY < $1.box.midY }
        let text = kept.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let maxGap = configuration.sampleInterval * 2.5
        if var current = open {
            let continues = !text.isEmpty && frame.time - current.lastTime <= maxGap
                && current.texts.suffix(3).contains { Self.similarity(text, $0) > 0.6 }
            if continues {
                current.texts.append(text)
                current.lastTime = frame.time
                open = current
                return
            }
            if text.isEmpty, frame.time - current.lastTime <= maxGap { return }
            closeOpenCue()
        }
        if !text.isEmpty { open = OpenCue(firstTime: frame.time, lastTime: frame.time, texts: [text]) }
    }

    private mutating func closeOpenCue() {
        guard let current = open else { return }
        open = nil
        let interval = configuration.sampleInterval
        // Under ~0.5 s on screen: a misread, not a subtitle.
        guard current.lastTime - current.firstTime >= interval * 1.9 else { return }
        let cue = OnScreenTextCue(start: current.firstTime, end: current.lastTime + interval,
                                  text: Self.medoid(current.texts), id: 0)
        append(cue)
    }

    private mutating func append(_ incoming: OnScreenTextCue) {
        var cue = incoming
        cue.id = nextID
        nextID += 1
        cues.append(cue)
        // Joining two cues can make the result joinable with the one before.
        while cues.count >= 2, let joined = Self.joined(cues[cues.count - 2], cues[cues.count - 1]) {
            cues.removeLast()
            cues[cues.count - 1] = joined
        }
    }

    /// One cue for two that are the same subtitle, else nil.
    static func joined(_ first: OnScreenTextCue, _ second: OnScreenTextCue) -> OnScreenTextCue? {
        let gap = second.start - first.end
        guard gap < 2.5 else { return nil }
        // Nearly the same words this soon again: the same subtitle, read
        // through something drawn over it for a moment.
        let alike = similarity(first.text, second.text)
        guard gap < 1.5 || alike > 0.9 else { return nil }
        var result = first
        result.end = max(first.end, second.end)
        let a = first.text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        let b = second.text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        if gap < 1.0, !a.isEmpty, !b.isEmpty {
            // The first line alone, then both once the second faded in.
            if b.hasPrefix(a) { result.text = second.text; return result }
            // Both, then one line for a moment (the other misread).
            if a.hasPrefix(b) { return result }
        }
        // The same subtitle, broken by a dropout or a flash.
        if alike > 0.75 {
            if second.text.count > first.text.count { result.text = second.text }
            return result
        }
        return nil
    }

    // MARK: Text

    /// The reading most like all the others, weighted by how often each was
    /// read; longer wins a tie (a frame that dropped a word loses).
    static func medoid(_ texts: [String]) -> String {
        var counts: [String: Int] = [:]
        for text in texts { counts[text, default: 0] += 1 }
        let unique = Array(counts.keys)
        guard unique.count > 1 else { return unique.first ?? "" }
        return unique.max { a, b in
            score(a, counts) + 0.001 * Double(a.count) < score(b, counts) + 0.001 * Double(b.count)
        }!
    }

    private static func score(_ text: String, _ counts: [String: Int]) -> Double {
        counts.reduce(0) { $0 + similarity(text, $1.key) * Double($1.value) }
    }

    /// 1 - normalised edit distance, case-insensitive.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().unicodeScalars), y = Array(b.lowercased().unicodeScalars)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}

private struct OpenCue: Sendable {
    var firstTime: Double
    var lastTime: Double
    var texts: [String]
}

/// Neutral (white, grey, black), or which channel leads.
enum ColorFamily: Hashable, Sendable {
    case neutral, red, green, blue

    init(_ line: OnScreenTextLine) {
        let mean = (line.red + line.green + line.blue) / 3
        let deviations = [line.red - mean, line.green - mean, line.blue - mean]
        // 25 of 255 from grey, as measured on amber and white subtitles.
        guard deviations.map(abs).max()! >= 25.0 / 255 else { self = .neutral; return }
        switch deviations.indices.max(by: { deviations[$0] < deviations[$1] })! {
        case 0: self = .red
        case 1: self = .green
        default: self = .blue
        }
    }
}

/// The colour family with the most candidate lines, and their median height.
/// Bounded to the last 3000 lines (about ten minutes of subtitles) so a video
/// whose style changes follows it, and sticky: another family takes over only
/// with half as many lines again, since a game's own subtitles can outnumber
/// a creator's for a minute (a dialogue scene) without being the narration.
struct StyleStatistics: Sendable {
    private var lines: [(family: ColorFamily, height: Double)] = []
    private var counts: [ColorFamily: Int] = [:]
    private(set) var dominantFamily: ColorFamily?

    mutating func add(_ line: OnScreenTextLine) {
        let family = ColorFamily(line)
        lines.append((family, line.height))
        counts[family, default: 0] += 1
        if lines.count > 3000 {
            counts[lines.removeFirst().family]! -= 1
        }
        guard isReady, let leader = counts.max(by: { $0.value < $1.value }) else { return }
        if let incumbent = dominantFamily, incumbent != leader.key,
           Double(leader.value) < Double(counts[incumbent] ?? 0) * 1.5 { return }
        dominantFamily = leader.key
    }

    var isReady: Bool { lines.count >= 20 }

    var medianHeight: Double? {
        guard let family = dominantFamily else { return nil }
        let heights = lines.filter { $0.family == family }.map(\.height).sorted()
        return heights.isEmpty ? nil : heights[heights.count / 2]
    }
}
