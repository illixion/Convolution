/*
 MatroskaRemux - cutting the file into HLS segments

 A segment starts at a video keyframe and is the clusters from that
 keyframe's to the next segment's. The keyframes come from the Cues (one
 cue point per keyframe from mkvmerge and ffmpeg, sparser from some
 muxers); a local file without Cues is indexed by reading its clusters'
 block headers, skipping every frame body.

 Keyframes a second or two apart would make segments too short for HLS,
 so they are merged: a cut is made once a segment has at least
 `minimumSeconds`, at whichever keyframe brings it nearest `targetSeconds`
 (so a 2 s GOP gives 6 s segments, a 4 s GOP 8 s, a 10 s GOP 10 s). A last
 segment shorter than `minimumSeconds / 2` joins the one before it.
 */

import Foundation

public struct SegmentIndex: Sendable {
    public struct Boundary: Sendable, Equatable {
        /// The keyframe's timestamp, in ticks.
        public var time: Int64
        /// Offset of the Cluster holding it.
        public var clusterPosition: Int64
    }

    /// Segment `k` starts at `boundaries[k]`.
    public var boundaries: [Boundary]
    /// End of the last segment, in ticks.
    public var endTime: Int64
    /// Where the last segment's bytes end.
    public var endPosition: Int64

    public var count: Int { boundaries.count }

    public func startTime(_ k: Int) -> Int64 { boundaries[k].time }
    public func endTime(_ k: Int) -> Int64 { k + 1 < boundaries.count ? boundaries[k + 1].time : endTime }

    /// Bytes the segment spans in the file (its clusters).
    public func byteLength(_ k: Int) -> Int64 {
        let end = k + 1 < boundaries.count ? boundaries[k + 1].clusterPosition : endPosition
        return max(0, end - boundaries[k].clusterPosition)
    }

    static let targetSeconds = 6.0
    static let minimumSeconds = 4.0
    static let maximumSeconds = 10.0

    /// Segments from keyframe positions (`keyframes` sorted by time, the
    /// first being the file's first video keyframe).
    static func build(keyframes: [Boundary], endTime: Int64, endPosition: Int64, timestampScale: Int64) -> SegmentIndex {
        let ticksPerSecond = 1e9 / Double(timestampScale)
        var unique: [Boundary] = []
        for keyframe in keyframes where unique.last.map({ keyframe.time > $0.time && keyframe.clusterPosition >= $0.clusterPosition }) ?? true {
            unique.append(keyframe)
        }
        guard let first = unique.first else {
            return SegmentIndex(boundaries: [], endTime: endTime, endPosition: endPosition)
        }
        var boundaries = [first]
        var i = 1
        while i < unique.count {
            let start = Double(boundaries.last!.time)
            let elapsed = (Double(unique[i].time) - start) / ticksPerSecond
            guard elapsed >= minimumSeconds else { i += 1; continue }
            // Take a later keyframe instead while it lands nearer the target
            // without making the segment too long.
            var pick = i
            while pick + 1 < unique.count {
                let next = (Double(unique[pick + 1].time) - start) / ticksPerSecond
                let current = (Double(unique[pick].time) - start) / ticksPerSecond
                guard next <= maximumSeconds, abs(next - targetSeconds) < abs(current - targetSeconds) else { break }
                pick += 1
            }
            boundaries.append(unique[pick])
            i = pick + 1
        }
        // A sliver at the end joins the segment before it.
        if boundaries.count > 1,
           Double(endTime - boundaries.last!.time) / ticksPerSecond < minimumSeconds / 2 {
            boundaries.removeLast()
        }
        return SegmentIndex(boundaries: boundaries, endTime: max(endTime, boundaries.last!.time + 1), endPosition: endPosition)
    }
}
