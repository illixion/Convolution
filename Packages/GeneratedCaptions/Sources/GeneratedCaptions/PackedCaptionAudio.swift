import AVFoundation
import Foundation

extension RAVECaptionAudioSource {
    /// Decode HLS packed audio (ADTS AAC, usually behind an ID3 tag) one
    /// segment at a time. `next` gives a segment's bytes and where it starts
    /// on the player's timeline; nil means the end of the media.
    public static func packedAudio(next: @escaping @Sendable () async throws -> (data: Data, start: Double)?) -> Self {
        let decoder = PackedCaptionAudio(next: next)
        return Self { try await decoder.next() }
    }
}

/// Packed audio has no initialization segment and no timestamps worth
/// trusting (its ID3 tag carries a 90 kHz clock the playlist already
/// states), so each segment is a bounded local file read from its own start
/// and placed by the playlist.
private actor PackedCaptionAudio {
    let segment: @Sendable () async throws -> (data: Data, start: Double)?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var file: URL?
    private var timeOffset = 0.0

    init(next: @escaping @Sendable () async throws -> (data: Data, start: Double)?) { segment = next }

    isolated deinit {
        reader?.cancelReading()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func next() async throws -> RAVECaptionAudioChunk? {
        while true {
            try Task.checkCancellation()
            if let output, let sample = output.copyNextSampleBuffer() {
                if let buffer = try pcm(sample) {
                    return RAVECaptionAudioChunk(buffer: buffer, time: timeOffset + CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
                continue
            }
            if let reader, reader.status == .failed { throw reader.error ?? URLError(.cannotDecodeContentData) }
            close()
            guard let (data, start) = try await segment() else { return nil }
            try Task.checkCancellation()
            // An MPEG-TS segment starts with 0x47; AVAssetReader can't read it.
            if data.first == 0x47 { throw HLSCaptionAudio.Failure.unsupportedContainer }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("caption-audio-\(UUID().uuidString).aac")
            self.file = file
            do {
                try data.write(to: file)
                let asset = AVURLAsset(url: file)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw URLError(.cannotDecodeContentData)
                }
                timeOffset = start - (try await track.load(.timeRange)).start.seconds
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: asset)
                // Linear PCM straight from the reader: with no edit list or
                // priming information, each segment decodes whole.
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
                ])
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

    private func pcm(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: stream),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return buffer
    }

    private func close() {
        reader?.cancelReading()
        reader = nil; output = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
