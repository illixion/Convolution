/*
 mkvremux - writes a Matroska file's HLS to a folder

     swift run mkvremux <file.mkv or http URL> <folder> [segments]
     swift run mkvremux --time <file.mkv or http URL>
     swift run mkvremux --still <file.mkv or http URL> <out.mp4>

 `segments` limits the media segments written, e.g. `0-2` or `7`. An http
 URL is read with range requests, as the app reads a server's file.
 `--time` only opens the file and waits for its index, printing how long
 each took and what was read (for a file without Cues, which is indexed
 while it plays). `--still` writes the one-keyframe MP4 the app makes
 thumbnails from (`VideoStill`).

 Writes master.m3u8, the media playlists, and every init and media segment,
 at the paths the app serves them on, then prints the summary. Serve the
 folder (`python3 -m http.server`) and point ffmpeg, Safari or the
 hdrplay probe at master.m3u8 to check a remux without the app.
 */

import Foundation
import MatroskaRemux

/// A file over HTTP, read with range requests, counting them.
final class HTTPByteSource: ByteSource, @unchecked Sendable {
    let url: URL
    private let session: URLSession
    private let lock = NSLock()
    private(set) var requests = 0
    private(set) var bytes: Int64 = 0

    init(url: URL) {
        self.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func length() async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.expectedContentLength
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, _) = try await session.data(for: request)
        lock.withLock {
            requests += 1
            bytes += Int64(data.count)
        }
        return data
    }

    var counts: (requests: Int, bytes: Int64) { lock.withLock { (requests, bytes) } }
}

func source(_ path: String) throws -> any ByteSource {
    path.hasPrefix("http") ? HTTPByteSource(url: URL(string: path)!) : try FileByteSource(url: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--still" {
    do {
        let bytes = try source(arguments[2])
        let started = Date()
        let still = try await VideoStill.make(source: bytes)
        try still.mp4.write(to: URL(fileURLWithPath: arguments[3]))
        print(String(format: "still at %.3f s, %dx%d, %d bytes, made in %.3f s from %d reads, %lld bytes",
                     still.seconds, still.width, still.height, still.mp4.count, Date().timeIntervalSince(started),
                     still.reads, still.bytesRead))
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}
if arguments.count == 3, arguments[1] == "--time" {
    do {
        let bytes = try source(arguments[2])
        let started = Date()
        let session = try await RemuxSession.open(source: bytes)
        let opened = Date().timeIntervalSince(started)
        let atOpen = (bytes as? HTTPByteSource)?.counts
        try await session.waitUntilIndexed()
        let indexed = Date().timeIntervalSince(started)
        let total = (bytes as? HTTPByteSource)?.counts
        print(String(format: "opened in %.3f s (%@), %d segments listed; indexed in %.3f s, %d segments",
                     opened, session.summary.indexing ? "growing" : "complete", session.summary.segmentCount,
                     indexed, session.segmentCount))
        if let atOpen, let total {
            print("reads: \(atOpen.requests) requests / \(atOpen.bytes) bytes at open, \(total.requests) / \(total.bytes) in all")
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}
guard arguments.count == 3 || arguments.count == 4 else {
    print("usage: mkvremux <file.mkv or URL> <folder> [segments] | mkvremux --time <file.mkv or URL>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)

do {
    let started = Date()
    let session = try await RemuxSession.open(source: try source(arguments[1]))
    let opened = Date().timeIntervalSince(started)
    let summary = session.summary
    print("opened in \(String(format: "%.3f", opened)) s: \(summary.docType) \(summary.video.codec) \(summary.width)x\(summary.height) \(summary.videoRange), \(summary.segmentCount) segments, \(String(format: "%.3f", summary.durationSeconds)) s\(summary.scannedClusters ? " (scanned)" : "")")
    for track in summary.audio {
        print("  audio \(track.number): \(track.codec) \(track.codecs) \(track.channels ?? 0)ch \(track.language ?? "-") \"\(track.name)\"\(track.isDefault ? " default" : "")")
    }
    for track in summary.dropped {
        print("  dropped \(track.number): \(track.codecID) (\(track.reason))")
    }
    var segments = 0 ..< session.segmentCount
    if arguments.count == 4 {
        let bounds = arguments[3].split(separator: "-").compactMap { Int($0) }
        if let first = bounds.first { segments = first ..< min(session.segmentCount, (bounds.last ?? first) + 1) }
    }
    var paths = ["master.m3u8", "video.m3u8", "video/init.mp4", "muxed.m3u8", "muxed/init.mp4"]
    paths += segments.flatMap { ["video/\($0).m4s", "muxed/\($0).m4s"] }
    for track in summary.audio {
        paths += ["audio-\(track.number).m3u8", "audio-\(track.number)/init.mp4"]
        paths += segments.map { "audio-\(track.number)/\($0).m4s" }
    }
    for path in paths {
        guard let (data, _) = try await session.data(at: path) else {
            print("missing \(path)")
            exit(1)
        }
        let file = output.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    print("wrote \(paths.count) files in \(String(format: "%.3f", Date().timeIntervalSince(started))) s, read \(await session.bytesRead) bytes for segments")
} catch {
    print("failed: \(error)")
    exit(1)
}
