/*
 Hypnos - turning a song's bytes into the music engine's samples.

 Two decoders, one result: interleaved stereo Float32 at the engine's output rate, with exactly the
 song's own frames. An encoder's priming and padding are trimmed by the container's packet table
 (MP3's LAME header, MPEG-4's edit list, FLAC's STREAMINFO), which is what makes two songs cut from
 one recording join without a click. AVPlayer doesn't: it plays a 24.000 s FLAC as 24.056 s
 (rounding its last frame up to a full block) and starts the next item ~70 ms after that, measured
 against the dev Jellyfin's "Unbroken Line" (2026-11-12).

 - `MusicStreamDecoder` parses the file while it downloads (AudioFileStream) and decodes its packets
   (AVAudioConverter), so a song starts as soon as its first frames are there. An MPEG-4 file whose
   index (moov) comes after its audio can't be parsed that way: `needsWholeFile` says so, and the
   engine waits for the download and uses the file decoder.
 - `MusicFileDecoder` reads a complete file (AVAudioFile, which trims by the same packet table) and
   seeks to an exact frame. Used for every song whose file is complete when it starts, and for seeks.

 Both hand their source-rate audio to `MusicResampler`, which makes it stereo (mono doubled, more
 channels mixed down) at the output rate.
 */

import AudioToolbox
import AVFoundation
import Foundation

/// The engine's sample format: interleaved stereo Float32 at one rate for a whole run of songs.
nonisolated struct MusicOutputFormat: Equatable, Sendable {
    static let channels = 2
    let sampleRate: Double
}

nonisolated enum MusicDecodeStep {
    /// Interleaved stereo frames (count / 2 frames).
    case audio([Float])
    /// Nothing new until more of the file arrives.
    case waiting
    /// The song's last frame has been handed out.
    case end
    case failed(String)
}

nonisolated protocol MusicDecoding: AnyObject {
    /// The song's length in output frames, once the container has said (nil: only the end will tell).
    var totalFrames: Int64? { get }
    /// Decodes up to about `maxFrames`. `output` is the run's format; when nil the decoder sets it from the
    /// song's own rate as soon as it knows it.
    func read(maxFrames: Int, output: inout MusicOutputFormat?) -> MusicDecodeStep
}

// MARK: - Resampling to the output format

/// Source-rate Float32 audio to interleaved stereo at the output rate.
nonisolated final class MusicResampler {
    let sourceFormat: AVAudioFormat
    let output: MusicOutputFormat
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private var finished = false

    init?(source: AVAudioFormat, output: MusicOutputFormat) {
        sourceFormat = source
        self.output = output
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: output.sampleRate,
                                               channels: AVAudioChannelCount(MusicOutputFormat.channels), interleaved: true) else { return nil }
        self.outputFormat = outputFormat
        // Same rate and one or two channels: interleaved by hand, bit for bit.
        if source.sampleRate == output.sampleRate, source.channelCount <= 2 {
            converter = nil
        } else {
            // Mono is doubled to stereo before conversion, so the converter only ever changes rate and mixes down.
            let from = source.channelCount == 1
                ? AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 2)!
                : source
            guard let converter = AVAudioConverter(from: from, to: outputFormat) else { return nil }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.downmix = source.channelCount > 2
            self.converter = converter
        }
    }

    var totalFramesFactor: Double { output.sampleRate / sourceFormat.sampleRate }

    /// `buffer` (deinterleaved Float32 in `sourceFormat`) as interleaved stereo output frames.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let stereo = Self.stereo(buffer)
        guard let converter else { return Self.interleave(stereo) }
        return run(converter, input: stereo, end: false)
    }

    /// What the rate converter still holds, at the end of the song.
    func finish() -> [Float] {
        guard let converter, !finished else { return [] }
        finished = true
        return run(converter, input: nil, end: true)
    }

    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, end: Bool) -> [Float] {
        let frames = Double(input?.frameLength ?? 0) * output.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(frames + 4096)
        var result: [Float] = []
        var given = input == nil
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return result }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, status in
                if !given, let input { given = true; status.pointee = .haveData; return input }
                status.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if out.frameLength > 0, let data = out.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength) * MusicOutputFormat.channels))
            }
            if status == .error || status == .endOfStream || status == .inputRanDry || out.frameLength == 0 { break }
        }
        return result
    }

    /// One or two deinterleaved channels as a two-channel buffer (mono doubled); more channels pass through.
    private static func stereo(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount == 1,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 2),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = out.floatChannelData else { return buffer }
        out.frameLength = buffer.frameLength
        let count = Int(buffer.frameLength)
        target[0].update(from: source[0], count: count)
        target[1].update(from: source[0], count: count)
        return out
    }

    private static func interleave(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return [] }
        let left = data[0], right = buffer.format.channelCount > 1 ? data[1] : data[0]
        var result = [Float](repeating: 0, count: frames * 2)
        result.withUnsafeMutableBufferPointer { out in
            for i in 0 ..< frames { out[2 * i] = left[i]; out[2 * i + 1] = right[i] }
        }
        return result
    }
}

// MARK: - A complete file

nonisolated final class MusicFileDecoder: MusicDecoding {
    private let file: AVAudioFile
    private var resampler: MusicResampler?
    private var output: MusicOutputFormat?
    private var ended = false
    private let sourceRate: Double

    /// Opens `url` at `startSeconds`. Nil when AVAudioFile can't read it.
    init?(url: URL, startSeconds: Double = 0) {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0 else { return nil }
        self.file = file
        sourceRate = file.processingFormat.sampleRate
        file.framePosition = min(file.length, max(0, AVAudioFramePosition((startSeconds * sourceRate).rounded())))
    }

    var totalFrames: Int64? {
        output.map { Int64((Double(file.length) * $0.sampleRate / sourceRate).rounded()) }
    }

    func read(maxFrames: Int, output runFormat: inout MusicOutputFormat?) -> MusicDecodeStep {
        if ended { return .end }
        if runFormat == nil { runFormat = MusicOutputFormat(sampleRate: sourceRate) }
        guard let runFormat else { return .end }
        if resampler == nil {
            guard let made = MusicResampler(source: file.processingFormat, output: runFormat) else {
                return .failed("This song's audio format can't be converted.")
            }
            resampler = made
            output = runFormat
        }
        guard let resampler else { return .end }
        let frames = AVAudioFrameCount(max(256, Double(maxFrames) * sourceRate / runFormat.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return .failed("Out of memory decoding this song.")
        }
        if file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: frames)
            } catch {
                return .failed("This song's file couldn't be read (\((error as NSError).code)).")
            }
        }
        var samples = resampler.convert(buffer)
        if buffer.frameLength == 0 || file.framePosition >= file.length {
            ended = true
            samples += resampler.finish()
            if samples.isEmpty { return .end }
        }
        return .audio(samples)
    }
}

// MARK: - A file still arriving

nonisolated final class MusicStreamDecoder: MusicDecoding {
    private let file: MusicSongFile
    private var handle: FileHandle?
    private var offset: Int64 = 0
    private var parser: AudioFileStreamID?

    // What the parser has found.
    fileprivate var ready = false
    fileprivate var streamFormat = AudioStreamBasicDescription()
    fileprivate var cookie: Data?
    fileprivate var layout: AVAudioChannelLayout?
    fileprivate var packetTable: AudioFilePacketTableInfo?
    fileprivate var pendingBytes = Data()
    fileprivate var pendingPackets: [AudioStreamPacketDescription] = []
    fileprivate var maxPacketSize: UInt32 = 0

    private var sourceFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var codec: AVAudioConverter?
    private var resampler: MusicResampler?
    /// Source frames still to drop from the front: the encoder's priming, and up to a seek's target.
    private var dropFrames: Int64 = 0
    /// Source frames handed on so far (after the priming).
    private var emitted: Int64 = 0
    private var skipTo: Int64 = 0
    private var drained = false
    private var flushedParser = false
    private var ended = false
    private var output: MusicOutputFormat?
    /// An MPEG-4 file with its index after its audio: only a complete file can be read.
    private(set) var needsWholeFile = false

    /// Starts decoding `file` from its start, discarding everything before `startSeconds`.
    init(file: MusicSongFile, startSeconds: Double = 0) {
        self.file = file
        skipTo = Int64(max(0, startSeconds) * 1_000_000) // in microseconds until the rate is known
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(context, musicStreamProperty, musicStreamPackets, file.typeHint, &parser)
    }

    deinit {
        if let parser { AudioFileStreamClose(parser) }
        try? handle?.close()
    }

    var totalFrames: Int64? {
        guard let packetTable, packetTable.mNumberValidFrames > 0, let output, streamFormat.mSampleRate > 0 else { return nil }
        return Int64((Double(packetTable.mNumberValidFrames) * output.sampleRate / streamFormat.mSampleRate).rounded())
    }

    func read(maxFrames: Int, output runFormat: inout MusicOutputFormat?) -> MusicDecodeStep {
        if ended { return .end }
        if needsWholeFile { return .waiting }
        // Parse until there's a packet or two of decodable data, or the file runs out for now.
        while pendingPacketsWorth() < maxFrames, parser != nil {
            let chunk = file.read(at: offset, count: 65_536, using: &handle)
            if chunk.isEmpty { break }
            offset += Int64(chunk.count)
            let status = chunk.withUnsafeBytes { bytes in
                AudioFileStreamParseBytes(parser!, UInt32(bytes.count), bytes.baseAddress, [])
            }
            if status == kAudioFileStreamError_NotOptimized {
                needsWholeFile = true
                return .waiting
            }
            if status != noErr { return .failed("This song's file couldn't be parsed (\(Self.code(status))).") }
        }
        let progress = file.progress
        if let failure = progress.failure { return .failed(failure) }
        let atEnd = progress.complete && offset >= progress.received
        if atEnd, !flushedParser, let parser {
            // The parser keeps a stream's last packet until it hears there is no more (FLAC's partial last frame).
            flushedParser = true
            AudioFileStreamParseBytes(parser, 0, nil, [])
        }
        guard ready else { return atEnd ? .failed("This song's file has no audio the device can read.") : .waiting }
        if output == nil {
            if runFormat == nil { runFormat = MusicOutputFormat(sampleRate: streamFormat.mSampleRate) }
            output = runFormat
            setUp()
        }
        guard let codec, let pcmFormat, let resampler else { return .failed("This song's audio format can't be decoded.") }
        if pendingPackets.isEmpty, pendingBytes.isEmpty, !atEnd { return .waiting }

        var decoded: AVAudioPCMBuffer?
        if streamFormat.mFormatID == kAudioFormatLinearPCM {
            decoded = linearPCM(pcmFormat: pcmFormat)
        } else {
            decoded = decodePackets(codec: codec, pcmFormat: pcmFormat, end: atEnd && pendingPackets.isEmpty)
        }
        var samples = decoded.flatMap { trim($0) }.map { resampler.convert($0) } ?? []
        if atEnd, pendingPackets.isEmpty, pendingBytes.isEmpty, drained || streamFormat.mFormatID == kAudioFormatLinearPCM {
            ended = true
            samples += resampler.finish()
        } else if let limit = validFrames, emitted >= limit {
            ended = true
            samples += resampler.finish()
        }
        if samples.isEmpty { return ended ? .end : (atEnd ? .audio([]) : .waiting) }
        return .audio(samples)
    }

    private var validFrames: Int64? {
        guard let packetTable, packetTable.mNumberValidFrames > 0 else { return nil }
        return packetTable.mNumberValidFrames
    }

    private func pendingPacketsWorth() -> Int {
        let perPacket = Int(streamFormat.mFramesPerPacket)
        if perPacket > 0, !pendingPackets.isEmpty { return pendingPackets.count * perPacket }
        if streamFormat.mBytesPerFrame > 0 { return pendingBytes.count / Int(streamFormat.mBytesPerFrame) }
        return 0
    }

    private func setUp() {
        var description = streamFormat
        let format: AVAudioFormat?
        if let layout, streamFormat.mChannelsPerFrame > 2 {
            format = AVAudioFormat(streamDescription: &description, channelLayout: layout)
        } else {
            format = AVAudioFormat(streamDescription: &description)
        }
        guard let format else { return }
        sourceFormat = format
        let channels = streamFormat.mChannelsPerFrame
        let pcm: AVAudioFormat? = channels > 2
            ? layout.map { AVAudioFormat(standardFormatWithSampleRate: streamFormat.mSampleRate, channelLayout: $0) }
            : AVAudioFormat(standardFormatWithSampleRate: streamFormat.mSampleRate, channels: channels)
        guard let pcm, let converter = AVAudioConverter(from: format, to: pcm), let output else { return }
        if let cookie { converter.magicCookie = cookie }
        pcmFormat = pcm
        codec = converter
        resampler = MusicResampler(source: pcm, output: output)
        dropFrames = Int64(packetTable?.mPrimingFrames ?? 0)
        skipTo = Int64((Double(skipTo) / 1_000_000 * streamFormat.mSampleRate).rounded())
    }

    /// Packets decoded through the codec.
    private func decodePackets(codec: AVAudioConverter, pcmFormat: AVAudioFormat, end: Bool) -> AVAudioPCMBuffer? {
        guard let sourceFormat else { return nil }
        let count = pendingPackets.count
        let framesPerPacket = max(1, Int(streamFormat.mFramesPerPacket))
        let capacity = AVAudioFrameCount(max(count, 1) * framesPerPacket + 8192)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }
        var input: AVAudioCompressedBuffer?
        if count > 0 {
            let compressed = AVAudioCompressedBuffer(format: sourceFormat, packetCapacity: AVAudioPacketCount(count),
                                                     maximumPacketSize: Int(max(maxPacketSize, 1)))
            pendingBytes.withUnsafeBytes { bytes in
                compressed.data.copyMemory(from: bytes.baseAddress!, byteCount: min(bytes.count, Int(compressed.byteCapacity)))
            }
            compressed.byteLength = UInt32(min(pendingBytes.count, Int(compressed.byteCapacity)))
            if let descriptions = compressed.packetDescriptions {
                for i in 0 ..< count { descriptions[i] = pendingPackets[i] }
            }
            compressed.packetCount = AVAudioPacketCount(count)
            input = compressed
        }
        pendingPackets.removeAll(keepingCapacity: true)
        pendingBytes.removeAll(keepingCapacity: true)
        var given = input == nil
        var error: NSError?
        let status = codec.convert(to: out, error: &error) { _, status in
            if !given, let input { given = true; status.pointee = .haveData; return input }
            status.pointee = end ? .endOfStream : .noDataNow
            return nil
        }
        if end && (status == .endOfStream || status == .inputRanDry || out.frameLength == 0) { drained = true }
        if status == .error { drained = true }
        return out.frameLength > 0 ? out : nil
    }

    /// Uncompressed packets (WAV, AIFF, CAF) through a format converter to deinterleaved Float32.
    private func linearPCM(pcmFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let sourceFormat, let codec else { return nil }
        let bytesPerFrame = Int(streamFormat.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = pendingBytes.count / bytesPerFrame
        guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        raw.frameLength = AVAudioFrameCount(frames)
        let list = UnsafeMutableAudioBufferListPointer(raw.mutableAudioBufferList)
        pendingBytes.withUnsafeBytes { bytes in
            if let target = list[0].mData { target.copyMemory(from: bytes.baseAddress!, byteCount: frames * bytesPerFrame) }
        }
        pendingBytes.removeSubrange(0 ..< frames * bytesPerFrame)
        do { try codec.convert(to: out, from: raw) } catch { return nil }
        return out
    }

    /// Drops the priming, a seek's lead-in and anything past the last valid frame.
    private func trim(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        var start = 0
        var length = Int(buffer.frameLength)
        if dropFrames > 0 {
            let drop = min(Int64(length), dropFrames)
            dropFrames -= drop
            start = Int(drop)
            length -= Int(drop)
        }
        if skipTo > emitted, length > 0 {
            let drop = Int(min(Int64(length), skipTo - emitted))
            emitted += Int64(drop)
            start += drop
            length -= drop
        }
        if let limit = validFrames { length = Int(max(0, min(Int64(length), limit - emitted))) }
        guard length > 0 else { return nil }
        emitted += Int64(length)
        if start == 0, length == Int(buffer.frameLength) { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length)),
              let source = buffer.floatChannelData, let target = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(length)
        for c in 0 ..< Int(buffer.format.channelCount) { target[c].update(from: source[c] + start, count: length) }
        return out
    }

    static func code(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
        return chars.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "?" || $0 == "!" }) ? String(chars) : String(status)
    }
}

// MARK: - AudioFileStream callbacks

private nonisolated func musicStreamProperty(_ context: UnsafeMutableRawPointer, _ stream: AudioFileStreamID,
                                             _ property: AudioFileStreamPropertyID, _ flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    let decoder = Unmanaged<MusicStreamDecoder>.fromOpaque(context).takeUnretainedValue()
    switch property {
    case kAudioFileStreamProperty_ReadyToProducePackets:
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var description = AudioStreamBasicDescription()
        AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &description)
        // HE-AAC: the format list's first entry is the full-rate layer the decoder should produce.
        var listSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_FormatList, &listSize, nil) == noErr, listSize > 0 {
            let count = Int(listSize) / MemoryLayout<AudioFormatListItem>.size
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &listSize, &items) == noErr,
               let first = items.first, first.mASBD.mFormatID == kAudioFormatMPEG4AAC_HE || first.mASBD.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                description = first.mASBD
            }
        }
        decoder.streamFormat = description
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = Data(count: Int(cookieSize))
            cookie.withUnsafeMutableBytes { _ = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, $0.baseAddress!) }
            decoder.cookie = cookie
        }
        var table = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        if AudioFileStreamGetProperty(stream, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr { decoder.packetTable = table }
        var layoutSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_ChannelLayout, &layoutSize, nil) == noErr, layoutSize > 0 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(layoutSize), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_ChannelLayout, &layoutSize, raw) == noErr {
                decoder.layout = AVAudioChannelLayout(layout: raw.assumingMemoryBound(to: AudioChannelLayout.self))
            }
        }
        var maxPacket: UInt32 = 0
        size = 4
        if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_PacketSizeUpperBound, &size, &maxPacket) == noErr { decoder.maxPacketSize = maxPacket }
        decoder.ready = true
    default:
        break
    }
}

private nonisolated func musicStreamPackets(_ context: UnsafeMutableRawPointer, _ byteCount: UInt32, _ packetCount: UInt32,
                                            _ data: UnsafeRawPointer, _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    let decoder = Unmanaged<MusicStreamDecoder>.fromOpaque(context).takeUnretainedValue()
    let base = Int64(decoder.pendingBytes.count)
    let format = decoder.streamFormat
    if descriptions == nil, format.mFormatID != kAudioFormatLinearPCM, format.mBytesPerPacket > 0 {
        // Constant-size compressed packets come without descriptions; the decoder needs them.
        let size = format.mBytesPerPacket
        for i in 0 ..< Int(packetCount) {
            decoder.pendingPackets.append(AudioStreamPacketDescription(mStartOffset: base + Int64(i) * Int64(size),
                                                                       mVariableFramesInPacket: 0, mDataByteSize: size))
        }
        decoder.maxPacketSize = max(decoder.maxPacketSize, size)
    } else if let descriptions {
        for i in 0 ..< Int(packetCount) {
            var packet = descriptions[i]
            decoder.maxPacketSize = max(decoder.maxPacketSize, packet.mDataByteSize)
            packet.mStartOffset += base
            decoder.pendingPackets.append(packet)
        }
    }
    decoder.pendingBytes.append(data.assumingMemoryBound(to: UInt8.self), count: Int(byteCount))
}
