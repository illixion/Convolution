import Foundation

/// What AI captions need from an HLS playlist: which audio a master offers,
/// and the media playlist's segments on the player's timeline.
public struct HLSPlaylist: Sendable {
    public struct Rendition: Sendable, Equatable {
        public var groupID: String?
        public var name: String?
        public var language: String?
        /// Absent when the audio is muxed into the variants' own segments.
        public var url: URL?
        public var isDefault: Bool
    }

    public struct Variant: Sendable, Equatable {
        public var bandwidth: Int
        public var url: URL
    }

    public struct Segment: Sendable, Equatable {
        public var url: URL
        public var byteRange: Range<Int>?
        /// Seconds on the playlist's timeline, which is the player's.
        public var start: Double
        public var duration: Double
    }

    /// The initialization segment of fragmented-MP4 segments.
    public struct Map: Sendable, Equatable {
        public var url: URL
        public var byteRange: Range<Int>?
    }

    public private(set) var renditions: [Rendition] = []
    public private(set) var variants: [Variant] = []
    public private(set) var segments: [Segment] = []
    public private(set) var map: Map?
    /// Segments are encrypted (`EXT-X-KEY` with a method other than NONE).
    public private(set) var isEncrypted = false
    public private(set) var hasEnd = false

    public var isMaster: Bool { !variants.isEmpty }

    public init(_ text: String, base: URL) {
        var pendingDuration = 0.0
        var pendingRange: Range<Int>?
        var pendingVariantBandwidth: Int?
        var time = 0.0
        // A byte range with no offset continues the previous one.
        var nextOffset = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let value = line.removingPrefix("#EXT-X-MEDIA:") {
                    let attributes = Self.attributes(value)
                    guard attributes["TYPE"] == "AUDIO" else { continue }
                    renditions.append(Rendition(
                        groupID: attributes["GROUP-ID"], name: attributes["NAME"], language: attributes["LANGUAGE"],
                        url: attributes["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                        isDefault: attributes["DEFAULT"] == "YES"))
                } else if let value = line.removingPrefix("#EXT-X-STREAM-INF:") {
                    pendingVariantBandwidth = Int(Self.attributes(value)["BANDWIDTH"] ?? "") ?? 0
                } else if let value = line.removingPrefix("#EXT-X-MAP:") {
                    let attributes = Self.attributes(value)
                    if let uri = attributes["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                        map = Map(url: url, byteRange: attributes["BYTERANGE"].flatMap { Self.range($0, after: 0) })
                    }
                } else if let value = line.removingPrefix("#EXT-X-KEY:") {
                    if let method = Self.attributes(value)["METHOD"], method != "NONE" { isEncrypted = true }
                } else if let value = line.removingPrefix("#EXTINF:") {
                    pendingDuration = Double(value.split(separator: ",").first ?? "") ?? 0
                } else if let value = line.removingPrefix("#EXT-X-BYTERANGE:") {
                    pendingRange = Self.range(value, after: nextOffset)
                } else if line == "#EXT-X-ENDLIST" {
                    hasEnd = true
                }
                continue
            }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            if let bandwidth = pendingVariantBandwidth {
                variants.append(Variant(bandwidth: bandwidth, url: url))
                pendingVariantBandwidth = nil
            } else {
                segments.append(Segment(url: url, byteRange: pendingRange, start: time, duration: pendingDuration))
                time += pendingDuration
                if let pendingRange { nextOffset = pendingRange.upperBound }
                pendingDuration = 0
                pendingRange = nil
            }
        }
    }

    /// The first segment that ends after `time`: where a read from there starts.
    public func firstSegment(after time: Double) -> Int {
        segments.firstIndex { $0.start + $0.duration > time } ?? segments.count
    }

    /// The audio rendition the player has selected: by name (unique within a
    /// group), else language, else the default one, else the first.
    public func rendition(name: String?, language: String?) -> Rendition? {
        let candidates = renditions.filter { $0.url != nil }
        if let name, let match = candidates.first(where: { $0.name == name }) { return match }
        if let language {
            let wanted = Self.normalized(language)
            if let match = candidates.first(where: { $0.language.map(Self.normalized) == wanted }) { return match }
            let code = wanted.split(separator: "-").first
            if let match = candidates.first(where: { $0.language.map(Self.normalized)?.split(separator: "-").first == code }) { return match }
        }
        return candidates.first(where: \.isDefault) ?? candidates.first
    }

    static func normalized(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// `KEY=value,KEY="quoted, value"` as a dictionary.
    static func attributes(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        func commit() {
            if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""; value = ""; readingKey = true
        }
        for character in list {
            if quoted {
                if character == "\"" { quoted = false } else { value.append(character) }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                commit()
            } else if character == "=", readingKey {
                readingKey = false
            } else if readingKey {
                key.append(character)
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }

    /// `length@offset`, or `length` continuing from `previousEnd`.
    static func range(_ text: String, after previousEnd: Int) -> Range<Int>? {
        let parts = text.split(separator: "@")
        guard let length = parts.first.flatMap({ Int($0) }), length > 0 else { return nil }
        let offset = parts.count > 1 ? Int(parts[1]) ?? previousEnd : previousEnd
        return offset ..< offset + length
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
