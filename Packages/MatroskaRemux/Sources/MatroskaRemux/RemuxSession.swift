/*
 MatroskaRemux - one file served as HLS

 `open` reads the file's head, decides which tracks go in (`TrackPlans`),
 reads the first frames (codec details Matroska doesn't store: a VP9
 keyframe header, an AC-3 syncframe, the first timestamps) and builds the
 segment index. After that everything is on demand: playlists and init
 segments are computed once, and a media segment is muxed when the player
 asks for it, from that segment's clusters only.

 Video and audio of one segment come from the same byte range, and the
 player asks for them at nearly the same moment, so a segment's clusters
 are parsed once into every kept track's frames and the result shared
 (`parsed`, which keeps the last few). The parse reads past the segment's
 last cluster until every track has a frame beyond the segment's end:
 muxers interleave by decode time, so audio belonging just before a
 keyframe can sit after it in the file.

 Which segment a frame belongs to is decided by time, not by where it is:
 video from one segment keyframe up to the next (decode order), audio by
 its snapped time against the segment's boundary. A frame stored before its
 segment's first cluster is found in the previous segment's read-past
 (`spill`), and taken from there.

 Output is deterministic, so a segment the player re-requests (after a
 seek, or a decoder reset when visionOS backgrounds the window) is
 byte-identical to the first.
 */

import Foundation

public struct RemuxOptions: Sendable {
    /// Index a file without Cues by scanning its clusters. Nil: only when
    /// the source is local.
    public var allowsClusterScan: Bool?
    /// How far into the file `open` reads for the first frames.
    public var probeByteLimit: Int64 = 48 << 20
    /// Parsed segments kept for the renditions still to ask for them: by
    /// count, and by bytes (the last one is always kept).
    public var cachedSegments = 2
    public var cachedBytes = 64 << 20

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
}

public actor RemuxSession {
    public nonisolated let summary: RemuxSummary
    public nonisolated let masterPlaylist: String

    nonisolated let source: any ByteSource
    nonisolated let header: MatroskaHeader
    nonisolated let index: SegmentIndex
    nonisolated let video: VideoPlan
    nonisolated let audio: [AudioPlan]
    nonisolated let videoPlaylist: String
    nonisolated let audioPlaylists: [UInt64: String]
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
    public nonisolated let muxedPlaylist: String
    nonisolated let muxedInit: Data

    private var parsed: [Int: Task<ParsedSegment, Error>] = [:]
    private var parsedOrder: [Int] = []
    private var parsedBytes: [Int: Int] = [:]

    /// Bytes read from the source while serving segments (for the caller's
    /// logs).
    public private(set) var bytesRead: Int64 = 0

    private init(source: any ByteSource, header: MatroskaHeader, index: SegmentIndex, video: VideoPlan,
                 audio: [AudioPlan], dropped: [RemuxSummary.DroppedTrack], scanned: Bool, options: RemuxOptions) {
        self.source = source
        self.header = header
        self.index = index
        self.video = video
        self.audio = audio
        self.options = options
        let names = Playlists.renditionNames(audio)
        videoPlaylist = Playlists.media(index: index, timestampScale: header.timestampScale, prefix: "video")
        var audioPlaylists: [UInt64: String] = [:]
        var audioInits: [UInt64: Data] = [:]
        for plan in audio {
            audioPlaylists[plan.track.number] = Playlists.media(index: index, timestampScale: header.timestampScale,
                                                               prefix: "audio-\(plan.track.number)")
            audioInits[plan.track.number] = Data(FragmentWriter.initSegment(
                handler: .audio, timescale: UInt32(plan.sampleRate),
                language: LanguageCodes.iso6392T(fromBCP47: plan.track.bcp47Language), sampleEntry: plan.sampleEntry))
        }
        self.audioPlaylists = audioPlaylists
        self.audioInits = audioInits
        videoInit = Data(FragmentWriter.initSegment(
            handler: .video(width: video.displayWidth, height: video.displayHeight), timescale: video.timescale,
            language: "und", sampleEntry: video.sampleEntry))
        masterPlaylist = Playlists.master(index: index, header: header, video: video, audio: audio, names: names)
        muxedAudio = Playlists.defaultAudio(audio)
        muxedPlaylist = Playlists.media(index: index, timestampScale: header.timestampScale, prefix: "muxed")
        var muxedTracks = [FragmentWriter.TrackHeader(handler: .video(width: video.displayWidth, height: video.displayHeight),
                                                      timescale: video.timescale, language: "und",
                                                      sampleEntry: video.sampleEntry)]
        if let plan = muxedAudio {
            muxedTracks.append(.init(handler: .audio, timescale: UInt32(plan.sampleRate),
                                     language: LanguageCodes.iso6392T(fromBCP47: plan.track.bcp47Language),
                                     sampleEntry: plan.sampleEntry))
        }
        muxedInit = Data(FragmentWriter.initSegment(tracks: muxedTracks))
        let duration = Double(index.endTime - (index.boundaries.first?.time ?? 0)) * Double(header.timestampScale) / 1e9
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
            scannedClusters: scanned)
    }

    // MARK: - Opening

    public static func open(source: any ByteSource, options: RemuxOptions = RemuxOptions()) async throws -> RemuxSession {
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

        // Every rendition's times start at or after zero (tfdt is unsigned):
        // a file whose first timestamps are negative, or whose first audio
        // block is earlier than its codec delay (an AAC or Opus track that
        // starts at 0 with priming ahead of it), is shifted as a whole, so
        // audio and video keep their relative timing.
        let scale = header.timestampScale
        var earliest = (firsts.videoFirstTicks ?? keyframe.blockTimestamp) * scale
        for track in candidates {
            guard let first = firsts.audio[track.number] else { continue }
            earliest = min(earliest, first.blockTimestamp * scale - Int64(clamping: track.codecDelay))
        }
        let offsetNanoseconds = max(0, -earliest)

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

        // The index: Cues, else (for a local file) a scan of the clusters.
        let videoCues = header.cues.filter { $0.track == videoTrack.number }.sorted { $0.time < $1.time }
        var keyframes: [SegmentIndex.Boundary] = []
        var endTime: Int64?
        var scanned = false
        let endPosition = header.contentEnd ?? firstCluster
        if !videoCues.isEmpty {
            keyframes = videoCues.map { .init(time: $0.time, clusterPosition: $0.clusterPosition) }
            if keyframes[0].time > keyframe.blockTimestamp || keyframes[0].clusterPosition > firstCluster {
                keyframes.insert(.init(time: keyframe.blockTimestamp, clusterPosition: firstCluster), at: 0)
            }
        } else if options.allowsClusterScan ?? source.isLocal {
            let scan = try await scanKeyframes(source: source, start: firstCluster, limit: contentEnd,
                                               video: videoTrack.number)
            keyframes = scan.keyframes
            endTime = scan.endTime
            scanned = true
        } else {
            throw RemuxError.declined("no Cues, and the source is remote")
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
        var endPositionValue = endPosition
        if header.contentEnd == nil { endPositionValue = keyframes.last!.clusterPosition }
        let index = SegmentIndex.build(keyframes: keyframes, endTime: end ?? keyframes.last!.time + 1,
                                       endPosition: endPositionValue, timestampScale: header.timestampScale)
        guard index.count > 0 else { throw RemuxError.declined("no segments") }

        return RemuxSession(source: source, header: header, index: index, video: video, audio: audio,
                            dropped: dropped, scanned: scanned, options: options)
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
    private static func lastFrameTime(source: any ByteSource, header: MatroskaHeader, from position: Int64,
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
                      audioPlaylists[number] != nil else { return nil }
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
        case .videoPlaylist: return (Data(videoPlaylist.utf8), playlist)
        case .audioPlaylist(let n): return audioPlaylists[n].map { (Data($0.utf8), playlist) }
        case .muxedPlaylist: return (Data(muxedPlaylist.utf8), playlist)
        case .videoInit: return (videoInit, "video/mp4")
        case .audioInit(let n): return audioInits[n].map { ($0, "audio/mp4") }
        case .muxedInit: return (muxedInit, "video/mp4")
        case .videoSegment(let k): return (try await videoSegment(k), "video/mp4")
        case .audioSegment(let n, let k): return try await audioSegment(track: n, k).map { ($0, "audio/mp4") }
        case .muxedSegment(let k): return (try await muxedSegment(k), "video/mp4")
        }
    }

    public nonisolated var segmentCount: Int { index.count }

    /// The video's MP4 sample entry, for asking the platform whether it has
    /// a decoder (CoreMedia builds a format description from it as is).
    public nonisolated var videoSampleEntry: Data { Data(video.sampleEntry) }

    // MARK: - Media segments

    /// mfhd sequence numbers count segments (see FragmentWriter).
    private static func sequenceNumber(_ k: Int) -> UInt32 { UInt32(k) + 1 }

    public func videoSegment(_ k: Int) async throws -> Data {
        let fragment = try await videoFragment(k)
        return FragmentWriter.mediaSegment(sequenceNumber: Self.sequenceNumber(k),
                                           runs: [TrackRun(trackID: 1, fragment: fragment, compositionOffsets: true)])
    }

    public func audioSegment(track number: UInt64, _ k: Int) async throws -> Data? {
        guard let plan = audio.first(where: { $0.track.number == number }) else { return nil }
        let runs = try await audioFragments(plan, k).map { TrackRun(trackID: 1, fragment: $0, compositionOffsets: false) }
        return FragmentWriter.mediaSegment(sequenceNumber: Self.sequenceNumber(k), runs: runs)
    }

    /// The video and the muxed audio track in one segment.
    public func muxedSegment(_ k: Int) async throws -> Data {
        var runs = [TrackRun(trackID: 1, fragment: try await videoFragment(k), compositionOffsets: true)]
        if let plan = muxedAudio {
            runs += try await audioFragments(plan, k).filter { !$0.samples.isEmpty }
                .map { TrackRun(trackID: 2, fragment: $0, compositionOffsets: false) }
        }
        return FragmentWriter.mediaSegment(sequenceNumber: Self.sequenceNumber(k), runs: runs)
    }

    private func videoFragment(_ k: Int) async throws -> Fragment {
        let segment = try await parsedSegment(k)
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
            } else if k + 1 < index.count {
                let next = video.time(ticks: index.startTime(k + 1))
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
    /// a stretch with no frames at all gets one placeholder sample (the
    /// track's first frame, usually silence) as long as the stretch.
    private func audioFragments(_ plan: AudioPlan, _ k: Int) async throws -> [Fragment] {
        let number = plan.track.number
        let segment = try await parsedSegment(k)
        var frames = segment.audio[number] ?? []
        let isLast = k + 1 == index.count
        let lower = k == 0 ? Int64.min : plan.boundary(ticks: index.startTime(k))
        let upper = isLast ? Int64.max : plan.boundary(ticks: index.startTime(k + 1))
        let start = plan.boundary(ticks: index.startTime(k))
        let end = plan.boundary(ticks: isLast ? index.endTime : index.startTime(k + 1))
        // Frames stored before this segment's first cluster were read as the
        // previous segment's spill.
        let grid = Int64(plan.gridSamples ?? 1024)
        if k > 0, (frames.first?.time ?? Int64.max) > lower + grid + grid / 2 {
            let previous = try await parsedSegment(k - 1)
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
        var bytes = 0
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

    /// Lets go of every parsed segment (a session nobody is playing).
    public func dropCache() {
        parsed.removeAll()
        parsedOrder.removeAll()
        parsedBytes.removeAll()
    }

    private func noteRead(_ count: Int64) { bytesRead += count }

    private nonisolated func parse(_ k: Int) async throws -> ParsedSegment {
        let start = index.boundaries[k]
        let upperTicks: Int64? = k + 1 < index.count ? index.startTime(k + 1) : nil
        let nominalEnd = k + 1 < index.count ? index.boundaries[k + 1].clusterPosition : index.endPosition
        let firstRead = Int(clamping: min(Int64(96 << 20), max(Int64(64 << 10), nominalEnd - start.clusterPosition + (256 << 10))))
        var modes: [UInt64: ClusterReader.Mode] = [video.track.number: .frames]
        var stripped: [UInt64: [UInt8]] = [video.track.number: video.track.strippedHeader]
        var plans: [UInt64: AudioPlan] = [:]
        for plan in audio {
            modes[plan.track.number] = .frames
            stripped[plan.track.number] = plan.track.strippedHeader
            plans[plan.track.number] = plan
        }
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
        noteReadDetached(reader.bytesFetched)
        return result
    }

    private nonisolated func noteReadDetached(_ count: Int64) {
        Task { await self.noteRead(count) }
    }
}

extension ClusterReader {
    mutating func setChunkSize(_ size: Int) { cursor.chunkSize = size }
}
