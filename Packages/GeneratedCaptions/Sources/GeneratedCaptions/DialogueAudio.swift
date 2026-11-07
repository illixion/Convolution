import AVFoundation
import AudioToolbox

/// Decoded audio as the one channel speech recognition hears.
///
/// `AVAudioConverter` taking 5.1 to mono keeps only the centre channel and
/// drops the rest; from stereo it keeps the left. The centre is where film
/// dialogue lives, and leaving the music and effects out is what keeps it
/// clear, so a centre that carries sound is still used alone. A centre that is
/// silent next to the front pair (stereo carried as 5.1, some TV and anime
/// mixes) gave the recognizer silence; then the front pair is mixed in. LFE and
/// surrounds never are.
struct DialogueMixer {
    /// Decaying energy of the centre and of the front pair, ~30 s memory, so a
    /// silent music intro doesn't decide for the whole film.
    private var centreEnergy = 0.0
    private var frontEnergy = 0.0
    private static let memorySeconds = 30.0
    /// Centre this far (−20 dB) below the front pair counts as empty.
    private static let emptyCentreRatio = 0.01

    /// Whether the last buffer took the front pair because the centre was empty.
    private(set) var usesFrontPair = false

    /// `input` as Float32 mono at its own rate, or nil for a sample format it
    /// doesn't read (the caller converts that one as before).
    mutating func mono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = input.format
        let channels = Int(format.channelCount)
        let frames = Int(input.frameLength)
        guard channels > 0, let reader = SampleReader(input),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(max(1, frames))),
              let out = output.floatChannelData?[0] else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        let labels = Self.labels(of: format)
        let centre = labels.firstIndex(of: kAudioChannelLabel_Center) ?? labels.firstIndex(of: kAudioChannelLabel_Mono)
        let left = labels.firstIndex(of: kAudioChannelLabel_Left)
        let right = labels.firstIndex(of: kAudioChannelLabel_Right)
        let front = [left, right].compactMap { $0 }

        if channels == 1 || (centre == nil && front.isEmpty) {
            // Nothing known to pick: one channel as it is, or every channel
            // but the LFE averaged.
            let used = (0..<channels).filter { labels[$0] != kAudioChannelLabel_LFEScreen }
            let weight = Float(1) / Float(max(1, used.count))
            for i in 0..<frames {
                var sum: Float = 0
                for c in used { sum += reader[c, i] }
                out[i] = sum * weight
            }
            usesFrontPair = false
            return output
        }
        guard let centre else {
            // Stereo (or a layout without a centre): the front pair's average.
            let weight = Float(1) / Float(front.count)
            for i in 0..<frames {
                var sum: Float = 0
                for c in front { sum += reader[c, i] }
                out[i] = sum * weight
            }
            usesFrontPair = true
            return output
        }
        var centreSum = 0.0, frontSum = 0.0
        for i in 0..<frames {
            let c = Double(reader[centre, i])
            centreSum += c * c
            for f in front { let v = Double(reader[f, i]); frontSum += v * v / Double(front.count) }
        }
        let decay = exp(-Double(frames) / format.sampleRate / Self.memorySeconds)
        centreEnergy = centreEnergy * decay + centreSum
        frontEnergy = frontEnergy * decay + frontSum
        usesFrontPair = !front.isEmpty && centreEnergy < frontEnergy * Self.emptyCentreRatio
        if usesFrontPair {
            let weight = Float(1) / Float(front.count)
            for i in 0..<frames {
                var sum: Float = 0
                for c in front { sum += reader[c, i] }
                out[i] = reader[centre, i] + sum * weight
            }
        } else {
            for i in 0..<frames { out[i] = reader[centre, i] }
        }
        return output
    }

    /// Each channel's label, from the format's layout, or the usual order for
    /// that many channels when it has none (WAVE/SMPTE: L R C LFE Ls Rs …).
    static func labels(of format: AVAudioFormat) -> [AudioChannelLabel] {
        let count = Int(format.channelCount)
        if let layout = format.channelLayout, let labels = labels(of: layout.layout), labels.count == count {
            return labels
        }
        let order: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
        switch count {
        case 1: return [kAudioChannelLabel_Mono]
        case 2: return [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        case 6, 8: return Array(order.prefix(count))
        default: return Array(repeating: kAudioChannelLabel_Unknown, count: count)
        }
    }

    private static func labels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel]? {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return descriptions(layout)
        }
        var size: UInt32 = 0
        var status: OSStatus
        let property: AudioFormatPropertyID
        var specifier: UInt32
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            property = kAudioFormatProperty_ChannelLayoutForBitmap
            specifier = layout.pointee.mChannelBitmap.rawValue
        } else {
            property = kAudioFormatProperty_ChannelLayoutForTag
            specifier = tag
        }
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        status = AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size)
        guard status == noErr, size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        status = AudioFormatGetProperty(property, specifierSize, &specifier, &size, storage)
        guard status == noErr else { return nil }
        return descriptions(UnsafePointer(storage.assumingMemoryBound(to: AudioChannelLayout.self)))
    }

    private static func descriptions(_ layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        // A variable-length C struct: the descriptions run on past the one
        // the Swift type declares.
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
        let first = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return UnsafeBufferPointer(start: first, count: count).map(\.mChannelLabel)
    }
}

/// Reads a sample of any channel as Float, whatever the buffer's layout.
private struct SampleReader {
    private let read: (Int, Int) -> Float
    subscript(channel: Int, frame: Int) -> Float { read(channel, frame) }

    init?(_ buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            read = interleaved ? { c, i in data[0][i * channels + c] } : { c, i in data[c][i] }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            read = interleaved ? { c, i in Float(data[0][i * channels + c]) / 32768 } : { c, i in Float(data[c][i]) / 32768 }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            read = interleaved ? { c, i in Float(data[0][i * channels + c]) / 2_147_483_648 } : { c, i in Float(data[c][i]) / 2_147_483_648 }
        default:
            return nil
        }
    }
}

/// Where in the fed audio someone is speaking, roughly: 20 ms frames well above
/// a tracked noise floor. Used to place a volatile guess. The recognizer gives
/// a guess one time range, from the end of the last final, so it began in the
/// pause before the speech, and the guess went on screen before the line was
/// said, then again when its final arrived.
struct VoiceActivity {
    private(set) var spans: [(start: Double, end: Double)] = []
    private var floor: Float?
    private static let frameSeconds = 0.02
    /// The floor follows a quieter frame at once and rises 3 dB a second.
    private static let floorRisePerFrame = Float(pow(10, 3.0 / 20 * frameSeconds))
    /// Voice: 10 dB over the floor and above −50 dBFS.
    private static let overFloor: Float = 3.16
    private static let minimumLevel: Float = 0.003
    /// Gaps shorter than this are inside one stretch of speech.
    private static let bridge = 0.15
    /// A stretch shorter than this (a click, a door) is not speech.
    private static let minimumSpan = 0.12

    mutating func add(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, at time: Double) {
        let frame = max(1, Int(sampleRate * Self.frameSeconds))
        var index = 0
        while index + frame / 4 <= samples.count {
            let end = min(samples.count, index + frame)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - index)).squareRoot()
            let current = floor.map { rms < $0 ? rms : $0 * Self.floorRisePerFrame } ?? rms
            floor = current
            if rms > max(current * Self.overFloor, Self.minimumLevel) {
                let start = time + Double(index) / sampleRate, stop = time + Double(end) / sampleRate
                if let last = spans.last, start - last.end <= Self.bridge, start >= last.start {
                    spans[spans.count - 1].end = max(last.end, stop)
                } else {
                    spans.append((start, stop))
                }
            }
            index = end
        }
    }

    /// The first moment of speech from `start` through `end`, or nil when the
    /// stretch has none.
    func onset(from start: Double, through end: Double) -> Double? {
        spans.first { $0.end > start && $0.start < end && $0.end - $0.start >= Self.minimumSpan }
            .map { max(start, $0.start) }
    }

    mutating func forget(before time: Double) {
        spans.removeAll { $0.end < time }
    }

    mutating func reset() { spans = []; floor = nil }
}
