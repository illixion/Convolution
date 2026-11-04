/*
 Hypnos - what a player is doing, for its playback info panel

 The panel in the top-right corner of the video window says how the picture
 gets here (the route), what it is (size, rate, dynamic range) and, when the
 route is a fallback, why. A server that transcodes because something on the
 way failed used to do so silently: an episode whose remux was declined
 played Jellyfin's single-audio AAC transcode with nothing on screen saying
 so (2026-11-04). Everything here is code-defined text: no titles, paths or
 server addresses, so the debug endpoint can report it as it is.
 */

import Foundation

struct PlaybackInfo: Equatable {
    enum Route: Equatable {
        /// The renderer is still being chosen.
        case opening
        /// The original file, decoded on this device.
        case direct
        /// The original's streams repackaged on this device, losslessly
        /// (MKV/WebM to fragmented MP4).
        case deviceRemux
        /// The server repackages the file and copies its video.
        case serverRemux
        /// The server re-encodes the video.
        case serverTranscode
        /// The web view plays the original.
        case webPlayer
        /// YouTube's own streams.
        case youTube

        var title: String {
            switch self {
            case .opening: "Opening"
            case .direct: "Direct Play"
            case .deviceRemux: "Remuxed on Device"
            case .serverRemux: "Server Remux"
            case .serverTranscode: "Server Transcode"
            case .webPlayer: "Web Player"
            case .youTube: "YouTube Stream"
            }
        }

        var symbol: String {
            switch self {
            case .opening: "hourglass"
            case .direct: "checkmark.circle.fill"
            case .deviceRemux: "arrow.triangle.2.circlepath.circle.fill"
            case .serverRemux, .serverTranscode: "server.rack"
            case .webPlayer: "safari.fill"
            case .youTube: "play.rectangle.fill"
            }
        }

        /// What the route means, for the details.
        var explanation: String {
            switch self {
            case .opening: "Choosing how to play this video."
            case .direct: "The original file, decoded on this device."
            case .deviceRemux: "The original video and audio, repackaged on this device without re-encoding."
            case .serverRemux: "The server repackages the file and sends the video as it is."
            case .serverTranscode: "The server re-encodes the video before sending it."
            case .webPlayer: "The web view plays the original. It can't show HDR or play in 3D, and AI 3D needs a server transcode."
            case .youTube: "YouTube's own streams, played natively."
            }
        }

        /// The route converts or loses something the original has.
        var isServerConversion: Bool { self == .serverRemux || self == .serverTranscode }
    }

    /// How the panel colours the route.
    enum Severity: Equatable {
        /// What this video would play as anyway.
        case normal
        /// A fallback the viewer or a feature chose: a quality cap, AI 3D's
        /// 1080p, the MKV setting.
        case chosen
        /// A fallback because something failed on the way.
        case issue
    }

    var route: Route
    var severity: Severity
    /// "Jellyfin", "Stash", for a server route.
    var server: String?
    /// Why the route is what it is, most telling first: "the remux on this
    /// device declined it: …", "quality set to 10 Mbps".
    var reasons: [String]
    /// "1920×1080 · 23.976 fps".
    var picture: String?
    var range: VideoDynamicRange?
    /// The range was read off the frames, not only the source's metadata.
    var rangeFromFrames: Bool
    /// What the server's encoder does, when it said.
    var transcode: LibraryTranscodeInfo?
    /// "HEVC Main 10 · 10-bit · Dolby Vision 8.1 · 4.4 Mbps · MKV".
    var source: String?

    /// The one line under the readout: the first reason, else a range note.
    var headline: String? {
        if severity != .normal, let first = reasons.first { return first.prefix(1).uppercased() + first.dropFirst() }
        if let note = range?.note, range?.isReduced == true { return note.prefix(1).uppercased() + note.dropFirst() }
        return nil
    }

    /// "1920×1080 · 23.976 fps · HDR10".
    var readout: String? {
        let parts = [picture, range.map(Self.rangeText)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func rangeText(_ range: VideoDynamicRange) -> String {
        range.label
    }

    /// The panel shows under the visibility setting: always, or when the
    /// route is a fallback or the picture lost something.
    func isShown(_ visibility: PlaybackInfoVisibility) -> Bool {
        switch visibility {
        case .always: route != .opening || picture != nil
        case .whenDegraded: severity == .issue || range?.isReduced == true
        case .never: false
        }
    }
}

/// Settings → Videos → Playback Info.
enum PlaybackInfoVisibility: String, CaseIterable, Sendable {
    case always
    case whenDegraded
    case never

    static let key = "player.playbackInfo"

    var label: String {
        switch self {
        case .always: "Always"
        case .whenDegraded: "When Something's Off"
        case .never: "Never"
        }
    }
}
