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

    /// Short, for "Skipped …" under the window.
    var shortName: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self-Promotion"
        case .interaction: "Reminder"
        case .intro: "Intro"
        case .outro: "Endcards"
        case .preview: "Preview"
        case .musicOfftopic: "Non-Music"
        case .filler: "Filler"
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
    static let serverKey = "youtube.sponsorblock.server"
    static let defaultServer = "https://sponsor.ajay.app"

    /// Opt-in (decided 2026-11-08): off until the viewer turns it on in
    /// Settings, because every lookup is a request to a third party. Nothing
    /// here reaches the network while it is off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    /// The server to ask: the viewer's own (a self-hosted one, or the dev server
    /// from `scripts/dev-sponsorblock.sh`) or SponsorBlock's.
    static var serverURL: URL {
        let saved = UserDefaults.standard.string(forKey: serverKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        if let url = URL(string: saved), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           url.host != nil {
            return url
        }
        return URL(string: defaultServer)!
    }

    /// "Name/Version", which the API asks every client to send.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Convolution/\(version)"
    }

    struct Segment: Sendable, Hashable {
        var category: SponsorBlockCategory
        var start: Double
        var end: Double
        /// The server's id for it, which voting needs.
        var uuid: String = ""
        /// The length of the video the segment was cut for; 0 when unknown.
        var videoDuration: Double = 0

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
        var components = URLComponents(url: serverURL.appendingPathComponent("api/skipSegments/\(hash.prefix(4))"), resolvingAgainstBaseURL: false)!
        let names = "[" + categories.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        components.queryItems = [URLQueryItem(name: "categories", value: names)]
        guard let url = components.url else { return [] }

        struct Entry: Decodable {
            struct Item: Decodable {
                let segment: [Double]
                let category: String
                let actionType: String
                let UUID: String?
                let videoDuration: Double?
            }
            let videoID: String
            let segments: [Item]
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            // 404: no segments for any video behind this prefix.
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            let items = entries.first { $0.videoID == id.rawValue }?.segments ?? []
            return items.compactMap { item in
                guard item.actionType == "skip", item.segment.count >= 2,
                      let category = SponsorBlockCategory(rawValue: item.category),
                      item.segment[1] > item.segment[0] else { return nil }
                return Segment(category: category, start: item.segment[0], end: item.segment[1],
                               uuid: item.UUID ?? "", videoDuration: item.videoDuration ?? 0)
            }
            .sorted { $0.start < $1.start }
        } catch {
            AppLogger.youtube.error("SponsorBlock lookup failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return []
        }
    }
}

// MARK: - Submitting

/// This installation's SponsorBlock identity: a random private id the server
/// only ever sees hashed, kept in the Keychain. Losing it loses the
/// submissions' attribution and reputation.
enum SponsorBlockIdentity {
    /// The server wants 32 or more characters of its own choosing.
    private static let length = 40

    static var userID: String {
        if let saved = KeychainStore.string(for: .sponsorBlockUserID), saved.count >= 32 { return saved }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        let fresh = String((0 ..< length).map { _ in alphabet.randomElement(using: &generator)! })
        KeychainStore.set(fresh, for: .sponsorBlockUserID)
        return fresh
    }
}

/// A segment a person timed and wants to send.
struct SponsorBlockDraft: Sendable, Equatable {
    var category: SponsorBlockCategory
    var start: Double
    var end: Double

    var isValid: Bool { start >= 0 && end > start && (end - start) >= 0.5 }
}

enum SponsorBlockSubmitError: LocalizedError {
    case notEnabled
    case rejected(status: Int, message: String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled: "Turn on SponsorBlock in Settings first."
        case .rejected(let status, let message):
            switch status {
            case 409: "That segment was already submitted."
            case 429: "Too many submissions for now. Try again later."
            default: message.isEmpty ? "SponsorBlock refused the segment (\(status))." : message
            }
        case .network(let text): "Couldn't reach SponsorBlock: \(text)"
        }
    }
}

extension SponsorBlock {
    /// Sends one segment the viewer timed by hand. SponsorBlock forbids
    /// automated submission, so this is only called from a button the person
    /// pressed after choosing both ends themselves. Returns the segment's UUID.
    static func submit(_ draft: SponsorBlockDraft, for id: YouTubeVideoID, videoDuration: Double) async throws -> String {
        guard isEnabled, YouTubeConsent.isGranted else { throw SponsorBlockSubmitError.notEnabled }
        struct Body: Encodable {
            struct Item: Encodable {
                let segment: [Double]
                let category: String
                let actionType: String
            }
            let videoID: String
            let userID: String
            let userAgent: String
            let service: String
            let videoDuration: Double
            let segments: [Item]
        }
        let body = Body(
            videoID: id.rawValue, userID: SponsorBlockIdentity.userID, userAgent: userAgent, service: "YouTube",
            videoDuration: videoDuration.isFinite ? videoDuration : 0,
            segments: [.init(segment: [draft.start, draft.end].map { ($0 * 1000).rounded() / 1000 },
                             category: draft.category.rawValue, actionType: "skip")])
        var request = URLRequest(url: serverURL.appendingPathComponent("api/skipSegments"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw SponsorBlockSubmitError.rejected(status: status, message: String(decoding: data.prefix(400), as: UTF8.self))
            }
            struct Reply: Decodable { let UUID: String }
            let uuid = (try? JSONDecoder().decode([Reply].self, from: data))?.first?.UUID ?? ""
            AppLogger.youtube.info("SponsorBlock: submitted \(draft.category.rawValue, privacy: .public)")
            return uuid
        } catch let error as SponsorBlockSubmitError {
            throw error
        } catch {
            throw SponsorBlockSubmitError.network(error.localizedDescription)
        }
    }
}

extension SponsorBlock {
    /// Votes on a segment: 1 up, 0 down, 20 takes the viewer's vote back.
    static func vote(segmentID: String, type: Int) async throws {
        guard isEnabled, YouTubeConsent.isGranted else { throw SponsorBlockSubmitError.notEnabled }
        // The server reads a vote's fields from the query string (the browser
        // extension does the same); a JSON body is answered with 400.
        var components = URLComponents(url: serverURL.appendingPathComponent("api/voteOnSponsorTime"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "UUID", value: segmentID),
                                 URLQueryItem(name: "userID", value: SponsorBlockIdentity.userID),
                                 URLQueryItem(name: "type", value: String(type))]
        guard let url = components.url else { throw SponsorBlockSubmitError.network("bad server address") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw SponsorBlockSubmitError.rejected(status: status, message: String(decoding: data.prefix(300), as: UTF8.self))
            }
        } catch let error as SponsorBlockSubmitError {
            throw error
        } catch {
            throw SponsorBlockSubmitError.network(error.localizedDescription)
        }
    }
}

#endif
