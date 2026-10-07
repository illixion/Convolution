/*
 Hypnos - Gallery Video Model

 Represents a video in the gallery with thumbnail and stream URLs.
 */

import Foundation

/// One Stash caption file: its language ("en"; "00" when untagged) and
/// original format ("srt", "vtt").
struct GalleryCaption: Codable, Hashable, Sendable {
    let languageCode: String
    let type: String
}

struct GalleryVideo: Identifiable, Equatable, Hashable, Codable {
    /// Derived from `identity`, not minted per instance — see
    /// `MediaIdentity.stableID(for:)`. Dropping the stored property also drops
    /// it from the synthesized CodingKeys, so archives that still carry an `id`
    /// simply ignore it.
    var id: UUID { MediaIdentity.stableID(for: identity) }
    /// Stable, source-agnostic key for everything that persists per-video
    /// state: the pseudo-3D depth cache, the 3D-settings tracker, the disk
    /// video cache, the open-window registry, saved window groups.
    ///
    /// For a Stash scene this is the scene id, unchanged, so caches written
    /// before identity was split out of `stashId` still resolve. Local files
    /// use `MediaIdentity.persistentKey(for:)`; direct streams use
    /// `StreamableURLResolver.stableIdentity(for:)`.
    let identity: String
    /// The Stash scene id — non-nil only for videos that actually came from a
    /// Stash server.
    ///
    /// Every GraphQL call site needs this one, not `identity`, and has to cope
    /// with its absence: a local file or a Photos asset has no scene to rate,
    /// mutate or destroy. Passing an identity here would send a container path
    /// or an asset localIdentifier to the server as an id.
    let stashId: String?
    let thumbnailURL: URL
    /// Primary playback URL — always the server's *original* file (direct
    /// stream). WebKit decodes WebM (VP8/VP9) on-device, so playing the original
    /// avoids burning server CPU on a transcode nobody asked for.
    let streamURL: URL
    /// Server-side live transcode of the same scene (HLS `/stream.m3u8`
    /// preferred, else the fragmented `/stream.mp4`), when the server advertises
    /// one and Settings → Server-Side Transcoding is on. It is *not* used for
    /// playback up front; it's the escape hatch for two cases:
    /// 1. the original turns out to be undecodable (`onSourceUnplayable`), and
    /// 2. a feature needs AVFoundation — fake-3D, MV-HEVC, depth pre-process —
    ///    since those decode via AVFoundation and WebM isn't readable by it
    ///    (still true on visionOS 27: VP8 and VP9 both fail the probe).
    let transcodeStreamURL: URL?
    /// Short auto-generated Stash scene preview clip (`/scene/{id}/preview`,
    /// typically 640×360 h264). Drives the gallery long-press quick look.
    /// `nil` for sources with no server-side preview (e.g. local files).
    let previewURL: URL?
    let title: String?
    let duration: TimeInterval?

    // Stereoscopic 3D properties
    let isStereoscopic: Bool
    let stereoscopicFormat: StereoscopicFormat?
    let sourceWidth: Int?
    let sourceHeight: Int?

    /// Whether the left/right eyes are swapped in the source video (detected via "stereo_eyes_reversed" tag)
    let eyesReversed: Bool

    // Stash metadata
    var rating100: Int?
    var oCounter: Int?

    /// Original filename from server (e.g. from files path), used for sharing
    let fileName: String?

    /// Sidecar caption files Stash found beside the scene's file
    /// (`movie.en.srt`), served converted to WebVTT from `captionsURL`.
    let captions: [GalleryCaption]
    /// Stash's `/scene/{id}/caption`; a caption is `?lang=<code>&type=<ext>`.
    let captionsURL: URL?

    init(
        identity: String,
        stashId: String? = nil,
        thumbnailURL: URL,
        streamURL: URL,
        transcodeStreamURL: URL? = nil,
        previewURL: URL? = nil,
        title: String? = nil,
        duration: TimeInterval? = nil,
        isStereoscopic: Bool = false,
        stereoscopicFormat: StereoscopicFormat? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        eyesReversed: Bool = false,
        rating100: Int? = nil,
        oCounter: Int? = nil,
        fileName: String? = nil,
        captions: [GalleryCaption] = [],
        captionsURL: URL? = nil
    ) {
        self.identity = identity
        self.stashId = stashId
        self.thumbnailURL = thumbnailURL
        self.streamURL = streamURL
        self.transcodeStreamURL = transcodeStreamURL
        self.previewURL = previewURL
        self.title = title
        self.duration = duration
        self.isStereoscopic = isStereoscopic
        self.stereoscopicFormat = stereoscopicFormat
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.eyesReversed = eyesReversed
        self.rating100 = rating100
        self.oCounter = oCounter
        self.fileName = fileName
        self.captions = captions
        self.captionsURL = captionsURL
    }

    // MARK: - Codable

    /// Hand-written so archives predating the identity/stashId split still
    /// decode. Those carry a non-optional `stashId` and no `identity`, and that
    /// one field was serving both roles: a scene id for Stash videos, and a
    /// container path or `stream:` hash for everything else.
    ///
    /// So the legacy value becomes `identity` unconditionally — which is what
    /// keeps a restored window pointing at the same depth cache — and only
    /// graduates to `stashId` when it actually looks like a Stash id. Without
    /// that test a restored local video would claim a scene id of
    /// `file:///…/holiday.mp4` and the first GraphQL call made on its behalf
    /// would fail in a thoroughly confusing way.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let legacy = try c.decodeIfPresent(String.self, forKey: .stashId)
        if let identity = try c.decodeIfPresent(String.self, forKey: .identity), !identity.isEmpty {
            self.identity = identity
            self.stashId = legacy.flatMap { MediaIdentity.isStashID($0) ? $0 : nil }
        } else {
            let value = legacy ?? ""
            self.identity = value
            self.stashId = MediaIdentity.isStashID(value) ? value : nil
        }

        self.thumbnailURL = try c.decode(URL.self, forKey: .thumbnailURL)
        self.streamURL = try c.decode(URL.self, forKey: .streamURL)
        self.transcodeStreamURL = try c.decodeIfPresent(URL.self, forKey: .transcodeStreamURL)
        self.previewURL = try c.decodeIfPresent(URL.self, forKey: .previewURL)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.isStereoscopic = try c.decodeIfPresent(Bool.self, forKey: .isStereoscopic) ?? false
        self.stereoscopicFormat = try c.decodeIfPresent(StereoscopicFormat.self, forKey: .stereoscopicFormat)
        self.sourceWidth = try c.decodeIfPresent(Int.self, forKey: .sourceWidth)
        self.sourceHeight = try c.decodeIfPresent(Int.self, forKey: .sourceHeight)
        self.eyesReversed = try c.decodeIfPresent(Bool.self, forKey: .eyesReversed) ?? false
        self.rating100 = try c.decodeIfPresent(Int.self, forKey: .rating100)
        self.oCounter = try c.decodeIfPresent(Int.self, forKey: .oCounter)
        self.fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        self.captions = try c.decodeIfPresent([GalleryCaption].self, forKey: .captions) ?? []
        self.captionsURL = try c.decodeIfPresent(URL.self, forKey: .captionsURL)
    }

    /// A URL suitable for downloading the full video to disk for AVAssetReader
    /// consumption (MV-HEVC conversion, depth pre-processing). Playback prefers
    /// the original file, but AVAssetReader can't read WebM at all, so this
    /// prefers the server transcode when one exists.
    ///
    /// The transcode is normally HLS (`/stream.m3u8`); downloading *that* yields
    /// a playlist text file, not video ("No video track found"), so it's
    /// rewritten to the sibling `/stream.mp4`. AVPlayer rejects that as a live
    /// *stream* (non-seekable chunked pipe), but downloaded to completion it's a
    /// normal fragmented MP4 that AVAssetReader reads fine. With no transcode
    /// available (server can't transcode, or the setting is off) this falls back
    /// to `streamURL` — fine for native MP4/MOV, and the caller surfaces a clear
    /// error for a raw WebM. Auth (apikey / ApiKey header) is layered by callers.
    var transcodedDownloadURL: URL {
        let source = transcodeStreamURL ?? streamURL
        let hlsSuffix = "/stream.m3u8"
        guard source.path.hasSuffix(hlsSuffix),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        else { return source }
        components.path = String(components.path.dropLast(hlsSuffix.count)) + "/stream.mp4"
        return components.url ?? source
    }

    /// Whether a server transcode exists that AVFoundation should be able to
    /// play natively — the route to the native/Metal renderer (and hence fake-3D)
    /// for a source WebKit is currently decoding.
    var hasNativePlayableTranscode: Bool {
        transcodeStreamURL != nil
    }

    /// Formatted duration string (e.g., "1:23:45" or "12:34")
    var formattedDuration: String? {
        guard let duration = duration else { return nil }

        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Local File URL Re-resolution

extension GalleryVideo {
    /// Returns a copy with file URLs re-resolved against the current container.
    ///
    /// The mirror of `GalleryImage.resolvingLocalFileURL()`, and needed for the
    /// same reason: `GalleryVideo` is `Codable` and persisted in
    /// `VideoWindowValue` / `SavedWindowEntry`, so a restored local-file window
    /// carries an absolute URL minted under a previous launch's container UUID.
    /// Without this the window restores pointing at a path that no longer
    /// exists and the video simply never loads.
    ///
    /// Identity is deliberately left alone — `stashId` is already the stable
    /// container-relative key, so it survives the round-trip untouched.
    func resolvingLocalFileURL() -> GalleryVideo {
        guard streamURL.isFileURL,
              let resolved = MediaIdentity.resolvingContainerURL(streamURL),
              resolved != streamURL else { return self }

        return GalleryVideo(
            identity: identity,
            stashId: stashId,
            thumbnailURL: thumbnailURL.isFileURL
                ? (MediaIdentity.resolvingContainerURL(thumbnailURL) ?? thumbnailURL)
                : thumbnailURL,
            streamURL: resolved,
            transcodeStreamURL: transcodeStreamURL,
            previewURL: previewURL,
            title: title,
            duration: duration,
            isStereoscopic: isStereoscopic,
            stereoscopicFormat: stereoscopicFormat,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            eyesReversed: eyesReversed,
            rating100: rating100,
            oCounter: oCounter,
            fileName: fileName,
            captions: captions,
            captionsURL: captionsURL
        )
    }

}
