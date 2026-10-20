/*
 Hypnos - SponsorBlock

 Crowd-sourced skip segments for YouTube videos (sponsor reads, self
 promotion, "like and subscribe", …), from the public SponsorBlock API.
 Ported from the retired web-yt-dlp player.

 The hash-prefix endpoint keeps the lookup private: only the first four hex
 characters of sha256(video id) leave the device, so the server can't tell
 which of the videos sharing that prefix is being watched.

 Segments become `LibraryMediaSegment`s (`.commercial`) so every player
 offers them with the skip button it already has for Jellyfin intros and
 credits (`MediaSegmentSkipper`). Categories marked auto-skip are also
 skipped by themselves, once each, in the video window; a viewer who
 scrubs back into one is left to watch it.
 */

#if HYPNOS_YOUTUBE

import CryptoKit
import DebugTrace
import Foundation

enum SponsorBlockCategory: String, CaseIterable, Identifiable, Sendable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case musicOfftopic = "music_offtopic"
    case filler

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Unpaid / self-promotion"
        case .interaction: "Interaction reminder"
        case .intro: "Intermission / intro"
        case .outro: "Endcards / credits"
        case .preview: "Preview / recap"
        case .musicOfftopic: "Non-music section"
        case .filler: "Filler tangent"
        }
    }

    private var defaultsKey: String { "youtube.sponsorblock.\(rawValue)" }

    /// Off, offered as a skip button, or skipped by itself.
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case off, button, auto
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .button: "Show Skip Button"
            case .auto: "Skip Automatically"
            }
        }
    }

    /// Mirrors the browser extension: sponsors skip by themselves, the
    /// rest are offered.
    private var defaultMode: Mode { self == .sponsor ? .auto : .button }

    var mode: Mode {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Mode.init(rawValue:)) ?? defaultMode }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The segment kind the players' skip button shows.
    var segmentKind: LibraryMediaSegment.Kind {
        switch self {
        case .intro: .intro
        case .outro: .outro
        case .preview: .preview
        default: .commercial
        }
    }
}

enum SponsorBlock {
    static let enabledKey = "youtube.sponsorblock.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    struct Segment: Sendable, Hashable {
        var category: SponsorBlockCategory
        var start: Double
        var end: Double

        var librarySegment: LibraryMediaSegment {
            LibraryMediaSegment(kind: category.segmentKind, startSeconds: start, endSeconds: end)
        }
    }

    /// The enabled categories' segments for `id`, sorted by start. Empty on
    /// any failure: missing segments only mean nothing gets skipped.
    static func segments(for id: YouTubeVideoID) async -> [Segment] {
        guard isEnabled, YouTubeConsent.isGranted else { return [] }
        let categories = SponsorBlockCategory.allCases.filter { $0.mode != .off }
        guard !categories.isEmpty else { return [] }
        let hash = SHA256.hash(data: Data(id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")!
        let names = "[" + categories.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        components.queryItems = [URLQueryItem(name: "categories", value: names)]
        guard let url = components.url else { return [] }

        struct Entry: Decodable {
            struct Item: Decodable {
                let segment: [Double]
                let category: String
                let actionType: String
            }
            let videoID: String
            let segments: [Item]
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            // 404: no segments for any video behind this prefix.
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            let items = entries.first { $0.videoID == id.rawValue }?.segments ?? []
            return items.compactMap { item in
                guard item.actionType == "skip", item.segment.count >= 2,
                      let category = SponsorBlockCategory(rawValue: item.category),
                      item.segment[1] > item.segment[0] else { return nil }
                return Segment(category: category, start: item.segment[0], end: item.segment[1])
            }
            .sorted { $0.start < $1.start }
        } catch {
            AppLogger.youtube.error("SponsorBlock lookup failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return []
        }
    }
}

#endif
