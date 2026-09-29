/*
 Hypnos - GraphQL Video Source

 VideoSource implementation that fetches scenes from Stash server via GraphQL.
 */

import DebugTrace
import Foundation

/// Video source that fetches from Stash GraphQL API
final class GraphQLVideoSource: VideoSource, @unchecked Sendable {
    private let apiClient: StashAPIClient

    init(apiClient: StashAPIClient) {
        self.apiClient = apiClient
    }

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        try await fetchVideos(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult {
        // Stash uses 1-indexed pages
        let stashPage = page + 1
        AppLogger.graphQLVideo.debug("Fetching videos page \(stashPage, privacy: .public), pageSize \(pageSize, privacy: .public), hasFilter: \(filter != nil, privacy: .public)")

        // See GraphQLImageSource for why this is an id list and why an empty one
        // returns early instead of being sent.
        var convertedIds: [String]?
        if filter?.showsOnlyConverted == true {
            let ids = await ConvertedMediaRegistry.stashIds(isVideo: true)
            guard !ids.isEmpty else {
                return VideoFetchResult(videos: [], hasMore: false, totalCount: 0)
            }
            convertedIds = ids
        }

        let result = try await apiClient.findScenes(page: stashPage, perPage: pageSize, filter: filter, ids: convertedIds)
        AppLogger.graphQLVideo.debug("Got \(result.scenes.count, privacy: .public) scenes, total: \(result.count, privacy: .public)")

        // Read live (default on) so toggling the setting takes effect on next fetch.
        // Mirrors AppModel.enableStashTranscoding.
        let allowTranscoding = UserDefaults.standard.object(forKey: "enableStashTranscoding") as? Bool ?? true

        let videos = result.scenes.compactMap { Self.makeGalleryVideo(from: $0, allowTranscoding: allowTranscoding) }

        let totalPages = (result.count + pageSize - 1) / pageSize
        let hasMore = (page + 1) < totalPages

        return VideoFetchResult(
            videos: videos,
            hasMore: hasMore,
            totalCount: result.count
        )
    }

    /// Read the transcoding preference live (default on) so toggling the setting
    /// takes effect on the next fetch. Mirrors `AppModel.enableStashTranscoding`.
    private static var allowTranscodingPreference: Bool {
        UserDefaults.standard.object(forKey: "enableStashTranscoding") as? Bool ?? true
    }

    /// Fetch a single scene by Stash ID and map it to a `GalleryVideo`.
    /// Used by the `hypnos://scene?id=` callback.
    func fetchVideo(id: String) async throws -> GalleryVideo? {
        guard let scene = try await apiClient.findScene(id: id) else { return nil }
        return Self.makeGalleryVideo(from: scene, allowTranscoding: Self.allowTranscodingPreference)
    }

    /// Map a raw GraphQL scene to a `GalleryVideo`. Shared by list fetching and
    /// the single-scene `fetchVideo(id:)` path so both stay in sync.
    static func makeGalleryVideo(from scene: StashAPIClient.StashScene, allowTranscoding: Bool) -> GalleryVideo? {
        guard let streamURLString = scene.paths.stream,
              let directStreamURL = URL(string: streamURLString) else {
            return nil
        }

        let thumbnailURL: URL
        if let screenshotString = scene.paths.screenshot,
           let screenshotURL = URL(string: screenshotString) {
            thumbnailURL = screenshotURL
        } else {
            // Use a placeholder or first frame
            thumbnailURL = directStreamURL
        }

        let firstFile = scene.files?.first
        let duration = firstFile?.duration
        let sourceWidth = firstFile?.width
        let sourceHeight = firstFile?.height

        // Extract original filename from files path
        let fileName = firstFile?.path.map { ($0 as NSString).lastPathComponent }
        // Play the original file; keep the server transcode in reserve.
        let transcodeStreamURL = allowTranscoding
            ? Self.transcodeStreamURL(directStreamURL: directStreamURL, streamEndpoints: scene.sceneStreams)
            : nil

        // Prefer the server-reported preview path; otherwise derive it as a
        // sibling of the screenshot (`/scene/{id}/screenshot` → `/preview`),
        // which matches Stash's default route layout.
        let previewURL: URL? = scene.paths.preview
            .flatMap { URL(string: $0) }
            ?? Self.derivedPreviewURL(fromScreenshot: thumbnailURL)

        // Detect stereoscopic format from tags
        let tagNames = scene.tags?.map { $0.name } ?? []
        let (isStereoscopic, stereoscopicFormat) = StereoscopicFormat.detect(from: tagNames)

        // Check for eyes reversed tag (for videos with swapped left/right eyes)
        let eyesReversed = tagNames.contains { tag in
            let lowercased = tag.lowercased()
            return lowercased == "stereo_eyes_reversed" ||
                   lowercased == "stereo-eyes-reversed" ||
                   lowercased == "eyes_reversed" ||
                   lowercased == "eyes-reversed"
        }

        return GalleryVideo(
            // Identity stays the bare scene id so every depth cache and 3D
            // setting written before the identity split still resolves.
            identity: scene.id,
            stashId: scene.id,
            thumbnailURL: thumbnailURL,
            streamURL: directStreamURL,
            transcodeStreamURL: transcodeStreamURL,
            previewURL: previewURL,
            title: scene.title,
            duration: duration,
            isStereoscopic: isStereoscopic,
            stereoscopicFormat: stereoscopicFormat,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            eyesReversed: eyesReversed,
            rating100: scene.rating100,
            oCounter: scene.o_counter,
            fileName: fileName
        )
    }

    /// The server's live-transcode endpoint for this scene, kept in reserve
    /// rather than used up front (see `GalleryVideo.transcodeStreamURL`).
    ///
    /// HLS (`/stream.m3u8`) is a proper VOD playlist of h264/AAC mpegts
    /// segments, which AVFoundation plays natively — so it routes to the Metal
    /// renderer (GPU-private textures) and, crucially, makes fake-3D available
    /// (the pseudo-3D pipeline decodes via AVPlayerItemVideoOutput and is gated
    /// on the native renderer). The `/stream.mp4` endpoint is a *fragmented*
    /// MP4 served over a single non-seekable chunked pipe: WebKit plays it but
    /// AVPlayer rejects it (it wants a byte-range-seekable resource), so it is
    /// only a playability fallback and cannot unlock fake-3D. Prefer HLS.
    ///
    /// Returned for every scene that advertises endpoints, not just WebM: any
    /// container/codec WebKit can't decode gets the same escape hatch, and for a
    /// natively-playable MP4 the transcode simply never gets used.
    private static func transcodeStreamURL(
        directStreamURL: URL,
        streamEndpoints: [StashAPIClient.StashSceneStreamEndpoint]?
    ) -> URL? {
        guard let streamEndpoints, !streamEndpoints.isEmpty else { return nil }

        let endpointURLs = streamEndpoints.compactMap { URL(string: $0.url) }

        if let hlsURL = endpointURLs.first(where: { $0.path.hasSuffix("/stream.m3u8") }) {
            return hlsURL
        }

        if let mp4URL = endpointURLs.first(where: { $0.path.hasSuffix("/stream.mp4") }) {
            return mp4URL
        }

        return nil
    }

    /// Fallback preview URL when the server didn't report `paths.preview`.
    /// Stash serves the preview as a sibling of the screenshot, so swap a
    /// trailing `/screenshot` path component for `/preview`, preserving the
    /// query string (e.g. the apikey). Returns `nil` for file URLs or paths
    /// that don't match the expected shape.
    private static func derivedPreviewURL(fromScreenshot screenshot: URL) -> URL? {
        guard !screenshot.isFileURL,
              var components = URLComponents(url: screenshot, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let suffix = "/screenshot"
        guard components.path.hasSuffix(suffix) else { return nil }
        components.path = String(components.path.dropLast(suffix.count)) + "/preview"
        return components.url
    }
}
