/*
 Hypnos - Spatial audio probe (Settings → Developer)

 Answers whether the Atmos spike can drop its immersive space. visionOS 26
 lets an app anchor a multichannel stream to one of its windows:
 `intendedSpatialExperience = .headTracked(.scene(identifier:), soundStageSize:)`
 on an `AVAudioEngine` output node or an `AVAudioPlayer`, where the identifier
 is `UIScene.session.persistentIdentifier` and a `.large` stage "spreads an
 audio stream's channels around the user according to the coordinates
 described in its channel layout". If that holds for app audio, the spike
 can pan objects onto virtual speakers itself and let the system keep them
 around the player window.

 Three things are unknown, and each test answers one by ear:

 - Engine sweep: does an `AVAudioEngine` stream with more than two channels
   reach the spatializer, or is it downmixed first? The report shows the
   session's channel counts and the formats either side of the output node.
 - Player sweep: the same sweep as a multichannel file through
   `AVAudioPlayer`, which never touches the hardware channel count, so it
   still works if the engine sweep turns out to be downmixed.
 - RealityKit in a window: one `SpatialAudioComponent` source in this
   window's `RealityView`, stepping to points far outside the window's
   bounds. Does its sound follow, or get pulled back to the window?

 The sweeps play a noise burst from one channel at a time, and the row shows
 which channel is playing. In "Custom" mode the layout gives every channel
 its own direction instead of using a standard speaker layout.

 Measured on device (visionOS 27, built-in speakers, 2026-09-23):

 - Engine sweep: only L and R. The session reports 2 output channels at most,
   and the output node takes 12 channels in but sends 2 out, so the stream
   is folded to stereo before the spatializer.
 - Player sweep, 7.1.4: every channel places, following this window, but
   the top channels sound no higher than the ear-level ones.
 - Custom coordinate layout: the player plays nothing and the engine only
   front L/R, so per-channel directions are not honoured. The API positions
   standard channel beds, not arbitrary objects.
 - `.front` anchoring follows the last recenter, not the window.
 - RealityKit in a window: sources outside the window's bounds are placed
   correctly, heights included. "3 m behind the window" matches "in the
   window" only because both lie in the same direction and distance
   attenuation is off.
 */

#if os(visionOS)
import AudioToolbox
import AVFoundation
import DebugTrace
import RealityKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

// MARK: - Sweep signal

/// One channel of a sweep layout, with the name shown while it plays.
struct ProbeSpeaker: Sendable {
    let channel: Int
    let name: String
}

enum ProbeLayout: String, CaseIterable, Identifiable {
    case atmos714 = "7.1.4"
    case custom = "Custom"

    var id: Self { self }

    var channelCount: Int { speakersAndLayout.layout.channelCount.asInt }

    /// Channels in sweep order (the LFE is skipped) and the channel layout.
    var speakersAndLayout: (speakers: [ProbeSpeaker], layout: AVAudioChannelLayout) {
        switch self {
        case .atmos714:
            // kAudioChannelLayoutTag_Atmos_7_1_4: L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr
            let names = ["L", "R", "C", "LFE", "Ls", "Rs", "Rls", "Rrs", "Vhl (top front L)",
                         "Vhr (top front R)", "Ltr (top rear L)", "Rtr (top rear R)"]
            let order = [2, 1, 5, 7, 6, 4, 0, 8, 9, 11, 10]
            return (order.map { ProbeSpeaker(channel: $0, name: names[$0]) },
                    AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4)!)
        case .custom:
            let directions: [(name: String, azimuth: Float, elevation: Float)] = [
                ("front", 0, 0), ("front-right", 45, 0), ("right", 90, 0), ("back-right", 135, 0),
                ("back", 180, 0), ("back-left", -135, 0), ("left", -90, 0), ("front-left", -45, 0),
                ("up-front", 0, 60), ("up-back", 180, 60)
            ]
            let speakers = directions.indices.map { ProbeSpeaker(channel: $0, name: directions[$0].name) }
            return (speakers, Self.coordinateLayout(directions.map { ($0.azimuth, $0.elevation) }))
        }
    }

    /// A layout that places each channel by spherical coordinates (azimuth:
    /// 0 front, positive right; elevation: +90 zenith) instead of by label.
    static func coordinateLayout(_ directions: [(azimuth: Float, elevation: Float)]) -> AVAudioChannelLayout {
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
        let size = offset + directions.count * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(directions.count)
        let descriptions = (raw + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        for (i, direction) in directions.enumerated() {
            descriptions[i].mChannelLabel = kAudioChannelLabel_UseCoordinates
            descriptions[i].mChannelFlags = .sphericalCoordinates
            descriptions[i].mCoordinates = (direction.azimuth, direction.elevation, 1)
        }
        return AVAudioChannelLayout(layout: layout)
    }
}

private extension AVAudioChannelCount {
    var asInt: Int { Int(self) }
}

/// Noise bursts that step through the speakers, one channel at a time.
/// Rendered on the audio thread; nothing here touches the main actor.
final class ProbeSweep: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let stepSeconds = 0.65
    static let burstSeconds = 0.5

    let channels: Int
    let speakers: [ProbeSpeaker]
    private var frame = 0
    private var seed: UInt32 = 0x1234_5678

    init(channels: Int, speakers: [ProbeSpeaker]) {
        self.channels = channels
        self.speakers = speakers
    }

    /// Frames in one pass over every speaker.
    var cycleFrames: Int { speakers.count * Int(Self.stepSeconds * Self.sampleRate) }

    /// Built here rather than in the view so the block is not main-actor
    /// isolated (see `AtmosObjectAudio.renderHandler(channel:)` in RAVESDK's RAVEFilm).
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, output in
            self.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(output))
            return noErr
        }
    }

    /// Fills deinterleaved float buffers, one per channel.
    func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let step = Int(Self.stepSeconds * Self.sampleRate)
        let burst = Int(Self.burstSeconds * Self.sampleRate)
        let fade = Int(0.01 * Self.sampleRate)
        for buffer in buffers {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        for i in 0..<frameCount {
            let position = (frame + i) % cycleFrames
            let speaker = speakers[position / step]
            let t = position % step
            guard t < burst, speaker.channel < buffers.count,
                  let data = buffers[speaker.channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let envelope = Float(min(t, burst - t, fade)) / Float(fade)
            data[i] = nextNoise() * 0.3 * min(envelope, 1)
        }
        frame = (frame + frameCount) % cycleFrames
    }

    private func nextNoise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }
}

/// Mono noise pulses for the RealityKit source.
final class ProbePulse: @unchecked Sendable {
    private var frame = 0
    private var seed: UInt32 = 0x9E37_79B9

    func renderHandler() -> Audio.GeneratorRenderHandler {
        { _, _, frameCount, output in
            self.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(output))
            return noErr
        }
    }

    private func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let period = Int(0.5 * ProbeSweep.sampleRate)
        let burst = Int(0.3 * ProbeSweep.sampleRate)
        let fade = Int(0.01 * ProbeSweep.sampleRate)
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<min(frameCount, count) {
                let t = (frame + i) % period
                if t < burst {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let envelope = min(Float(min(t, burst - t, fade)) / Float(fade), 1)
                    data[i] = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3 * envelope
                } else {
                    data[i] = 0
                }
            }
        }
        frame = (frame + frameCount) % period
    }
}

// MARK: - View

struct SpatialAudioProbeSection: View {
    enum Anchoring: String, CaseIterable, Identifiable {
        case scene = "This window"
        case front = "Front"
        case automatic = "Automatic"
        case fixed = "Fixed (no head tracking)"
        var id: Self { self }
    }

    enum Stage: String, CaseIterable, Identifiable {
        case small = "Small", medium = "Medium", large = "Large", automatic = "Automatic"
        var id: Self { self }

        var value: SpatialAudioExperiences.SoundStageSize {
            switch self {
            case .small: .small
            case .medium: .medium
            case .large: .large
            case .automatic: .automatic
            }
        }
    }

    enum Test: Equatable {
        case engine, player, realityKit
    }

    @State private var sceneID: String?
    @State private var layout: ProbeLayout = .atmos714
    @State private var anchoring: Anchoring = .scene
    @State private var stage: Stage = .large
    @State private var running: Test?
    @State private var startedAt = Date()
    @State private var speakers: [ProbeSpeaker] = []
    @State private var report: [String] = []

    @State private var engine: AVAudioEngine?
    @State private var player: AVAudioPlayer?
    @State private var realityRoot = Entity()
    @State private var generator: AudioGeneratorController?
    @State private var waypointTask: Task<Void, Never>?
    @State private var waypoint = ""

    /// Points relative to the RealityView's origin, in metres; +z points out
    /// of the window toward the viewer.
    private static let waypoints: [(name: String, position: SIMD3<Float>)] = [
        ("in the window", [0, 0, 0]),
        ("2 m left", [-2, 0, 0.5]),
        ("2 m right", [2, 0, 0.5]),
        ("behind you (3 m out of the window)", [0, 0, 3]),
        ("overhead", [0, 1.5, 1.2]),
        ("3 m behind the window", [0, 0, -3])
    ]

    var body: some View {
        Section("Spatial Audio Probe") {
            LabeledContent("Scene", value: sceneID ?? "unknown")
                .font(.caption.monospaced())
                .background(SceneIdentifierReader(identifier: $sceneID))

            Picker("Layout", selection: $layout) {
                ForEach(ProbeLayout.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Anchoring", selection: $anchoring) {
                ForEach(Anchoring.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Sound stage", selection: $stage) {
                ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(anchoring == .automatic)

            HStack {
                testButton("Engine sweep", test: .engine, action: startEngine)
                testButton("Player sweep", test: .player, action: startPlayer)
                testButton("RealityKit", test: .realityKit, action: startRealityKit)
            }
            .buttonStyle(.bordered)

            if running == .engine || running == .player {
                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    Text("Playing: \(currentSpeaker(at: context.date))")
                        .font(.headline.monospaced())
                }
            } else if running == .realityKit {
                Text("Source: \(waypoint)").font(.headline.monospaced())
            }

            RealityView { content in
                content.add(realityRoot)
            }
            .frame(height: 60)

            if !report.isEmpty {
                Text(report.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Text("Engine and Player sweeps play a noise burst from one channel at a time: listen for whether each comes from its own direction, and whether they follow this window when you move it. The RealityKit test steps one source to points far outside the window.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onDisappear(perform: stop)
    }

    private func testButton(_ title: String, test: Test, action: @escaping () -> Void) -> some View {
        Button(running == test ? "Stop" : title) {
            let wasRunning = running == test
            stop()
            if !wasRunning { action() }
        }
    }

    private func currentSpeaker(at date: Date) -> String {
        guard !speakers.isEmpty else { return "" }
        let step = Int(date.timeIntervalSince(startedAt) / ProbeSweep.stepSeconds)
        return speakers[step % speakers.count].name
    }

    // MARK: Spatial experience

    private var experience: any SpatialAudioExperience {
        switch anchoring {
        case .scene:
            if let sceneID {
                return .headTracked(.scene(identifier: sceneID), soundStageSize: stage.value)
            }
            log("No scene identifier; falling back to automatic anchoring")
            return .headTracked(.automatic, soundStageSize: stage.value)
        case .front:
            return .headTracked(.front, soundStageSize: stage.value)
        case .automatic:
            return AutomaticSpatialAudio.automatic
        case .fixed:
            return .fixed(soundStageSize: stage.value)
        }
    }

    // MARK: Tests

    private func startEngine() {
        report = []
        let (speakers, channelLayout) = layout.speakersAndLayout
        let format = AVAudioFormat(standardFormatWithSampleRate: ProbeSweep.sampleRate, channelLayout: channelLayout)
        logSession(wanting: layout.channelCount)

        let engine = AVAudioEngine()
        let sweep = ProbeSweep(channels: layout.channelCount, speakers: speakers)
        let node = sweep.makeSourceNode(format: format)
        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: format)
        engine.outputNode.intendedSpatialExperience = experience
        do {
            try engine.start()
        } catch {
            log("Engine failed to start: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return
        }
        log("Source format: \(describe(format), privacy: .public)")
        log("Output node in: \(describe(engine.outputNode.inputFormat(forBus: 0)), privacy: .public)")
        log("Output node out: \(describe(engine.outputNode.outputFormat(forBus: 0)), privacy: .public)")
        log("Experience: \(String(describing: engine.outputNode.intendedSpatialExperience), privacy: .public)")
        self.engine = engine
        self.speakers = speakers
        startedAt = Date()
        running = .engine
    }

    private func startPlayer() {
        report = []
        let (speakers, channelLayout) = layout.speakersAndLayout
        let format = AVAudioFormat(standardFormatWithSampleRate: ProbeSweep.sampleRate, channelLayout: channelLayout)
        logSession(wanting: layout.channelCount)

        // One full pass of the sweep, written as a multichannel file.
        let sweep = ProbeSweep(channels: layout.channelCount, speakers: speakers)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-probe-\(layout.rawValue).caf")
        do {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sweep.cycleFrames)) else {
                log("Could not allocate the sweep buffer")
                return
            }
            buffer.frameLength = buffer.frameCapacity
            sweep.render(frameCount: sweep.cycleFrames, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            try? FileManager.default.removeItem(at: url)
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.intendedSpatialExperience = experience
            guard player.play() else {
                log("AVAudioPlayer refused to play")
                return
            }
            log("File format: \(describe(player.format), privacy: .public)")
            log("Experience: \(String(describing: player.intendedSpatialExperience), privacy: .public)")
            self.player = player
        } catch {
            log("Player failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return
        }
        self.speakers = speakers
        startedAt = Date()
        running = .player
    }

    private func startRealityKit() {
        report = []
        let entity = Entity()
        entity.components.set(SpatialAudioComponent(
            gain: 0,
            directLevel: 0,
            reverbLevel: -12,
            directivity: .beam(focus: 0),
            distanceAttenuation: .rolloff(factor: 0)
        ))
        entity.addChild(ModelEntity(mesh: .generateSphere(radius: 0.03),
                                    materials: [UnlitMaterial(color: .systemOrange)]))
        realityRoot.addChild(entity)
        do {
            let pulse = ProbePulse()
            let controller = try entity.prepareAudio(
                configuration: AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono, mixGroupName: nil),
                pulse.renderHandler()
            )
            controller.play()
            generator = controller
        } catch {
            log("Generator failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            realityRoot.children.removeAll()
            return
        }
        log("Distance attenuation off, so only direction should change")
        running = .realityKit
        waypointTask = Task { @MainActor in
            var index = 0
            while !Task.isCancelled {
                let point = Self.waypoints[index % Self.waypoints.count]
                entity.position = point.position
                waypoint = point.name
                index += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stop() {
        engine?.stop()
        engine = nil
        player?.stop()
        player = nil
        waypointTask?.cancel()
        waypointTask = nil
        generator?.stop()
        generator = nil
        realityRoot.children.removeAll()
        running = nil
    }

    // MARK: Reporting

    private func logSession(wanting channels: Int) {
        let session = AVAudioSession.sharedInstance()
        let before = session.outputNumberOfChannels
        do {
            try session.setActive(true)
            try session.setPreferredOutputNumberOfChannels(min(channels, session.maximumOutputNumberOfChannels))
        } catch {
            log("Preferred output channels: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
        let route = session.currentRoute.outputs.map {
            "\($0.portType.rawValue) ch=\($0.channels?.count ?? 0) spatial=\($0.isSpatialAudioEnabled)"
        }.joined(separator: ", ")
        log("Session: max out \(session.maximumOutputNumberOfChannels), out \(before) → \(session.outputNumberOfChannels), preferred \(session.preferredOutputNumberOfChannels), multichannel content \(session.supportsMultichannelContent)")
        log("Route: \(route, privacy: .public)")
    }

    private func describe(_ format: AVAudioFormat) -> String {
        let tag = format.channelLayout.map { String(format: "0x%08X", $0.layoutTag) } ?? "none"
        return "\(format.channelCount) ch @ \(Int(format.sampleRate)) Hz, layout \(tag)"
    }

    /// Shows the line in the on-screen report in full, and logs it with each
    /// value's own privacy.
    private func log(_ message: DebugLogMessage) {
        report.append(message.revealed)
        AppLogger.filmPlayer.info(message)
    }
}

/// Reports the persistent identifier of the scene this view is in, which is
/// what `.scene(identifier:)` anchoring expects.
private struct SceneIdentifierReader: UIViewRepresentable {
    @Binding var identifier: String?

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = { id in
            if identifier != id { identifier = id }
        }
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onScene: ((String?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onScene?(window?.windowScene?.session.persistentIdentifier)
        }
    }
}
#endif
