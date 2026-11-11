import AVFoundation
import Foundation

/// One codec decoder kept across a stream's segments, so that the stream
/// decodes as one: a fresh decoder per segment restarts the codec's overlap
/// (AAC's first frame of every segment comes out wrong) and, read as PCM by
/// AVAssetReader, trims priming at every boundary. AI captions shrugged that
/// off; the equalizer plays the result, where it is a click every segment.
final class CompressedAudioDecoder {
    private var converter: AVAudioConverter?

    /// Decodes one compressed sample buffer (one or more packets) to float PCM.
    func decode(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        let packets = CMSampleBufferGetNumSamples(sample)
        guard packets > 0, let description = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if converter?.inputFormat != format {
            let pcm = format.channelLayout.map {
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: false, channelLayout: $0)
            } ?? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount)
            guard let pcm,
                  let decoder = AVAudioConverter(from: format, to: pcm) else { throw URLError(.cannotDecodeContentData) }
            decoder.primeMethod = .none
            var size = 0
            if let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0 {
                decoder.magicCookie = Data(bytes: cookie, count: size)
            }
            converter = decoder
        }
        guard let converter else { throw URLError(.cannotDecodeContentData) }
        // A file reader's buffers carry packet descriptions (ADTS, AC-3);
        // a fragment's carry a size per sample.
        var described: UnsafePointer<AudioStreamPacketDescription>?
        var describedSize = 0
        let hasDescriptions = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
            sample, packetDescriptionsPointerOut: &described, sizeOut: &describedSize) == noErr
            && described != nil && describedSize >= packets * MemoryLayout<AudioStreamPacketDescription>.stride
        let sizes = hasDescriptions
            ? (0..<packets).map { Int(described![$0].mDataByteSize) }
            : (0..<packets).map { CMSampleBufferGetSampleSize(sample, at: $0) }
        let input = AVAudioCompressedBuffer(format: format, packetCapacity: AVAudioPacketCount(packets), maximumPacketSize: max(1, sizes.max() ?? 1))
        input.packetCount = AVAudioPacketCount(packets)
        input.byteLength = UInt32(CMBlockBufferGetDataLength(block))
        let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: Int(input.byteLength), destination: input.data)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if hasDescriptions, let described, let destination = input.packetDescriptions {
            destination.update(from: described, count: packets)
        }
        var offset = 0
        for (index, size) in sizes.enumerated() where !hasDescriptions {
            var timing = CMSampleTimingInfo()
            let status = CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing)
            let frames = status == noErr && timing.duration.isNumeric ? timing.duration.seconds * format.sampleRate : 0
            input.packetDescriptions?[index] = AudioStreamPacketDescription(mStartOffset: Int64(offset),
                mVariableFramesInPacket: UInt32(max(0, frames.rounded())), mDataByteSize: UInt32(size))
            offset += size
        }
        let duration = CMSampleBufferGetDuration(sample)
        let frames = (duration.isNumeric ? duration.seconds : Double(packets) * 1536 / format.sampleRate) * format.sampleRate
        guard frames.isFinite, frames >= 0, frames < 10_000_000,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(ceil(frames)) + 8192) else {
            throw URLError(.cannotDecodeContentData)
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if result == .error { throw error ?? URLError(.cannotDecodeContentData) }
        return output.frameLength > 0 ? output : nil
    }

    /// Linear PCM a reader already decoded (ALAC; see `FragmentedCaptionAudio`), copied out.
    static func pcm(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        // From the CoreMedia description, which carries a 5.1 layout that a
        // bare stream description can't (that init fails for 6 channels).
        guard frames > 0, let description = CMSampleBufferGetFormatDescription(sample),
              let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                                            frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return buffer
    }
}

/// The audio of an MPEG-TS segment as a raw elementary stream a reader can
/// open (ADTS AAC, AC-3, E-AC-3, MP3): Stash's HLS transcodes and Jellyfin's
/// music are TS, which AVAssetReader can't read.
struct MPEGTSAudio: Equatable {
    /// The audio's bytes, PES headers removed.
    var elementaryStream: Data
    /// A file extension AVFoundation reads that stream by.
    var fileExtension: String
    /// Seconds from the segment's reference (its first video frame, else its
    /// first audio frame) to its first audio frame: where the audio starts
    /// on the player's timeline, relative to the segment's start.
    var leadIn: Double

    private struct Stream { var pid: Int; var kind: String }

    static func extract(_ data: Data) -> MPEGTSAudio? {
        let bytes = [UInt8](data)
        var pmtPIDs = Set<Int>()
        var audio: Stream?
        var videoPID: Int?
        var es = Data()
        var firstAudioPTS: Int64?
        var firstVideoPTS: Int64?
        var inAudioPES = false
        var offset = 0
        // Skip anything before the first sync byte (some servers lead with an ID3 tag).
        while offset < bytes.count, bytes[offset] != 0x47 { offset += 1 }
        while offset + 188 <= bytes.count {
            defer { offset += 188 }
            guard bytes[offset] == 0x47 else { continue }
            let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
            let unitStart = bytes[offset + 1] & 0x40 != 0
            let adaptation = (bytes[offset + 3] >> 4) & 0x3
            guard adaptation & 0x1 != 0 else { continue } // no payload
            var start = offset + 4
            if adaptation == 0x3 { start += 1 + Int(bytes[offset + 4]) }
            let end = offset + 188
            guard start < end else { continue }

            if pid == 0 {
                guard unitStart else { continue }
                let table = start + 1 + Int(bytes[start])
                guard table + 8 <= end, bytes[table] == 0x00 else { continue }
                let length = (Int(bytes[table + 1] & 0x0F) << 8) | Int(bytes[table + 2])
                var entry = table + 8
                while entry + 4 <= min(end, table + 3 + length - 4) {
                    let program = (Int(bytes[entry]) << 8) | Int(bytes[entry + 1])
                    let mapPID = (Int(bytes[entry + 2] & 0x1F) << 8) | Int(bytes[entry + 3])
                    if program != 0 { pmtPIDs.insert(mapPID) }
                    entry += 4
                }
            } else if pmtPIDs.contains(pid), audio == nil {
                guard unitStart else { continue }
                let table = start + 1 + Int(bytes[start])
                guard table + 12 <= end, bytes[table] == 0x02 else { continue }
                let length = (Int(bytes[table + 1] & 0x0F) << 8) | Int(bytes[table + 2])
                let programInfo = (Int(bytes[table + 10] & 0x0F) << 8) | Int(bytes[table + 11])
                var entry = table + 12 + programInfo
                let tableEnd = min(end, table + 3 + length - 4)
                while entry + 5 <= tableEnd {
                    let type = bytes[entry]
                    let streamPID = (Int(bytes[entry + 1] & 0x1F) << 8) | Int(bytes[entry + 2])
                    let infoLength = (Int(bytes[entry + 3] & 0x0F) << 8) | Int(bytes[entry + 4])
                    let descriptors = Array(bytes[min(entry + 5, tableEnd) ..< min(entry + 5 + infoLength, tableEnd)])
                    switch type {
                    case 0x1B, 0x24, 0x02, 0x01: if videoPID == nil { videoPID = streamPID }
                    default:
                        if audio == nil, let kind = Self.audioKind(type: type, descriptors: descriptors) {
                            audio = Stream(pid: streamPID, kind: kind)
                        }
                    }
                    entry += 5 + infoLength
                }
            } else if let audio, pid == audio.pid {
                if unitStart {
                    guard let (payload, pts) = Self.pes(bytes, start, end) else { inAudioPES = false; continue }
                    inAudioPES = true
                    if firstAudioPTS == nil { firstAudioPTS = pts }
                    es.append(contentsOf: bytes[payload ..< end])
                } else if inAudioPES {
                    es.append(contentsOf: bytes[start ..< end])
                }
            } else if pid == videoPID, unitStart, firstVideoPTS == nil {
                firstVideoPTS = Self.pes(bytes, start, end)?.pts
            }
        }
        guard let audio, !es.isEmpty, let firstAudioPTS else { return nil }
        let reference = firstVideoPTS ?? firstAudioPTS
        // 33-bit clock: take the shorter way round a wrap.
        var difference = (firstAudioPTS - reference) & ((1 << 33) - 1)
        if difference >= 1 << 32 { difference -= 1 << 33 }
        return MPEGTSAudio(elementaryStream: es, fileExtension: audio.kind, leadIn: Double(difference) / 90_000)
    }

    private static func audioKind(type: UInt8, descriptors: [UInt8]) -> String? {
        switch type {
        case 0x0F: return "aac"
        case 0x03, 0x04: return "mp3"
        case 0x81: return "ac3"
        case 0x87: return "ec3"
        case 0x06:
            // DVB carries AC-3 and E-AC-3 as private data, named by a descriptor.
            var index = 0
            while index + 2 <= descriptors.count {
                let tag = descriptors[index]
                if tag == 0x6A { return "ac3" }
                if tag == 0x7A { return "ec3" }
                index += 2 + Int(descriptors[index + 1])
            }
            return nil
        default: return nil
        }
    }

    /// Where a PES packet's payload starts, and its PTS.
    private static func pes(_ bytes: [UInt8], _ start: Int, _ end: Int) -> (payload: Int, pts: Int64?)? {
        guard start + 9 <= end, bytes[start] == 0, bytes[start + 1] == 0, bytes[start + 2] == 1 else { return nil }
        let headerLength = Int(bytes[start + 8])
        let payload = start + 9 + headerLength
        guard payload <= end else { return nil }
        var pts: Int64?
        if bytes[start + 7] & 0x80 != 0, start + 14 <= end {
            let p = bytes[start + 9 ..< start + 14].map(Int64.init)
            pts = ((p[0] >> 1) & 0x07) << 30 | p[1] << 22 | (p[2] >> 1) << 15 | p[3] << 7 | p[4] >> 1
        }
        return (payload, pts)
    }
}

/// Where a fragmented MP4's tracks sit on the movie's timeline, from their
/// edit lists. ffmpeg's HLS muxer lines audio up with video this way rather
/// than in the timestamps: on a muxed stream the video gets an empty edit
/// (a delay) and a media time equal to its first frame's composition offset,
/// the audio its own delay, so read by its timestamps alone the audio is
/// that much off the picture (21-106 ms in the fixtures). The player's clock
/// starts at the first picture, so a sample's time on it is its media time,
/// less its track's media time, plus its track's delay, less the video's.
enum FragmentEditList {
    struct Placement: Equatable {
        /// The leading empty edit, in seconds (movie timescale).
        var delay: Double = 0
        /// The first real edit's media time, in the track's timescale.
        var mediaTime: Int64 = 0
        var isVideo = false
    }

    static func placements(initSegment data: Data) -> [UInt32: Placement] {
        let bytes = [UInt8](data)
        var result: [UInt32: Placement] = [:]
        for moov in boxes(bytes, 0 ..< bytes.count) where moov.type == "moov" {
            var movieScale: UInt32 = 1000
            for box in boxes(bytes, moov.body) where box.type == "mvhd" && box.body.count >= 20 {
                movieScale = max(1, u32(bytes, box.body.lowerBound + (bytes[box.body.lowerBound] == 1 ? 20 : 12)))
            }
            for trak in boxes(bytes, moov.body) where trak.type == "trak" {
                var id: UInt32?
                var placement = Placement()
                for box in boxes(bytes, trak.body) {
                    if box.type == "tkhd", box.body.count >= 24 {
                        id = u32(bytes, box.body.lowerBound + (bytes[box.body.lowerBound] == 1 ? 20 : 12))
                    } else if box.type == "mdia" {
                        for hdlr in boxes(bytes, box.body) where hdlr.type == "hdlr" && hdlr.body.count >= 12 {
                            placement.isVideo = String(decoding: bytes[hdlr.body.lowerBound + 8 ..< hdlr.body.lowerBound + 12], as: UTF8.self) == "vide"
                        }
                    } else if box.type == "edts" {
                        for elst in boxes(bytes, box.body) where elst.type == "elst" && elst.body.count >= 8 {
                            let version = bytes[elst.body.lowerBound]
                            let count = Int(u32(bytes, elst.body.lowerBound + 4))
                            var entry = elst.body.lowerBound + 8
                            for _ in 0 ..< count {
                                let size = version == 1 ? 20 : 12
                                guard entry + size <= elst.body.upperBound else { break }
                                let duration: UInt64 = version == 1
                                    ? UInt64(u32(bytes, entry)) << 32 | UInt64(u32(bytes, entry + 4))
                                    : UInt64(u32(bytes, entry))
                                let time: Int64 = version == 1
                                    ? Int64(bitPattern: UInt64(u32(bytes, entry + 8)) << 32 | UInt64(u32(bytes, entry + 12)))
                                    : Int64(Int32(bitPattern: u32(bytes, entry + 4)))
                                entry += size
                                if time < 0 {
                                    placement.delay += Double(duration) / Double(movieScale) // an empty edit
                                } else {
                                    placement.mediaTime = time
                                    break
                                }
                            }
                        }
                    }
                }
                if let id { result[id] = placement }
            }
        }
        return result
    }

    /// Seconds to add to `track`'s media times to put them on the player's clock.
    static func offset(track: UInt32, timescale: UInt32, initSegment data: Data) -> Double {
        let placements = placements(initSegment: data)
        guard let own = placements[track] else { return 0 }
        let videoDelay = placements.values.first(where: \.isVideo)?.delay ?? own.delay
        return -Double(own.mediaTime) / Double(max(1, timescale)) + own.delay - videoDelay
    }

    private static func boxes(_ bytes: [UInt8], _ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(u32(bytes, offset))
            var header = 8
            if size == 1, offset + 16 <= range.upperBound {
                size = Int(UInt64(u32(bytes, offset + 8)) << 32 | UInt64(u32(bytes, offset + 12)))
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { break }
            let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
            result.append((type, offset + header ..< offset + size))
            offset += size
        }
        return result
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
