/*
 Hypnos - the film player's state on the debug server

 `GET /film` reports what the film player is doing: transport, the audio
 clock, the picture renderer, and for a Blu-ray disc what the on-device
 decoder (`MVCPictureSource`) is busy with. Registered on DebugSurface at
 launch, so a debug trace captures it too. Nothing personal: no titles,
 paths or server addresses.
 */

import AVFoundation
import DebugTrace
import Foundation
import RAVEFilm

@MainActor
enum FilmDebugEndpoints {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        DebugSurface.shared.register([
            .query("film", "The film player: transport, the audio clock and its segments, the picture renderer, and "
                   + "for a Blu-ray disc the on-device decoder's current run (phase, frames out, last frame time). "
                   + "A picture that never appears shows here as a decoder phase that doesn't move or a renderer that "
                   + "isn't ready.") { _ in
                reply()
            },
            .command("filmDiscAudio", "For a Blu-ray disc: switch from the plugin's object audio to the disc's own AC-3 "
                     + "5.1, decoded on the device, keeping the position. Returns the film state after the switch.") { _ in
                _ = await FilmSession.shared.switchToDiscAudio()
                return reply()
            },
            .command("filmCompare", "Opens a window beside the film player showing the same film through one of "
                     + "Apple's renderers (Jellyfin's HLS remux with Dolby Vision kept, muted, following the film's "
                     + "clock), for comparing how visionOS presents HDR. renderer: playerLayer (AVPlayerLayer with the "
                     + "film's display criteria), playerViewController (AVKit, controls hidden), videoPlayerComponent (RealityKit's video component), filmRenderer (the film player's own renderer handed to RealityKit's video component), filmComponent (the film's samples into a second renderer on RealityKit's video component, clocked by a synchronizer mirroring the film clock; uses the stereo tap, so keep 3D off), or close.",
                     parameters: [.string("renderer", "playerLayer, playerViewController or close", required: true,
                                          choices: ["playerLayer", "playerViewController", "videoPlayerComponent", "filmRenderer", "filmComponent", "close"])]) { args in
                let name = args.string("renderer") ?? "close"
                #if os(visionOS)
                guard let renderer = PictureCompare.Renderer(rawValue: name) else {
                    PictureCompare.shared.close()
                    return CompareReply(status: "Closed", driftSeconds: nil, filmLayerRange: layerRange())
                }
                var status = await PictureCompare.shared.open(renderer)
                if renderer == .filmComponent { status += ": " + PictureCompare.shared.componentStatus }
                return CompareReply(status: status, driftSeconds: PictureCompare.shared.drift, filmLayerRange: layerRange())
                #else
                return CompareReply(status: "visionOS only (\(name))", driftSeconds: nil, filmLayerRange: layerRange())
                #endif
            },
            .query("filmCompareLayers", "The comparison window's view and layer tree (filmCompare), with each "
                   + "layer's dynamic-range settings and the window's display criteria, to find what AVKit's player "
                   + "sets that a plain layer doesn't. Also the film player's own layer for reference.") { _ in
                #if os(visionOS)
                return ["compare": PictureCompare.shared.layerTree(),
                        "film": [PictureCompare.describeFilmLayer()]]
                #else
                return ["compare": ["visionOS only"]]
                #endif
            },
            .command("filmLayerRange", "Sets the film player's own picture layer's preferredDynamicRange (default "
                     + "high), to compare against a stock layer.",
                     parameters: [.string("range", "high, constrainedHigh or standard", required: true,
                                          choices: ["high", "constrainedHigh", "standard"])]) { args in
                let layer = FilmSession.shared.player.video.displayLayer
                switch args.string("range") ?? "high" {
                case "standard": layer.preferredDynamicRange = .standard
                case "constrainedHigh": layer.preferredDynamicRange = .constrainedHigh
                default: layer.preferredDynamicRange = .high
                }
                return CompareReply(status: "Set", driftSeconds: nil, filmLayerRange: layerRange())
            },
        ])
    }

    struct Reply: Encodable {
        struct Picture: Encodable {
            var source: String
            var status: String
            var loaded: Bool
            var primed: Bool
            var playing: Bool
            var currentSeconds: Double
            var bufferedUntilSeconds: Double
            var durationSeconds: Double
            var lastSeekLatencyMs: Double
            var rendererStatus: String
            var rendererReadyForMore: Bool
            var stereoTap: Bool
        }
        var playing: Bool
        var status: String
        var audioStatus: String
        var clockReport: String
        var scheduledSkewMs: Double?
        var muted: Bool
        var volume: Float
        /// The audio's render playhead and where the picture's clock puts it:
        /// far apart, the sound plays the wrong part of the film (or silence).
        var audioFrame: Int?
        var expectedAudioFrame: Int?
        /// Loudest element level the stage measured lately, 0…1: zero while
        /// playing means silence is being rendered, not lost downstream.
        var peakLevel: Float
        var audioStream: Int?
        var audioTracks: Int
        var picture: Picture
        var disc: MVCPictureSource.Diagnostics?
    }

    struct CompareReply: Encodable {
        var status: String
        var driftSeconds: Double?
        var filmLayerRange: String
    }

    private static func layerRange() -> String {
        switch FilmSession.shared.player.video.displayLayer.preferredDynamicRange {
        case .high: "high"
        case .constrainedHigh: "constrainedHigh"
        case .standard: "standard"
        default: "other"
        }
    }

    private static func reply() -> Reply {
        let player = FilmSession.shared.player
        let video = player.video
        let renderer = video.displayLayer.sampleBufferRenderer
        let rendererStatus = switch renderer.status {
        case .rendering: "rendering"
        case .failed: "failed: \(renderer.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "?")"
        default: "unknown"
        }
        let disc = video.pictureSource as? MVCPictureSource
        return Reply(
            playing: player.isPlaying,
            status: player.status,
            audioStatus: player.audioStatus,
            clockReport: player.clockReport,
            scheduledSkewMs: player.scheduledSkewMs,
            muted: player.isMuted,
            volume: player.volume,
            audioFrame: player.audio == nil ? nil : player.currentFrame,
            expectedAudioFrame: player.scene.map { Int(((video.currentTime - $0.startSeconds) * Double($0.sampleRate)).rounded()) },
            peakLevel: player.levels.max() ?? 0,
            audioStream: player.audioStream,
            audioTracks: player.audioTracks.count,
            picture: .init(
                source: disc != nil ? "disc" : (video.index != nil ? "segments" : "none"),
                status: video.status,
                loaded: video.isLoaded,
                primed: video.isPrimed,
                playing: video.isPlaying,
                currentSeconds: video.currentTime,
                bufferedUntilSeconds: video.bufferedUntil,
                durationSeconds: video.duration,
                lastSeekLatencyMs: video.lastSeekLatency * 1000,
                rendererStatus: rendererStatus,
                rendererReadyForMore: renderer.isReadyForMoreMediaData,
                stereoTap: video.onSampleBuffer != nil
            ),
            disc: disc?.diagnostics
        )
    }
}
