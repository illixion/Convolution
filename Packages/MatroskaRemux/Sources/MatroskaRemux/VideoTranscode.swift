/*
 MatroskaRemux - video MP4 can't carry, decoded and re-encoded

 VP8 has no MP4 sample entry AVFoundation plays and no decoder on Apple
 platforms (VideoToolbox's supplemental decoder is VP9 only). When the
 caller supplies a decoder for it (`RemuxOptions.videoDecoding`; the app's
 sideload edition passes FFmpeg's, the package never links one), the track
 plays re-encoded: each segment's frames are decoded and fed straight into
 a VideoToolbox compression session (the hardware HEVC encoder, else H.264
 where HEVC encoding is missing, as in some simulators), and the encoded
 frames go into the segment in place of the stored ones, with the stored
 frames' times. Everything else (segment boundaries, audio, the playlists)
 is as for any other file.

 - Segments stay independently decodable, so a seek works: each is encoded
   by a session of its own whose first picture is forced to a keyframe,
   and frames are never reordered (no B-frames), so a frame's decode time
   is its presentation time, as the source's.
 - The sample entry's parameter sets come from encoding the first keyframe
   at open with the same settings every segment uses (`make`), which gives
   the same parameter sets; a segment whose session says otherwise carries
   its own in band ahead of its first frame, which every decoder reads.
 - Memory stays bounded: a picture is copied into a buffer from the
   session's pool and handed to the encoder as soon as it is decoded, with
   at most `framesInFlight` waiting for the encoder; nothing holds a
   segment's decoded pictures.
 - Unlike every other segment, a re-encoded one is not byte-identical when
   asked for again (hardware encoders aren't deterministic), only
   equivalent: same frames, times, keyframes and parameter sets. The
   session keeps the last few (`RemuxSession.videoFrames`) so a player's
   re-request within a few segments gets the same bytes.
 - The bit rate is fixed per file, from the picture size and frame rate
   (`bitsPerPixel`): generous for a lossy-to-lossy step, and the master's
   BANDWIDTH says so.

 Only the hook types exist where VideoToolbox doesn't (Linux): a file there
 is declined as before.
 */

import Foundation

/// One decoded picture, 8-bit 4:2:0, valid only inside the callback it is
/// handed to.
public struct RemuxPicture {
    public var width: Int
    public var height: Int
    /// The tag of the frame it was decoded from.
    public var tag: Int64
    public var isFullRange: Bool
    /// Copies the picture into NV12 planes: luma, then interleaved Cb Cr
    /// (the planes of a 420v or 420f pixel buffer), each with its stride.
    public var copyNV12: (_ luma: UnsafeMutablePointer<UInt8>, _ lumaStride: Int,
                          _ chroma: UnsafeMutablePointer<UInt8>, _ chromaStride: Int) -> Void

    public init(width: Int, height: Int, tag: Int64, isFullRange: Bool,
                copyNV12: @escaping (UnsafeMutablePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, Int) -> Void) {
        self.width = width
        self.height = height
        self.tag = tag
        self.isFullRange = isFullRange
        self.copyNV12 = copyNV12
    }
}

/// Decodes one stretch of a video track (see `RemuxVideoDecoding`).
public protocol RemuxVideoDecoder: AnyObject {
    /// One stored frame, in decode order, tagged; each picture that is ready
    /// goes to `output` (none for a frame that shows nothing). False when
    /// the frame didn't decode.
    @discardableResult
    func decode(_ frame: [UInt8], tag: Int64, output: (RemuxPicture) -> Void) -> Bool
    /// Hands out every picture still held back.
    func finish(output: (RemuxPicture) -> Void)
}

/// The decoders a session may use for video MP4 can't carry (VP8).
public struct RemuxVideoDecoding: Sendable {
    /// Whether a Matroska CodecID can be decoded.
    public var decodes: @Sendable (_ codecID: String) -> Bool
    /// A new decoder for one stretch of a track.
    public var make: @Sendable (_ codecID: String, _ codecPrivate: [UInt8]) -> (any RemuxVideoDecoder)?

    public init(decodes: @escaping @Sendable (String) -> Bool,
                make: @escaping @Sendable (String, [UInt8]) -> (any RemuxVideoDecoder)?) {
        self.decodes = decodes
        self.make = make
    }
}

#if canImport(VideoToolbox)
import CoreMedia
import CoreVideo
import VideoToolbox

/// How a decoded track is re-encoded.
struct VideoTranscode: @unchecked Sendable {
    enum Codec: Sendable {
        case hevc, h264
        var type: CMVideoCodecType { self == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264 }
        var recordKey: String { self == .hevc ? "hvcC" : "avcC" }
        var name: String { self == .hevc ? "HEVC" : "H.264" }
    }

    let decoding: RemuxVideoDecoding
    let codecID: String
    let codecPrivate: [UInt8]
    let codec: Codec
    let width: Int
    let height: Int
    let framesPerSecond: Double
    let fullRange: Bool
    let colour: ColourDescription
    let bitRate: Int
    /// The configuration record (hvcC or avcC) of the sample entry.
    let record: [UInt8]

    /// Pictures waiting for the encoder at most.
    static let framesInFlight = 6

    /// Bits per pixel per frame of the fixed bit rate.
    static func bitsPerPixel(_ codec: Codec) -> Double { codec == .hevc ? 0.1 : 0.15 }

    /// The plan for a track: its first keyframe decoded and encoded, which
    /// says the picture size and gives the parameter sets.
    static func make(track: MatroskaTrack, firstKeyframe: [UInt8], decoding: RemuxVideoDecoding,
                     framesPerSecond: Double?, colour element: ColourDescription?) throws -> VideoTranscode {
        let id = track.codecID
        guard let decoder = decoding.make(id, track.codecPrivate) else {
            throw RemuxError.declined("no decoder for \(id)")
        }
        let fps = framesPerSecond.map { min(240, max(1, $0)) } ?? 30
        var made: VideoTranscode?
        var size: (Int, Int, Bool)?
        let handle: (RemuxPicture) -> Void = { picture in
            guard made == nil, size == nil else { return }
            size = (picture.width, picture.height, picture.isFullRange)
            for codec in [Codec.hevc, .h264] {
                let rate = Self.bitRate(codec, width: picture.width, height: picture.height, fps: fps)
                let colour = element ?? ColourDescription(primaries: 6, transfer: 6, matrix: 6,
                                                          fullRange: picture.isFullRange)
                guard let encoder = VideoEncoder(codec: codec, width: picture.width, height: picture.height,
                                                 fps: fps, bitRate: rate, colour: colour) else { continue }
                encoder.encode(picture, index: 0, time: .zero, duration: CMTime(value: 1, timescale: 30),
                               forceKeyframe: true)
                let outputs = encoder.finish()
                guard let first = outputs[0], first.isSync, let record = encoder.record else { continue }
                made = VideoTranscode(decoding: decoding, codecID: id, codecPrivate: track.codecPrivate, codec: codec,
                                      width: picture.width, height: picture.height, framesPerSecond: fps,
                                      fullRange: picture.isFullRange, colour: colour, bitRate: rate, record: record)
                return
            }
        }
        decoder.decode(firstKeyframe, tag: 0, output: handle)
        decoder.finish(output: handle)
        guard size != nil else { throw RemuxError.declined("\(id) first keyframe didn't decode") }
        guard let made else { throw RemuxError.declined("no video encoder for \(id) re-encoding here") }
        return made
    }

    static func bitRate(_ codec: Codec, width: Int, height: Int, fps: Double) -> Int {
        Int(Double(width * height) * fps * bitsPerPixel(codec))
    }

    /// A segment's frames (decode order, from its keyframe) re-encoded: the
    /// same frames with the encoder's data, minus any that showed nothing.
    /// `time` gives a frame's presentation time at `timescale`.
    func encode(_ frames: [MatroskaFrame], timescale: Int32, time: (MatroskaFrame) -> Int64) throws -> [MatroskaFrame] {
        guard !frames.isEmpty else { return [] }
        guard let decoder = decoding.make(codecID, codecPrivate) else { throw RemuxError.declined("no decoder for \(codecID)") }
        guard let encoder = VideoEncoder(codec: codec, width: width, height: height, fps: framesPerSecond,
                                         bitRate: bitRate, colour: colour) else {
            throw RemuxError.malformed("the \(codec.name) encoder didn't start")
        }
        let times = frames.map(time)
        var submitted = 0
        let output: (RemuxPicture) -> Void = { picture in
            let i = Int(picture.tag)
            guard i >= 0, i < frames.count, picture.width == width, picture.height == height else { return }
            let next = times[(i + 1)...].first { $0 > times[i] }
            let duration = max(1, (next ?? times[i] + Int64(Double(timescale) / framesPerSecond)) - times[i])
            encoder.encode(picture, index: i, time: CMTime(value: times[i], timescale: timescale),
                           duration: CMTime(value: duration, timescale: timescale), forceKeyframe: submitted == 0)
            submitted += 1
        }
        for (i, frame) in frames.enumerated() {
            decoder.decode(frame.data, tag: Int64(i), output: output)
        }
        decoder.finish(output: output)
        let encoded = encoder.finish()

        // Parameter sets in band when this session's differ from the
        // sample entry's.
        var prefix: [UInt8] = []
        if let record = encoder.record, record != self.record {
            prefix = Self.parameterSetNALs(record, codec: codec)
        }
        var out: [MatroskaFrame] = []
        out.reserveCapacity(encoded.count)
        for (i, frame) in frames.enumerated() {
            guard let sample = encoded[i] else { continue }
            var copy = frame
            copy.data = out.isEmpty ? prefix + sample.data : sample.data
            copy.isKeyframe = sample.isSync
            out.append(copy)
        }
        if let first = out.first, !first.isKeyframe {
            throw RemuxError.malformed("re-encoded segment doesn't start with a keyframe")
        }
        return out
    }

    /// A configuration record's parameter sets as 4-byte length-prefixed
    /// NAL units, in order (VPS, SPS, PPS).
    static func parameterSetNALs(_ record: [UInt8], codec: Codec) -> [UInt8] {
        var nals: [[UInt8]] = []
        switch codec {
        case .hevc:
            guard let config = HEVCConfiguration(record: record) else { return [] }
            for type: UInt8 in [32, 33, 34] { nals += config.arrays[type] ?? [] }
        case .h264:
            guard let config = AVCConfiguration(record: record) else { return [] }
            nals = config.sps + config.pps
        }
        var out: [UInt8] = []
        for nal in nals {
            let n = nal.count
            out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal
        }
        return out
    }
}

/// One VideoToolbox compression session: pictures in, length-prefixed
/// samples out, keyed by the index they were submitted with.
final class VideoEncoder: @unchecked Sendable {
    struct Sample {
        var data: [UInt8]
        var isSync: Bool
    }

    let codec: VideoTranscode.Codec
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var samples: [Int: Sample] = [:]
    private var format: CMFormatDescription?
    private let slots = DispatchSemaphore(value: VideoTranscode.framesInFlight)
    private let colour: ColourDescription
    private var finished = false

    init?(codec: VideoTranscode.Codec, width: Int, height: Int, fps: Double, bitRate: Int, colour: ColourDescription) {
        self.codec = codec
        self.colour = colour
        var specification: [CFString: Any] = [:]
        #if os(macOS)
        specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
        #endif
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: colour.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec.type,
            encoderSpecification: specification.isEmpty ? nil : specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else { return nil }
        session = made
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(made, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // One keyframe per segment, at its start (forced); none in between.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000 as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        if let primaries = Self.primaries(colour.primaries) { set(kVTCompressionPropertyKey_ColorPrimaries, primaries) }
        if let transfer = Self.transfer(colour.transfer) { set(kVTCompressionPropertyKey_TransferFunction, transfer) }
        if let matrix = Self.matrix(colour.matrix) { set(kVTCompressionPropertyKey_YCbCrMatrix, matrix) }
        guard VTCompressionSessionPrepareToEncodeFrames(made) == noErr else {
            VTCompressionSessionInvalidate(made)
            return nil
        }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// The configuration record of what has been encoded so far.
    var record: [UInt8]? {
        lock.withLock {
            guard let format,
                  let atoms = CMFormatDescriptionGetExtension(
                    format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                  let data = atoms[codec.recordKey] as? Data else { return nil }
            return [UInt8](data)
        }
    }

    /// Copies a picture into a pixel buffer and submits it. Blocks while
    /// `framesInFlight` pictures are waiting.
    func encode(_ picture: RemuxPicture, index: Int, time: CMTime, duration: CMTime, forceKeyframe: Bool) {
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
           let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            picture.copyNV12(luma.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                             chroma.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        Self.attachColour(buffer, colour)
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        slots.wait()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: duration,
            frameProperties: properties, infoFlagsOut: nil) { [self] status, _, sample in
                defer { slots.signal() }
                guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
                let length = CMBlockBufferGetDataLength(block)
                var data = [UInt8](repeating: 0, count: length)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data) == noErr
                else { return }
                var isSync = true
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[CFString: Any]], let first = attachments.first,
                   first[kCMSampleAttachmentKey_NotSync] as? Bool == true {
                    isSync = false
                }
                let description = CMSampleBufferGetFormatDescription(sample)
                lock.withLock {
                    samples[index] = Sample(data: data, isSync: isSync)
                    if format == nil { format = description }
                }
            }
        if status != noErr { slots.signal() }
    }

    /// Waits for every submitted picture; the samples by index.
    func finish() -> [Int: Sample] {
        if !finished {
            finished = true
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
        return lock.withLock { samples }
    }

    static func attachColour(_ buffer: CVPixelBuffer, _ colour: ColourDescription) {
        if let primaries = primaries(colour.primaries) {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let transfer = transfer(colour.transfer) {
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        if let matrix = matrix(colour.matrix) {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
    }

    // ISO/IEC 23091-2 code points to CoreVideo's names (the SDR ones a VP8
    // file can say).
    static func primaries(_ code: Int) -> CFString? {
        switch code {
        case 1: kCVImageBufferColorPrimaries_ITU_R_709_2
        case 5: kCVImageBufferColorPrimaries_EBU_3213
        case 6, 7: kCVImageBufferColorPrimaries_SMPTE_C
        default: nil
        }
    }

    static func transfer(_ code: Int) -> CFString? {
        switch code {
        case 1, 6, 14, 15: kCVImageBufferTransferFunction_ITU_R_709_2
        case 13: kCVImageBufferTransferFunction_sRGB
        default: nil
        }
    }

    static func matrix(_ code: Int) -> CFString? {
        switch code {
        case 1: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case 5, 6: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case 7: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        default: nil
        }
    }
}

/// A decoded picture as an image (a still of a file whose video only
/// decodes through the caller's decoder).
enum PictureImage {
    static func make(_ picture: RemuxPicture, colour: ColourDescription) -> CGImage? {
        var buffer: CVPixelBuffer?
        let format = picture.isFullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard CVPixelBufferCreate(nil, picture.width, picture.height, format,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                  &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
           let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            picture.copyNV12(luma.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                             chroma.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        VideoEncoder.attachColour(buffer, colour)
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }
}

#else

/// Without VideoToolbox nothing re-encodes: a file that needs it is declined.
struct VideoTranscode: Sendable {
    enum Codec: Sendable {
        case hevc, h264
        var name: String { self == .hevc ? "HEVC" : "H.264" }
    }

    let codec: Codec = .hevc
    let width = 0, height = 0, bitRate = 0
    let record: [UInt8] = []
    let colour = ColourDescription(primaries: 6, transfer: 6, matrix: 6, fullRange: false)

    static func make(track: MatroskaTrack, firstKeyframe: [UInt8], decoding: RemuxVideoDecoding,
                     framesPerSecond: Double?, colour element: ColourDescription?) throws -> VideoTranscode {
        throw RemuxError.declined("video codec \(track.codecID)")
    }

    func encode(_ frames: [MatroskaFrame], timescale: Int32, time: (MatroskaFrame) -> Int64) throws -> [MatroskaFrame] {
        frames
    }
}

#endif
