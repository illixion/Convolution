/*
 mkvremux - writes a Matroska file's HLS to a folder

     swift run mkvremux <file.mkv> <folder> [segments]

 `segments` limits the media segments written, e.g. `0-2` or `7`.

 Writes master.m3u8, the media playlists, and every init and media segment,
 at the paths the app serves them on, then prints the summary. Serve the
 folder (`python3 -m http.server`) and point ffmpeg, Safari or the
 hdrplay probe at master.m3u8 to check a remux without the app.
 */

import Foundation
import MatroskaRemux

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    print("usage: mkvremux <file.mkv> <folder> [segments]")
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)

do {
    let started = Date()
    let session = try await RemuxSession.open(source: try FileByteSource(url: input))
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
