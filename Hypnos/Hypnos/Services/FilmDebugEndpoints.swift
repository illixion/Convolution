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
import simd
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
            .query("filmCinema", "The players' cinema space (visionOS): its owner (film or a video window), mode "
                   + "(window, roomSound, bigScreen), head-locked sound, whether the space is open and holds the "
                   + "picture (and for a video window whether it lent its player), and in the space's metres the head, the film "
                   + "window, the room's centre and the screen, with the distances between them. A head that never "
                   + "appears means head tracking isn't running; a window that never appears means the window's "
                   + "pose in the space can't be read.") { _ in
                cinemaReply()
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
            .command("stereoEdges", "AI 3D's outline handling, live, for comparing by eye. snap: snap the realtime "
                     + "depth's soft outlines to the picture. fill: fill the strip a near subject uncovers with the "
                     + "background beside it instead of stretching the outline across it. gaps: squeeze the empty depth between a near "
                     + "subject and a far background out of each shot. separated: experimental disconnected "
                     + "mesh with explicit background hole fill (off by default). holes: show its holes in magenta. "
                     + "omitted ones keep their state. Not saved.",
                     parameters: [.boolean("snap", "snap soft depth outlines to the picture"),
                                  .boolean("fill", "fill uncovered strips with background"),
                                  .boolean("gaps", "squeeze empty depth between subject and background"),
                                  .boolean("separated", "use experimental disconnected surfaces and hole fill"),
                                  .boolean("holes", "highlight uncovered pixels in the prototype"),
                                  .number("gapFloor", "share of an empty range's depth kept (0…1)", range: 0 ... 1),
                                  .number("gapEmpty", "density (of an even spread) at or below which a range is empty", range: 0 ... 2),
                                  .number("gapFull", "density at or above which a range is occupied", range: 0 ... 4)]) { args in
                #if os(visionOS)
                if let snap = args.bool("snap") { DepthRefinement.snapsEdges = snap }
                if let fill = args.bool("fill") { DepthRefinement.fillsUncoveredEdges = fill }
                if let gaps = args.bool("gaps") { DepthRefinement.compressesGaps = gaps }
                if let v = args.bool("separated") { DepthRefinement.separatesBoundaries = v }
                if let v = args.bool("holes") { DepthRefinement.showsBoundaryHoles = v }
                if let v = args.double("gapFloor") { DepthGapCompressor.tuning.floorSlope = Float(v) }
                if let v = args.double("gapEmpty") { DepthGapCompressor.tuning.emptyDensity = Float(v) }
                if let v = args.double("gapFull") { DepthGapCompressor.tuning.fullDensity = Float(v) }
                let t = DepthGapCompressor.tuning
                return ["snap": DepthRefinement.snapsEdges ? 1 : 0, "fill": DepthRefinement.fillsUncoveredEdges ? 1 : 0,
                        "gaps": DepthRefinement.compressesGaps ? 1 : 0,
                        "separated": DepthRefinement.separatesBoundaries ? 1 : 0,
                        "holes": DepthRefinement.showsBoundaryHoles ? 1 : 0, "gapFloor": Double(t.floorSlope),
                        "gapEmpty": Double(t.emptyDensity), "gapFull": Double(t.fullDensity)] as [String: Double]
                #else
                return ["snap": 0.0, "fill": 0.0, "gaps": 0.0]
                #endif
            },
            .query("stereoCaptureInfo", "Timestamp, source/depth dimensions and disparity settings of the last "
                   + "stereoEyes capture. Use to reject an A/B set taken while playback advanced.") { _ in
                #if os(visionOS)
                guard let frame = StereoEyeCapture.latest else { return ["captured": 0.0] }
                return ["captured": 1.0, "itemSeconds": frame.itemSeconds,
                        "width": Double(CVPixelBufferGetWidth(frame.source)),
                        "height": Double(CVPixelBufferGetHeight(frame.source)),
                        "depthWidth": Double(frame.depth?.width ?? 0),
                        "depthHeight": Double(frame.depth?.height ?? 0),
                        "depthStrength": Double(frame.depthStrength), "convergence": Double(frame.convergence)]
                #else
                return ["captured": 0.0]
                #endif
            },
            .raw("stereoEyes", kind: .query,
                 "One AI 3D frame as a PNG, captured from the next frame the stereo pump draws: view left or right "
                 + "(each eye exactly as warped), source (the decoded frame), depth (the depth map it warped with, near "
                 + "white), anaglyph (left red, right cyan) or difference (the eyes' difference, contrast ×4). crop: "
                 + "\"x,y,w,h\" as fractions of the frame from the top left, to zoom in. fresh=false reuses the last "
                 + "capture, so several views show the same frame. Works paused too (the last frame is drawn again "
                 + "with the depth on screen); recompute=true computes a paused frame's depth afresh instead, as the "
                 + "first frame of a shot, so a changed stereoEdges setting shows on it.",
                 parameters: [.string("view", "which image", required: true,
                                      choices: ["left", "right", "source", "depth", "anaglyph", "difference"]),
                              .string("crop", "x,y,w,h as fractions, e.g. 0.3,0.2,0.4,0.4"),
                              .boolean("fresh", "capture a new frame (default true)", default: true),
                              .boolean("recompute", "paused: compute the depth afresh (default false)")],
                 sensitivity: .screenCapture) { args in
                #if os(visionOS)
                let view = StereoEyeImages.View(rawValue: args.string("view") ?? "") ?? .left
                let frame: StereoEyeCapture.Frame
                if args.bool("fresh") == false, let last = StereoEyeCapture.latest {
                    frame = last
                } else {
                    frame = try await StereoEyeImages.capture(recomputingDepth: args.bool("recompute") == true)
                }
                let crop = args.string("crop").flatMap { text -> CGRect? in
                    let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    guard parts.count == 4 else { return nil }
                    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
                let png = try StereoEyeImages.png(view, of: frame, crop: crop)
                return .binary(png, contentType: "image/png", filename: "stereo-\(view.rawValue).png")
                #else
                throw CocoaError(.featureUnsupported)
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
        var playerOpen: Bool
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
        /// visionOS: the player window's dynamic scale and the listener
        /// distance the stage uses with it (real metres).
        var windowScale: Float
        var listenerDistanceAuto: Bool
        var listenerDistanceMetres: Float?
    }

    struct CinemaReply: Encodable {
        var owner: String?
        var headLocked: Bool
        var screenPlayer: Bool
        var mode: String
        var open: Bool
        var screenAttached: Bool
        var status: String
        var head: [Float]?
        var window: [Float]?
        var room: [Float]?
        var screen: [Float]?
        var headToWindowMetres: Float?
        var headToScreenMetres: Float?
        var screenWidthMetres: Float?
    }

    private static func cinemaReply() -> CinemaReply {
        #if os(visionOS)
        let cinema = Cinema.shared
        func position(_ m: simd_float4x4?) -> SIMD3<Float>? { m.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) } }
        func array(_ v: SIMD3<Float>?) -> [Float]? { v.map { [$0.x, $0.y, $0.z] } }
        let head = position(cinema.headPose)
        let window = position(cinema.windowPose)
        let screen = position(cinema.screenPose)
        let owner: String? = switch cinema.owner {
        case .film: "film"
        case .video: "videoWindow"
        case nil: nil
        }
        return CinemaReply(
            owner: owner, headLocked: cinema.headLocked, screenPlayer: cinema.screenPlayer != nil,
            mode: cinema.mode.rawValue, open: cinema.isOpen, screenAttached: cinema.screenAttached,
            status: cinema.status, head: array(head), window: array(window),
            room: array(position(cinema.roomPose)), screen: array(screen),
            headToWindowMetres: head.flatMap { h in window.map { simd_distance(h, $0) } },
            headToScreenMetres: head.flatMap { h in screen.map { simd_distance(h, $0) } },
            screenWidthMetres: cinema.screenPose == nil ? nil : cinema.screenWidth
        )
        #else
        return CinemaReply(headLocked: false, screenPlayer: false, mode: "window", open: false, screenAttached: false,
                           status: "visionOS only")
        #endif
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
        #if os(visionOS)
        let listenerDistanceMetres: Float? = FilmSession.shared.listenerPlacement.metres(windowScale: FilmSession.shared.windowScale)
        #else
        let listenerDistanceMetres: Float? = nil
        #endif
        return Reply(
            playing: player.isPlaying,
            playerOpen: FilmSession.shared.isPlayerOpen,
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
            disc: disc?.diagnostics,
            windowScale: FilmSession.shared.windowScale,
            listenerDistanceAuto: FilmSession.shared.listenerDistanceAuto,
            listenerDistanceMetres: listenerDistanceMetres
        )
    }
}
