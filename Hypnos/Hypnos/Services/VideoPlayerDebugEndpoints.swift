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
import Synchronization

@MainActor
enum VideoPlayerDebugEndpoints {
    private static var registered = false

    static func registerNetworkTests() {
        DebugSurface.shared.register([
            .command("videoNetworkTest", "Temporarily fail or delay remote file reads for the active device-remux player. "
                     + "Keeps the debug connection intact. Existing buffers must drain before a stall; this is transport "
                     + "fault injection, not Wi-Fi packet conditioning. Automatically expires. off stops the fault.",
                     parameters: [.string("profile", "outage, slow or off", required: true, choices: ["outage", "slow", "off"]),
                                  .number("seconds", "Test duration (default 30)", range: 0 ... 600),
                                  .number("delaySeconds", "Per-read delay for slow (default 2)", range: 0 ... 30)]) { args in
                VideoPlayerDebugEndpoints.applyNetworkTest(args)
            },
            .query("videoNetworkSamples", "Once-per-second clocks, buffering and fault counts from the last network test. "
                   + "Recording stops if its player changes. No titles, URLs, dialogue or credentials.", trace: .never) { _ in
                PlaybackNetworkRecording.samples
            },
        ])
    }

    static func applyNetworkTest(_ args: DebugArguments) -> [String: Double] {
        let profile = args.string("profile") ?? "off"
        if profile == "off" {
            PlaybackNetworkFault.stop()
            PlaybackNetworkRecording.generation = UUID()
            return ["stopped": 1.0]
        }
        let seconds: Double = args.double("seconds") ?? 30
        var delay: Double = 0
        if profile == "slow" { delay = args.double("delaySeconds") ?? 2 }
        return VideoPlayerDebugEndpoints.networkTest(seconds: seconds, delay: delay, fails: profile == "outage")
    }

    static func networkTest(seconds: Double, delay: Double = 0, fails: Bool = true) -> [String: Double] {
        guard let model = VideoWindowModel.withNativePlayers.allObjects.first(where: { $0.nativePlayer?.currentItem != nil }),
              let player = model.nativePlayer, let item = player.currentItem,
              let asset = item.asset as? AVURLAsset, asset.url.host == "127.0.0.1",
              MatroskaRemuxService.shared.session(for: MediaAuthorization.shared.authorizedURL(model.video.streamURL)) != nil
        else { return ["available": 0] }
        PlaybackNetworkFault.configure(target: MediaAuthorization.shared.authorizedURL(model.video.streamURL),
                                       seconds: seconds, delay: delay, fails: fails)
        PlaybackNetworkRecording.samples = []
        PlaybackNetworkRecording.generation = UUID()
        let generation = PlaybackNetworkRecording.generation
        Task { @MainActor [weak model, weak player, weak item] in
            for _ in 0 ..< Int(seconds + 35) {
                guard let model, let player, let item, model.nativePlayer === player,
                      player.currentItem === item, PlaybackNetworkRecording.generation == generation else { break }
                let current = player.currentTime().seconds
                let end = item.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? current
                PlaybackNetworkRecording.samples.append([
                    "wall": Date.timeIntervalSinceReferenceDate,
                    "player": current, "model": model.currentTime, "bufferEnd": end,
                    "playing": player.timeControlStatus == .playing ? 1 : 0,
                    "waiting": player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? 1 : 0,
                    "failed": item.status == .failed ? 1 : 0,
                    "delay": model.subtitles.delay,
                    "faults": Double(PlaybackNetworkFault.state.withLock { $0.affected })
                ])
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return ["available": 1, "seconds": seconds, "responseDelay": delay, "player": player.currentTime().seconds,
                "bufferEnd": item.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? 0]
    }

    static func register() {
        guard !registered else { return }
        registered = true
        registerNetworkTests()
        DebugSurface.shared.register([
            .query("videoAudio", "Each video window's native player: item status, the audio track as decoded "
                   + "(codec, channels), the audible option selected, and the spatial-audio experience in force. "
                   + "Includes player and model clocks and subtitle timing, without cue text.") { _ in
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
        var timing: Timing
    }

    struct Timing: Encodable {
        var playerSeconds: Double?
        var modelSeconds: Double?
        var subtitleDelaySeconds: Double
        var subtitleEmbedded: Bool?
        var subtitleFromMatroska: Bool
        var subtitleCueCount: Int
        var originalFileOnDevice: Bool
        var showing: [[Double]]
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
                audioMenuSelected: model.audioTracks.firstIndex { $0.id == model.selectedAudioTrack },
                timing: Timing(
                    playerSeconds: player.currentTime().seconds.isFinite ? player.currentTime().seconds : nil,
                    modelSeconds: model.currentTime.isFinite ? model.currentTime : nil,
                    subtitleDelaySeconds: model.subtitles.delay,
                    subtitleEmbedded: model.subtitles.selected?.isEmbedded,
                    subtitleFromMatroska: model.subtitles.selected.map(MatroskaSubtitles.owns) == true,
                    subtitleCueCount: model.subtitles.cues?.cues.count ?? 0,
                    originalFileOnDevice: model.video.streamURL.isFileURL,
                    showing: model.subtitles.cues?.cues(at: model.subtitles.cueTime(forFilmTime: model.currentTime))
                        .map { [$0.start, $0.end] } ?? []
                )
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

@MainActor
private enum PlaybackNetworkRecording {
    static var samples: [[String: Double]] = []
    static var generation = UUID()
}
