/*
 Hypnos - Video Slideshow Content Provider

 SlideshowContentProvider implementation that fetches videos from a
 VideoSource (GraphQL scenes, local files, etc.) and presents them as
 video posts for the slideshow engine. Mirrors GalleryContentProvider,
 but maps GalleryVideo → RemotePost with a video file extension so the
 engine routes each post through its video display path.
 */

import DebugTrace
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO
import RAVESlideshow

@MainActor
class VideoSlideshowContentProvider: SlideshowContentProvider, RAVESlideshowContentProvider {
    let videoSource: any VideoSource
    var filter: SceneFilterCriteria?

    private var page: Int = 0
    /// URL mapping for video posts (RemotePost._id → streamURL)
    private var videoURLMap: [Int: URL] = [:]
    /// Server-side transcode per post (RemotePost._id → transcodeStreamURL).
    /// Reserve stream, exactly as in the video window: the flat `<video>` tier
    /// escalates to it when the device can't decode the original, and slideshow
    /// fake-3D needs it for containers AVFoundation won't open at all (WebM).
    private var transcodeURLMap: [Int: URL] = [:]

    init(videoSource: any VideoSource, filter: SceneFilterCriteria? = nil) {
        self.videoSource = videoSource
        self.filter = filter
    }

    func fetchMoreContent(
        tagQuery: String,
        ratioRange: String?,
        blockedPosts: Set<Int>,
        blockedTags: Set<String>
    ) async -> [RemotePost] {
        do {
            let result = try await videoSource.fetchVideos(page: page, pageSize: 20, filter: filter)
            page += 1

            let posts = result.videos.map { video -> RemotePost in
                // Stash stream URLs often have no path extension; fall back
                // to "mp4" so SlideshowEngine.videoExtensions matches and the
                // engine routes the post through its video display path.
                let pathExt = video.streamURL.pathExtension.lowercased()
                let ext = pathExt.isEmpty ? "mp4" : pathExt
                return RemotePost(
                    _id: abs(video.identity.hashValue),
                    file_ext: ext,
                    tags: [],
                    rating: nil, image_width: video.sourceWidth, image_height: video.sourceHeight,
                    fav_count: nil, md5: nil, parent_id: nil,
                    score: nil, ratio: nil, path: video.streamURL.absoluteString,
                    // nil duration keeps effectiveDelay on the strict configured
                    // interval — videos autoplay and cut off like animated GIFs.
                    duration: nil
                )
            }
            for (video, post) in zip(result.videos, posts) {
                videoURLMap[post._id] = video.streamURL
                if let transcode = video.transcodeStreamURL {
                    transcodeURLMap[post._id] = transcode
                }
            }
            AppLogger.remoteViewer.info("Video slideshow: fetched \(posts.count, privacy: .public) videos")
            return posts
        } catch {
            AppLogger.remoteViewer.error("Video slideshow fetch failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return []
        }
    }

    func downloadImage(for post: RemotePost, maxResolution: Int) async -> DownloadedMedia? {
        // Never reached for video posts — the engine routes by extension to
        // displayVideo before calling this.
        nil
    }

    func resolveImageURL(for post: RemotePost) -> URL? {
        videoURLMap[post._id]
    }

    func hlsURL(for post: RemotePost) -> URL? {
        transcodeURLMap[post._id]
    }

    func onPostDisplayed(_ post: RemotePost) async {
        // No server-side history for video slideshow mode
    }

    func resetPagination() {
        page = 0
        videoURLMap.removeAll()
        transcodeURLMap.removeAll()
    }

    func fetchMoreContent(_ request: RAVESlideshowFetchRequest) async throws -> [RAVESlideshowItem] {
        let posts = await fetchMoreContent(
            tagQuery: "",
            ratioRange: nil,
            blockedPosts: [],
            blockedTags: request.excludedTags
        )
        return posts.map { post in
            RAVESlideshowItem(
                id: String(post._id),
                title: nil,
                mediaKind: .video,
                fileExtension: post.file_ext,
                duration: post.duration,
                metadata: [
                    "legacyID": String(post._id),
                    "url": resolveImageURL(for: post)?.absoluteString ?? ""
                ]
            )
        }
    }

    func loadMedia(for item: RAVESlideshowItem, maxResolution: Int) async throws -> RAVESlideshowLoadedMedia {
        guard let id = Int(item.id) else { throw RAVESlideshowError.noContent }
        let post = RemotePost(
            _id: id,
            file_ext: item.fileExtension,
            tags: [],
            rating: nil,
            image_width: nil,
            image_height: nil,
            fav_count: nil,
            md5: nil,
            parent_id: nil,
            score: nil,
            ratio: nil,
            path: item.metadata["url"],
            duration: item.duration
        )
        guard let url = resolveImageURL(for: post) else { throw RAVESlideshowError.noContent }
        return .video(url: url, hlsURL: hlsURL(for: post))
    }

    func displayURL(for item: RAVESlideshowItem) -> URL? {
        item.metadata["url"].flatMap(URL.init(string:))
    }

    func streamingFallbackURL(for item: RAVESlideshowItem) -> URL? {
        guard let id = Int(item.id) else { return nil }
        let post = RemotePost(
            _id: id,
            file_ext: item.fileExtension,
            tags: [],
            rating: nil,
            image_width: nil,
            image_height: nil,
            fav_count: nil,
            md5: nil,
            parent_id: nil,
            score: nil,
            ratio: nil,
            path: item.metadata["url"],
            duration: item.duration
        )
        return hlsURL(for: post)
    }
}
