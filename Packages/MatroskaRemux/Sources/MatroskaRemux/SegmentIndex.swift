/*
 MatroskaRemux - cutting the file into HLS segments

 A segment starts at a video keyframe and is the clusters from that
 keyframe's to the next segment's. The keyframes come from the Cues (one
 cue point per keyframe from mkvmerge and ffmpeg, sparser from some
 muxers); a local file without Cues is indexed by reading its clusters'
 block headers, skipping every frame body; a server's file without Cues by
 hopping from cluster to cluster (`ClusterHopper`), which finds the
 keyframes clusters start with.

 Keyframes a second or two apart would make segments too short for HLS,
 so they are merged: a cut is made once a segment has at least
 `minimumSeconds`, at whichever keyframe brings it nearest `targetSeconds`
 (so a 2 s GOP gives 6 s segments, a 4 s GOP 8 s, a 10 s GOP 10 s). A last
 segment shorter than `minimumSeconds / 2` joins the one before it.

 `Builder` makes those cuts as keyframes arrive, committing a boundary only
 once no later keyframe could change it, so an index can be published while
 it grows: a segment listed once never changes. An index still growing ends
 at its last boundary, the start of a segment not listed yet.
 */

import Foundation

public struct SegmentIndex: Sendable {
    public struct Boundary: Sendable, Equatable {
        /// The keyframe's timestamp, in ticks.
        public var time: Int64
        /// Offset of the Cluster holding it.
        public var clusterPosition: Int64
    }

    /// Segment `k` starts at `boundaries[k]`. While the index grows, the
    /// last one is where the next segment, not listed yet, starts.
    public var boundaries: [Boundary]
    /// End of the last segment, in ticks (while growing: the last boundary).
    public var endTime: Int64
    /// Where the last segment's bytes end.
    public var endPosition: Int64
    /// Every segment is known. False while a file without Cues is indexed.
    public var isComplete = true

    /// Segments listed: those whose end is known.
    public var count: Int { isComplete ? boundaries.count : max(0, boundaries.count - 1) }

    public func startTime(_ k: Int) -> Int64 { boundaries[k].time }
    public func endTime(_ k: Int) -> Int64 { k + 1 < boundaries.count ? boundaries[k + 1].time : endTime }

    /// The segment runs to the end of the file.
    func isLast(_ k: Int) -> Bool { isComplete && k + 1 == boundaries.count }

    /// Where segment `k + 1` starts, unless `k` is the last.
    func next(_ k: Int) -> Boundary? { k + 1 < boundaries.count ? boundaries[k + 1] : nil }

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
        var builder = Builder(timestampScale: timestampScale)
        for keyframe in keyframes { builder.add(keyframe) }
        return builder.finish(endTime: endTime, endPosition: endPosition, mergesSliver: true)
    }

    /// The cuts, made as keyframes arrive in time order.
    struct Builder: Sendable {
        let ticksPerSecond: Double
        private(set) var boundaries: [Boundary] = []
        /// Keyframes after the last boundary, not yet decided on.
        private var pending: [Boundary] = []

        init(timestampScale: Int64) {
            ticksPerSecond = 1e9 / Double(max(1, timestampScale))
        }

        /// Adds a keyframe (ignored unless later, and no earlier in the
        /// file, than the last one added) and commits what it decides.
        mutating func add(_ keyframe: Boundary) {
            if let last = pending.last ?? boundaries.last,
               !(keyframe.time > last.time && keyframe.clusterPosition >= last.clusterPosition) { return }
            if boundaries.isEmpty {
                boundaries.append(keyframe)
            } else {
                pending.append(keyframe)
                commit(final: false, through: nil)
            }
        }

        /// Commits what can be decided once the clusters up to one at `time`
        /// (ticks) have been read: a keyframe later than that (a second of
        /// slack, as a block may be timed a little before its cluster) that
        /// would make a segment longer than `maximumSeconds` never wins.
        mutating func scanned(through time: Int64) {
            commit(final: false, through: time)
        }

        /// The index with every boundary committed so far.
        func snapshot(endPosition: Int64) -> SegmentIndex {
            SegmentIndex(boundaries: boundaries, endTime: boundaries.last?.time ?? 0, endPosition: endPosition,
                         isComplete: false)
        }

        /// The finished index. A short last segment joins the one before if
        /// `mergesSliver`, or if its start was committed only now, after the
        /// `listed` boundaries (nobody has seen the segment before it end
        /// there).
        mutating func finish(endTime: Int64, endPosition: Int64, mergesSliver: Bool, listed: Int = 0) -> SegmentIndex {
            commit(final: true, through: nil)
            let mergesSliver = mergesSliver || boundaries.count > listed
            guard !boundaries.isEmpty else {
                return SegmentIndex(boundaries: [], endTime: endTime, endPosition: endPosition)
            }
            // A sliver at the end joins the segment before it.
            if mergesSliver, boundaries.count > 1,
               Double(endTime - boundaries.last!.time) / ticksPerSecond < minimumSeconds / 2 {
                boundaries.removeLast()
            }
            return SegmentIndex(boundaries: boundaries, endTime: max(endTime, boundaries.last!.time + 1),
                                endPosition: endPosition)
        }

        private mutating func commit(final: Bool, through scannedTime: Int64?) {
            while let start = boundaries.last.map({ Double($0.time) }) {
                func elapsed(_ i: Int) -> Double { (Double(pending[i].time) - start) / ticksPerSecond }
                guard let i = pending.indices.first(where: { elapsed($0) >= minimumSeconds }) else { return }
                // Take a later keyframe instead while it lands nearer the
                // target without making the segment too long.
                var pick = i
                var decided = final
                while pick + 1 < pending.count {
                    let next = elapsed(pick + 1), current = elapsed(pick)
                    guard next <= maximumSeconds, abs(next - targetSeconds) < abs(current - targetSeconds) else {
                        decided = true
                        break
                    }
                    pick += 1
                }
                if !decided {
                    // Out of keyframes: a later one could still win, unless
                    // the pick is past the target already (anything later is
                    // further from it) or anything later is past the maximum.
                    if elapsed(pick) >= targetSeconds {
                        decided = true
                    } else if let scannedTime, (Double(scannedTime) - start) / ticksPerSecond > maximumSeconds + 1 {
                        decided = true
                    }
                }
                guard decided else { return }
                boundaries.append(pending[pick])
                pending.removeFirst(pick + 1)
            }
        }
    }
}
