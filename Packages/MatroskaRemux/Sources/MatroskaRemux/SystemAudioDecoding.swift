/*
 MatroskaRemux - AAC, AC-3 and E-AC-3 decoded with the system's codecs

 These play as they are (MP4 carries them), so nothing decodes them for
 playback. Stable Audio needs the PCM, though (`StableAudio.swift`): its copy
 of a track is decoded, processed and served as ALAC like a DTS track's. The
 OS has decoders for all three in AudioToolbox, so this works in every build,
 the App Store one included (it is the OS's codec doing the decoding, which
 CLAUDE.md allows), on every Apple platform.

 One `AudioConverter` per decoder, fed a stored frame (one packet) at a time.
 The output is the codec's own channel order, read back from the converter
 (`kAudioConverterOutputChannelLayout`), as 24-bit values in 32-bit integers,
 which is what `RemuxAudioDecoder` hands on.
 */

#if canImport(AudioToolbox)
import AudioToolbox
import Foundation

public enum SystemAudioDecoding {
    /// The system's decoders for the Matroska codecs it has one for.
    public static let decoding = RemuxAudioDecoding(
        decodes: { codec(for: $0) != nil },
        make: { id, codecPrivate in
            guard let codec = codec(for: id) else { return nil }
            return SystemAudioDecoder(codec: codec, codecPrivate: codecPrivate)
        })

    /// `preferred` (FFmpeg's, in the sideload edition) for what it decodes,
    /// the system's for the rest.
    public static func combined(with preferred: RemuxAudioDecoding?) -> RemuxAudioDecoding {
        guard let preferred else { return decoding }
        let system = decoding
        return RemuxAudioDecoding(
            decodes: { preferred.decodes($0) || system.decodes($0) },
            make: { id, codecPrivate in
                preferred.decodes(id) ? preferred.make(id, codecPrivate) : system.make(id, codecPrivate)
            })
    }

    enum Codec { case aac, ac3, eac3 }

    static func codec(for id: String) -> Codec? {
        if id == "A_AAC" { return .aac }
        if id == "A_AC3" || id.hasPrefix("A_AC3/") { return .ac3 }
        if id == "A_EAC3" { return .eac3 }
        return nil
    }
}

final class SystemAudioDecoder: RemuxAudioDecoder {
    private let codec: SystemAudioDecoding.Codec
    private let codecPrivate: [UInt8]
    private var converter: AudioConverterRef?
    private var failed = false
    private var inputFormat = AudioStreamBasicDescription()
    private var channels = 0
    private(set) var sampleRate = 0
    private(set) var speakers: [RemuxSpeaker] = []
    private var samples: [Int32] = []
    var frameCount: Int { channels > 0 ? samples.count / channels : 0 }

    init?(codec: SystemAudioDecoding.Codec, codecPrivate: [UInt8]) {
        // AAC is set up from its AudioSpecificConfig, so a bad one fails
        // here; AC-3 and E-AC-3 from their first syncframe.
        if codec == .aac, codecPrivate.count < 2 { return nil }
        self.codec = codec
        self.codecPrivate = codecPrivate
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    private var packets = 0
    private var firstOutput: Int?
    private var lastPacket: [UInt8] = []

    func feed(_ frame: [UInt8]) {
        guard !frame.isEmpty, !failed else { return }
        if converter == nil, !open(firstFrame: frame) { failed = true; return }
        let before = frameCount
        decode(frame)
        if firstOutput == nil { firstOutput = frameCount - before }
        packets += 1
        lastPacket = frame
    }

    /// The system's AC-3 decoders hold their last 288 samples back (the
    /// first packet puts out 1248 of its 1536; the output starts on time),
    /// so the PCM would end short and, lined up at its end
    /// (`RemuxSession.transcoded`), play that much late. The last packet
    /// once more pushes them out; the output is then cut to exactly the
    /// packets fed (measured with clicks against the track as played).
    func finish() {
        let perPacket = Int(inputFormat.mFramesPerPacket)
        guard let firstOutput, perPacket > 0, firstOutput < perPacket, !lastPacket.isEmpty else { return }
        decode(lastPacket)
        let wanted = min(frameCount, packets * perPacket)
        samples.removeSubrange((wanted * channels)...)
    }

    func withSamples<R>(_ body: (UnsafeBufferPointer<Int32>) throws -> R) rethrows -> R {
        try samples.withUnsafeBufferPointer(body)
    }

    // MARK: Setting up

    private func open(firstFrame: [UInt8]) -> Bool {
        var input = AudioStreamBasicDescription()
        var cookie: [UInt8] = []
        switch codec {
        case .aac:
            // The ES descriptor (an esds box's payload) is the cookie the
            // AAC decoder takes, and the format list it gives names the
            // highest layer (HE-AAC's SBR rate, not the core's).
            var w = BoxWriter()
            SampleEntries.esds(&w, objectType: 0x40, decoderSpecificInfo: codecPrivate)
            cookie = Array(w.bytes.dropFirst(12))
            guard let format = Self.highestLayer(cookie: cookie) else { return false }
            input = format
        case .ac3:
            guard let sync = AC3Syncframe(firstFrame) else { return false }
            input.mFormatID = kAudioFormatAC3
            input.mSampleRate = Double(sync.sampleRate)
            input.mChannelsPerFrame = UInt32(sync.channels)
            input.mFramesPerPacket = 1536
        case .eac3:
            guard let info = EAC3Info(firstFrame) else { return false }
            input.mFormatID = kAudioFormatEnhancedAC3
            input.mSampleRate = Double(info.sampleRate)
            input.mChannelsPerFrame = UInt32(info.channels)
            input.mFramesPerPacket = UInt32(info.samplesPerFrame)
        }
        guard input.mChannelsPerFrame > 0, input.mSampleRate > 0 else { return false }
        let count = Int(input.mChannelsPerFrame)
        var output = AudioStreamBasicDescription(
            mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * count), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * count),
            mChannelsPerFrame: UInt32(count), mBitsPerChannel: 32, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &made) == noErr, let made else { return false }
        if !cookie.isEmpty {
            _ = cookie.withUnsafeBytes {
                AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
            }
        }
        converter = made
        inputFormat = input
        channels = count
        sampleRate = Int(input.mSampleRate.rounded())
        speakers = Self.speakers(of: made, channels: count, codec: codec)
        return true
    }

    private static func highestLayer(cookie: [UInt8]) -> AudioStreamBasicDescription? {
        cookie.withUnsafeBytes { raw -> AudioStreamBasicDescription? in
            guard let cookieBase = raw.baseAddress else { return nil }
            var info = AudioFormatInfo(mASBD: AudioStreamBasicDescription(), mMagicCookie: cookieBase,
                                       mMagicCookieSize: UInt32(raw.count))
            info.mASBD.mFormatID = kAudioFormatMPEG4AAC
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, UInt32(MemoryLayout<AudioFormatInfo>.size),
                                             &info, &size) == noErr, size > 0 else { return nil }
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(),
                                              count: Int(size) / MemoryLayout<AudioFormatListItem>.size)
            guard AudioFormatGetProperty(kAudioFormatProperty_FormatList, UInt32(MemoryLayout<AudioFormatInfo>.size),
                                         &info, &size, &items) == noErr else { return nil }
            return items.first?.mASBD
        }
    }

    /// The decoder's output order, read back as speakers; the codec's
    /// default order for the count when the converter names none.
    private static func speakers(of converter: AudioConverterRef, channels: Int,
                                 codec: SystemAudioDecoding.Codec) -> [RemuxSpeaker] {
        var size: UInt32 = 0
        var layout: [RemuxSpeaker] = []
        if AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout, &size, nil) == noErr,
           size >= UInt32(MemoryLayout<AudioChannelLayout>.size) {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
            defer { raw.deallocate() }
            if AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &size, raw) == noErr {
                layout = labels(of: raw.assumingMemoryBound(to: AudioChannelLayout.self), size: size)
            }
        }
        if layout.count == channels { return layout }
        // The codec's own order: AC-3's is L C R Ls Rs LFE (measured on
        // macOS 27 with per-channel tones), AAC's C L R Ls Rs LFE.
        if codec != .aac {
            switch channels {
            case 3: return [.frontLeft, .frontCenter, .frontRight]
            case 5: return [.frontLeft, .frontCenter, .frontRight, .sideLeft, .sideRight]
            case 6: return [.frontLeft, .frontCenter, .frontRight, .sideLeft, .sideRight, .lowFrequency]
            default: break
            }
        }
        switch channels {
        case 1: return [.frontCenter]
        case 2: return [.frontLeft, .frontRight]
        case 3: return [.frontCenter, .frontLeft, .frontRight]
        case 5: return [.frontCenter, .frontLeft, .frontRight, .sideLeft, .sideRight]
        case 6: return [.frontCenter, .frontLeft, .frontRight, .sideLeft, .sideRight, .lowFrequency]
        default: return Array(repeating: .other, count: channels)
        }
    }

    private static func labels(of layout: UnsafePointer<AudioChannelLayout>, size: UInt32) -> [RemuxSpeaker] {
        let tag = layout.pointee.mChannelLayoutTag
        var descriptions: [AudioChannelDescription] = []
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let count = Int(layout.pointee.mNumberChannelDescriptions)
            withUnsafePointer(to: layout.pointee.mChannelDescriptions) { first in
                let base = UnsafeRawPointer(first).assumingMemoryBound(to: AudioChannelDescription.self)
                descriptions = (0 ..< count).map { base[$0] }
            }
        } else {
            // Expanded to descriptions by the system.
            var copy = layout.pointee
            var expandedSize: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size),
                                             &copy.mChannelLayoutTag, &expandedSize) == noErr, expandedSize > 0 else { return [] }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(expandedSize), alignment: 8)
            defer { raw.deallocate() }
            var tagValue = tag
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size),
                                         &tagValue, &expandedSize, raw) == noErr else { return [] }
            let expanded = raw.assumingMemoryBound(to: AudioChannelLayout.self)
            guard expanded.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions else { return [] }
            return labels(of: expanded, size: expandedSize)
        }
        return descriptions.map { description in
            switch description.mChannelLabel {
            case kAudioChannelLabel_Left: .frontLeft
            case kAudioChannelLabel_Right: .frontRight
            case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: .frontCenter
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: .lowFrequency
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect: .sideLeft
            case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect: .sideRight
            case kAudioChannelLabel_RearSurroundLeft: .backLeft
            case kAudioChannelLabel_RearSurroundRight: .backRight
            case kAudioChannelLabel_CenterSurround: .backCenter
            default: .other
            }
        }
    }

    // MARK: Decoding

    /// What the input callback hands the converter: one packet, once.
    private final class Pending {
        var data: UnsafeMutableRawPointer?
        var size = 0
        var description = AudioStreamPacketDescription()
        var used = false
    }

    private static let noMoreInput: OSStatus = 0x6E6F6D6F // 'nomo'

    private func decode(_ frame: [UInt8]) {
        guard let converter else { return }
        let pending = Pending()
        let data = UnsafeMutableRawPointer.allocate(byteCount: frame.count, alignment: 16)
        defer { data.deallocate() }
        frame.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
        pending.data = data
        pending.size = frame.count
        pending.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                           mDataByteSize: UInt32(frame.count))
        let capacity = 8192
        var buffer = [Float](repeating: 0, count: capacity * channels)
        let context = Unmanaged.passUnretained(pending).toOpaque()
        while true {
            var frames = UInt32(capacity)
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, packets, io, descriptions, user in
                    let pending = Unmanaged<Pending>.fromOpaque(user!).takeUnretainedValue()
                    guard !pending.used else { packets.pointee = 0; return SystemAudioDecoder.noMoreInput }
                    pending.used = true
                    packets.pointee = 1
                    io.pointee.mBuffers.mData = pending.data
                    io.pointee.mBuffers.mDataByteSize = UInt32(pending.size)
                    io.pointee.mBuffers.mNumberChannels = 0
                    if let descriptions {
                        withUnsafeMutablePointer(to: &pending.description) { descriptions.pointee = $0 }
                    }
                    return noErr
                }, context, &frames, &list, nil)
            }
            if frames > 0 {
                samples.reserveCapacity(samples.count + Int(frames) * channels)
                for i in 0 ..< Int(frames) * channels {
                    let v = (buffer[i] * 8_388_608).rounded()
                    samples.append(Int32(max(-8_388_608, min(8_388_607, v))))
                }
            }
            // Out of input (this packet decoded), or an error: next packet.
            if status != noErr || frames == 0 { break }
        }
    }
}
#endif

/// Codec ids, also where AudioToolbox isn't.
enum SystemAudioDecodingCodec {
    static func isAAC(_ id: String) -> Bool { id == "A_AAC" || id.hasPrefix("A_AAC/") }
}
