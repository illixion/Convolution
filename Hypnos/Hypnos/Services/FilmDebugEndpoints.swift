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
