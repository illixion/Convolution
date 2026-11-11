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
    private let decoder = CompressedAudioDecoder()
    /// The reader hands out linear PCM itself (see `readsPCM`).
    private var decodesInReader = false

    init(next: @escaping @Sendable () async throws -> Data?) { fragment = next }

    isolated deinit {
        reader?.cancelReading()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func next() async throws -> RAVECaptionAudioChunk? {
        while true {
            try Task.checkCancellation()
            if let output, let sample = output.copyNextSampleBuffer() {
                if let buffer = try decodesInReader ? CompressedAudioDecoder.pcm(sample) : decoder.decode(sample) {
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
                // Placed against the picture by the edit lists, as the player places it.
                let edits = FragmentEditList.offset(track: UInt32(bitPattern: track.trackID), timescale: scale, initSegment: data)
                timeOffset = Double(presentation) / Double(scale) + edits - (try await track.load(.timeRange)).start.seconds
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: asset)
                // ALAC (what the remux makes of DTS and TrueHD) is read as PCM
                // by the reader: our converter fails every ALAC packet as bad
                // data ('!dat', 560226676), with the cookie wrapped or not, and
                // ALAC has no priming to trim. Keep one codec decoder across
                // fragments for the rest. Asking each reader
                // for PCM applies AAC priming trims at every segment boundary,
                // dropping speech there (96 ms per segment at 22.05 kHz).
                let readsPCM = try await track.load(.formatDescriptions).contains {
                    CMFormatDescriptionGetMediaSubType($0) == kAudioFormatAppleLossless
                }
                decodesInReader = readsPCM
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: readsPCM ? [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
                ] : nil)
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

    private func close() {
        reader?.cancelReading()
        reader = nil; output = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
