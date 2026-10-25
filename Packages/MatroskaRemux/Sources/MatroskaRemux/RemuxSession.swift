/*
 MatroskaRemux - one file served as HLS

 `open` reads the file's head, decides which tracks go in (`TrackPlans`),
 reads the first frames (codec details Matroska doesn't store: a VP9
 keyframe header, an AC-3 syncframe, the first timestamps) and builds the
 segment index (for a server's file without Cues, starts building it:
 `ProgressiveIndex.swift`). After that everything is on demand: playlists
 and init segments are computed once (a growing index's media playlists on
 each request), and a media segment is muxed when the player asks for it,
 from that segment's clusters only.

 Video and audio of one segment come from the same byte range, and the
 player asks for them at nearly the same moment, so a segment's clusters
 are parsed once into every kept track's frames and the result shared
 (`parsed`, which keeps the last few). The audio of a parse is kept longer
 (`parsedAudio`): it is a few percent of the bytes, and an audio rendition
 can trail its video by a segment or two, which would otherwise read a UHD
 segment's 100 MB again for its 500 KB of audio. The parse reads past the
 segment's last cluster until every track has a frame beyond the segment's
 end: muxers interleave by decode time, so audio belonging just before a
 keyframe can sit after it in the file. The next segment's read starts
 there, so a server file's recent reads are kept (`RecentReadsSource`).

 Which segment a frame belongs to is decided by time, not by where it is:
 video from one segment keyframe up to the next (decode order), audio by
 its snapped time against the segment's boundary. A frame stored before its
 segment's first cluster is found in the previous segment's read-past
 (`spill`), and taken from there.

 Output is deterministic, so a segment the player re-requests (after a
 seek, or a decoder reset when visionOS backgrounds the window) is
 byte-identical to the first.

 Subtitle tracks are handed to the app as blocks rather than muxed
 (`Subtitles.swift`): read alone through the Cues, and kept from every
 parse.
 */

import Foundation

public struct RemuxOptions: Sendable {
    /// Index a file without Cues by scanning its clusters before `open`
    /// returns. Nil: only when the source is local; a server's file is
    /// indexed by hopping from cluster to cluster while it plays instead.
    public var allowsClusterScan: Bool?
    /// How long `open` waits for a hopped index to finish before handing
    /// out a growing one (it always waits for `listedSegmentsAtOpen`).
    public var indexWait: Double = 1.5
    public var listedSegmentsAtOpen = 3
    /// Hop chains a hopped index may run at once, and the clusters there
    /// have to be per chain for another to pay.
    public var indexChains = 4
    public var clustersPerIndexChain: Int64 = 400
    /// How far into the file `open` reads for the first frames.
    public var probeByteLimit: Int64 = 48 << 20
    /// Parsed segments kept for the renditions still to ask for them: by
    /// count, and by bytes (the last one is always kept).
    public var cachedSegments = 2
    public var cachedBytes = 64 << 20
    /// Segments whose audio is kept after their video is let go: by count,
    /// and by bytes (lossless 5.1 is 3 MB a segment).
    public var cachedAudioSegments = 16
    public var cachedAudioBytes = 24 << 20

    public init() {}
}

/// What a session plays, for logging and for the caller's decisions.
public struct RemuxSummary: Sendable {
    public struct Track: Sendable {
        public var number: UInt64
        public var codecID: String
        /// A short codec name ("HEVC", "E-AC-3").
        public var codec: String
        public var codecs: String
        public var language: String?
        public var name: String
        public var channels: Int?
        public var isDefault: Bool
    }

    public struct DroppedTrack: Sendable {
        public var number: UInt64
        public var codecID: String
        public var reason: String
    }

    public var docType: String
    public var video: Track
    public var audio: [Track]
    public var dropped: [DroppedTrack]
    public var segmentCount: Int
    public var durationSeconds: Double
    public var videoRange: String
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double?
    /// The index came from scanning clusters (no Cues).
    public var scannedClusters: Bool
    /// The index was still growing when the session opened (a server's file
    /// without Cues): the media playlists are EVENT playlists until it is
    /// done. `segmentCount` is what was listed then; `durationSeconds` is
    /// Info's Duration, or what was indexed then when the file has none.
    public var indexing: Bool
}

public actor RemuxSession {
    public nonisolated let summary: RemuxSummary
    public nonisolated let masterPlaylist: String
    /// The master's audio renditions, in its order (for an app's own audio
    /// menu; the players' come from the playlist).
    public nonisolated let audioRenditions: [AudioRendition]

    nonisolated let source: any ByteSource
    nonisolated let header: MatroskaHeader
    /// The segment index; it grows while a server's file without Cues is
    /// hopped over (`ProgressiveIndex.swift`).
    nonisolated let indexStore: SegmentIndexStore
    nonisolated var index: SegmentIndex { indexStore.current }
    /// The background indexing, while it runs.
    private nonisolated let indexing: Task<Void, Never>?
    nonisolated let video: VideoPlan
    nonisolated let audio: [AudioPlan]
    /// Media playlists of an index complete at `open`, by prefix; the
    /// growing index's are made on each request.
    nonisolated let fixedPlaylists: [String: String]
    /// EXT-X-TARGETDURATION of a growing index's playlists.
    nonisolated let eventTargetDuration: Int?
    nonisolated let videoInit: Data
    nonisolated let audioInits: [UInt64: Data]
    nonisolated let options: RemuxOptions
    /// The audio track the muxed fallback carries (the default one).
    nonisolated let muxedAudio: AudioPlan?
    /// One media playlist carrying the video and the default audio track
    /// in the same segments. A player that can't present HDR refuses an HDR
    /// master outright (AVFoundation, `eligibleForHDRPlayback` false), but
    /// plays a media playlist, tone-mapping the picture; this is that
    /// playlist. It has no audio choice.
    public nonisolated var muxedPlaylist: String { mediaPlaylist("muxed") }
    nonisolated let muxedInit: Data

    private var parsed: [Int: Task<ParsedSegment, Error>] = [:]
    private var parsedOrder: [Int] = []
    private var parsedBytes: [Int: Int] = [:]
    /// Recent parses without their video.
    private var parsedAudio: [Int: ParsedSegment] = [:]
    private var parsedAudioOrder: [Int] = []
    private var parsedAudioBytes: [Int: Int] = [:]

    /// Bytes read from the source while serving segments (for the caller's
    /// logs).
    public private(set) var bytesRead: Int64 = 0

    /// The file's subtitle tracks, shown or not (`unsupportedReason`).
    public nonisolated let subtitleTracks: [MatroskaSubtitleTrack]
    /// Each readable track's entry, and its cue points by time when indexed.
    nonisolated let subtitleEntries: [UInt64: MatroskaTrack]
    nonisolated let subtitleCues: [UInt64: [CuePoint]]
    /// The source without `RecentReadsSource`, whose kept ends are for
    /// segments: a subtitle read is a few kilobytes anywhere in the file.
    nonisolated let subtitleSource: any ByteSource
    private var subtitleStores: [UInt64: SubtitleStore] = [:]

    private init(source: any ByteSource, subtitleSource: any ByteSource, header: MatroskaHeader,
                 indexStore: SegmentIndexStore, indexing: Task<Void, Never>?, video: VideoPlan, audio: [AudioPlan],
                 dropped: [RemuxSummary.DroppedTrack], scanned: Bool, options: RemuxOptions) {
        self.source = source
        self.indexStore = indexStore
        self.indexing = indexing
        let index = indexStore.publish()
        self.subtitleSource = subtitleSource
        var subtitleTracks: [MatroskaSubtitleTrack] = []
        var subtitleEntries: [UInt64: MatroskaTrack] = [:]
        var subtitleCues: [UInt64: [CuePoint]] = [:]
        for track in header.tracks where track.kind == .subtitle && track.isEnabled {
            let format = MatroskaSubtitleTrack.format(of: track.codecID)
            let cues = header.cues.filter { $0.track == track.number }.sorted { $0.time < $1.time }
            let reason = format == .unsupported ? track.codecID : SubtitleReading.unreadableEncoding(track)
            subtitleTracks.append(MatroskaSubtitleTrack(
                number: track.number, codecID: track.codecID, format: format, language: track.bcp47Language,
                name: track.name.flatMap { $0.isEmpty ? nil : $0 }, isDefault: track.isDefault, isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isIndexed: !cues.isEmpty && cues.allSatisfy { $0.relativePosition != nil }, unsupportedReason: reason))
            guard reason == nil else { continue }
            subtitleEntries[track.number] = track
            if subtitleTracks.last!.isIndexed { subtitleCues[track.number] = cues }
        }
        self.subtitleTracks = subtitleTracks
        self.subtitleEntries = subtitleEntries
        self.subtitleCues = subtitleCues
        self.header = header
        self.video = video
        self.audio = audio
        self.options = options
        let renditions = Playlists.renditions(audio)
        audioRenditions = renditions
        let names = Dictionary(uniqueKeysWithValues: renditions.map { ($0.trackNumber, $0.name) })
        let prefixes = ["video", "muxed"] + audio.map { "audio-\($0.track.number)" }
        if index.isComplete {
            fixedPlaylists = Dictionary(uniqueKeysWithValues: prefixes.map {
                ($0, Playlists.media(index: index, timestampScale: header.timestampScale, prefix: $0))
            })
            eventTargetDuration = nil
        } else {
            fixedPlaylists = [:]
            eventTargetDuration = Playlists.targetDuration(index: index, timestampScale: header.timestampScale)
        }
        var audioInits: [UInt64: Data] = [:]
        for plan in audio {
            audioInits[plan.track.number] = Data(FragmentWriter.initSegment(
                handler: .audio, timescale: UInt32(plan.sampleRate),
                language: LanguageCodes.iso6392T(fromBCP47: plan.track.bcp47Language), sampleEntry: plan.sampleEntry))
        }
        self.audioInits = audioInits
        videoInit = Data(FragmentWriter.initSegment(
            handler: .video(width: video.displayWidth, height: video.displayHeight), timescale: video.timescale,
            language: "und", sampleEntry: video.sampleEntry))
        masterPlaylist = Playlists.master(index: index, header: header, video: video, audio: audio,
                                          renditions: renditions)
        muxedAudio = Playlists.defaultAudio(audio)
        var muxedTracks = [FragmentWriter.TrackHeader(handler: .video(width: video.displayWidth, height: video.displayHeight),
                                                      timescale: video.timescale, language: "und",
                                                      sampleEntry: video.sampleEntry)]
        if let plan = muxedAudio {
            muxedTracks.append(.init(handler: .audio, timescale: UInt32(plan.sampleRate),
                                     language: LanguageCodes.iso6392T(fromBCP47: plan.track.bcp47Language),
                                     sampleEntry: plan.sampleEntry))
        }
        muxedInit = Data(FragmentWriter.initSegment(tracks: muxedTracks))
        // Info's Duration while the index grows, else where it ends.
        let endTicks = index.isComplete ? index.endTime : header.duration.map { Int64($0.rounded()) } ?? index.endTime
        let duration = Double(endTicks - (index.boundaries.first?.time ?? 0)) * Double(header.timestampScale) / 1e9
        summary = RemuxSummary(
            docType: header.docType,
            video: .init(number: video.track.number, codecID: video.track.codecID, codec: video.codecName,
                         codecs: video.codecs, language: nil, name: video.track.name ?? "", channels: nil,
                         isDefault: true),
            audio: audio.map { plan in
                .init(number: plan.track.number, codecID: plan.track.codecID, codec: plan.codecName,
                      codecs: plan.codecs, language: plan.track.bcp47Language,
                      name: names[plan.track.number] ?? "", channels: plan.channels,
                      isDefault: Playlists.defaultAudio(audio)?.track.number == plan.track.number)
            },
            dropped: dropped, segmentCount: index.count, durationSeconds: duration, videoRange: video.videoRange,
            width: video.displayWidth, height: video.displayHeight, framesPerSecond: video.framesPerSecond,
            scannedClusters: scanned, indexing: !index.isComplete)
    }

    deinit { indexing?.cancel() }

    // MARK: - Opening

    public static func open(source: any ByteSource, options: RemuxOptions = RemuxOptions()) async throws -> RemuxSession {
        let original = source
        let source: any ByteSource = source.isLocal ? source : RecentReadsSource(base: source)
        let header = try await MatroskaHeaderReader.read(source)
        guard let firstCluster = header.firstClusterPosition else { throw RemuxError.malformed("no Cluster") }
        let contentEnd = header.contentEnd ?? Int64.max

        // The video: the first enabled one, which has to be a codec MP4 carries.
        guard let videoTrack = header.tracks.first(where: { $0.kind == .video && $0.isEnabled }) else {
            throw RemuxError.declined("no video track")
        }
        guard SupportedCodecs.video.contains(videoTrack.codecID) else {
            throw RemuxError.declined("video codec \(videoTrack.codecID)")
        }
        if let encoding = videoTrack.unreadableEncoding { throw RemuxError.declined("video track is \(encoding)") }

        var dropped: [RemuxSummary.DroppedTrack] = []
        var candidates: [MatroskaTrack] = []
        let audioTracks = header.tracks.filter { $0.kind == .audio && $0.isEnabled }
        for track in audioTracks {
            if !SupportedCodecs.isAudioSupported(track.codecID) {
                dropped.append(.init(number: track.number, codecID: track.codecID, reason: "codec"))
            } else if let encoding = track.unreadableEncoding {
                dropped.append(.init(number: track.number, codecID: track.codecID, reason: encoding))
            } else {
                candidates.append(track)
            }
        }
        if !audioTracks.isEmpty, candidates.isEmpty {
            throw RemuxError.declined("no playable audio (\(audioTracks.map(\.codecID).joined(separator: ", ")))")
        }

        // The first frames: the video's first keyframe and each audio
        // track's first frame.
        let firsts = try await probeFirstFrames(source: source, header: header, start: firstCluster,
                                                limit: contentEnd, video: videoTrack, audio: candidates,
                                                byteLimit: options.probeByteLimit)
        guard let keyframe = firsts.videoKeyframe else { throw RemuxError.declined("no video keyframe near the start") }

        // Every rendition's times start at zero: the file is shifted as a
        // whole, so audio and video keep their relative timing. Not below
        // zero, as tfdt is unsigned: a file whose first timestamps are
        // negative, or whose first audio block is earlier than its codec
        // delay (an AAC or Opus track that starts at 0 with priming ahead of
        // it). And not above it: the player's clock starts at the first
        // segment whatever its times say, and the app's subtitles, timed on
        // this timeline, have to read the same clock (a file cut from the
        // middle of a recording starts at 7 s, or an hour).
        let scale = header.timestampScale
        var earliest = (firsts.videoFirstTicks ?? keyframe.blockTimestamp) * scale
        for track in candidates {
            guard let first = firsts.audio[track.number] else { continue }
            earliest = min(earliest, first.blockTimestamp * scale - Int64(clamping: track.codecDelay))
        }
        let offsetNanoseconds = -earliest

        let video = try VideoPlan.make(track: videoTrack, firstKeyframe: keyframe.data,
                                       firstKeyframeTicks: keyframe.blockTimestamp,
                                       timestampScale: header.timestampScale, offsetNanoseconds: offsetNanoseconds)
        var audio: [AudioPlan] = []
        for track in candidates {
            guard let first = firsts.audio[track.number] else {
                dropped.append(.init(number: track.number, codecID: track.codecID, reason: "no frames near the start"))
                continue
            }
            switch AudioPlan.make(track: track, firstFrame: first.data, firstTicks: first.blockTimestamp,
                                  timestampScale: header.timestampScale, offsetNanoseconds: offsetNanoseconds) {
            case .success(let plan): audio.append(plan)
            case .failure(let error): dropped.append(.init(number: track.number, codecID: track.codecID,
                                                           reason: error.description))
            }
        }
        if !audioTracks.isEmpty, audio.isEmpty {
            throw RemuxError.declined("no playable audio")
        }

        // The index: Cues, else a scan of the clusters (a local file) or, for
        // a server's file, hops from cluster to cluster while it plays.
        let videoCues = header.cues.filter { $0.track == videoTrack.number }.sorted { $0.time < $1.time }
        let store: SegmentIndexStore
        var indexing: Task<Void, Never>?
        var scanned = false
        if !videoCues.isEmpty || options.allowsClusterScan ?? source.isLocal {
            var keyframes: [SegmentIndex.Boundary] = []
            var endTime: Int64?
            if !videoCues.isEmpty {
                keyframes = videoCues.map { .init(time: $0.time, clusterPosition: $0.clusterPosition) }
                if keyframes[0].time > keyframe.blockTimestamp || keyframes[0].clusterPosition > firstCluster {
                    keyframes.insert(.init(time: keyframe.blockTimestamp, clusterPosition: firstCluster), at: 0)
                }
            } else {
                let scan = try await scanKeyframes(source: source, start: firstCluster, limit: contentEnd,
                                                   video: videoTrack.number)
                keyframes = scan.keyframes
                endTime = scan.endTime
                scanned = true
            }
            guard !keyframes.isEmpty else { throw RemuxError.declined("no video keyframes") }

            // The later of the two: Info's Duration covers every track (audio can
            // outlast the video), a scan only the video's frames.
            var end = [endTime, header.duration.map { Int64($0.rounded()) }].compactMap { $0 }.max()
            if end == nil {
                // Cues but no Duration: the last cue's segment says where it ends.
                end = try await lastFrameTime(source: source, header: header, from: keyframes.last!.clusterPosition,
                                              video: videoTrack)
            }
            let endPosition = header.contentEnd ?? keyframes.last!.clusterPosition
            store = SegmentIndexStore(SegmentIndex.build(keyframes: keyframes, endTime: end ?? keyframes.last!.time + 1,
                                                         endPosition: endPosition,
                                                         timestampScale: header.timestampScale))
        } else {
            store = SegmentIndexStore(SegmentIndex(boundaries: [], endTime: 0, endPosition: contentEnd,
                                                   isComplete: false))
            let task = ProgressiveIndexing.start(
                store: store, source: original, header: header, firstCluster: firstCluster,
                firstKeyframe: .init(time: keyframe.blockTimestamp, clusterPosition: firstCluster), video: videoTrack,
                options: options)
            indexing = task
            do {
                try await waitForSegments(store, options: options)
            } catch {
                task.cancel()
                throw error
            }
        }
        guard store.current.count > 0 else {
            indexing?.cancel()
            throw RemuxError.declined("no segments")
        }

        return RemuxSession(source: source, subtitleSource: original, header: header, indexStore: store,
                            indexing: indexing, video: video, audio: audio, dropped: dropped, scanned: scanned,
                            options: options)
    }

    /// Waits until a hopped index is done, or has listed its first segments
    /// and either `indexWait` has passed or, at the rate it is going, it
    /// won't be done by then.
    private static func waitForSegments(_ store: SegmentIndexStore, options: RemuxOptions) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let budget = Duration.seconds(options.indexWait)
        while true {
            if let error = store.error { throw error }
            let index = store.current
            if index.isComplete { return }
            if index.count >= max(1, options.listedSegmentsAtOpen) {
                let elapsed = clock.now - started
                if elapsed >= budget { return }
                let progress = store.progress
                if elapsed >= .milliseconds(50), progress > 0, elapsed / progress > budget { return }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Whether every segment is known (always, but for a server's file
    /// without Cues still being indexed).
    public nonisolated var isIndexComplete: Bool { index.isComplete }

    /// Returns once the index is complete (at once for a file with Cues);
    /// throws what stopped it.
    public func waitUntilIndexed() async throws {
        if let indexing { await indexing.value }
        if let error = indexStore.error { throw error }
    }

    private struct FirstFrames {
        var videoKeyframe: MatroskaFrame?
        var videoFirstTicks: Int64?
        var audio: [UInt64: MatroskaFrame] = [:]
    }

    private static func probeFirstFrames(source: any ByteSource, header: MatroskaHeader, start: Int64, limit: Int64,
                                         video: MatroskaTrack, audio: [MatroskaTrack],
                                         byteLimit: Int64) async throws -> FirstFrames {
        var modes: [UInt64: ClusterReader.Mode] = [video.number: .frames]
        var stripped: [UInt64: [UInt8]] = [video.number: video.strippedHeader]
        for track in audio {
            modes[track.number] = .frames
            stripped[track.number] = track.strippedHeader
        }
        var reader = ClusterReader(source: source, start: start, limit: limit, chunkSize: 512 << 10,
                                   modes: modes, strippedHeaders: stripped)
        var result = FirstFrames()
        let ticksPerSecond = Int64(1e9) / max(1, header.timestampScale)
        while let frame = try await reader.next() {
            if frame.track == video.number {
                if result.videoFirstTicks == nil { result.videoFirstTicks = frame.blockTimestamp }
                if result.videoKeyframe == nil, frame.isKeyframe { result.videoKeyframe = frame }
            } else if result.audio[frame.track] == nil, frame.laceIndex == 0 {
                result.audio[frame.track] = frame
            }
            if result.videoKeyframe != nil, result.audio.count == audio.count { break }
            if reader.bytesFetched > byteLimit { break }
            if let keyframe = result.videoKeyframe, frame.blockTimestamp > keyframe.blockTimestamp + 30 * ticksPerSecond {
                break
            }
        }
        return result
    }

    /// Keyframe positions from the clusters' block headers (frame bodies
    /// are skipped, so a local file is indexed at the speed of its headers).
    private static func scanKeyframes(source: any ByteSource, start: Int64, limit: Int64,
                                      video: UInt64) async throws -> (keyframes: [SegmentIndex.Boundary], endTime: Int64) {
        var reader = ClusterReader(source: source, start: start, limit: limit, chunkSize: 256 << 10,
                                   modes: [video: .headers])
        var keyframes: [SegmentIndex.Boundary] = []
        var last: Int64 = 0
        var gaps: [Int64] = []
        var previous: Int64?
        while let frame = try await reader.next() {
            if frame.isKeyframe {
                keyframes.append(.init(time: frame.blockTimestamp, clusterPosition: frame.clusterPosition))
            }
            if let previous, frame.blockTimestamp > previous, gaps.count < 64 { gaps.append(frame.blockTimestamp - previous) }
            previous = frame.blockTimestamp
            last = max(last, frame.blockTimestamp + (frame.blockDuration ?? 0))
        }
        let typical = gaps.sorted()[safe: gaps.count / 2] ?? 0
        return (keyframes, last + typical)
    }

    /// The end of the video, from the frames after the last keyframe.
    static func lastFrameTime(source: any ByteSource, header: MatroskaHeader, from position: Int64,
                                      video: MatroskaTrack) async throws -> Int64? {
        var reader = ClusterReader(source: source, start: position, limit: header.contentEnd ?? Int64.max,
                                   chunkSize: 1 << 20, modes: [video.number: .headers])
        var last: Int64?
        while let frame = try await reader.next() {
            last = max(last ?? frame.blockTimestamp, frame.blockTimestamp)
        }
        guard let last else { return nil }
        let frameTicks = video.defaultDuration.map { Int64($0) / max(1, header.timestampScale) } ?? 0
        return last + max(1, frameTicks)
    }

    // MARK: - Resources

    public enum Resource: Sendable, Equatable {
        case master
        case videoPlaylist
        case audioPlaylist(UInt64)
        case videoInit
        case audioInit(UInt64)
        case videoSegment(Int)
        case audioSegment(UInt64, Int)
        case muxedPlaylist
        case muxedInit
        case muxedSegment(Int)
    }

    /// The resource a path (relative to the master) names, if any.
    public nonisolated func resource(at path: String) -> Resource? {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.count {
        case 1:
            switch parts[0] {
            case "master.m3u8": return .master
            case "video.m3u8": return .videoPlaylist
            case "muxed.m3u8": return .muxedPlaylist
            default:
                guard parts[0].hasPrefix("audio-"), parts[0].hasSuffix(".m3u8"),
                      let number = UInt64(parts[0].dropFirst(6).dropLast(5)),
                      audioInits[number] != nil else { return nil }
                return .audioPlaylist(number)
            }
        case 2:
            enum Rendition { case video, muxed, audio(UInt64) }
            let rendition: Rendition
            if parts[0] == "video" {
                rendition = .video
            } else if parts[0] == "muxed" {
                rendition = .muxed
            } else if parts[0].hasPrefix("audio-"), let number = UInt64(parts[0].dropFirst(6)), audioInits[number] != nil {
                rendition = .audio(number)
            } else {
                return nil
            }
            if parts[1] == "init.mp4" {
                switch rendition {
                case .video: return .videoInit
                case .muxed: return .muxedInit
                case .audio(let n): return .audioInit(n)
                }
            }
            guard parts[1].hasSuffix(".m4s"), let k = Int(parts[1].dropLast(4)), k >= 0, k < index.count else { return nil }
            switch rendition {
            case .video: return .videoSegment(k)
            case .muxed: return .muxedSegment(k)
            case .audio(let n): return .audioSegment(n, k)
            }
        default:
            return nil
        }
    }

    /// The bytes and content type at `path`; nil for a path that names
    /// nothing.
    public func data(at path: String) async throws -> (data: Data, contentType: String)? {
        guard let resource = resource(at: path) else { return nil }
        let playlist = "application/vnd.apple.mpegurl"
        switch resource {
        case .master: return (Data(masterPlaylist.utf8), playlist)
        case .videoPlaylist: return (Data(mediaPlaylist("video").utf8), playlist)
        case .audioPlaylist(let n): return (Data(mediaPlaylist("audio-\(n)").utf8), playlist)
        case .muxedPlaylist: return (Data(muxedPlaylist.utf8), playlist)
        case .videoInit: return (videoInit, "video/mp4")
        case .audioInit(let n): return audioInits[n].map { ($0, "audio/mp4") }
        case .muxedInit: return (muxedInit, "video/mp4")
        case .videoSegment(let k): return (try await videoSegment(k), "video/mp4")
        case .audioSegment(let n, let k): return try await audioSegment(track: n, k).map { ($0, "audio/mp4") }
        case .muxedSegment(let k): return (try await muxedSegment(k), "video/mp4")
        }
    }

    /// Segments listed (so far, while the index grows).
    public nonisolated var segmentCount: Int { index.count }

    /// A media playlist: fixed for an index complete at `open`, else made
    /// from the index as it stands.
    nonisolated func mediaPlaylist(_ prefix: String) -> String {
        if let fixed = fixedPlaylists[prefix] { return fixed }
        return Playlists.media(index: index, timestampScale: header.timestampScale, prefix: prefix,
                               eventTargetDuration: eventTargetDuration)
    }

    /// The video's MP4 sample entry, for asking the platform whether it has
    /// a decoder (CoreMedia builds a format description from it as is).
    public nonisolated var videoSampleEntry: Data { Data(video.sampleEntry) }

    // MARK: - Subtitles

    /// `track`'s blocks known so far, after reading the indexed ones that
    /// start between `start` and `end` (seconds on the remux's timeline) and
    /// haven't been read. `revision` changes whenever a block is added, so a
    /// caller polling this can tell when to rebuild what it shows.
    public func subtitleBlocks(track number: UInt64, from start: Double, through end: Double) async throws
        -> (blocks: [SubtitleBlock], revision: Int) {
        guard let entry = subtitleEntries[number] else { return ([], 0) }
        if let cues = subtitleCues[number] {
            let first = cues.partitionIndex { self.subtitleSeconds($0.time) >= start }
            let last = cues.partitionIndex { self.subtitleSeconds($0.time) > end }
            let wanted = (first ..< last).filter { !(subtitleStores[number]?.requested.contains($0) ?? false) }
            if !wanted.isEmpty {
                subtitleStores[number, default: SubtitleStore()].requested.formUnion(wanted)
                do {
                    try await readIndexed(wanted.map { cues[$0] }, entry: entry)
                } catch {
                    subtitleStores[number]?.requested.subtract(wanted)
                    throw error
                }
            }
        }
        let store = subtitleStores[number] ?? SubtitleStore()
        let blocks = store.blocks.values.sorted { $0.ticks < $1.ticks }.map { raw in
            SubtitleBlock(start: subtitleSeconds(raw.ticks),
                          duration: raw.durationTicks.map { Double($0 * header.timestampScale) / 1e9 }, data: raw.data)
        }
        return (blocks, store.revision)
    }

    /// Seconds on the remux's timeline for a block's ticks.
    nonisolated func subtitleSeconds(_ ticks: Int64) -> Double {
        Double(ticks * header.timestampScale + video.offsetNanoseconds) / 1e9
    }

    private func readIndexed(_ cues: [CuePoint], entry: MatroskaTrack) async throws {
        let source = subtitleSource
        var pending = cues[...]
        try await withThrowingTaskGroup(of: RawSubtitle?.self) { group in
            func next() {
                guard let cue = pending.popFirst() else { return }
                group.addTask { try await SubtitleReading.read(cue, track: entry, from: source) }
            }
            for _ in 0 ..< SubtitleReading.concurrency { next() }
            while let read = try await group.next() {
                if let read { subtitleStores[entry.number, default: SubtitleStore()].add(read) }
                next()
            }
        }
    }

    private func keepSubtitles(of segment: ParsedSegment) {
        for (number, subtitles) in segment.subtitles {
            for subtitle in subtitles { subtitleStores[number, default: SubtitleStore()].add(subtitle) }
        }
    }

    // MARK: - Media segments

    /// mfhd sequence numbers count segments (see FragmentWriter).
    private static func sequenceNumber(_ k: Int) -> UInt32 { UInt32(k) + 1 }

    public func videoSegment(_ k: Int) async throws -> Data {
        let fragment = try videoFragment(k, from: try await parsedSegment(k))
        return FragmentWriter.mediaSegment(sequenceNumber: Self.sequenceNumber(k),
                                           runs: [TrackRun(trackID: 1, fragment: fragment, compositionOffsets: true)])
    }

    public func audioSegment(track number: UInt64, _ k: Int) async throws -> Data? {
        guard let plan = audio.first(where: { $0.track.number == number }) else { return nil }
        let runs = try await audioFragments(plan, k, from: try await audioOf(k))
            .map { TrackRun(trackID: 1, fragment: $0, compositionOffsets: false) }
        return FragmentWriter.mediaSegment(sequenceNumber: Self.sequenceNumber(k), runs: runs)
    }

    /// The video and the muxed audio track in one segment.
    public func muxedSegment(_ k: Int) async throws -> Data {
        // One parse for both: a second lookup could find it already let go
        // (a UHD segment is over the byte budget on its own) and read it again.
        let segment = try await parsedSegment(k)
        var runs = [TrackRun(trackID: 1, fragment: try videoFragment(k, from: segment), compositionOffsets: true)]
        if let plan = muxedAudio {
            runs += try await audioFragments(plan, k, from: segment).filter { !$0.samples.isEmpty }
                .map { TrackRun(trackID: 2, fragment: $0, compositionOffsets: false) }
        }
        return FragmentWriter.mediaSegment(sequenceNumber: Self.sequenceNumber(k), runs: runs)
    }

    private func videoFragment(_ k: Int, from segment: ParsedSegment) throws -> Fragment {
        let index = self.index
        let frames = segment.video
        guard !frames.isEmpty else { throw RemuxError.malformed("segment \(k) has no video") }
        let presentation = frames.map { video.time(ticks: $0.blockTimestamp, laceIndex: $0.laceIndex) }
        // Decode times are the presentation times in order (CMAF's
        // negative-composition-offset form), kept strictly increasing.
        var decode = presentation.sorted()
        for i in 1 ..< max(1, decode.count) where decode[i] <= decode[i - 1] { decode[i] = decode[i - 1] + 1 }
        var samples: [FragmentSample] = []
        samples.reserveCapacity(frames.count)
        for (i, frame) in frames.enumerated() {
            let duration: Int64
            if i + 1 < decode.count {
                duration = decode[i + 1] - decode[i]
            } else if let boundary = index.next(k) {
                let next = video.time(ticks: boundary.time)
                let gap = next - decode[i]
                duration = gap > 0 && gap <= 4 * video.nominalFrameTicks ? gap : video.nominalFrameTicks
            } else {
                duration = video.nominalFrameTicks
            }
            samples.append(FragmentSample(duration: UInt32(clamping: max(1, duration)),
                                          compositionOffset: Int32(clamping: presentation[i] - decode[i]),
                                          isSync: frame.isKeyframe, data: frame.data))
        }
        return Fragment(baseDecodeTime: UInt64(max(0, decode[0])), samples: samples)
    }

    /// A segment's audio for one track: a single run covering the
    /// segment's whole time.
    ///
    /// Covering it matters: AVPlayer's HLS clock runs on audio, so where an
    /// audio rendition runs out before the video (a track that ends early,
    /// a gap, audio that starts late) playback stalls there for good, or
    /// starts only where the audio does, even though a plain MP4 of the same
    /// streams plays through (measured, and the same with ffmpeg's HLS). So
    /// a gap is bridged by lengthening the sample before it (the decoder
    /// still outputs one frame; the player keeps time across the rest), and
    /// a stretch with no frames at all gets one placeholder sample as long as
    /// the stretch: a frame of silence (`SilentFrame`; it used to be the
    /// track's first frame, audible as a blip of the soundtrack).
    private func audioFragments(_ plan: AudioPlan, _ k: Int, from segment: ParsedSegment) async throws -> [Fragment] {
        let number = plan.track.number
        let index = self.index
        var frames = segment.audio[number] ?? []
        let isLast = index.isLast(k)
        let lower = k == 0 ? Int64.min : plan.boundary(ticks: index.startTime(k))
        let upper = isLast ? Int64.max : plan.boundary(ticks: index.startTime(k + 1))
        let start = plan.boundary(ticks: index.startTime(k))
        let end = plan.boundary(ticks: isLast ? index.endTime : index.startTime(k + 1))
        // Frames stored before this segment's first cluster were read as the
        // previous segment's spill.
        let grid = Int64(plan.gridSamples ?? 1024)
        if k > 0, (frames.first?.time ?? Int64.max) > lower + grid + grid / 2 {
            let previous = try await audioOf(k - 1)
            frames += (previous.spill[number] ?? []).filter { $0.time >= lower && $0.time < upper }
        }
        // File order isn't time order where a muxer interleaved loosely;
        // a frame read twice (the previous segment's spill) is kept once.
        var seen = Set<Int64>()
        frames = frames.sorted { $0.time < $1.time }.filter { seen.insert($0.time).inserted }

        func placeholder(_ duration: Int64) -> FragmentSample {
            FragmentSample(duration: UInt32(clamping: max(1, duration)), isSync: true, data: plan.placeholder)
        }
        guard let first = frames.first else {
            return [Fragment(baseDecodeTime: UInt64(max(0, start)), samples: [placeholder(end - start)])]
        }

        var samples: [FragmentSample] = []
        var base = first.time
        // A late start: at the first segment, only past a quarter second
        // (a frame's worth of offset is just where the track starts); later,
        // past a frame (the segment before ended at `start`).
        let lead = first.time - max(0, start)
        if lead > (k == 0 ? Int64(plan.sampleRate / 4) : grid) {
            samples.append(placeholder(lead))
            base = max(0, start)
        }
        let tolerance = max(grid, Int64(plan.sampleRate / 100))
        for (i, frame) in frames.enumerated() {
            var duration = Int64(frame.samples)
            if i + 1 < frames.count {
                // A gap to the next frame (more than a frame, or 10 ms) is
                // bridged by this one.
                let gap = frames[i + 1].time - (frame.time + duration)
                if gap > tolerance { duration += gap }
            }
            samples.append(FragmentSample(duration: UInt32(clamping: duration), isSync: true, data: frame.data))
        }
        // The end: on to where the next segment's audio starts, or, when the
        // track has nothing past this segment, to the segment's end.
        let last = frames[frames.count - 1]
        let runEnd = last.time + Int64(last.samples)
        let next = (segment.spill[number] ?? []).map(\.time).min()
        let target = next ?? end
        if target - runEnd > tolerance, !samples.isEmpty {
            samples[samples.count - 1].duration = UInt32(clamping: Int64(samples[samples.count - 1].duration) + target - runEnd)
        }
        return [Fragment(baseDecodeTime: UInt64(max(0, base)), samples: samples)]
    }

    // MARK: - Parsing a segment's clusters

    struct AudioFrame {
        /// In samples.
        var time: Int64
        var samples: Int
        var data: [UInt8]
    }

    struct ParsedSegment {
        /// Decode order, from the segment's keyframe to the next one.
        var video: [MatroskaFrame] = []
        /// In file order, within the segment's time.
        var audio: [UInt64: [AudioFrame]] = [:]
        /// Audio past the segment's end, read on the way.
        var spill: [UInt64: [AudioFrame]] = [:]
        /// Every subtitle block passed, whatever its time.
        var subtitles: [UInt64: [RawSubtitle]] = [:]
        var bytes = 0
        /// What the parse read from the source.
        var fetched: Int64 = 0
    }

    private func parsedSegment(_ k: Int) async throws -> ParsedSegment {
        if let task = parsed[k] {
            parsedOrder.removeAll { $0 == k }
            parsedOrder.append(k)
            return try await task.value
        }
        let task = Task { try await self.parse(k) }
        parsed[k] = task
        parsedOrder.append(k)
        trimCache()
        do {
            let segment = try await task.value
            bytesRead += segment.fetched
            keepAudio(of: segment, k)
            keepSubtitles(of: segment)
            if parsed[k] != nil {
                parsedBytes[k] = segment.bytes
                trimCache()
            }
            return segment
        } catch {
            parsed[k] = nil
            parsedOrder.removeAll { $0 == k }
            throw error
        }
    }

    private func trimCache() {
        while parsedOrder.count > 1,
              parsedOrder.count > max(1, options.cachedSegments)
              || parsedBytes.values.reduce(0, +) > options.cachedBytes {
            let oldest = parsedOrder.removeFirst()
            parsed[oldest] = nil
            parsedBytes[oldest] = nil
        }
    }

    /// Segment `k`'s audio (and its spill): kept from an earlier parse, else
    /// parsed.
    private func audioOf(_ k: Int) async throws -> ParsedSegment {
        if let kept = parsedAudio[k] {
            parsedAudioOrder.removeAll { $0 == k }
            parsedAudioOrder.append(k)
            return kept
        }
        return try await parsedSegment(k)
    }

    private func keepAudio(of segment: ParsedSegment, _ k: Int) {
        guard parsedAudio[k] == nil else { return }
        var audioOnly = segment
        audioOnly.video = []
        parsedAudio[k] = audioOnly
        parsedAudioOrder.append(k)
        parsedAudioBytes[k] = [segment.audio, segment.spill].flatMap { $0.values.joined() }
            .reduce(0) { $0 + $1.data.count }
        while parsedAudioOrder.count > 1,
              parsedAudioOrder.count > max(1, options.cachedAudioSegments)
              || parsedAudioBytes.values.reduce(0, +) > options.cachedAudioBytes {
            let oldest = parsedAudioOrder.removeFirst()
            parsedAudio[oldest] = nil
            parsedAudioBytes[oldest] = nil
        }
    }

    /// Lets go of every parsed segment (a session nobody is playing).
    public func dropCache() {
        parsed.removeAll()
        parsedOrder.removeAll()
        parsedBytes.removeAll()
        parsedAudio.removeAll()
        parsedAudioOrder.removeAll()
        parsedAudioBytes.removeAll()
    }

    private nonisolated func parse(_ k: Int) async throws -> ParsedSegment {
        let index = self.index
        let start = index.boundaries[k]
        let upperTicks: Int64? = index.next(k)?.time
        let nominalEnd = index.next(k)?.clusterPosition ?? index.endPosition
        let firstRead = Int(clamping: min(Int64(96 << 20), max(Int64(64 << 10), nominalEnd - start.clusterPosition + (256 << 10))))
        var modes: [UInt64: ClusterReader.Mode] = [video.track.number: .frames]
        var stripped: [UInt64: [UInt8]] = [video.track.number: video.track.strippedHeader]
        var plans: [UInt64: AudioPlan] = [:]
        for plan in audio {
            modes[plan.track.number] = .frames
            stripped[plan.track.number] = plan.track.strippedHeader
            plans[plan.track.number] = plan
        }
        // Subtitle frames come as stored: `SubtitleReading.decoded` undoes
        // their encodings.
        for number in subtitleEntries.keys { modes[number] = .frames }
        var reader = ClusterReader(source: source, start: start.clusterPosition, limit: header.contentEnd ?? Int64.max,
                                   chunkSize: firstRead, modes: modes, strippedHeaders: stripped)
        var result = ParsedSegment()
        var videoStarted = false, videoDone = false
        var reached = Set<UInt64>()
        var laceBase: [UInt64: Int64] = [:]
        let ticksPerSecond = Int64(1e9) / max(1, header.timestampScale)
        let lowerSamples = plans.mapValues { k == 0 ? Int64.min : $0.boundary(ticks: start.time) }
        let upperSamples = plans.mapValues { plan in upperTicks.map { plan.boundary(ticks: $0) } ?? Int64.max }

        while let frame = try await reader.next() {
            reader.setChunkSize(512 << 10)
            if frame.track == video.track.number {
                if !videoStarted {
                    guard frame.isKeyframe, frame.blockTimestamp >= start.time else { continue }
                    videoStarted = true
                } else if !videoDone, let upperTicks, frame.isKeyframe, frame.blockTimestamp >= upperTicks {
                    videoDone = true
                }
                if videoStarted, !videoDone {
                    result.video.append(frame)
                    result.bytes += frame.data.count
                }
            } else if let entry = subtitleEntries[frame.track] {
                if frame.laceCount == 1, let data = SubtitleReading.decoded(frame.data, track: entry) {
                    result.subtitles[frame.track, default: []].append(
                        RawSubtitle(ticks: frame.blockTimestamp, durationTicks: frame.blockDuration, data: data))
                }
            } else if let plan = plans[frame.track] {
                let samples = plan.samples(in: frame.data)
                let time: Int64
                if frame.laceIndex == 0 {
                    time = plan.blockTime(ticks: frame.blockTimestamp)
                } else {
                    time = laceBase[frame.track] ?? plan.blockTime(ticks: frame.blockTimestamp)
                }
                laceBase[frame.track] = time + Int64(samples)
                let audioFrame = AudioFrame(time: time, samples: samples, data: frame.data)
                let upper = upperSamples[frame.track]!
                if time >= upper {
                    // Past the end, read after the next keyframe, and clear
                    // of the boundary by a few frames: anything of this
                    // segment's stored behind the keyframe has been read.
                    if videoDone, time >= upper + 4 * Int64(plan.gridSamples ?? 1024) { reached.insert(frame.track) }
                    result.spill[frame.track, default: []].append(audioFrame)
                } else if time >= lowerSamples[frame.track]! {
                    result.audio[frame.track, default: []].append(audioFrame)
                    result.bytes += frame.data.count
                }
            }
            guard let upperTicks else { continue } // the last segment reads to the end
            if videoDone, reached.count == plans.count { break }
            if videoDone, frame.blockTimestamp > upperTicks + 3 * ticksPerSecond { break }
            if reader.position > nominalEnd + (64 << 20) { break }
        }
        result.fetched = reader.bytesFetched
        return result
    }
}

extension ClusterReader {
    mutating func setChunkSize(_ size: Int) { cursor.chunkSize = size }
}
