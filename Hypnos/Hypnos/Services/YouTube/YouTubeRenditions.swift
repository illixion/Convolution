/*
 Hypnos - the picture sizes a YouTube video offers, and playing exactly one
 (sideload builds only: `HYPNOS_YOUTUBE`)

 YouTube's HLS master lists every rendition the video has (a 1080p upload
 stops at 1080p), each as an `#EXT-X-STREAM-INF` with its `RESOLUTION` and
 `FRAME-RATE`. The video window's Quality menu lists those, the way
 YouTube's own player does, rather than a fixed ladder up to 4K.

 Picking one plays it: a copy of the master holding only that rendition's
 variants is served on loopback (`LoopbackPlaylistServer`), so the player
 can't pick another by bandwidth. Auto plays the full master. The copies
 are remembered with the master they came from, so a window that reopens
 one this launch can return to Auto, and an expired source is still seen
 as expired.

 Pure text in, text out, apart from that registry.
 */

#if HYPNOS_YOUTUBE

import Foundation

/// One picture size a video's master offers.
struct YouTubeRendition: Hashable, Sendable {
    /// The size class YouTube names it by: 1080 for "1080p" (a 1920×800
    /// scope video and a 1080×1920 portrait one included).
    let height: Int
    /// The highest frame rate any of its variants has.
    let framesPerSecond: Double?

    /// "1080p60", "2160p (4K)", "720p".
    var title: String {
        let rate = framesPerSecond.map { $0 >= 48 ? String(Int($0.rounded())) : "" } ?? ""
        return Self.label(height) + rate + (Self.nickname(height).map { " (\($0))" } ?? "")
    }

    /// "1080p", or "4K" for the bar's badge where it's shorter.
    static func badge(_ height: Int) -> String {
        nickname(height) ?? label(height)
    }

    static func label(_ height: Int) -> String { "\(height)p" }

    private static func nickname(_ height: Int) -> String? {
        switch height {
        case 4320: "8K"
        case 2160: "4K"
        default: nil
        }
    }
}

enum YouTubeRenditions {
    /// YouTube's ladder.
    static let classes = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144]

    /// The class a `width`×`height` picture is named by: its short side, or
    /// for a picture wider than 16:9 the height a 16:9 one of its width has.
    static func sizeClass(width: Int, height: Int) -> Int {
        let short = Double(min(width, height))
        let long = Double(max(width, height))
        let measure = max(short, long * 9 / 16)
        return classes.min { abs(Double($0) - measure) < abs(Double($1) - measure) } ?? Int(short)
    }

    /// The renditions `master` offers, highest first; empty for a playlist
    /// that isn't a master (or names no sizes).
    static func parse(master: String) -> [YouTubeRendition] {
        // The highest frame rate per class, 0 where no variant says.
        var rates: [Int: Double] = [:]
        for line in master.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let attributes = YouTubeManifestComposer.parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            guard let size = attributes.value(for: "RESOLUTION").flatMap(resolution) else { continue }
            let height = sizeClass(width: size.width, height: size.height)
            let rate = attributes.value(for: "FRAME-RATE").flatMap(Double.init) ?? 0
            rates[height] = max(rates[height] ?? 0, rate)
        }
        return rates.map { YouTubeRendition(height: $0.key, framesPerSecond: $0.value > 0 ? $0.value : nil) }
            .sorted { $0.height > $1.height }
    }

    /// `master` keeping only the variants (and I-frame playlists) of the
    /// `height` class, everything else (audio renditions, tags) as it is.
    /// Nil when it has none.
    static func master(_ master: String, keepingHeight height: Int) -> String? {
        let lines = master.components(separatedBy: .newlines)
        var output: [String] = []
        var kept = 0
        var index = 0
        func matches(_ attributeText: Substring) -> Bool {
            let attributes = YouTubeManifestComposer.parseAttributes(String(attributeText))
            guard let size = attributes.value(for: "RESOLUTION").flatMap(resolution) else { return false }
            return sizeClass(width: size.width, height: size.height) == height
        }
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let uri = index + 1 < lines.count ? lines[index + 1] : ""
                index += 2
                guard matches(line.dropFirst("#EXT-X-STREAM-INF:".count)) else { continue }
                output.append(line)
                output.append(uri)
                kept += 1
                continue
            }
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:"),
               !matches(line.dropFirst("#EXT-X-I-FRAME-STREAM-INF:".count)) {
                index += 1
                continue
            }
            output.append(line)
            index += 1
        }
        return kept > 0 ? output.joined(separator: "\n") : nil
    }

    private static func resolution(_ value: String) -> (width: Int, height: Int)? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    // MARK: Copies served on loopback

    @MainActor private static var sources: [URL: URL] = [:]

    /// Serves `master` cut to the `height` class; nil when it has none or
    /// the loopback server can't start.
    @MainActor
    static func publish(_ master: String, from source: URL, keepingHeight height: Int) async -> URL? {
        guard let text = self.master(master, keepingHeight: height),
              let url = await LoopbackPlaylistServer.shared.publish(text) else { return nil }
        sources[url] = source
        return url
    }

    /// The full master a served copy was cut from; nil for anything else.
    @MainActor
    static func source(of url: URL) -> URL? {
        sources[url]
    }
}

#endif
