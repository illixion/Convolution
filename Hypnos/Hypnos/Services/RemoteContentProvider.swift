/*
 Hypnos - Remote Content Provider

 SlideshowContentProvider implementation that consumes posts pushed by
 the RoboFrame server's `playback` channel. The server is the single
 DuckDB reader and broadcasts `playback { current, next }` frames over
 the WebSocket. RemoteViewerModel feeds those posts into the buffer below
 via `enqueueFromPlayback`, and the engine's prefetch loop pulls them out
 through `fetchMoreContent`.
 */

import CoreGraphics
import DebugTrace
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

@MainActor
class RemoteContentProvider: SlideshowContentProvider {
    let apiClient: RemoteAPIClient
    let baseURL: String
    let accessToken: String
    /// This window's WS channel id, recorded with each displayed post so the
    /// server's /history page groups them under this display.
    let deviceId: String

    /// Posts the server has nominated via `playback`. Drained by the
    /// engine's prefetch loop on each `fetchMoreContent` call.
    private var pending: [RemotePost] = []

    /// IDs already enqueued via `playback`. Used to suppress duplicate
    /// frames the server sometimes emits at session start — without this
    /// the engine would prefetch and visibly display the same pair twice
    /// (A → B → A → B …) before catching up to the next push. Cleared on
    /// `resetPagination` so a tag-list / remote jump can resurface the
    /// same ids legitimately.
    private var seenIds: Set<Int> = []

    init(apiClient: RemoteAPIClient, baseURL: String, accessToken: String, deviceId: String) {
        self.apiClient = apiClient
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.deviceId = deviceId
    }

    /// Called by RemoteViewerModel when a `playback` frame arrives. The posts
    /// here are the server's `current` / `next` reconstructed from the playback
    /// payload (just id + ext; other fields are nil — the engine only uses
    /// `_id`, `file_ext`, and `tags` for routing).
    func enqueueFromPlayback(_ posts: [RemotePost]) {
        for post in posts where !seenIds.contains(post._id) {
            pending.append(post)
            seenIds.insert(post._id)
        }
    }

    func fetchMoreContent(
        tagQuery: String,
        ratioRange: String?,
        blockedPosts: Set<Int>,
        blockedTags: Set<String>
    ) async -> [RemotePost] {
        if !pending.isEmpty {
            let drained = pending
            pending.removeAll()
            return drained.filter { post in
                !blockedPosts.contains(post._id) &&
                !post.tags.contains(where: { blockedTags.contains($0) })
            }
        }
        // Yield a beat so the engine's prefetch loop doesn't tight-spin
        // between server pushes when the channel is paused or briefly
        // empty between ticks.
        try? await Task.sleep(for: .milliseconds(500))
        return []
    }

    func downloadImage(for post: RemotePost, maxResolution: Int) async -> DownloadedMedia? {
        guard let imageURL = resolveImageURL(for: post) else { return nil }

        let maxDim = CGFloat(maxResolution)
        return await Task.detached {
            do {
                let (data, response) = try await URLSession.shared.data(from: imageURL)
                // An animated post comes back as H.264 mp4 (we request
                // vcodec=h264): it can't be decoded as a still, so hand it to
                // the video-in-<img> path instead of the texture pipeline.
                if (response.mimeType ?? "").hasPrefix("video/") {
                    return .video(url: imageURL)
                }
                // Skip downsampling for animated formats — the thumbnail API
                // returns only the first frame, which kills animation in
                // both the HEVC converter (needs original GIF bytes) and
                // the WKWebView path (the static UIImage is fine, but we
                // want the full-resolution first frame as the crossfade
                // preview to match what the animation will display).
                let effectiveMax: CGFloat = (data.isAnimatedGIF || data.isAnimatedWebP || data.isAnimatedJXL) ? 0 : maxDim
                guard let image = MetalImageRenderer.downsampledImage(from: data, maxDimension: effectiveMax) else {
                    return nil
                }
                return .still(image: image, data: data)
            } catch {
                AppLogger.remoteViewer.error("Failed to load post \(post._id, privacy: .private(mask: .hash)): \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                return nil
            }
        }.value
    }

    func resolveImageURL(for post: RemotePost) -> URL? {
        // Fetch the raw source (no transcode). Don't record on fetch —
        // onPostDisplayed records authoritatively with our deviceId once shown.
        // Serving raw means: still/animated images arrive as their real bytes
        // (animated JXL is decoded on-device, not converted to mp4), and video
        // posts get their source file — played natively via <img> (H.264) or
        // <video>, falling back to HLS (hlsURL) only when the device can't
        // decode the source.
        apiClient.getImageURL(baseURL: baseURL, postId: post._id, accessToken: accessToken, record: false, rawAnimated: true)
    }

    func hlsURL(for post: RemotePost) -> URL? {
        apiClient.getHLSURL(baseURL: baseURL, postId: post._id, accessToken: accessToken)
    }

    // Video posts start on the video-in-<img> path (native H.264 in an image
    // element) so the web view manages playback lifecycle across room
    // transitions; on error the slideshow falls through to <video> raw, then
    // <video> + HLS.
    var rendersVideoAsAnimatedImage: Bool { true }

    func onPostDisplayed(_ post: RemotePost) async {
        try? await apiClient.addToHistory(baseURL: baseURL, postId: post._id, accessToken: accessToken, deviceId: deviceId)
    }

    func resetPagination() {
        // The orchestrator manages pagination; locally we just drop any
        // server-pushed posts that haven't been consumed yet, and forget
        // which ids we've seen so a legitimate replay (e.g. tag-list
        // change) can resurface the same post.
        pending.removeAll()
        seenIds.removeAll()
    }
}
