import AVFoundation
import Foundation
import VergenceApple

extension RAVECaptionAudioSource {
    /// Decode one independently readable MP4 fragment at a time (initialization
    /// segment + media fragment). PTS stays on the original media timeline.
    /// The producer starts near the playhead; nil means actual end of media.
    public static func fragmentedMP4(next: @escaping @Sendable () async throws -> Data?) -> Self {
        let decoder = FragmentedCaptionAudio(next: next)
        return Self { try await decoder.next() }
    }
}

/// AVAssetReader cannot read HLS. A bounded local MP4 containing one audio
/// fragment can be read even on visionOS, where the HLS sample output is silent.
private actor FragmentedCaptionAudio {
    let fragment: @Sendable () async throws -> Data?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var file: URL?
    private var timeOffset = 0.0
    private var converter: AVAudioConverter?

    init(next: @escaping @Sendable () async throws -> Data?) { fragment = next }

    isolated deinit {
        reader?.cancelReading()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func next() async throws -> RAVECaptionAudioChunk? {
        while true {
            try Task.checkCancellation()
            if let output, let sample = output.copyNextSampleBuffer() {
                if let buffer = try decode(sample) {
                    return RAVECaptionAudioChunk(buffer: buffer, time: timeOffset + CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
                continue
            }
            if let reader, reader.status == .failed { throw reader.error ?? URLError(.cannotDecodeContentData) }
            close()
            guard let data = try await fragment() else { return nil }
            try Task.checkCancellation()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("caption-audio-\(UUID().uuidString).mp4")
            self.file = file
            do {
                try data.write(to: file)
                let asset = AVURLAsset(url: file)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw URLError(.cannotDecodeContentData)
                }
                let scales = FragmentTimes.timescales(initSegment: data)
                guard let scale = scales[UInt32(bitPattern: track.trackID)], scale > 0,
                      let presentation = FragmentTimes.firstPresentation(data)[UInt32(bitPattern: track.trackID)] else {
                    throw URLError(.cannotDecodeContentData)
                }
                timeOffset = Double(presentation) / Double(scale) - (try await track.load(.timeRange)).start.seconds
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: asset)
                // Keep one codec decoder across fragments. Asking each reader
                // for PCM applies AAC priming trims at every segment boundary,
                // dropping speech there (96 ms per segment at 22.05 kHz).
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? URLError(.cannotDecodeContentData) }
                self.reader = reader
                self.output = output
            } catch {
                close()
                throw error
            }
        }
    }

    private func decode(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
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
        let sizes = (0..<packets).map { CMSampleBufferGetSampleSize(sample, at: $0) }
        let input = AVAudioCompressedBuffer(format: format, packetCapacity: AVAudioPacketCount(packets), maximumPacketSize: sizes.max() ?? 1)
        input.packetCount = AVAudioPacketCount(packets)
        input.byteLength = UInt32(CMBlockBufferGetDataLength(block))
        let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: Int(input.byteLength), destination: input.data)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var offset = 0
        for (index, size) in sizes.enumerated() {
            var timing = CMSampleTimingInfo()
            let status = CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing)
            let frames = status == noErr && timing.duration.isNumeric ? timing.duration.seconds * format.sampleRate : 0
            input.packetDescriptions?[index] = AudioStreamPacketDescription(mStartOffset: Int64(offset),
                mVariableFramesInPacket: UInt32(max(0, frames.rounded())), mDataByteSize: UInt32(size))
            offset += size
        }
        let frames = CMSampleBufferGetDuration(sample).seconds * format.sampleRate
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

    private func close() {
        reader?.cancelReading()
        reader = nil; output = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
