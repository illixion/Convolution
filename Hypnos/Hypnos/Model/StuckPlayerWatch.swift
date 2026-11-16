/*
 Hypnos - a native player that waits for data it never asks for

 visionOS 27's AVFoundation sometimes stops fetching a server's progressive
 file (not HLS) while it waits for more of it: buffer empty, nothing loaded
 past the playhead, its access log's byte count not moving, for good. Seen
 on a Vision Pro (2026-11-16) mid-file on an MP4 stored as one 30 MB chunk
 (3 of 10 plays; re-indexing that file, `MP4ReindexService`, made it 0 of
 10) and at the start of a loop, after the seek back from the end, on any
 layout (about one loop in four of a 30 MB video-only clip). A seek doesn't
 wake it; a new player item at the same place does, at once (a bare player
 recovered from three such stalls in four loops of that clip).

 So a window rebuilds its player at the playhead once its player has
 waited `stuckAfter` with no new bytes. A slow network still moves bytes and
 is left to buffer; HLS isn't watched at all, since a server still making a
 segment (a Jellyfin transcode) moves none for a while either. Rebuilds are
 capped, so a server that has gone away is left to the usual failure path.
 */

import Foundation

struct StuckPlayerWatch {
    /// How long a player may wait with no new bytes before it is rebuilt.
    static let stuckAfter: TimeInterval = 3
    /// At most this many rebuilds in `rebuildWindow`.
    static let maxRebuilds = 3
    static let rebuildWindow: TimeInterval = 60

    private var lastBytes: Int64?
    private var stuckSince: Date?
    private var rebuilds: [Date] = []

    /// Forgets the current wait (the player plays again, or isn't watched).
    mutating func reset() {
        lastBytes = nil
        stuckSince = nil
    }

    /// Called about once a second while the player waits; true when it
    /// should be rebuilt now.
    mutating func update(bytesTransferred bytes: Int64, at now: Date) -> Bool {
        defer { lastBytes = bytes }
        guard let lastBytes, bytes == lastBytes else {
            stuckSince = nil
            return false
        }
        let since = stuckSince ?? now
        stuckSince = since
        guard now.timeIntervalSince(since) >= Self.stuckAfter - 1 else { return false }
        rebuilds.removeAll { now.timeIntervalSince($0) > Self.rebuildWindow }
        guard rebuilds.count < Self.maxRebuilds else { return false }
        rebuilds.append(now)
        stuckSince = nil
        return true
    }
}
