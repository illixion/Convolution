import AVFoundation
import Foundation
import GeneratedCaptions
import RAVEMedia

/// The audio of an HLS item for the equalizer's stream path (`EQStreamPlayback`): no tap reaches
/// HLS, so the stream's audio is read and decoded here, the way AI captions read it, and played
/// through the curve in the player's place. A device remux's own fragments, else the playlist's
/// segments (`HLSCaptionAudio`: fMP4, MPEG-TS and packed audio, timed as the container times them,
/// one decoder across segments).
enum StreamEQAudio {
    @MainActor static func reader(item: AVPlayerItem, start: Double) async throws -> EQStreamReader? {
        do {
            guard let source = try await source(item: item, start: start) else { return nil }
            return {
                do { return try await source.next().map { EQStreamChunk(buffer: $0.buffer, time: $0.time) } }
                catch let failure as HLSCaptionAudio.Failure { throw Unreadable(failure) }
            }
        } catch let failure as HLSCaptionAudio.Failure {
            throw Unreadable(failure)
        }
    }

    /// The reader's refusals, worded for the equalizer rather than AI captions.
    struct Unreadable: LocalizedError {
        let failure: HLSCaptionAudio.Failure
        init(_ failure: HLSCaptionAudio.Failure) { self.failure = failure }
        var errorDescription: String? {
            switch failure {
            case .protected: "this stream is protected."
            case .noSegments: "this stream has no audio to read."
            case .unsupportedContainer: "this stream's audio format can't be read."
            }
        }
    }

    @MainActor private static func source(item: AVPlayerItem, start: Double) async throws -> RAVECaptionAudioSource? {
        let source: RAVECaptionAudioSource?
        if let remux = try await MatroskaCaptionAudio.source(item: item, start: start) {
            source = remux
        } else if let playlist = try await playlistURL(of: item) {
            source = try await StreamCaptionAudio.source(item: item, playlist: playlist, start: start)
        } else {
            source = nil
        }
        return source
    }

    /// The item's playlist. Most HLS URLs say so (`.m3u8`); Jellyfin's `universal` audio URL
    /// redirects to one, which is then the base its segments are relative to.
    @MainActor private static func playlistURL(of item: AVPlayerItem) async throws -> URL? {
        guard let url = (item.asset as? AVURLAsset)?.url else { return nil }
        if url.pathExtension.lowercased() == "m3u8" { return url }
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        var request = MediaAuthorization.shared.request(for: url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.starts(with: Array("#EXTM3U".utf8)) else { return nil }
        return response.url ?? url
    }
}
