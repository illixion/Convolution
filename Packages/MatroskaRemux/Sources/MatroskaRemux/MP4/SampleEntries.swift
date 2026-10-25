/*
 MatroskaRemux - MP4 sample entries

 The sample entry is what CoreMedia builds a track's format description
 from, so everything the player needs to know about a stream before its
 first sample goes here: the codec configuration box (avcC, hvcC, vpcC,
 av1C, esds, dac3, dec3, dOps, dfLa, alac), and for video the colour boxes.

 Colour: `colr` (nclx) carries primaries, transfer and matrix; `mdcv` and
 `clli` carry mastering display colour volume and content light levels.
 CoreMedia reads all three for `vp09` into the format description's
 ColorPrimaries / TransferFunction / YCbCrMatrix, MasteringDisplayColorVolume
 and ContentLightLevelInfo extensions (checked against an ffmpeg-made MP4
 of the same VP9 stream, which writes the same three boxes), and the same
 boxes are standard under avc1/hvc1/av01.
 */

import Foundation

enum SampleEntries {
    static func visual(_ type: String, width: Int, height: Int, children: (inout BoxWriter) -> Void) -> [UInt8] {
        var w = BoxWriter()
        w.box(type) { w in
            w.zeros(6)
            w.u16(1) // data_reference_index
            w.zeros(16) // pre_defined, reserved
            w.u16(UInt16(clamping: width))
            w.u16(UInt16(clamping: height))
            w.u32(0x0048_0000) // 72 dpi
            w.u32(0x0048_0000)
            w.u32(0)
            w.u16(1) // frame_count
            w.zeros(32) // compressorname
            w.u16(0x0018) // depth
            w.u16(0xFFFF) // pre_defined = -1
            children(&w)
        }
        return w.bytes
    }

    static func audio(_ type: String, channels: Int, sampleSize: Int, sampleRate: Int,
                      children: (inout BoxWriter) -> Void) -> [UInt8] {
        var w = BoxWriter()
        w.box(type) { w in
            w.zeros(6)
            w.u16(1) // data_reference_index
            w.zeros(8) // version, revision, vendor
            w.u16(UInt16(clamping: channels))
            w.u16(UInt16(clamping: sampleSize))
            w.u16(0) // compression id
            w.u16(0) // packet size
            // 16.16; rates above 65535 Hz don't fit and the codec box says them.
            w.u32(sampleRate <= 0xFFFF ? UInt32(sampleRate) << 16 : 0)
            children(&w)
        }
        return w.bytes
    }

    /// A QuickTime sound description, version 1 (compressed audio with a
    /// fixed number of samples per packet).
    static func quickTimeSound(_ type: String, channels: Int, sampleRate: Int, samplesPerPacket: Int) -> [UInt8] {
        var w = BoxWriter()
        w.box(type) { w in
            w.zeros(6)
            w.u16(1) // data_reference_index
            w.u16(1) // version
            w.u16(0) // revision
            w.u32(0) // vendor
            w.u16(UInt16(clamping: channels))
            w.u16(16) // sample size
            w.u16(0xFFFE) // compression id: -2, variable
            w.u16(0) // packet size
            w.u32(sampleRate <= 0xFFFF ? UInt32(sampleRate) << 16 : 0)
            w.u32(UInt32(samplesPerPacket))
            w.u32(0) // bytes per packet
            w.u32(0) // bytes per frame
            w.u32(2) // bytes per sample
        }
        return w.bytes
    }

    static func colr(_ w: inout BoxWriter, _ colour: ColourDescription) {
        w.box("colr") { w in
            w.fourCC("nclx")
            w.u16(UInt16(clamping: colour.primaries))
            w.u16(UInt16(clamping: colour.transfer))
            w.u16(UInt16(clamping: colour.matrix))
            w.u8(colour.fullRange ? 0x80 : 0)
        }
    }

    /// SMPTE ST 2086 in the HEVC SEI's order and units: green, blue, red
    /// primaries then the white point in 0.00002 steps, luminances in
    /// 0.0001 cd/m².
    static func mdcv(_ w: inout BoxWriter, _ mastering: MatroskaTrack.Colour.Mastering) {
        guard mastering.isComplete, let red = mastering.red, let green = mastering.green, let blue = mastering.blue,
              let white = mastering.whitePoint, let maxL = mastering.luminanceMax, let minL = mastering.luminanceMin
        else { return }
        func chroma(_ value: Double) -> UInt16 { UInt16(clamping: Int((value / 0.00002).rounded())) }
        w.box("mdcv") { w in
            for primary in [green, blue, red] {
                w.u16(chroma(primary.x))
                w.u16(chroma(primary.y))
            }
            w.u16(chroma(white.x))
            w.u16(chroma(white.y))
            w.u32(UInt32(clamping: Int((maxL * 10000).rounded())))
            w.u32(UInt32(clamping: Int((minL * 10000).rounded())))
        }
    }

    static func clli(_ w: inout BoxWriter, maxCLL: Int, maxFALL: Int) {
        w.box("clli") { w in
            w.u16(UInt16(clamping: maxCLL))
            w.u16(UInt16(clamping: maxFALL))
        }
    }

    /// Pixel aspect for an anamorphic picture (display size ≠ pixel size).
    static func pasp(_ w: inout BoxWriter, video: MatroskaTrack.Video) {
        guard video.displayUnit == 0 || video.displayUnit == 3,
              let displayWidth = video.displayWidth, let displayHeight = video.displayHeight,
              displayWidth > 0, displayHeight > 0, video.pixelWidth > 0, video.pixelHeight > 0 else { return }
        var h = displayWidth * video.pixelHeight
        var v = displayHeight * video.pixelWidth
        guard h != v else { return }
        let divisor = gcd(h, v)
        h /= divisor
        v /= divisor
        w.box("pasp") { w in
            w.u32(UInt32(clamping: h))
            w.u32(UInt32(clamping: v))
        }
    }

    /// The video's colour boxes: colr from the stream's description, mdcv
    /// and clli from the track's Colour element.
    static func colourBoxes(_ w: inout BoxWriter, colour: ColourDescription?, track: MatroskaTrack) {
        if let colour, !colour.isUnspecified { colr(&w, colour) }
        if let element = track.video?.colour {
            if let mastering = element.mastering { mdcv(&w, mastering) }
            if element.maxCLL != nil || element.maxFALL != nil {
                clli(&w, maxCLL: element.maxCLL ?? 0, maxFALL: element.maxFALL ?? 0)
            }
        }
        if let video = track.video { pasp(&w, video: video) }
    }

    /// An ES_Descriptor (the esds body after version/flags): a
    /// DecoderConfigDescriptor with the object type and optional
    /// DecoderSpecificInfo, then the SLConfigDescriptor.
    static func esds(_ w: inout BoxWriter, objectType: UInt8, decoderSpecificInfo: [UInt8]?, averageBitrate: Int = 0) {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            // Four-byte expanded length, as most muxers write it.
            let n = body.count
            return [tag, UInt8(0x80 | (n >> 21) & 0x7F), UInt8(0x80 | (n >> 14) & 0x7F), UInt8(0x80 | (n >> 7) & 0x7F),
                    UInt8(n & 0x7F)] + body
        }
        var config = BoxWriter()
        config.u8(objectType)
        config.u8(0x15) // streamType audio (5) << 2 | upStream 0 | reserved 1
        config.u24(0) // bufferSizeDB
        config.u32(UInt32(clamping: averageBitrate)) // maxBitrate
        config.u32(UInt32(clamping: averageBitrate)) // avgBitrate
        var configBytes = config.bytes
        if let info = decoderSpecificInfo { configBytes += descriptor(0x05, info) }
        var es = BoxWriter()
        es.u16(0) // ES_ID
        es.u8(0) // flags
        var esBytes = es.bytes + descriptor(0x04, configBytes)
        esBytes += descriptor(0x06, [0x02])
        w.fullBox("esds", version: 0, flags: 0) { w in
            w.bytes += descriptor(0x03, esBytes)
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return max(1, a)
    }
}
