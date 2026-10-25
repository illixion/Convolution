/*
 MatroskaRemux - which tracks go into the HLS, and how each is timed

 The first enabled video track is the variant's video; it has to be a codec
 MP4 carries (H.264, HEVC, VP9, AV1) or the file is declined. Every audio
 track whose codec MP4 carries becomes an audio rendition; the others
 (TrueHD, DTS, Vorbis, PCM, anything encrypted or compressed) are dropped,
 and a file whose audio is all dropped is declined, since playing it silent
 would be worse than the caller's fallback.

 Timing. Matroska block timestamps are presentation times, in ticks of the
 file's TimestampScale (a millisecond, usually). Both renditions keep the
 file's own timeline (tick 0 is time 0 in every rendition), so audio and
 video stay in sync however each is cut.

 - Video: constant-rate video (a DefaultDuration that is a whole number of
   1/120000 s, which covers 23.976 through 60 fps) is timed at 120 kHz and
   its millisecond-rounded timestamps snapped back onto the frame grid, so
   frames are evenly paced; anything else is converted at 90 kHz as it is.
 - Audio: the timescale is the sample rate. A block's time is snapped to the
   grid of the codec's frame length counted from the track's first frame,
   and the frames of a lace follow on from it by their own lengths.
 */

import Foundation

struct VideoPlan: Sendable {
    let track: MatroskaTrack
    let sampleEntry: [UInt8]
    let codecs: String
    let supplementalCodecs: String?
    /// HLS VIDEO-RANGE: SDR, PQ or HLG.
    let videoRange: String
    let codecName: String
    /// The picture size players show (display size for anamorphic video).
    let displayWidth: Int
    let displayHeight: Int
    let framesPerSecond: Double?
    let timescale: UInt32
    /// Ticks per frame at `timescale`, when the video is snapped to a grid.
    let gridTicks: Int64?
    /// The first keyframe's time, the grid's origin.
    let originNanoseconds: Int64
    let timestampScale: Int64
    let offsetNanoseconds: Int64

    /// Presentation time of a block, at `timescale`.
    func time(ticks: Int64, laceIndex: Int = 0) -> Int64 {
        var ns = ticks * timestampScale + offsetNanoseconds
        if laceIndex > 0, let duration = track.defaultDuration { ns += Int64(laceIndex) * Int64(duration) }
        let raw = Double(ns) * Double(timescale) / 1e9
        if let grid = gridTicks {
            let origin = Double(originNanoseconds + offsetNanoseconds) * Double(timescale) / 1e9
            let n = ((raw - origin) / Double(grid)).rounded()
            let snapped = origin.rounded() + n * Double(grid)
            // Within rounding of the file's tick (and 0.6 ms): on the grid.
            let tolerance = max(0.0006, Double(timestampScale) / 2e9) * Double(timescale)
            if abs(snapped - raw) <= tolerance { return Int64(snapped) }
        }
        return Int64(raw.rounded())
    }

    /// A frame's duration when nothing else says.
    var nominalFrameTicks: Int64 {
        if let gridTicks { return gridTicks }
        if let duration = track.defaultDuration { return max(1, Int64((Double(duration) * Double(timescale) / 1e9).rounded())) }
        return Int64(timescale) / 25
    }

    static func make(track: MatroskaTrack, firstKeyframe: [UInt8], firstKeyframeTicks: Int64,
                     timestampScale: Int64, offsetNanoseconds: Int64) throws -> VideoPlan {
        if let encoding = track.unreadableEncoding { throw RemuxError.declined("video track is \(encoding)") }
        let video = track.video ?? MatroskaTrack.Video()
        let width = video.pixelWidth, height = video.pixelHeight
        guard width > 0, height > 0 else { throw RemuxError.declined("video track has no picture size") }

        var framesPerSecond: Double?
        var timescale: UInt32 = 90000
        var gridTicks: Int64?
        if let duration = track.defaultDuration, duration > 0 {
            framesPerSecond = 1e9 / Double(duration)
            let ticks = Double(duration) * 120_000 / 1e9
            if ticks >= 1, abs(ticks - ticks.rounded()) < 0.01 {
                timescale = 120_000
                gridTicks = Int64(ticks.rounded())
                framesPerSecond = 120_000 / ticks.rounded()
            }
        }

        let element = video.colour
        func merged(_ bitstream: ColourDescription?) -> ColourDescription? {
            let primaries = element?.primaries ?? bitstream?.primaries
            let transfer = element?.transferCharacteristics ?? bitstream?.transfer
            let matrix = element?.matrixCoefficients ?? bitstream?.matrix
            guard primaries != nil || transfer != nil || matrix != nil else { return nil }
            let fullRange = element?.range.map { $0 == 2 } ?? bitstream?.fullRange ?? false
            return ColourDescription(primaries: primaries ?? 2, transfer: transfer ?? 2, matrix: matrix ?? 2,
                                     fullRange: fullRange)
        }

        var colour: ColourDescription?
        var sampleEntry: [UInt8]
        var codecs: String
        var supplemental: String?
        var codecName: String
        var dolbyRange: String?
        switch track.codecID {
        case "V_MPEG4/ISO/AVC":
            guard let config = AVCConfiguration(record: track.codecPrivate) else {
                throw RemuxError.declined("H.264 track without a usable avcC")
            }
            colour = merged(config.colour)
            codecs = config.codecString
            codecName = "H.264"
            sampleEntry = SampleEntries.visual("avc1", width: width, height: height) { w in
                w.box("avcC", payload: config.record)
                SampleEntries.colourBoxes(&w, colour: colour, track: track)
            }
        case "V_MPEGH/ISO/HEVC":
            guard let config = HEVCConfiguration(record: track.codecPrivate) else {
                throw RemuxError.declined("HEVC track without a usable hvcC")
            }
            colour = merged(config.colour)
            codecName = "HEVC"
            var entryType = config.hasParameterSets ? "hvc1" : "hev1"
            let dolby = track.blockAdditionMappings.lazy.compactMap(DolbyVisionConfiguration.init).first
            var dolbyBox: DolbyVisionConfiguration?
            if let dolby, dolby.hasRPU, dolby.hasBaseLayer {
                switch dolby.profile {
                case 5:
                    // No compatible base layer: only a Dolby Vision decoder
                    // shows it right.
                    entryType = config.hasParameterSets ? "dvh1" : "dvhe"
                    dolbyBox = dolby
                    dolbyRange = "PQ"
                    codecName = "HEVC (DV profile 5)"
                case 8:
                    dolbyBox = dolby
                    supplemental = dolby.compatibilityBrand.map { "\(dolby.codecString)/\($0)" }
                    if dolby.compatibilityID == 4 { dolbyRange = "HLG" }
                    codecName = "HEVC (DV profile 8.\(dolby.compatibilityID))"
                default:
                    break // profile 7's enhancement layer can't play here; the base layer can
                }
            }
            codecs = dolbyBox?.profile == 5
                ? dolbyBox!.codecString.replacingOccurrences(of: "dvh1", with: entryType)
                : config.codecString(sampleEntry: entryType)
            sampleEntry = SampleEntries.visual(entryType, width: width, height: height) { w in
                w.box("hvcC", payload: config.record)
                if let dolbyBox { w.box(dolbyBox.boxType, payload: dolbyBox.payload) }
                SampleEntries.colourBoxes(&w, colour: colour, track: track)
            }
        case "V_VP9":
            guard let config = VP9Configuration(track: track, firstKeyframe: firstKeyframe,
                                                framesPerSecond: framesPerSecond) else {
                throw RemuxError.declined("VP9 track without a readable keyframe header")
            }
            colour = config.colour
            codecs = config.codecString
            codecName = "VP9 profile \(config.profile)"
            sampleEntry = SampleEntries.visual("vp09", width: width, height: height) { w in
                w.fullBox("vpcC", version: 1, flags: 0) { $0.bytes += config.vpcC }
                SampleEntries.colourBoxes(&w, colour: config.colour, track: track)
            }
        case "V_AV1":
            guard let config = AV1Configuration(track: track, firstKeyframe: firstKeyframe) else {
                throw RemuxError.declined("AV1 track without a configuration record")
            }
            colour = config.colour
            codecs = config.codecString
            codecName = "AV1"
            sampleEntry = SampleEntries.visual("av01", width: width, height: height) { w in
                w.box("av1C", payload: config.record)
                SampleEntries.colourBoxes(&w, colour: config.colour, track: track)
            }
        default:
            throw RemuxError.declined("video codec \(track.codecID)")
        }

        let range: String = dolbyRange ?? {
            switch colour?.transfer {
            case 16: "PQ"
            case 18: "HLG"
            default: "SDR"
            }
        }()

        var displayWidth = width, displayHeight = height
        if video.displayUnit == 0, let dw = video.displayWidth, let dh = video.displayHeight, dw > 0, dh > 0 {
            displayWidth = dw
            displayHeight = dh
        } else if video.displayUnit == 3, let dw = video.displayWidth, let dh = video.displayHeight, dw > 0, dh > 0 {
            displayWidth = Int((Double(height) * Double(dw) / Double(dh)).rounded())
        }

        return VideoPlan(track: track, sampleEntry: sampleEntry, codecs: codecs, supplementalCodecs: supplemental,
                         videoRange: range, codecName: codecName, displayWidth: displayWidth,
                         displayHeight: displayHeight, framesPerSecond: framesPerSecond, timescale: timescale,
                         gridTicks: gridTicks, originNanoseconds: firstKeyframeTicks * timestampScale,
                         timestampScale: timestampScale, offsetNanoseconds: offsetNanoseconds)
    }
}

struct AudioPlan: Sendable {
    let track: MatroskaTrack
    let codec: AudioCodec
    let codecName: String
    let sampleRate: Int
    let channels: Int
    let sampleEntry: [UInt8]
    let codecs: String
    let averageBitrate: Int
    /// HLS CHANNELS: the count, or "16/JOC" for E-AC-3 with object audio.
    var hlsChannels: String {
        if case .eac3(let info) = codec, info.objectComplexity != nil { return "16/JOC" }
        return "\(channels)"
    }
    /// The track's first block time, in samples: the grid's origin.
    let originSamples: Int64
    /// What fills a stretch of a segment the track has no frames for (see
    /// `RemuxSession.audioFragments`): a frame of silence made for the
    /// track's configuration (`SilentFrame`), or, for a codec setup none can
    /// safely be made for, the track's first frame.
    let placeholder: [UInt8]
    let placeholderIsSilent: Bool
    let timestampScale: Int64
    let offsetNanoseconds: Int64

    var gridSamples: Int? { codec.constantFrameSamples }

    /// A block's time in samples, snapped to the codec's frame grid. The
    /// track's CodecDelay comes off: Matroska block times include it (a
    /// first AAC block at 0 holds the encoder's priming, which plays before
    /// time 0), and MP4 here has no edit list to trim it.
    func blockTime(ticks: Int64) -> Int64 {
        let ns = ticks * timestampScale - Int64(clamping: track.codecDelay) + offsetNanoseconds
        let raw = Double(ns) * Double(sampleRate) / 1e9
        if let grid = gridSamples, grid > 0 {
            let n = ((raw - Double(originSamples)) / Double(grid)).rounded()
            return originSamples + Int64(n) * Int64(grid)
        }
        return Int64(raw.rounded())
    }

    /// The time in samples a segment boundary falls at.
    func boundary(ticks: Int64) -> Int64 {
        Int64((Double(ticks * timestampScale + offsetNanoseconds) * Double(sampleRate) / 1e9).rounded())
    }

    func samples(in frame: [UInt8]) -> Int {
        if let n = codec.samples(in: frame), n > 0 { return n }
        if let n = codec.constantFrameSamples { return n }
        if let duration = track.defaultDuration {
            return max(1, Int((Double(duration) * Double(sampleRate) / 1e9).rounded()))
        }
        return 1024
    }

    /// The plan for an audio track, given its first frame; nil when MP4
    /// can't carry it (with the reason).
    static func make(track: MatroskaTrack, firstFrame: [UInt8], firstTicks: Int64, timestampScale: Int64,
                     offsetNanoseconds: Int64) -> Result<AudioPlan, RemuxError> {
        if let encoding = track.unreadableEncoding { return .failure(.declined("\(track.codecID) is \(encoding)")) }
        let audio = track.audio ?? MatroskaTrack.Audio()
        let codec: AudioCodec
        let codecName: String
        let sampleRate: Int
        var channels = audio.channels
        let entry: [UInt8]
        let codecs: String
        var bitrate = 0

        let id = track.codecID
        if id == "A_AAC" || id.hasPrefix("A_AAC/") {
            let config = id == "A_AAC" && !track.codecPrivate.isEmpty
                ? AACConfig(asc: track.codecPrivate, channelsHint: audio.channels)
                : AACConfig(legacyCodecID: id, sampleRate: audio.samplingFrequency,
                            outputSampleRate: audio.outputSamplingFrequency, channels: audio.channels)
            guard let config else { return .failure(.declined("AAC track without a usable configuration")) }
            codec = .aac(config)
            codecName = config.objectType == 2 ? "AAC" : "HE-AAC"
            sampleRate = config.sampleRate
            channels = config.channels
            codecs = config.codecString
            let entryRate = Int((audio.outputSamplingFrequency ?? Double(config.sampleRate)).rounded())
            entry = SampleEntries.audio("mp4a", channels: channels, sampleSize: 16, sampleRate: entryRate) { w in
                SampleEntries.esds(&w, objectType: 0x40, decoderSpecificInfo: config.asc)
            }
        } else if id == "A_AC3" || id.hasPrefix("A_AC3/") || id == "A_EAC3" {
            if let syncframe = AC3Syncframe(firstFrame) {
                codec = .ac3(syncframe)
                codecName = "AC-3"
                sampleRate = syncframe.sampleRate
                channels = syncframe.channels
                codecs = "ac-3"
                bitrate = (AC3Syncframe.frameBytes(fscod: syncframe.fscod, frmsizecod: syncframe.frmsizecod) ?? 0)
                    * 8 * sampleRate / 1536
                entry = SampleEntries.audio("ac-3", channels: channels, sampleSize: 16, sampleRate: sampleRate) { w in
                    w.box("dac3", payload: syncframe.dac3)
                }
            } else if let info = EAC3Info(firstFrame) {
                codec = .eac3(info)
                codecName = "E-AC-3"
                sampleRate = info.sampleRate
                channels = info.channels
                codecs = "ec-3"
                bitrate = info.dataRateKbps * 1000
                entry = SampleEntries.audio("ec-3", channels: channels, sampleSize: 16, sampleRate: sampleRate) { w in
                    w.box("dec3", payload: info.dec3)
                }
            } else {
                return .failure(.declined("\(id) track whose first frame isn't a syncframe"))
            }
        } else if id == "A_OPUS" {
            guard var head = OpusHead(track.codecPrivate) else { return .failure(.declined("Opus track without OpusHead")) }
            head.firstPacketSamples = OpusHead.samples(inPacket: firstFrame)
            codec = .opus(head)
            codecName = "Opus"
            sampleRate = 48000
            channels = head.channels
            codecs = "Opus"
            entry = SampleEntries.audio("Opus", channels: channels, sampleSize: 16, sampleRate: 48000) { w in
                w.box("dOps", payload: head.dOps)
            }
        } else if id == "A_FLAC" {
            guard let info = FLACStreamInfo(codecPrivate: track.codecPrivate) else {
                return .failure(.declined("FLAC track without STREAMINFO"))
            }
            codec = .flac(info)
            codecName = "FLAC"
            sampleRate = info.sampleRate
            channels = info.channels
            codecs = "fLaC"
            entry = SampleEntries.audio("fLaC", channels: channels, sampleSize: info.bitsPerSample,
                                        sampleRate: sampleRate) { w in
                w.fullBox("dfLa", version: 0, flags: 0) { $0.bytes += info.dfLa }
            }
        } else if id == "A_ALAC" {
            guard let config = ALACConfig(codecPrivate: track.codecPrivate) else {
                return .failure(.declined("ALAC track without a configuration"))
            }
            codec = .alac(config)
            codecName = "ALAC"
            sampleRate = config.sampleRate
            channels = config.channels
            codecs = "alac"
            entry = SampleEntries.audio("alac", channels: channels, sampleSize: config.bitDepth,
                                        sampleRate: sampleRate) { w in
                w.fullBox("alac", version: 0, flags: 0) { $0.bytes += config.config }
            }
        } else if id == "A_MPEG/L3" {
            guard let header = MPEGAudioHeader(firstFrame), header.layer == 3 else {
                return .failure(.declined("MP3 track whose first frame isn't a frame header"))
            }
            codec = .mp3(header)
            codecName = "MP3"
            sampleRate = header.sampleRate
            channels = header.channels
            // AVFoundation doesn't play MP3 as ISO's `mp4a` with object type
            // 0x6B (not even a plain MP4 ffmpeg writes), but does play
            // QuickTime's `.mp3` sound description, in HLS too, when the
            // master names it mp4a.40.34.
            codecs = "mp4a.40.34"
            entry = SampleEntries.quickTimeSound(".mp3", channels: channels, sampleRate: sampleRate,
                                                 samplesPerPacket: header.samplesPerFrame)
        } else {
            return .failure(.declined("audio codec \(id)"))
        }

        let firstNanoseconds = firstTicks * timestampScale - Int64(clamping: track.codecDelay) + offsetNanoseconds
        let rawOrigin = Double(firstNanoseconds) * Double(sampleRate) / 1e9
        let silence = SilentFrame.make(codec: codec, firstFrame: firstFrame)
        return .success(AudioPlan(track: track, codec: codec, codecName: codecName, sampleRate: sampleRate,
                                  channels: max(1, channels), sampleEntry: entry, codecs: codecs,
                                  averageBitrate: bitrate, originSamples: Int64(rawOrigin.rounded()),
                                  placeholder: silence ?? firstFrame, placeholderIsSilent: silence != nil,
                                  timestampScale: timestampScale, offsetNanoseconds: offsetNanoseconds))
    }
}

/// Codec ids MP4 carries, for deciding which tracks a file needs probed.
enum SupportedCodecs {
    static let video: Set<String> = ["V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC", "V_VP9", "V_AV1"]

    static func isAudioSupported(_ id: String) -> Bool {
        id == "A_AAC" || id.hasPrefix("A_AAC/") || id == "A_AC3" || id.hasPrefix("A_AC3/") || id == "A_EAC3"
            || id == "A_OPUS" || id == "A_FLAC" || id == "A_ALAC" || id == "A_MPEG/L3"
    }
}
