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

 **HDR.** An HDR upload's master lists every size three times: H.264 SDR,
 VP9 SDR and VP9 Profile 2 PQ (`VIDEO-RANGE=PQ`). Given the choice, AVPlayer
 took an SDR one, so where the device plays HDR (`prefersHDR`) a size that
 has HDR variants keeps only those, and Auto plays a copy cut the same way.
 Its menu entry says "HDR", as YouTube's own player does. Every HDR
 variant is VP9, which AVFoundation plays only once the app has registered
 the supplemental VP9 decoder (`HypnosApp.init`); without it visionOS refused
 them, like every VP9 variant (AVFoundation -11848, CoreMedia -15812,
 2026-10-25). A device whose player still refuses HDR (`noteHDRRefused`, also
 what a non-HDR display does) gets no HDR cut until the OS changes, and the
 window replays its rendition in SDR.

 Pure text in, text out, apart from that registry and `playlistText`, which
 reads a master for the video window and the TV and Mac players.
 */

#if HYPNOS_YOUTUBE

import AVFoundation
import DebugTrace
import Foundation

/// One picture size a video's master offers.
struct YouTubeRendition: Hashable, Sendable {
    /// The size class YouTube names it by: 1080 for "1080p" (a 1920×800
    /// scope video and a 1080×1920 portrait one included).
    let height: Int
    /// The highest frame rate any of its variants has.
    let framesPerSecond: Double?
    /// It plays in HDR (PQ or HLG).
    var isHDR = false

    /// "1080p60", "2160p60 HDR (4K)", "720p".
    var title: String {
        let rate = framesPerSecond.map { $0 >= 48 ? String(Int($0.rounded())) : "" } ?? ""
        return Self.label(height) + rate + (isHDR ? " HDR" : "") + (Self.nickname(height).map { " (\($0))" } ?? "")
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

    /// This device shows HDR and its player hasn't refused YouTube's HDR
    /// variants on this OS, so an HDR variant is worth choosing over SDR.
    static var prefersHDR: Bool {
        AVPlayer.eligibleForHDRPlayback
            && UserDefaults.standard.string(forKey: hdrRefusedKey) != osVersion
    }

    /// The player couldn't open an HDR cut: SDR from now until the OS changes.
    static func noteHDRRefused() {
        UserDefaults.standard.set(osVersion, forKey: hdrRefusedKey)
    }

    // Renamed when visionOS's refusals turned out to be the VP9 decoder not
    // being registered there, so those don't count.
    private static let hdrRefusedKey = "youtube.hdrRefusedOnOSVersion"
    private static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// One `#EXT-X-STREAM-INF` (or I-frame) line's size class, frame rate
    /// and dynamic range; nil when it names no size.
    private struct Variant {
        let height: Int
        let framesPerSecond: Double
        let isHDR: Bool

        init?(_ attributeText: Substring) {
            let attributes = YouTubeManifestComposer.parseAttributes(String(attributeText))
            guard let size = attributes.value(for: "RESOLUTION").flatMap(YouTubeRenditions.resolution) else { return nil }
            height = YouTubeRenditions.sizeClass(width: size.width, height: size.height)
            framesPerSecond = attributes.value(for: "FRAME-RATE").flatMap(Double.init) ?? 0
            let range = attributes.value(for: "VIDEO-RANGE")?.uppercased()
            isHDR = range == "PQ" || range == "HLG"
        }
    }

    private static func variants(of master: String) -> [Variant] {
        master.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
            .compactMap { Variant($0.dropFirst("#EXT-X-STREAM-INF:".count)) }
    }

    /// The renditions `master` offers, highest first; empty for a playlist
    /// that isn't a master (or names no sizes). With `preferringHDR` a size
    /// that has HDR variants is its HDR rendition.
    static func parse(master: String, preferringHDR: Bool = prefersHDR) -> [YouTubeRendition] {
        let all = variants(of: master)
        let hdrClasses = preferringHDR ? Set(all.filter(\.isHDR).map(\.height)) : []
        // The highest frame rate per class among the variants that play, 0 where none says.
        var rates: [Int: Double] = [:]
        for variant in all where !hdrClasses.contains(variant.height) || variant.isHDR {
            rates[variant.height] = max(rates[variant.height] ?? 0, variant.framesPerSecond)
        }
        return rates.map {
            YouTubeRendition(height: $0.key, framesPerSecond: $0.value > 0 ? $0.value : nil,
                             isHDR: hdrClasses.contains($0.key))
        }
        .sorted { $0.height > $1.height }
    }

    /// True when `master` would play differently cut for HDR: it has HDR
    /// variants and the device prefers them.
    static func offersHDR(_ master: String, preferringHDR: Bool = prefersHDR) -> Bool {
        preferringHDR && variants(of: master).contains(where: \.isHDR)
    }

    /// `master` keeping only the variants (and I-frame playlists) of the
    /// `height` class (nil: every class), everything else (audio
    /// renditions, tags) as it is. With `preferringHDR` a class that has HDR
    /// variants keeps only those. Nil when nothing is left.
    static func master(_ master: String, keepingHeight height: Int?, preferringHDR: Bool = prefersHDR) -> String? {
        let lines = master.components(separatedBy: .newlines)
        let hdrClasses = preferringHDR ? Set(variants(of: master).filter(\.isHDR).map(\.height)) : []
        var output: [String] = []
        var kept = 0
        var index = 0
        func matches(_ attributeText: Substring) -> Bool {
            guard let variant = Variant(attributeText) else { return false }
            guard height == nil || variant.height == height else { return false }
            return !hdrClasses.contains(variant.height) || variant.isHDR
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

    fileprivate static func resolution(_ value: String) -> (width: Int, height: Int)? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    // MARK: Copies served on loopback

    @MainActor private static var sources: [URL: URL] = [:]

    /// Serves `master` cut to the `height` class (nil: every class, cut only
    /// for HDR); nil when it has none or the loopback server can't start.
    @MainActor
    static func publish(_ master: String, from source: URL, keepingHeight height: Int?,
                        preferringHDR: Bool = prefersHDR) async -> URL? {
        guard let text = self.master(master, keepingHeight: height, preferringHDR: preferringHDR),
              let url = await LoopbackPlaylistServer.shared.publish(text) else { return nil }
        sources[url] = source
        return url
    }

    /// A playlist's text: from the loopback server when it's one of ours.
    static func playlistText(at url: URL) async -> String? {
        if let served = LoopbackPlaylistServer.shared.playlist(at: url) { return served }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            AppLogger.youtube.error("Couldn't read the HLS master for its renditions: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    /// The full master a served copy was cut from; nil for anything else.
    @MainActor
    static func source(of url: URL) -> URL? {
        sources[url]
    }
}

#endif
