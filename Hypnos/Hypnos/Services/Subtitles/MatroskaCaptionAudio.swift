import AVFoundation
import Foundation
import GeneratedCaptions
import MatroskaRemux

enum MatroskaCaptionAudio {
    /// Use the remux's audio fragments instead of AVPlayer's HLS sample output,
    /// which supplies no audio on visionOS 27.2. Never fetch the whole movie.
    @MainActor static func source(item: AVPlayerItem, start: Double) async throws -> RAVECaptionAudioSource? {
        guard let url = (item.asset as? AVURLAsset)?.url,
              let session = MatroskaRemuxService.shared.session(playing: url) else { return nil }
        let renditions = session.audioRenditions
        var rendition = renditions.first(where: \.isDefault) ?? renditions.first
        if url.lastPathComponent != "muxed.m3u8",
           let group = try await item.asset.loadMediaSelectionGroup(for: .audible),
           let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
            let metadata = AVMetadataItem.metadataItems(from: selected.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first
            let name = try await metadata?.load(.stringValue)
            // NAME is unique within this generated group; language alone isn't.
            guard let chosen = renditions.first(where: {
                $0.name.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ") == name
            }) else {
                throw URLError(.cannotDecodeContentData)
            }
            rendition = chosen
        }
        guard let rendition else { throw URLError(.cannotDecodeContentData) }
        let fragments = MatroskaCaptionFragments(session: session, track: rendition.trackNumber, start: start)
        return .fragmentedMP4 { try await fragments.next() }
    }
}

private actor MatroskaCaptionFragments {
    let session: RemuxSession
    let track: UInt64
    let start: Double
    var nextIndex: Int?
    var initialization: Data?

    init(session: RemuxSession, track: UInt64, start: Double) {
        self.session = session; self.track = track; self.start = start
    }

    func next() async throws -> Data? {
        if initialization == nil {
            initialization = try await session.data(at: "audio-\(track)/init.mp4")?.data
        }
        guard let initialization else { throw URLError(.cannotDecodeContentData) }
        // A cue-less file's EVENT index grows as it is read. Its current end
        // is not EOF. Wait boundedly for the requested segment to be indexed.
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            try Task.checkCancellation()
            guard let data = try await session.data(at: "audio-\(track).m3u8")?.data,
                  let playlist = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            var time = 0.0
            var index = 0
            var duration = 0.0
            for line in playlist.split(separator: "\n") {
                if line.hasPrefix("#EXTINF:") {
                    duration = Double(line.dropFirst(8).split(separator: ",")[0]) ?? 0
                } else if !line.hasPrefix("#") {
                    if nextIndex.map({ index == $0 }) ?? (time + duration > start) {
                        guard let fragment = try await session.audioSegment(track: track, index) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        nextIndex = index + 1
                        return initialization + fragment
                    }
                    time += duration
                    index += 1
                }
            }
            if playlist.contains("#EXT-X-ENDLIST") { return nil }
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
