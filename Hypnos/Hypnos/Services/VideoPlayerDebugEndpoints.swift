/*
 Hypnos - the video windows' native players on the debug server

 `GET /videoAudio` reports, per video window playing through the native
 renderer, what its AVPlayer is actually doing with sound: the item's
 status, the audio track's codec and channel count as decoded, the audible
 option the stream selected, and the spatial-audio experience in force. The
 spatial-audio policy (`applySpatialAudioPolicy(for:)` in RAVEMedia) decides
 from probes that can miss a stream; this is what to compare it against.
 Nothing personal: no titles, URLs or hosts, only whether the source is
 loopback.
 */

import AVFoundation
import CoreMedia
import DebugTrace
import Foundation

@MainActor
enum VideoPlayerDebugEndpoints {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        DebugSurface.shared.register([
            .query("videoAudio", "Each video window's native player: item status, the audio track as decoded "
                   + "(codec, channels), the audible option selected, and the spatial-audio experience in force. "
                   + "For checking that a surround stream is surround and spatialized.") { _ in
                await reply()
            },
        ])
    }

    struct Reply: Encodable {
        var windows: [Window]
    }

    struct Window: Encodable {
        var source: String
        var status: String
        var error: String?
        var audioTracks: [Track]
        var audibleOption: String?
        var spatialAudio: String
        var allowedSpatialization: String
        var playing: Bool
    }

    struct Track: Encodable {
        var codec: String
        var channels: Int
        var sampleRate: Double
    }

    private static func reply() async -> Reply {
        var windows: [Window] = []
        for model in VideoWindowModel.withNativePlayers.allObjects {
            guard let player = model.nativePlayer, let item = player.currentItem else { continue }
            var tracks: [Track] = []
            for itemTrack in item.tracks {
                guard let track = itemTrack.assetTrack, track.mediaType == .audio,
                      let descriptions = try? await track.load(.formatDescriptions) else { continue }
                for description in descriptions {
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                    tracks.append(Track(codec: fourCC(CMFormatDescriptionGetMediaSubType(description)),
                                        channels: Int(asbd?.mChannelsPerFrame ?? 0),
                                        sampleRate: asbd?.mSampleRate ?? 0))
                }
            }
            var audible: String?
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                audible = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName
            }
            let url = (item.asset as? AVURLAsset)?.url
            let source = url?.host == "127.0.0.1" ? "loopback" : "remote"
            #if os(visionOS)
            let experience = String(describing: player.intendedSpatialAudioExperience)
            #else
            let experience = "n/a"
            #endif
            #if os(tvOS)
            let allowed = "n/a"
            #else
            let allowed = String(describing: item.allowedAudioSpatializationFormats.rawValue)
            #endif
            windows.append(Window(
                source: source,
                status: ["unknown", "readyToPlay", "failed"][item.status.rawValue],
                error: item.error.map(\.logCode),
                audioTracks: tracks,
                audibleOption: audible,
                spatialAudio: experience,
                allowedSpatialization: allowed,
                playing: player.timeControlStatus == .playing
            ))
        }
        return Reply(windows: windows)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
