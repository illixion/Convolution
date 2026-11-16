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
 4. Clean-up: a cue seen in fewer than two frames is noise; the same text split by a
    short gap is one cue; a cue that is only the first line of the next one
    (two-line subtitles whose second line fades in later) folds into it.

 Incremental: frames arrive in time order as the reader works ahead, and the
 finished cues are revised only near their end, while the next frames could
 still extend or merge them.

 Two things a video of long subtitles taught (2026-11-16, "Locations in
 Liberty City that make NO SENSE": white all-caps at the top, 5 to 35 s each):
 - **A subtitle is listed while it is still on screen** (`isOpen`), once its
   words have settled (0.8 s, the last three readings agreeing). It used to be
   listed when it went, so a subtitle longer than the 8 s the reader works
   ahead reached the narrator after it had begun, and past 4 s late it was
   skipped. Its id stays as it grows and closes.
 - **The style is judged again when it changes.** An amber title card in the
   middle of the picture fixed the style (amber, tall) before any subtitle had
   been read, and the white subtitles were thrown away until enough had been
   read to change it (the first 9 s). When the dominant colour changes, the
   latest frames are consumed again by the new style, which keeps only its
   colour, and the cues made keep the ids of the ones they replace.
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
    /// The cues so far, in time order. The last one may be a subtitle still
    /// on screen (`isOpen`), listed once its words have settled so that a
    /// narrator hears of a long subtitle when it appears, not when it goes;
    /// its id stays when it is closed.
    public var cues: [OnScreenTextCue] {
        guard var live = provisional else { return closed }
        live.isOpen = true
        // The same join the cue gets when it closes, so a subtitle broken by
        // a flash is not listed (and spoken) twice meanwhile.
        if let last = closed.last, var merged = Self.joined(last, live) {
            merged.isOpen = true
            return Array(closed.dropLast()) + [merged]
        }
        return closed + [live]
    }
    /// Media time up to which frames have been read: cues ending well before
    /// it are final.
    public private(set) var readThrough: Double = 0

    private var closed: [OnScreenTextCue] = []
    private var style = StyleStatistics()
    /// Frames held until the style has enough lines to judge by.
    private var warmup: [OnScreenTextFrame] = []
    /// The latest frames consumed, so they can be judged again if the video's
    /// style turns out to be another than it first looked.
    private var recent: [OnScreenTextFrame] = []
    private var open: OpenCue?
    private var nextID = 1
    /// How long a subtitle has been seen before it is listed while still on
    /// screen: past the fade-in, when its words have settled.
    private static let settleSeconds = 0.8
    /// A text this long is told apart by its words: the same one twice within
    /// `holeLimit` seconds is one subtitle.
    static let longText = 20
    static let holeLimit = 4.0
    private static let recentFrames = 75

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Starts again at a new place (a seek), keeping what was learned about
    /// the video's subtitle style and the cues before `time`.
    public mutating func restart(at time: Double) {
        closed.removeAll { $0.end > time - 0.25 }
        open = nil
        warmup = []
        recent = []
        readThrough = time
    }

    public mutating func add(_ frame: OnScreenTextFrame) {
        readThrough = max(readThrough, frame.time + configuration.sampleInterval)
        let candidates = frame.lines.filter(isCandidate)
        let before = style.dominantFamily
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
        for frame in held { consumeAndRemember(frame) }
        if let before, let now = style.dominantFamily, before != now {
            replayRecent(with: current)
        } else {
            consumeAndRemember(current)
        }
    }

    /// Ends the current run (the reader reached the end of the video).
    public mutating func finish() {
        let held = warmup
        warmup = []
        for frame in held { consumeAndRemember(frame) }
        closeOpenCue()
    }

    private mutating func consumeAndRemember(_ frame: OnScreenTextFrame) {
        consume(frame)
        recent.append(frame)
        if recent.count > Self.recentFrames { recent.removeFirst(recent.count - Self.recentFrames) }
    }

    /// The video's style turned out to be another colour than the first
    /// lines made it look (a title card in amber, then white subtitles): what
    /// the first style threw away may have been the subtitles. The latest
    /// frames are judged again by the new style, and the cues they make keep
    /// the ids of the ones they replace, so nothing already spoken is
    /// spoken twice.
    private mutating func replayRecent(with current: OnScreenTextFrame) {
        guard let first = recent.first?.time else { consumeAndRemember(current); return }
        let old = cues
        closed.removeAll { $0.start >= first - 0.01 }
        open = nil
        let frames = recent + [current]
        recent = []
        for frame in frames {
            consume(frame, strict: true)
            recent.append(frame)
        }
        func inherited(_ cue: OnScreenTextCue) -> Int? {
            old.first { abs($0.start - cue.start) < 1.0 && Self.similarity($0.text, cue.text) > 0.8 }?.id
        }
        for index in closed.indices where closed[index].start >= first - 0.01 {
            if let id = inherited(closed[index]) { closed[index].id = id }
        }
        if var current = open, let id = inherited(OnScreenTextCue(start: current.firstTime, end: current.lastTime,
                                                                  text: Self.medoid(current.texts), id: 0)) {
            current.id = id
            open = current
        }
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

    /// `strict`: only the dominant colour counts (frames judged again after
    /// the style changed, where the old colour is what was wrongly believed).
    private func isSubtitle(_ line: OnScreenTextLine, strict: Bool = false) -> Bool {
        guard let dominant = style.dominantFamily, let height = style.medianHeight else { return true }
        guard abs(log(line.height / height)) <= 0.45 else { return false }
        let family = ColorFamily(line)
        if strict, family != dominant { return false }
        if family != dominant {
            let range = NSRange(line.text.startIndex..., in: line.text)
            if Self.speakerPrefix.firstMatch(in: line.text, range: range) != nil { return false }
            if dominant != .neutral, family == .neutral { return false }
        }
        return true
    }

    private mutating func consume(_ frame: OnScreenTextFrame, strict: Bool = false) {
        // Top to bottom, as the lines are read.
        let kept = frame.lines.filter { isSubtitle($0, strict: strict) }.sorted { $0.box.midY < $1.box.midY }
        let text = kept.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let maxGap = configuration.sampleInterval * 2.5
        if var current = open {
            // A hole in the reading (the scout stalled, a read ran long) is not the
            // subtitle going away: the same long text on both sides of it is
            // one cue. (Seen on a headset: a 102-character subtitle read as two
            // cues 2.8 s apart, and narrated twice.)
            let sameText = text.count >= Self.longText && Self.similarity(text, current.texts.last ?? "") > 0.9
            let continues = !text.isEmpty && frame.time - current.lastTime <= (sameText ? Self.holeLimit : maxGap)
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
        if !text.isEmpty {
            open = OpenCue(id: nextID, firstTime: frame.time, lastTime: frame.time, texts: [text])
            nextID += 1
        }
    }

    /// The open cue as a listing, once it has been seen long enough for its
    /// words to settle (the last three readings agree).
    private var provisional: OnScreenTextCue? {
        guard let current = open, current.lastTime - current.firstTime >= Self.settleSeconds else { return nil }
        let latest = current.texts.suffix(3)
        guard latest.count == 3, let last = latest.last,
              latest.allSatisfy({ Self.similarity($0, last) > 0.9 }) else { return nil }
        return OnScreenTextCue(start: current.firstTime, end: current.lastTime + configuration.sampleInterval,
                               text: Self.medoid(current.texts), id: current.id, isOpen: true)
    }

    private mutating func closeOpenCue() {
        guard let current = open else { return }
        open = nil
        let interval = configuration.sampleInterval
        // Fewer than two agreeing frames (~0.2 s on screen): a misread, not a subtitle.
        // Quick text (fast dialogue, rapid captions) lives for a few frames only.
        guard current.lastTime - current.firstTime >= interval * 0.9 else { return }
        let cue = OnScreenTextCue(start: current.firstTime, end: current.lastTime + interval,
                                  text: Self.medoid(current.texts), id: current.id)
        append(cue)
    }

    private mutating func append(_ cue: OnScreenTextCue) {
        closed.append(cue)
        // Joining two cues can make the result joinable with the one before.
        while closed.count >= 2, let joined = Self.joined(closed[closed.count - 2], closed[closed.count - 1]) {
            closed.removeLast()
            closed[closed.count - 1] = joined
        }
    }

    /// One cue for two that are the same subtitle, else nil.
    static func joined(_ first: OnScreenTextCue, _ second: OnScreenTextCue) -> OnScreenTextCue? {
        let gap = second.start - first.end
        // Nearly the same words this soon again: the same subtitle, read
        // through something drawn over it for a moment. A long text that is
        // the same is the same subtitle across a longer gap too.
        let alike = similarity(first.text, second.text)
        let sameLongText = alike > 0.9 && min(first.text.count, second.text.count) >= longText
        guard gap < (sameLongText ? holeLimit + 2 : 2.5) else { return nil }
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
    /// Given when the cue opens, so it keeps it while it is listed and after.
    var id: Int
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
