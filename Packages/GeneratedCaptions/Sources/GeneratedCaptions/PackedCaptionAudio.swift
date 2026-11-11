import AVFoundation
import Foundation

extension RAVECaptionAudioSource {
    /// Decode HLS segments without an initialization segment one at a time:
    /// packed audio (ADTS AAC or AC-3, usually behind an ID3 tag; YouTube's
    /// audio renditions) and MPEG-TS (Stash's transcodes, Jellyfin's music).
    /// `next` gives a segment's bytes and where it starts on the player's
    /// timeline; nil means the end of the media.
    public static func packedAudio(next: @escaping @Sendable () async throws -> (data: Data, start: Double)?) -> Self {
        let decoder = PackedCaptionAudio(next: next)
        return Self { try await decoder.next() }
    }
}

/// Packed audio has no initialization segment and no timestamps worth
/// trusting (its ID3 tag carries a 90 kHz clock the playlist already
/// states), so each segment is a bounded local file read from its own start
/// and placed by the playlist. A TS segment's audio is taken out of the
/// transport stream first and placed by its PTS against the segment's first
/// video frame. One decoder runs across segments (`CompressedAudioDecoder`).
private actor PackedCaptionAudio {
    let segment: @Sendable () async throws -> (data: Data, start: Double)?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var file: URL?
    private var timeOffset = 0.0
    private let decoder = CompressedAudioDecoder()

    init(next: @escaping @Sendable () async throws -> (data: Data, start: Double)?) { segment = next }

    isolated deinit {
        reader?.cancelReading()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func next() async throws -> RAVECaptionAudioChunk? {
        while true {
            try Task.checkCancellation()
            if let output, let sample = output.copyNextSampleBuffer() {
                if let buffer = try decoder.decode(sample) {
                    return RAVECaptionAudioChunk(buffer: buffer, time: timeOffset + CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
                continue
            }
            if let reader, reader.status == .failed { throw reader.error ?? URLError(.cannotDecodeContentData) }
            close()
            guard let (data, start) = try await segment() else { return nil }
            try Task.checkCancellation()
            var bytes = data
            var fileExtension = "aac"
            var leadIn = 0.0
            if Self.isTransportStream(data) {
                guard let audio = MPEGTSAudio.extract(data) else { throw HLSCaptionAudio.Failure.unsupportedContainer }
                bytes = audio.elementaryStream
                fileExtension = audio.fileExtension
                leadIn = audio.leadIn
            } else if Self.isAC3(data) {
                // A raw AC-3 file can't start with an ID3 tag.
                bytes = data.subdata(in: (data.startIndex + Self.id3Length(data)) ..< data.endIndex)
                fileExtension = "ac3"
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("caption-audio-\(UUID().uuidString).\(fileExtension)")
            self.file = file
            do {
                try bytes.write(to: file)
                let asset = AVURLAsset(url: file)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw URLError(.cannotDecodeContentData)
                }
                timeOffset = start + leadIn - (try await track.load(.timeRange)).start.seconds
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: asset)
                // The packets as they are: the decoder carries over from the
                // last segment, which a PCM reader per segment can't.
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

    /// The length of a leading ID3v2 tag, 0 without one.
    static func id3Length(_ data: Data) -> Int {
        let start = data.startIndex
        guard data.count > 10, data[start] == 0x49, data[start + 1] == 0x44, data[start + 2] == 0x33 else { return 0 } // "ID3"
        return min(data.count, 10 + data[(start + 6) ..< (start + 10)].reduce(0) { $0 << 7 | Int($1 & 0x7F) })
    }

    /// TS packets start with 0x47 every 188 bytes (after an optional ID3 tag).
    static func isTransportStream(_ data: Data) -> Bool {
        let start = data.startIndex + id3Length(data)
        guard start + 189 <= data.endIndex else { return start < data.endIndex && data[start] == 0x47 }
        return data[start] == 0x47 && data[start + 188] == 0x47
    }

    /// Packed AC-3/E-AC-3 (sync word 0x0B77 after the ID3 tag).
    static func isAC3(_ data: Data) -> Bool {
        let start = data.startIndex + id3Length(data)
        return start + 2 <= data.endIndex && data[start] == 0x0B && data[start + 1] == 0x77
    }

    private func close() {
        reader?.cancelReading()
        reader = nil; output = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
