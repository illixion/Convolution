/*
 Hypnos - the video windows' native players on the debug server

 `GET /videoAudio` reports, per video window playing through the native
 renderer, what its AVPlayer is actually doing with sound: the item's
 status, the audio track's codec and channel count as decoded, the audible
 option the stream selected, and the spatial-audio experience in force. The
 spatial-audio policy (`applySpatialAudioPolicy(for:)` in RAVEMedia) decides
 from probes that can miss a stream; this is what to compare it against.
 Nothing personal: no titles, URLs or hosts, only whether the source is
 loopback. The Audio menu is described by where each entry came from and
 what labels it (language, the stream's own name, or only its number), not
 by its text; `videoAudioTrack` picks one, as the menu would.
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
            .command("videoAudioTrack", "Picks an entry of the first video window's Audio menu, as a tap would: "
                     + "position counts from 0 in menu order. Returns the windows' state after it.",
                     parameters: [.integer("position", "the entry's position in the Audio menu", required: true,
                                           range: 0 ... 64)]) { args in
                guard let model = VideoWindowModel.withNativePlayers.allObjects.first(where: { !$0.audioTracks.isEmpty }),
                      let position = args.int("position"),
                      model.audioTracks.indices.contains(position) else { return await reply() }
                model.selectAudioTrack(model.audioTracks[position])
                try? await Task.sleep(for: .seconds(1))
                return await reply()
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
        /// The Audio menu: each entry's source and what labels it.
        var audioMenu: [MenuEntry]
        var audioMenuSelected: Int?
    }

    struct MenuEntry: Encodable {
        /// "player" (a media-selection option) or "server" (a Library
        /// file's audio stream).
        var source: String
        /// "number" ("Track 2"), "two parts" ("English, Commentary") or
        /// "one part" (a language or a name).
        var labeledBy: String
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
                playing: player.timeControlStatus == .playing,
                audioMenu: model.audioTracks.map(menuEntry),
                audioMenuSelected: model.audioTracks.firstIndex { $0.id == model.selectedAudioTrack }
            ))
        }
        return Reply(windows: windows)
    }

    private static func menuEntry(_ track: VideoAudioTrack) -> MenuEntry {
        let source = switch track.id {
        case .player: "player"
        case .server: "server"
        }
        let label = track.title.components(separatedBy: " · ")[0]
        let labeledBy = label.hasPrefix("Track ") ? "number" : label.contains(", ") ? "two parts" : "one part"
        return MenuEntry(source: source, labeledBy: labeledBy)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
