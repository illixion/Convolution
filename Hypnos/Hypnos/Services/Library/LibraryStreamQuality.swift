/*
 Hypnos - Library feature: streaming quality

 What a Library title is streamed at. `auto` plays the original (direct
 play, or a full-quality remux of a file Apple players can't open) and
 steps down a level when the stream can't keep up; `original` is the same
 start that never steps down ("Always Direct Play"); the rest cap the
 bitrate, so on a slow link a title can start low rather than stall on the
 original first.

 One preference for every title, chosen on the detail page or from the
 player: picking a level mid-film is also the answer for the next one.
 */

import Foundation

enum LibraryStreamQuality: String, CaseIterable, Codable, Sendable {
    case auto
    case original
    case mbps40
    case mbps20
    case mbps10
    case mbps4
    case mbps1_5

    static let defaultsKey = "library.streamQuality"

    /// The saved preference.
    static var preferred: LibraryStreamQuality {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The capped levels, highest first: what `auto` steps down through.
    static let capped: [LibraryStreamQuality] = [.mbps40, .mbps20, .mbps10, .mbps4, .mbps1_5]

    /// Total bitrate (video + audio), or nil for the original.
    var maxBitrate: Int? {
        switch self {
        case .auto, .original: nil
        case .mbps40: 40_000_000
        case .mbps20: 20_000_000
        case .mbps10: 10_000_000
        case .mbps4: 4_000_000
        case .mbps1_5: 1_500_000
        }
    }

    /// The largest picture worth sending at the bitrate.
    var maxWidth: Int? {
        switch self {
        case .auto, .original: nil
        case .mbps40: 3840
        case .mbps20, .mbps10: 1920
        case .mbps4: 1280
        case .mbps1_5: 854
        }
    }

    var maxHeight: Int? {
        switch self {
        case .auto, .original: nil
        case .mbps40: 2160
        case .mbps20, .mbps10: 1080
        case .mbps4: 720
        case .mbps1_5: 480
        }
    }

    /// Audio within the cap: 5.1 AAC down to 1080p, stereo below.
    var audioBitrate: Int {
        switch self {
        case .mbps4: 256_000
        case .mbps1_5: 128_000
        default: 640_000
        }
    }

    var audioChannels: Int {
        switch self {
        case .mbps4, .mbps1_5: 2
        default: 6
        }
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .original: "Always Direct Play"
        case .mbps40: "4K · 40 Mbps"
        case .mbps20: "1080p · 20 Mbps"
        case .mbps10: "1080p · 10 Mbps"
        case .mbps4: "720p · 4 Mbps"
        case .mbps1_5: "480p · 1.5 Mbps"
        }
    }

    /// Short form for a label next to the level in force.
    var shortTitle: String {
        switch self {
        case .auto: "Auto"
        case .original: "Original"
        case .mbps40: "4K"
        case .mbps20: "1080p 20"
        case .mbps10: "1080p 10"
        case .mbps4: "720p"
        case .mbps1_5: "480p"
        }
    }

    var detail: String? {
        switch self {
        case .auto: "Original quality, lowered if the stream can't keep up"
        case .original: "Original quality, never lowered"
        default: nil
        }
    }

    /// Whether a source at `sourceBitrate` needs this level's transcode at
    /// all: a cap above the file's own bitrate would only cost a server
    /// encode for the same picture.
    func caps(sourceBitrate: Int?) -> Bool {
        guard let maxBitrate else { return false }
        guard let sourceBitrate, sourceBitrate > 0 else { return true }
        return sourceBitrate > maxBitrate
    }

    /// The capped level a stream URL was built at (its
    /// `MaxStreamingBitrate`), or nil for the original. Read off the URL so
    /// it stays true through renewed play sessions and restored windows.
    static func level(ofStream url: URL) -> LibraryStreamQuality? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "MaxStreamingBitrate" })?.value,
            let bitrate = Int(value)
        else { return nil }
        return capped.first { $0.maxBitrate == bitrate }
    }

    /// The next level down from what is playing now, or nil at the bottom.
    /// `current` nil is the original, whose own bitrate decides where the
    /// first step lands: a 6 Mbps file steps to 4 Mbps, not to 20.
    static func stepDown(from current: LibraryStreamQuality?, sourceBitrate: Int?) -> LibraryStreamQuality? {
        let ceiling = current?.maxBitrate ?? sourceBitrate ?? Int.max
        return capped.first { ($0.maxBitrate ?? 0) < ceiling }
    }
}

/// Watches a Library stream for the two ways a too-fast stream shows itself
/// and says when `auto` should step down:
///
/// - **No picture at start.** `startupTimeout` after the player was given the
///   stream, no frame has shown.
/// - **Rebuffering.** The player waiting for data while it means to play,
///   either one wait of `longStall` or `stallBudget` in total over the last
///   `window`. Waits in the `seekGrace` after a seek or stream switch don't
///   count: every player waits there, whatever the link.
///
/// Pure bookkeeping over the times it's told, so it can be tested without a
/// player.
struct StreamStallMonitor {
    static let startupTimeout: TimeInterval = 12
    static let longStall: TimeInterval = 6
    static let stallBudget: TimeInterval = 10
    static let window: TimeInterval = 90
    static let seekGrace: TimeInterval = 4
    /// After a step, the new stream gets this long before another.
    static let settleTime: TimeInterval = 15

    private var stallStart: Date?
    private var finishedStalls: [(end: Date, length: TimeInterval)] = []
    private var graceUntil: Date = .distantPast
    private var lastStep: Date = .distantPast

    /// A seek, a new stream, a pause: waits right after it are expected.
    mutating func restartGrace(at now: Date) {
        graceUntil = now.addingTimeInterval(Self.seekGrace)
        stallStart = nil
    }

    mutating func noteStepped(at now: Date) {
        lastStep = now
        finishedStalls = []
        restartGrace(at: now)
    }

    /// The player's waiting state at `now`. Returns true when the stream
    /// should step down.
    mutating func update(waiting: Bool, at now: Date) -> Bool {
        guard now >= graceUntil else {
            stallStart = nil
            return false
        }
        if waiting {
            if stallStart == nil { stallStart = now }
        } else if let start = stallStart {
            finishedStalls.append((now, now.timeIntervalSince(start)))
            stallStart = nil
        }
        finishedStalls.removeAll { now.timeIntervalSince($0.end) > Self.window }
        guard now.timeIntervalSince(lastStep) >= Self.settleTime else { return false }
        let current = stallStart.map { now.timeIntervalSince($0) } ?? 0
        let total = finishedStalls.reduce(current) { $0 + $1.length }
        return current >= Self.longStall || total >= Self.stallBudget
    }
}
