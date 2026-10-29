import Foundation

/// Decoded audio for AI captions from an HLS stream, read independently of
/// the player. AVPlayerItem's own sample output supplies no audio on
/// visionOS 27.2, so the playlists are read here and the audio segments
/// decoded one at a time: fragmented MP4 (an `EXT-X-MAP` and moof/mdat
/// segments, Jellyfin's) through `RAVECaptionAudioSource.fragmentedMP4`, and
/// packed audio (ADTS AAC behind an ID3 tag, YouTube's) through
/// `RAVECaptionAudioSource.packedAudio`. Only segments from the playhead on
/// are fetched, never the whole stream.
public enum HLSCaptionAudio {
    /// The audio the player has selected, as its media selection says.
    public struct Selection: Sendable {
        public var name: String?
        public var language: String?
        public init(name: String? = nil, language: String? = nil) { self.name = name; self.language = language }
    }

    /// Reads a URL (a byte range of it, when given) with the stream's credentials.
    public typealias Fetch = @Sendable (URL, Range<Int>?) async throws -> Data

    public enum Failure: LocalizedError {
        case protected, noSegments, unsupportedContainer
        public var errorDescription: String? {
            switch self {
            case .protected: "This stream is protected, so AI captions can't read its audio."
            case .noSegments: "This stream has no audio segments for AI captions to read."
            case .unsupportedContainer: "AI captions can't read this stream's audio format yet. Try another stream or use its built-in subtitles."
            }
        }
    }

    /// The audio of `playlist` (a master or a media playlist) from `start`.
    public static func source(playlist url: URL, selection: Selection, start: Double, fetch: @escaping Fetch) async throws -> RAVECaptionAudioSource {
        var media = try await load(url, fetch: fetch)
        if media.isMaster {
            // The selected rendition's own playlist, or for audio muxed into
            // the variants the lightest variant (the audio is the same).
            let target = media.rendition(name: selection.name, language: selection.language)?.url
                ?? media.variants.min { $0.bandwidth < $1.bandwidth }?.url
            guard let target else { throw Failure.noSegments }
            media = try await load(target, fetch: fetch)
        }
        if media.isEncrypted { throw Failure.protected }
        guard !media.segments.isEmpty else { throw Failure.noSegments }
        let feed = SegmentFeed(playlist: media, start: start, fetch: fetch)
        if media.map != nil {
            return .fragmentedMP4 { try await feed.nextFragment() }
        }
        return .packedAudio { try await feed.nextPacked() }
    }

    private static func load(_ url: URL, fetch: Fetch) async throws -> HLSPlaylist {
        let data = try await fetch(url, nil)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return HLSPlaylist(text, base: url)
    }
}

/// Hands out a playlist's segments in order from a start time.
private actor SegmentFeed {
    let playlist: HLSPlaylist
    let fetch: HLSCaptionAudio.Fetch
    private var next: Int
    private var initialization: Data?

    init(playlist: HLSPlaylist, start: Double, fetch: @escaping HLSCaptionAudio.Fetch) {
        self.playlist = playlist
        self.fetch = fetch
        next = playlist.firstSegment(after: start)
    }

    /// The initialization segment followed by the next media segment.
    func nextFragment() async throws -> Data? {
        guard let segment = take() else { return nil }
        if initialization == nil, let map = playlist.map {
            initialization = try await read(map.url, map.byteRange)
        }
        return (initialization ?? Data()) + (try await read(segment.url, segment.byteRange))
    }

    func nextPacked() async throws -> (data: Data, start: Double)? {
        guard let segment = take() else { return nil }
        return (try await read(segment.url, segment.byteRange), segment.start)
    }

    private func take() -> HLSPlaylist.Segment? {
        guard next < playlist.segments.count else { return nil }
        defer { next += 1 }
        return playlist.segments[next]
    }

    /// One retry: a segment URL that was fine a second ago usually still is.
    private func read(_ url: URL, _ range: Range<Int>?) async throws -> Data {
        try Task.checkCancellation()
        do {
            return try await fetch(url, range)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await Task.sleep(for: .milliseconds(500))
            return try await fetch(url, range)
        }
    }
}
