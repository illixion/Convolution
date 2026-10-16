/*
 Hypnos - Video Slideshow Content Provider

 Feeds a video slideshow from a VideoSource (Stash scenes, local files) and
 the filter it was started with. Each video carries its transcode, when the
 source has one, as the streaming fallback: the flat `<video>` tier
 escalates to it when the device can't decode the original, and slideshow
 fake-3D needs it for containers AVFoundation won't open at all (WebM).
 */

import DebugTrace
import Foundation
import RAVESlideshow

@MainActor
class VideoSlideshowContentProvider: RAVESlideshowContentProvider {
    let videoSource: any VideoSource
    var filter: SceneFilterCriteria?

    private var page: Int = 0

    init(videoSource: any VideoSource, filter: SceneFilterCriteria? = nil) {
        self.videoSource = videoSource
        self.filter = filter
    }

    func fetchMoreContent(_ request: RAVESlideshowFetchRequest) async throws -> [RAVESlideshowItem] {
        do {
            let result = try await videoSource.fetchVideos(page: page, pageSize: 20, filter: filter)
            page += 1
            AppLogger.remoteViewer.info("Video slideshow: fetched \(result.videos.count, privacy: .public) videos")
            return result.videos.map { video in
                // Stash stream URLs often have no path extension.
                let pathExt = video.streamURL.pathExtension.lowercased()
                var metadata = ["url": video.streamURL.absoluteString]
                if let transcode = video.transcodeStreamURL {
                    metadata["transcode"] = transcode.absoluteString
                }
                // No duration: videos autoplay and cut off at the interval,
                // like animated GIFs.
                return RAVESlideshowItem(
                    id: String(abs(video.identity.hashValue)),
                    title: nil,
                    mediaKind: .video,
                    fileExtension: pathExt.isEmpty ? "mp4" : pathExt,
                    metadata: metadata
                )
            }
        } catch {
            AppLogger.remoteViewer.error("Video slideshow fetch failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return []
        }
    }

    func loadMedia(for item: RAVESlideshowItem, maxResolution: Int) async throws -> RAVESlideshowLoadedMedia {
        guard let url = displayURL(for: item) else { throw RAVESlideshowError.noContent }
        return .video(url: url, hlsURL: streamingFallbackURL(for: item))
    }

    func displayURL(for item: RAVESlideshowItem) -> URL? {
        item.metadata["url"].flatMap(URL.init(string:))
    }

    func streamingFallbackURL(for item: RAVESlideshowItem) -> URL? {
        item.metadata["transcode"].flatMap(URL.init(string:))
    }
}
