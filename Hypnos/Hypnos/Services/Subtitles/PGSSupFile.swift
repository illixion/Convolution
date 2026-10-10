/*
 Hypnos - a PGS subtitle track as a `.sup` file

 Jellyfin can't convert image subtitles to text (10.11 answers `Stream.vtt`
 for one with "Unsupported file extension: PGSSUB"), but it serves the
 track as it extracted it when asked for its own format (`Stream.pgssub`):
 a `.sup` file, every segment prefixed with "PG", its presentation and
 decode times (90 kHz) and its type and length. The segments are the same
 ones a Blu-ray carries in its PES packets, so the disc's decoder reads
 them (Vergence's `SupFile`), and the cues are images like a disc's
 (`DiscSubtitles`).

 A caption lasts until the next caption of the track: PGS clears the
 screen with an empty composition, which ends the one before it. The last
 caption, or one followed by nothing for a long time, stops at
 `maximumSeconds`.

 The first request for an embedded track makes Jellyfin extract every
 subtitle stream of the file in one pass, which reads the whole file:
 about 4.5 minutes for a 60 GB UHD remux on servo (2026-10-10). Afterwards
 it answers at once.
 */

import CoreGraphics
import Foundation
import VergenceApple
import RAVEUI

enum PGSSupFile {
    /// Longest a caption shows when nothing follows it.
    static let maximumSeconds = 10.0

    enum ParseError: LocalizedError {
        case notPGS

        var errorDescription: String? { "The server's subtitle data isn't a PGS (.sup) stream." }
    }

    /// Parses `data` into image cues, in film seconds (the file's own time).
    static func track(from data: Data, trackID: Int) throws -> RAVESubtitleTrack {
        guard data.count >= 13, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x47 else {
            throw ParseError.notPGS
        }
        let captions = SupFile.captions(data)
        // A re-sent caption (an acquisition point) replaces its own.
        var byTime: [Int64: PGSCaption] = [:]
        for caption in captions { byTime[caption.pts] = caption }
        let ordered = byTime.values.sorted { $0.pts < $1.pts }

        var cues: [RAVESubtitleCue] = []
        let maximum = Int64(maximumSeconds * 90_000)
        for (index, caption) in ordered.enumerated() where !caption.isEmpty {
            guard let bounds = caption.bounds, caption.videoWidth > 0, caption.videoHeight > 0 else { continue }
            let next = index + 1 < ordered.count ? ordered[index + 1].pts : caption.pts + maximum
            let end = min(next, caption.pts + maximum)
            let frame = CGRect(x: Double(bounds.x) / Double(caption.videoWidth),
                               y: Double(bounds.y) / Double(caption.videoHeight),
                               width: Double(bounds.width) / Double(caption.videoWidth),
                               height: Double(bounds.height) / Double(caption.videoHeight))
            let image = RAVESubtitleImage(id: trackID << 40 ^ Int(truncatingIfNeeded: caption.pts), frame: frame) {
                DiscSubtitles.makeImage(caption)
            }
            cues.append(RAVESubtitleCue(start: Double(caption.pts) / 90_000, end: Double(end) / 90_000, image: image))
        }
        return RAVESubtitleTrack(cues: cues)
    }
}
