/*
 MatroskaRemux - one frame of a file, as an MP4 a thumbnailer can open

 AVAssetImageGenerator can't open Matroska, so a grid of MKV or WebM files
 has no thumbnails. `VideoStill.make` writes the smallest MP4 that has the
 frame: the video's init segment and one fragment holding a single
 keyframe, at time 0. AVFoundation opens it from a file like any MP4.

 Which keyframe: the one at or before a tenth of the way in (the first
 frames are often black), and no later than ten minutes in. With Cues that
 is a cue point and its cluster; without them, a probe at that fraction of
 the file's bytes finds a Cluster and hops on to the first that starts with
 a keyframe (`ClusterHopper`), reading cluster heads, not frames. Either way
 a server's file is read in ranges: the head (and Cues), a 256 KB probe
 without them, the start of one cluster and the keyframe: a few hundred KB
 for 1080p, a few MB for UHD.
 */

import Foundation

public struct VideoStill: Sendable {
    /// An MP4 file: the init segment and one fragment with the keyframe.
    public var mp4: Data
    /// Where the frame is, in seconds from the video's start.
    public var seconds: Double
    /// The picture size players show.
    public var width: Int
    public var height: Int
    /// What was read from the source to make it.
    public var bytesRead: Int64
    public var reads: Int

    /// The keyframe at or before `fraction` of the video (by time with
    /// Cues, by bytes without), but no later than `maximumSeconds` in.
    public static func make(source: any ByteSource, fraction: Double = 0.1,
                            maximumSeconds: Double = 600) async throws -> VideoStill {
        let counting = CountedSource(base: source)
        let header = try await MatroskaHeaderReader.read(counting)
        guard let firstCluster = header.firstClusterPosition else { throw RemuxError.malformed("no Cluster") }
        guard let track = header.tracks.first(where: { $0.kind == .video && $0.isEnabled }) else {
            throw RemuxError.declined("no video track")
        }
        guard SupportedCodecs.video.contains(track.codecID) else { throw RemuxError.declined("video codec \(track.codecID)") }
        if let encoding = track.unreadableEncoding { throw RemuxError.declined("video track is \(encoding)") }
        let contentEnd = header.contentEnd ?? Int64.max
        let scale = header.timestampScale
        let ticksPerSecond = 1e9 / Double(max(1, scale))

        // Where to look: a cluster, and the earliest keyframe time to take.
        var cluster = firstCluster
        var notBefore = Int64.min
        let cues = header.cues.filter { $0.track == track.number }.sorted { $0.time < $1.time }
        if let first = cues.first {
            let end = header.duration.map { Int64($0.rounded()) } ?? cues.last!.time
            let span = Double(end - first.time)
            let target = first.time + Int64(min(span * fraction, maximumSeconds * ticksPerSecond))
            let cue = cues.last { $0.time <= target } ?? first
            cluster = cue.clusterPosition
            notBefore = cue.time
        } else if contentEnd < Int64.max, fraction > 0 {
            var share = fraction
            if let duration = header.duration, duration > 0 {
                share = min(share, maximumSeconds * ticksPerSecond / duration)
            }
            let offset = firstCluster + Int64(Double(contentEnd - firstCluster) * share)
            if let found = try await keyframeCluster(near: offset, source: counting, limit: contentEnd,
                                                     video: track.number) {
                cluster = found
            }
        }

        // The keyframe: the first of the video's from there.
        var reader = ClusterReader(source: counting, start: cluster, limit: contentEnd, chunkSize: 64 << 10,
                                   modes: [track.number: .frames], strippedHeaders: [track.number: track.strippedHeader])
        var keyframe: MatroskaFrame?
        while let frame = try await reader.next() {
            if frame.isKeyframe, frame.blockTimestamp >= notBefore {
                keyframe = frame
                break
            }
            if reader.bytesFetched > 32 << 20 { break }
        }
        guard let keyframe else { throw RemuxError.declined("no video keyframe where the still was looked for") }

        let video = try VideoPlan.make(track: track, firstKeyframe: keyframe.data, firstKeyframeTicks: keyframe.blockTimestamp,
                                       timestampScale: scale, offsetNanoseconds: -keyframe.blockTimestamp * scale)
        var mp4 = Data(FragmentWriter.initSegment(
            handler: .video(width: video.displayWidth, height: video.displayHeight), timescale: video.timescale,
            language: "und", sampleEntry: video.sampleEntry))
        let sample = FragmentSample(duration: UInt32(clamping: video.nominalFrameTicks), isSync: true, data: keyframe.data)
        mp4.append(FragmentWriter.mediaSegment(sequenceNumber: 1, runs: [
            TrackRun(trackID: 1, fragment: Fragment(baseDecodeTime: 0, samples: [sample]), compositionOffsets: true),
        ]))
        let start = cues.first?.time ?? 0
        let counts = counting.counts
        return VideoStill(mp4: mp4, seconds: Double(keyframe.blockTimestamp - start) / ticksPerSecond,
                          width: video.displayWidth, height: video.displayHeight, bytesRead: counts.bytes,
                          reads: counts.reads)
    }

    /// A cluster starting with a video keyframe at or after `offset`: a probe
    /// read finds a Cluster, then hops find one whose first video block is a
    /// keyframe. Nil when none turns up within a few dozen clusters.
    static func keyframeCluster(near offset: Int64, source: any ByteSource, limit: Int64,
                                video: UInt64) async throws -> Int64? {
        // 256 KB holds a cluster start for most files; larger clusters get
        // one more read of 1 MB (overlapping by a header's length).
        var found = try await ProgressiveIndexing.findCluster(in: source, from: offset, length: 256 << 10, limit: limit)
        if found == nil {
            found = try await ProgressiveIndexing.findCluster(in: source, from: offset + (256 << 10) - 24,
                                                              length: 1 << 20, limit: limit)
        }
        guard let found else { return nil }
        var hopper = ClusterHopper(source: source, start: found, limit: limit, videoTrack: video)
        for _ in 0 ..< 48 {
            switch try await hopper.next() {
            case .cluster(let head):
                if head.firstVideo?.isKeyframe == true { return head.position }
            case .unknownSize(let position):
                // Can't hop: read on from this one to its keyframe instead.
                return position
            case .end:
                return nil
            }
        }
        return nil
    }
}

/// A source that counts what is read through it.
final class CountedSource: ByteSource, @unchecked Sendable {
    let base: any ByteSource
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var reads = 0

    init(base: any ByteSource) { self.base = base }

    var isLocal: Bool { base.isLocal }
    var counts: (bytes: Int64, reads: Int) { lock.withLock { (bytes, reads) } }

    func length() async throws -> Int64? { try await base.length() }

    func read(_ range: Range<Int64>) async throws -> Data {
        let data = try await base.read(range)
        lock.withLock {
            bytes += Int64(data.count)
            reads += 1
        }
        return data
    }
}
