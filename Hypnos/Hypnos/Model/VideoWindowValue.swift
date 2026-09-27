/*
 Hypnos - Video Window Value

 Wrapper around GalleryVideo with a unique instance ID for pop-out video windows.
 Snapshots the stereoscopic mode and 3D settings at pop-out time so the window
 is independent of the main window's video state.
 */

import Foundation
import RAVEMedia
import RAVEUI

struct VideoWindowValue: Identifiable, Codable, Hashable {
    /// Unique per window instance — ensures visionOS treats each opening as a new window
    let id: UUID
    var video: GalleryVideo

    /// Complete sibling list for prev/next navigation. Used by sources not backed
    /// by `appModel.galleryVideos` (e.g. the Local tab), so the window navigates
    /// this fixed list instead of the (Stash) app gallery. nil = fall back to the
    /// app gallery snapshot with lazy pagination.
    var galleryVideos: [GalleryVideo]?

    /// Snapshot of stereoscopic override at pop-out time (nil = auto-detect, true = 3D, false = 2D)
    var stereoscopicOverride: Bool?

    /// Snapshot of custom 3D settings at pop-out time
    var video3DSettings: Video3DSettings?

    /// Snapshot of real-time fake-3D intent at pop-out time
    var pseudo3DEnabled: Bool

    /// Snapshot of fake-3D depth tuning at pop-out time
    var pseudo3DSettings: Pseudo3DSettings?

    /// Whether this window was opened via pushWindow (back button dismisses)
    /// vs openWindow (standalone pop-out with gallery button)
    var wasPushed: Bool

    /// Geometry to open at, set when the window is restored from a saved window
    /// group. The video window's aspect lock fits the video inside this box
    /// instead of its default cap, so a saved arrangement comes back at the size
    /// the user left it at. `nil` on ordinary opens.
    var restoredSize: RAVECodableSize?

    /// Where to start playing, in seconds: the Library's Resume. Applied
    /// once, to `video` only (not to siblings navigated to afterwards).
    var startSeconds: Double?

    init(
        video: GalleryVideo,
        galleryVideos: [GalleryVideo]? = nil,
        stereoscopicOverride: Bool? = nil,
        video3DSettings: Video3DSettings? = nil,
        pseudo3DEnabled: Bool = false,
        pseudo3DSettings: Pseudo3DSettings? = nil,
        wasPushed: Bool = false
    ) {
        self.id = UUID()
        self.video = video
        self.galleryVideos = galleryVideos
        self.stereoscopicOverride = stereoscopicOverride
        self.video3DSettings = video3DSettings
        self.pseudo3DEnabled = pseudo3DEnabled
        self.pseudo3DSettings = pseudo3DSettings
        self.wasPushed = wasPushed
        self.restoredSize = nil
    }

    /// Identity is the window id alone — see the note on `PhotoWindowValue`: a
    /// synthesized conformance folds in every mutable field, so a tracked value
    /// stops matching its own scene the moment one of them changes and
    /// `openWindow(id:value:)` spawns a duplicate instead of summoning.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Local File URL Re-resolution

extension VideoWindowValue {
    /// Re-resolves local file URLs in this value against the current container.
    ///
    /// Applied at window construction, the same place `PhotoWindowView` does it
    /// for images: a visionOS scene restoration replays a value archived under a
    /// previous launch's container UUID, so every `file://` URL inside it is
    /// stale. The navigation snapshot needs it too, not just the current video —
    /// otherwise prev/next lands on dead paths.
    func resolvingLocalFileURLs() -> VideoWindowValue {
        var copy = self
        copy.video = video.resolvingLocalFileURL()
        copy.galleryVideos = galleryVideos?.map { $0.resolvingLocalFileURL() }
        return copy
    }
}
