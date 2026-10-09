/*
 Hypnos - splice a surround track into YouTube's HLS master playlist

 YouTube's master playlist already keeps audio apart from video: each
 `#EXT-X-STREAM-INF` names an `AUDIO` group of `#EXT-X-MEDIA:TYPE=AUDIO`
 renditions (stereo HE-AAC and AAC). So surround needs no remux: add the
 backend's EC-3/AC-3 playlist as one more audio group and point every video
 variant at it. The video playlists stay YouTube's own, untouched.

 The stereo variants are dropped rather than kept beside the surround ones.
 Given both, AVPlayer is free to pick stereo, and a player that may or may
 not play the surround track the user asked for is worse than one that
 reliably does. If the surround playlist fails, the resolver reopens the
 video without it.

 Pure text in, text out, so it is testable without a network.
 */

#if HYPNOS_YOUTUBE

import Foundation

enum YouTubeManifestComposer {
    static let surroundGroupID = "hypnos-surround"

    /// `master` with every video variant moved onto `surround`. Nil when the
    /// playlist has no variant to move (nothing to compose).
    static func compose(master: String, surround: YouTubeSurroundAudio) -> String? {
        let lines = master.components(separatedBy: .newlines)
        var output: [String] = []
        var seenURIs = Set<String>()
        var addedMedia = false
        var variants = 0
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let uri = index + 1 < lines.count ? lines[index + 1] : ""
                index += 2
                var attributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                guard let codecs = attributes.value(for: "CODECS"),
                      let video = videoCodec(in: codecs),
                      !uri.isEmpty, seenURIs.insert(uri).inserted else { continue }
                if !addedMedia {
                    output.append(mediaLine(for: surround))
                    addedMedia = true
                }
                attributes.set("CODECS", quoted: "\(video),\(surround.codecs)")
                attributes.set("AUDIO", quoted: surroundGroupID)
                if let bandwidth = attributes.value(for: "BANDWIDTH").flatMap(Int.init) {
                    // The stereo track YouTube counted was ≤ 160 kbps.
                    attributes.set("BANDWIDTH", bare: String(bandwidth + surround.bandwidth))
                }
                attributes.remove("AVERAGE-BANDWIDTH")
                output.append("#EXT-X-STREAM-INF:" + attributes.serialized)
                output.append(uri)
                variants += 1
                continue
            }
            // YouTube's stereo renditions: nothing points at them any more.
            if line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=AUDIO") {
                index += 1
                continue
            }
            output.append(line)
            index += 1
        }
        return variants > 0 ? output.joined(separator: "\n") : nil
    }

    private static func mediaLine(for surround: YouTubeSurroundAudio) -> String {
        var attributes = AttributeList()
        attributes.set("TYPE", bare: "AUDIO")
        attributes.set("GROUP-ID", quoted: surroundGroupID)
        attributes.set("NAME", quoted: "Surround \(surround.channels == 6 ? "5.1" : "\(surround.channels)ch")")
        if let language = surround.language, !language.isEmpty {
            attributes.set("LANGUAGE", quoted: language)
        }
        attributes.set("CHANNELS", quoted: String(surround.channels))
        attributes.set("DEFAULT", bare: "YES")
        attributes.set("AUTOSELECT", bare: "YES")
        attributes.set("URI", quoted: surround.playlistURL.absoluteString)
        return "#EXT-X-MEDIA:" + attributes.serialized
    }

    /// The video half of a `CODECS` value ("avc1.640028,mp4a.40.2" → "avc1.640028").
    static func videoCodec(in codecs: String) -> String? {
        let videoPrefixes = ["avc1", "avc3", "hvc1", "hev1", "vp09", "vp9", "av01", "dvh1", "dvhe"]
        return codecs.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { codec in videoPrefixes.contains { codec.lowercased().hasPrefix($0) } }
    }

    // MARK: - Attribute lists (RFC 8216 §4.2)

    struct AttributeList {
        fileprivate var entries: [(key: String, raw: String)] = []

        func value(for key: String) -> String? {
            guard let raw = entries.first(where: { $0.key == key })?.raw else { return nil }
            return raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2
                ? String(raw.dropFirst().dropLast()) : raw
        }

        mutating func set(_ key: String, quoted value: String) { set(key, raw: "\"\(value)\"") }
        mutating func set(_ key: String, bare value: String) { set(key, raw: value) }

        mutating func remove(_ key: String) { entries.removeAll { $0.key == key } }

        private mutating func set(_ key: String, raw: String) {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                entries[i].raw = raw
            } else {
                entries.append((key, raw))
            }
        }

        var serialized: String { entries.map { "\($0.key)=\($0.raw)" }.joined(separator: ",") }
    }

    static func parseAttributes(_ text: String) -> AttributeList {
        var list = AttributeList()
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { list.entries.append((k, value)) }
            key = ""
            value = ""
            inKey = true
        }
        for character in text {
            if inKey {
                if character == "=" { inKey = false } else { key.append(character) }
                continue
            }
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                flush()
            } else {
                value.append(character)
            }
        }
        flush()
        return list
    }
}

#endif
