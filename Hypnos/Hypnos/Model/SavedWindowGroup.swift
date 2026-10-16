/*
 Hypnos - Saved Window Group

 A user-saved named arrangement of windows, for restoring it later.

 A group is heterogeneous by design: what the user is saving is an arrangement
 of *windows* in the room, not a set of images, so a single group can mix photo
 pop-outs, video pop-outs and slideshow windows. Each entry also carries the window's size at
 save time so the restored arrangement comes back at the geometry it was left
 at rather than the scene default.
 */

import CoreGraphics
import Foundation
import RAVEMedia
import RAVEUI

/// One window inside a saved group.
///
/// Deliberately a flat struct with per-kind optionals rather than an enum with
/// associated values: `init(from:)` can then use `decodeIfPresent` throughout,
/// so persisted groups survive new fields being added (the same reason
/// `Pseudo3DSettings` hand-writes its decoder).
struct SavedWindowEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case photo
        case video
        /// A slideshow window (the picture or the video profile). The raw value
        /// keeps its original spelling, as saved groups persist it.
        case remote
        /// A kind written by a newer build than this one. Dropped on load rather
        /// than failing the decode of the whole group.
        case unknown

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// Identity of this entry within the group (not the window's runtime id —
    /// a restored window always gets a fresh window-value UUID).
    let id: UUID
    var kind: Kind

    /// Window size at save time, in points. `nil` when the window never
    /// reported a size, in which case the restored window sizes itself the way
    /// a fresh open would.
    var size: RAVECodableSize?

    // MARK: Photo

    var image: GalleryImage?

    // MARK: Video

    var video: GalleryVideo?
    /// Snapshot of the window's 3D intent, so a video restored into a group
    /// comes back in the mode it was being watched in.
    var videoStereoscopicOverride: Bool?
    var video3DSettings: Video3DSettings?
    var videoPseudo3DEnabled: Bool
    /// Only ever a *genuine* per-window override — see the note in
    /// `Pseudo3DSettings` about why an unmodified value must not be snapshotted.
    var videoPseudo3DSettings: Pseudo3DSettings?

    // MARK: Slideshow

    var remoteConfigId: UUID?
    /// Profile name snapshotted at save time.
    var remoteName: String?

    // MARK: - Init

    private init(
        kind: Kind,
        size: CGSize?,
        image: GalleryImage? = nil,
        video: GalleryVideo? = nil,
        videoStereoscopicOverride: Bool? = nil,
        video3DSettings: Video3DSettings? = nil,
        videoPseudo3DEnabled: Bool = false,
        videoPseudo3DSettings: Pseudo3DSettings? = nil,
        remoteConfigId: UUID? = nil,
        remoteName: String? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.size = size.map(RAVECodableSize.init)
        self.image = image
        self.video = video
        self.videoStereoscopicOverride = videoStereoscopicOverride
        self.video3DSettings = video3DSettings
        self.videoPseudo3DEnabled = videoPseudo3DEnabled
        self.videoPseudo3DSettings = videoPseudo3DSettings
        self.remoteConfigId = remoteConfigId
        self.remoteName = remoteName
    }

    static func photo(_ image: GalleryImage, size: CGSize? = nil) -> SavedWindowEntry {
        SavedWindowEntry(kind: .photo, size: size, image: image)
    }

    static func video(
        _ video: GalleryVideo,
        size: CGSize? = nil,
        stereoscopicOverride: Bool? = nil,
        settings3D: Video3DSettings? = nil,
        pseudo3DEnabled: Bool = false,
        pseudo3DSettings: Pseudo3DSettings? = nil
    ) -> SavedWindowEntry {
        SavedWindowEntry(
            kind: .video,
            size: size,
            video: video,
            videoStereoscopicOverride: stereoscopicOverride,
            video3DSettings: settings3D,
            videoPseudo3DEnabled: pseudo3DEnabled,
            videoPseudo3DSettings: pseudo3DSettings
        )
    }

    static func remote(
        configId: UUID,
        name: String,
        size: CGSize? = nil
    ) -> SavedWindowEntry {
        SavedWindowEntry(
            kind: .remote,
            size: size,
            remoteConfigId: configId,
            remoteName: name
        )
    }

    // MARK: - Codable (tolerant of missing / future fields)

    private enum CodingKeys: String, CodingKey {
        case id, kind, size, image, video
        case videoStereoscopicOverride, video3DSettings
        case videoPseudo3DEnabled, videoPseudo3DSettings
        case remoteConfigId, remoteName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .unknown
        self.size = try container.decodeIfPresent(RAVECodableSize.self, forKey: .size)
        self.image = try container.decodeIfPresent(GalleryImage.self, forKey: .image)
        self.video = try container.decodeIfPresent(GalleryVideo.self, forKey: .video)
        self.videoStereoscopicOverride = try container.decodeIfPresent(Bool.self, forKey: .videoStereoscopicOverride)
        self.video3DSettings = try container.decodeIfPresent(Video3DSettings.self, forKey: .video3DSettings)
        self.videoPseudo3DEnabled = try container.decodeIfPresent(Bool.self, forKey: .videoPseudo3DEnabled) ?? false
        self.videoPseudo3DSettings = try container.decodeIfPresent(Pseudo3DSettings.self, forKey: .videoPseudo3DSettings)
        self.remoteConfigId = try container.decodeIfPresent(UUID.self, forKey: .remoteConfigId)
        self.remoteName = try container.decodeIfPresent(String.self, forKey: .remoteName)
    }

    // MARK: - Validity

    /// Whether this entry can actually be restored. Guards against a group
    /// written by a newer build, or a half-written entry.
    var isRestorable: Bool {
        switch kind {
        case .photo: return image != nil
        case .video: return video != nil
        case .remote: return remoteConfigId != nil
        case .unknown: return false
        }
    }

    /// Stable key identifying *what* this window shows, used to avoid offering
    /// an already-present window when adding open windows to a group.
    var dedupeKey: String {
        switch kind {
        case .photo:
            return "photo:\(image?.identity ?? "?")"
        case .video:
            guard let video else { return "video:?" }
            return "video:\(video.identity.isEmpty ? video.streamURL.absoluteString : video.identity)"
        case .remote:
            return "remote:\(remoteConfigId?.uuidString ?? "?")"
        case .unknown:
            return "unknown:\(id.uuidString)"
        }
    }

    // MARK: - Presentation

    /// Thumbnail to render on the entry's tile. `nil` for windows that have no
    /// meaningful still image (slideshows) — those get a textual tile instead.
    var thumbnailURL: URL? {
        switch kind {
        case .photo: return image?.thumbnailURL
        case .video: return video?.thumbnailURL
        case .remote, .unknown: return nil
        }
    }

    var displayTitle: String {
        switch kind {
        case .photo:
            return image?.title ?? image?.fileName ?? "Photo"
        case .video:
            return video?.title ?? video?.fileName ?? "Video"
        case .remote:
            let name = remoteName?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? "Slideshow" : name
        case .unknown:
            return "Unsupported Window"
        }
    }

    /// Second line on the tile: what kind of window this is.
    var displaySubtitle: String? {
        switch kind {
        case .photo:
            return nil
        case .video:
            guard let duration = video?.duration, duration > 0 else { return "Video" }
            let total = Int(duration.rounded())
            return String(format: "Video · %d:%02d", total / 60, total % 60)
        case .remote:
            return "Slideshow"
        case .unknown:
            return "Saved by a newer version"
        }
    }

    var systemImage: String {
        switch kind {
        case .photo: return "photo"
        case .video: return "film"
        case .remote: return "play.rectangle"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    /// "1200×800", or nil when no size was captured.
    var sizeDescription: String? {
        guard let size, size.width > 2, size.height > 2 else { return nil }
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    /// Re-resolves any local file URLs against the current sandbox container.
    /// Covers video entries as well as photo ones — a restored local video
    /// window was previously left holding a path from a dead container.
    func resolvingLocalFileURLs() -> SavedWindowEntry {
        var copy = self
        switch kind {
        case .photo:
            guard let image else { return self }
            copy.image = image.resolvingLocalFileURL()
        case .video:
            guard let video else { return self }
            copy.video = video.resolvingLocalFileURL()
        default:
            return self
        }
        return copy
    }
}

struct SavedWindowGroup: Codable, Identifiable {
    let id: UUID
    var name: String
    var entries: [SavedWindowEntry]
    let savedDate: Date

    init(name: String, entries: [SavedWindowEntry]) {
        self.id = UUID()
        self.name = name
        self.entries = entries
        self.savedDate = Date()
    }

    // MARK: - Codable (with legacy migration)

    private enum CodingKeys: String, CodingKey {
        case id, name, entries, savedDate
        /// Pre-refactor groups stored a bare `[GalleryImage]` — photo pop-outs
        /// were the only window type a group could hold.
        case images
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Window Group"
        self.savedDate = try container.decodeIfPresent(Date.self, forKey: .savedDate) ?? Date()

        if let entries = try container.decodeIfPresent([SavedWindowEntry].self, forKey: .entries) {
            self.entries = entries
        } else {
            let legacy = try container.decodeIfPresent([GalleryImage].self, forKey: .images) ?? []
            self.entries = legacy.map { SavedWindowEntry.photo($0) }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(entries, forKey: .entries)
        try container.encode(savedDate, forKey: .savedDate)
    }

    // MARK: - Summary

    /// "3 photos · 1 video · 2 slideshows" — the counts a user needs to tell
    /// two saved arrangements apart at a glance.
    var contentSummary: String {
        var parts: [String] = []
        func append(_ count: Int, _ singular: String, _ plural: String) {
            guard count > 0 else { return }
            parts.append("\(count) \(count == 1 ? singular : plural)")
        }
        append(entries.filter { $0.kind == .photo }.count, "photo", "photos")
        append(entries.filter { $0.kind == .video }.count, "video", "videos")
        append(entries.filter { $0.kind == .remote }.count, "slideshow", "slideshows")
        return parts.isEmpty ? "empty" : parts.joined(separator: " · ")
    }
}
