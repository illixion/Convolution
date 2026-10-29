import AVFoundation
import Foundation
import GeneratedCaptions

/// AI captions' audio for an HLS stream that isn't a device remux (YouTube's
/// master, Jellyfin's remux or transcode): the playlists are read and the
/// audio segments decoded here, because AVPlayer's own HLS sample output
/// supplies no audio on visionOS 27.2. See `HLSCaptionAudio`.
enum StreamCaptionAudio {
    @MainActor static func source(item: AVPlayerItem, start: Double) async throws -> RAVECaptionAudioSource? {
        guard let url = (item.asset as? AVURLAsset)?.url, url.pathExtension.lowercased() == "m3u8" else { return nil }
        // The audio the player is playing: its option's title is the
        // rendition's NAME (unique within a group) and its locale the LANGUAGE.
        var selection = HLSCaptionAudio.Selection()
        if let group = try await item.asset.loadMediaSelectionGroup(for: .audible),
           let option = item.currentMediaSelection.selectedMediaOption(in: group) {
            selection.language = option.locale?.identifier
            let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first
            selection.name = try await title?.load(.stringValue)
        }
        return try await HLSCaptionAudio.source(playlist: url, selection: selection, start: start) { url, range in
            var request = MediaAuthorization.shared.request(for: url)
            if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 || status == 206 else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Stream audio: HTTP \(status)"])
            }
            return data
        }
    }
}
