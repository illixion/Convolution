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
#if os(visionOS)
import RAVEMedia
#endif

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
                     + "film's display criteria), playerViewController (AVKit, controls hidden), videoPlayerComponent (RealityKit's video component), or close. (The film player itself now draws through the video component on visionOS.)",
                     parameters: [.string("renderer", "playerLayer, playerViewController or close", required: true,
                                          choices: ["playerLayer", "playerViewController", "videoPlayerComponent", "close"])]) { args in
                let name = args.string("renderer") ?? "close"
                #if os(visionOS)
                guard let renderer = PictureCompare.Renderer(rawValue: name) else {
                    PictureCompare.shared.close()
                    return CompareReply(status: "Closed", driftSeconds: nil)
                }
                let status = await PictureCompare.shared.open(renderer)
                return CompareReply(status: status, driftSeconds: PictureCompare.shared.drift)
                #else
                return CompareReply(status: "visionOS only (\(name))", driftSeconds: nil)
                #endif
            },
            .command("stereoStrength", "Scales the AI 3D (depth warp) strength of every 3D picture, live: 1 is the "
                     + "shipped strength (0.8 % of the picture width per eye at the far end). For finding by eye how "
                     + "much separation reads right. Not saved.",
                     parameters: [.number("scale", "multiplier on the shipped strength", required: true, range: 0 ... 2)]) { args in
                #if os(visionOS)
                Pseudo3DStereoEngine.strengthScale = Float(args.double("scale") ?? 1)
                return ["scale": Double(Pseudo3DStereoEngine.strengthScale),
                        "perEyePercentOfWidth": Double(Pseudo3DStereoEngine.strengthScale) * 0.8]
                #else
                return ["scale": 1.0, "perEyePercentOfWidth": 0.8]
                #endif
            },
            .query("stereoDepth", "How AI 3D's realtime depth is spread over the picture (0 far … 1 near, after the "
                   + "depth budget): the last frame, the shot playing and the last 40 shots (split at cuts), each with the "
                   + "strength multiplier the shot-adaptive policy would choose (measured only, not applied). Also the "
                   + "plane width, strength and convergence in force, and the stereoStrength debug multiplier.") { _ in
                #if os(visionOS)
                let configured = Pseudo3DStereoEngine.lastConfigured
                return StereoDepthReply(
                    metrics: StereoDepthMetrics.snapshot,
                    planeWidthMeters: configured?.planeWidthMeters,
                    depthStrength: configured?.depthStrength,
                    convergence: configured?.convergence,
                    debugStrengthScale: Pseudo3DStereoEngine.strengthScale,
                    targetMeanShift: StereoStrengthPolicy.targetMeanShift
                )
                #else
                return ["stereoDepth": "visionOS only"]
                #endif
            },
            .query("filmCompareLayers", "The comparison window's view and layer tree (filmCompare), with each "
                   + "layer's dynamic-range settings and the window's display criteria, to find what AVKit's player "
                   + "sets that a plain layer doesn't.") { _ in
                #if os(visionOS)
                return ["compare": PictureCompare.shared.layerTree()]
                #else
                return ["compare": ["visionOS only"]]
                #endif
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

    #if os(visionOS)
    struct StereoDepthReply: Encodable {
        var metrics: StereoDepthMetrics.Snapshot
        var planeWidthMeters: Float?
        var depthStrength: Float?
        var convergence: Float?
        var debugStrengthScale: Float
        var targetMeanShift: Float
    }
    #endif

    struct CompareReply: Encodable {
        var status: String
        var driftSeconds: Double?
    }

    private static func reply() -> Reply {
        let player = FilmSession.shared.player
        let video = player.video
        let renderer = video.renderer
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
