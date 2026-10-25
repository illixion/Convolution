/*
 MatroskaRemux - fragmented MP4: init segments and media segments

 Each demuxed rendition (the video, each audio track) is its own
 single-track fMP4 stream, as HLS's demuxed renditions want: an init segment
 (ftyp, moov with an empty sample table and mvex) and media segments of one
 or more moof+mdat chunks. The muxed fallback (`RemuxSession.muxedPlaylist`)
 puts the video and one audio track in the same init and the same chunks.

 Video uses version 1 `trun`s with signed composition offsets, the CMAF way
 of carrying B-frames: decode times are the segment's presentation times in
 sorted order, so the earliest presentation time is the base decode time
 and no edit list is needed to keep decode times from going negative. A
 segment boundary then leaves decode time continuous too, since the next
 segment's presentation times all follow this one's.
 */

import Foundation

struct FragmentSample {
    var duration: UInt32
    var compositionOffset: Int32 = 0
    var isSync: Bool
    var data: [UInt8]
}

/// One run of contiguous samples, starting at a decode time.
struct Fragment {
    var baseDecodeTime: UInt64
    var samples: [FragmentSample]
}

/// A track's run in one moof.
struct TrackRun {
    var trackID: UInt32
    var fragment: Fragment
    var compositionOffsets: Bool
}

enum FragmentWriter {
    enum Handler {
        case video(width: Int, height: Int)
        case audio
    }

    struct TrackHeader {
        var handler: Handler
        var timescale: UInt32
        var language: String
        var sampleEntry: [UInt8]
    }

    static func initSegment(handler: Handler, timescale: UInt32, language: String, sampleEntry: [UInt8]) -> [UInt8] {
        initSegment(tracks: [TrackHeader(handler: handler, timescale: timescale, language: language,
                                         sampleEntry: sampleEntry)])
    }

    /// An init segment for `tracks`, numbered 1, 2… in order.
    static func initSegment(tracks: [TrackHeader]) -> [UInt8] {
        var w = BoxWriter()
        w.box("ftyp") { w in
            w.fourCC("iso6")
            w.u32(1)
            for brand in ["iso6", "cmfc", "mp41"] { w.fourCC(brand) }
        }
        w.box("moov") { w in
            w.fullBox("mvhd", version: 0, flags: 0) { w in
                w.u32(0); w.u32(0) // creation, modification
                w.u32(1000) // timescale
                w.u32(0) // duration (fragmented)
                w.u32(0x0001_0000) // rate
                w.u16(0x0100) // volume
                w.zeros(10)
                for value in BoxWriter.unityMatrix { w.u32(value) }
                w.zeros(24)
                w.u32(UInt32(tracks.count + 1)) // next_track_ID
            }
            for (index, track) in tracks.enumerated() {
                trak(&w, trackID: UInt32(index + 1), track)
            }
            w.box("mvex") { w in
                for index in tracks.indices {
                    w.fullBox("trex", version: 0, flags: 0) { w in
                        w.u32(UInt32(index + 1)) // track_ID
                        w.u32(1) // default_sample_description_index
                        w.u32(0); w.u32(0); w.u32(0)
                    }
                }
            }
        }
        return w.bytes
    }

    private static func trak(_ w: inout BoxWriter, trackID: UInt32, _ track: TrackHeader) {
        var isAudio = false
        if case .audio = track.handler { isAudio = true }
        w.box("trak") { w in
            w.fullBox("tkhd", version: 0, flags: 0x7) { w in
                w.u32(0); w.u32(0)
                w.u32(trackID)
                w.u32(0)
                w.u32(0) // duration
                w.zeros(8)
                w.u16(0) // layer
                w.u16(0) // alternate_group
                w.u16(isAudio ? 0x0100 : 0)
                w.u16(0)
                for value in BoxWriter.unityMatrix { w.u32(value) }
                if case .video(let width, let height) = track.handler {
                    w.u32(UInt32(clamping: width) << 16)
                    w.u32(UInt32(clamping: height) << 16)
                } else {
                    w.u32(0); w.u32(0)
                }
            }
            w.box("mdia") { w in
                w.fullBox("mdhd", version: 0, flags: 0) { w in
                    w.u32(0); w.u32(0)
                    w.u32(track.timescale)
                    w.u32(0)
                    w.u16(packedLanguage(track.language))
                    w.u16(0)
                }
                w.fullBox("hdlr", version: 0, flags: 0) { w in
                    w.u32(0)
                    w.fourCC(isAudio ? "soun" : "vide")
                    w.zeros(12)
                    w.bytes += Array((isAudio ? "SoundHandler" : "VideoHandler").utf8) + [0]
                }
                w.box("minf") { w in
                    if isAudio {
                        w.fullBox("smhd", version: 0, flags: 0) { w in w.u32(0) }
                    } else {
                        w.fullBox("vmhd", version: 0, flags: 1) { w in w.zeros(8) }
                    }
                    w.box("dinf") { w in
                        w.fullBox("dref", version: 0, flags: 0) { w in
                            w.u32(1)
                            w.fullBox("url ", version: 0, flags: 1) { _ in }
                        }
                    }
                    w.box("stbl") { w in
                        w.fullBox("stsd", version: 0, flags: 0) { w in
                            w.u32(1)
                            w.bytes += track.sampleEntry
                        }
                        w.fullBox("stts", version: 0, flags: 0) { w in w.u32(0) }
                        w.fullBox("stsc", version: 0, flags: 0) { w in w.u32(0) }
                        w.fullBox("stsz", version: 0, flags: 0) { w in w.u32(0); w.u32(0) }
                        w.fullBox("stco", version: 0, flags: 0) { w in w.u32(0) }
                    }
                }
            }
        }
    }

    /// A media segment: one moof holding a traf per run, then one mdat with
    /// the runs' samples in the same order.
    ///
    /// One moof per segment, numbered by segment: AVFoundation stops reading
    /// a fragmented file at a gap in mfhd sequence numbers (a local file of
    /// these segments read only its first fragment while numbers jumped),
    /// so they count up by one. A track whose samples have a gap gets a
    /// second traf in the same moof, which ISO allows ("zero or more per
    /// track"). A run with no samples is still written, so a rendition
    /// with nothing in a segment's time still gets a segment.
    static func mediaSegment(sequenceNumber: UInt32, runs: [TrackRun]) -> Data {
        var w = BoxWriter()
        var dataOffsetFields: [Int] = []
        w.box("moof") { w in
            w.fullBox("mfhd", version: 0, flags: 0) { w in w.u32(sequenceNumber) }
            for run in runs {
                w.box("traf") { w in
                    w.fullBox("tfhd", version: 0, flags: 0x02_0000) { w in w.u32(run.trackID) } // default-base-is-moof
                    w.fullBox("tfdt", version: 1, flags: 0) { w in w.u64(run.fragment.baseDecodeTime) }
                    var flags: UInt32 = 0x1 | 0x100 | 0x200 | 0x400
                    if run.compositionOffsets { flags |= 0x800 }
                    w.fullBox("trun", version: run.compositionOffsets ? 1 : 0, flags: flags) { w in
                        w.u32(UInt32(run.fragment.samples.count))
                        dataOffsetFields.append(w.bytes.count)
                        w.u32(0) // data_offset, patched below
                        for sample in run.fragment.samples {
                            w.u32(sample.duration)
                            w.u32(UInt32(sample.data.count))
                            // sample_depends_on 2 (independent) for a sync
                            // sample; 1 plus is_non_sync otherwise.
                            w.u32(sample.isSync ? 0x0200_0000 : 0x0101_0000)
                            if run.compositionOffsets { w.i32(sample.compositionOffset) }
                        }
                    }
                }
            }
        }
        var offset = w.bytes.count + 8
        for (field, run) in zip(dataOffsetFields, runs) {
            w.patchU32(at: field, UInt32(offset))
            offset += run.fragment.samples.reduce(0) { $0 + $1.data.count }
        }
        w.u32(UInt32(offset - w.bytes.count))
        w.fourCC("mdat")
        var output = Data(w.bytes)
        output.reserveCapacity(offset)
        for run in runs {
            for sample in run.fragment.samples { output.append(contentsOf: sample.data) }
        }
        return output
    }

    /// ISO 639-2/T packed into 15 bits.
    static func packedLanguage(_ code: String) -> UInt16 {
        let letters = Array(code.lowercased().utf8)
        guard letters.count == 3, letters.allSatisfy({ (0x61 ... 0x7A).contains($0) }) else {
            return packedLanguage("und")
        }
        return letters.reduce(0) { $0 << 5 | UInt16($1 - 0x60) }
    }
}
