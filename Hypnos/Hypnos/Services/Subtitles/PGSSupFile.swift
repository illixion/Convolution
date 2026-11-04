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
 it answers at once. So the track is streamed from the plugin instead
 (`JellyfinLibrary.subtitleStream`, `FilmSubtitles/….sup`), from the
 playhead, cut at whole display sets (`DisplaySetScanner`).
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

    /// Finds where display sets end in a `.sup` file arriving a byte at a
    /// time (the plugin's streamed `FilmSubtitles/….sup`): each segment is
    /// "PG", PTS and DTS (4 bytes each), its type and a 2-byte length, then
    /// that many bytes, and an END segment (0x80) completes a set.
    struct DisplaySetScanner {
        private var header = 0
        private var type: UInt8 = 0
        private var length = 0
        private var remaining = 0

        /// Takes the next byte; true when it completes a display set.
        mutating func feed(_ byte: UInt8) -> Bool {
            if remaining > 0 {
                remaining -= 1
                return remaining == 0 && type == 0x80
            }
            switch header {
            case 10: type = byte
            case 11: length = Int(byte) << 8
            case 12: length |= Int(byte)
            default: break
            }
            header += 1
            guard header == 13 else { return false }
            header = 0
            remaining = length
            return length == 0 && type == 0x80
        }
    }

    /// Parses `data` into image cues, in film seconds (the file's own time).
    /// `isGrowing` is for a stream still arriving: its last caption's end is
    /// the next set, which hasn't come yet, so it is left out until it has
    /// (shown with a made-up end it would be kept twice, once the real end
    /// came).
    static func track(from data: Data, trackID: Int, isGrowing: Bool = false) throws -> RAVESubtitleTrack {
        guard data.count >= 13, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x47 else {
            throw ParseError.notPGS
        }
        let captions = SupFile.captions(data)
        // A re-sent caption (an acquisition point) replaces its own.
        var byTime: [Int64: PGSCaption] = [:]
        for caption in captions { byTime[caption.pts] = caption }
        let ordered = byTime.values.sorted { $0.pts < $1.pts }
        // Still in `ordered`: it ends the caption before it.
        let open = isGrowing ? ordered.count - 1 : ordered.count

        var cues: [RAVESubtitleCue] = []
        let maximum = Int64(maximumSeconds * 90_000)
        for (index, caption) in ordered.enumerated() where !caption.isEmpty && index < open {
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
