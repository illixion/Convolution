/*
 Hypnos - tvOS spatial audio probe

 Which of the game-style spatial audio engines can place film objects
 around an Apple TV listener (AirPods, HomePods), and what the route
 offers. RealityKit's audio isn't in the tvOS SDK, so the visionOS stage
 can't be reused; the candidates are:

 - AVAudioEnvironmentNode, binaural (HRTFHQ) to stereo, with the listener
   head-tracked by the system (`listenerHeadTrackingEnabled`, tvOS 18).
 - AVAudioEnvironmentNode rendering to the route's multichannel layout,
   with the app flagged multichannel, so the system's own spatial audio
   (AirPods) or the speakers (HomePods, a receiver) take it from there.
 - PHASE, a pull-stream source through a spatial mixer, listener
   head-tracked (`automaticHeadTrackingFlags`, tvOS 18). A pull stream's
   render block has the same shape as RAVEFilm's element reader, which is
   what makes it a candidate for film audio at all.

 The test signal is pink-noise bursts, the easiest thing to localize, on a
 source that orbits the listener at ear height, or holds still in front
 (turn your head: with head tracking it should stay at the TV). The screen
 and the console report the route and what the render callbacks' time
 stamps carry, since the film's picture sync depends on host time.

 Launch with `-SpatialProbe 1` (`xcrun devicectl device process launch
 --console … com.illixion.filmlab -- -SpatialProbe 1`); choose with the
 remote.
 */

import AVFoundation
import PHASE
import SwiftUI
import Synchronization

// MARK: - Test signal

/// Pink-noise bursts, mono, written straight into whatever buffers the
/// engine hands over. Nonisolated on purpose: a closure made inside a
/// main-actor view would inherit its isolation and trap on the audio
/// thread (see RAVEFilm's `AtmosObjectAudio.renderHandler`).
final class ProbeSignal: @unchecked Sendable {
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0
    private var seed: UInt32 = 0x1234_5678
    private var frame = 0
    private let sampleRate: Double
    let gain = Atomic<UInt32>(Float(0.25).bitPattern)

    // Telemetry, written by the render thread.
    let renders = Atomic<Int>(0)
    let lastFlags = Atomic<UInt32>(0)
    let lastFrames = Atomic<Int>(0)
    let lastBuffers = Atomic<Int>(0)
    let lastChannels = Atomic<Int>(0)

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func handler() -> (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, AVAudioFrameCount,
                       UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        { isSilence, timestamp, count, output in
            self.render(isSilence: isSilence, timestamp: timestamp, count: count, output: output)
        }
    }

    func render(isSilence: UnsafeMutablePointer<ObjCBool>, timestamp: UnsafePointer<AudioTimeStamp>,
                count: AVAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        renders.add(1, ordering: .relaxed)
        lastFlags.store(timestamp.pointee.mFlags.rawValue, ordering: .relaxed)
        lastFrames.store(Int(count), ordering: .relaxed)
        lastBuffers.store(buffers.count, ordering: .relaxed)
        lastChannels.store(Int(buffers.first?.mNumberChannels ?? 0), ordering: .relaxed)

        let g = Float(bitPattern: gain.load(ordering: .relaxed))
        let burst = Int(sampleRate * 0.35), cycle = Int(sampleRate * 0.5)
        let fade = Int(sampleRate * 0.005)
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            var f = frame
            for i in 0 ..< Int(count) {
                let phase = f % cycle
                var value: Float = 0
                if phase < burst {
                    // Paul Kellet's economy pink filter over white noise.
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let white = Float(Int32(bitPattern: seed)) / Float(Int32.max)
                    b0 = 0.99765 * b0 + white * 0.0990460
                    b1 = 0.96300 * b1 + white * 0.2965164
                    b2 = 0.57000 * b2 + white * 1.0526913
                    let envelope = Float(min(phase, burst - phase, fade)) / Float(fade)
                    value = (b0 + b1 + b2 + white * 0.1848) * 0.25 * g * min(envelope, 1)
                }
                for c in 0 ..< stride { data[i * stride + c] = value }
                f += 1
            }
        }
        frame += Int(count)
        isSilence.pointee = false
        return noErr
    }
}

// MARK: - Backends

enum ProbeBackend: String, CaseIterable, Identifiable {
    case environmentBinaural = "3D mixer, binaural (HRTF)"
    case environmentSpeakers = "3D mixer, route's speaker layout"
    case phase = "PHASE"

    var id: String { rawValue }
}

@MainActor
protocol ProbeRenderer: AnyObject {
    var summary: String { get }
    func setPosition(_ position: SIMD3<Float>)
    func setHeadTracking(_ on: Bool)
    func stop()
}

/// AVAudioEngine: one mono source node into an AVAudioEnvironmentNode.
@MainActor
final class EnvironmentRenderer: ProbeRenderer {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let source: AVAudioSourceNode
    private(set) var summary = ""

    init(signal: ProbeSignal, speakers: Bool) throws {
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        source = AVAudioSourceNode(format: mono, renderBlock: signal.handler())
        engine.attach(source)
        engine.attach(environment)
        engine.connect(source, to: environment, format: mono)

        let hardware = engine.outputNode.outputFormat(forBus: 0)
        var lines = ["output node: \(hardware.channelCount) ch @ \(Int(hardware.sampleRate)) Hz, layout \(Self.describe(hardware.channelLayout))"]
        if speakers, hardware.channelCount > 2 {
            let layout = hardware.channelLayout ?? Self.fallbackLayout(channels: hardware.channelCount)
            guard let layout else { throw ProbeError("no channel layout for \(hardware.channelCount) channels") }
            let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channelLayout: layout)
            engine.connect(environment, to: engine.mainMixerNode, format: format)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
            environment.outputType = .externalSpeakers
            lines.append("environment → \(format.channelCount) ch, \(Self.describe(layout))")
        } else {
            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            environment.outputType = speakers ? .externalSpeakers : .headphones
            if speakers { lines.append("route has only \(hardware.channelCount) ch; rendering stereo speakers") }
        }
        let algorithms = environment.applicableRenderingAlgorithms.compactMap { AVAudio3DMixingRenderingAlgorithm(rawValue: $0.intValue) }
        let wanted: AVAudio3DMixingRenderingAlgorithm = speakers ? .soundField : .HRTFHQ
        source.renderingAlgorithm = algorithms.contains(wanted) ? wanted : (algorithms.first ?? .equalPowerPanning)
        source.sourceMode = .pointSource
        source.pointSourceInHeadMode = .mono
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 10
        environment.reverbParameters.enable = false
        environment.listenerPosition = .init(x: 0, y: 0, z: 0)
        lines.append("algorithms: \(algorithms.map(Self.name).joined(separator: ", ")); using \(Self.name(source.renderingAlgorithm))")

        engine.prepare()
        try engine.start()
        summary = lines.joined(separator: "\n")
    }

    func setPosition(_ p: SIMD3<Float>) { source.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z) }
    func setHeadTracking(_ on: Bool) { environment.isListenerHeadTrackingEnabled = on }
    func stop() { engine.stop() }

    private static func fallbackLayout(channels: AVAudioChannelCount) -> AVAudioChannelLayout? {
        switch channels {
        case 6: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AudioUnit_5_1)
        case 8: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AudioUnit_7_1)
        default: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        }
    }

    static func describe(_ layout: AVAudioChannelLayout?) -> String {
        guard let layout else { return "none" }
        let tag = layout.layoutTag
        return String(format: "tag %u|%u", tag >> 16, tag & 0xFFFF)
    }

    static func name(_ algorithm: AVAudio3DMixingRenderingAlgorithm) -> String {
        switch algorithm {
        case .equalPowerPanning: "equalPower"
        case .sphericalHead: "sphericalHead"
        case .HRTF: "HRTF"
        case .soundField: "soundField"
        case .stereoPassThrough: "stereoPass"
        case .HRTFHQ: "HRTFHQ"
        case .auto: "auto"
        @unknown default: "\(algorithm.rawValue)"
        }
    }
}

/// PHASE: a pull-stream sound event on one source, through a spatial mixer.
@MainActor
final class PhaseRenderer: ProbeRenderer {
    private let engine = PHASEEngine(updateMode: .automatic)
    private let listener: PHASEListener
    private let source: PHASESource
    private let event: PHASESoundEvent
    private(set) var summary = ""

    init(signal: ProbeSignal) throws {
        listener = PHASEListener(engine: engine)
        listener.transform = matrix_identity_float4x4
        try engine.rootObject.addChild(listener)
        source = PHASESource(engine: engine)
        try engine.rootObject.addChild(source)

        guard let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission]) else { throw ProbeError("no spatial pipeline") }
        let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline)
        let distance = PHASEGeometricSpreadingDistanceModelParameters()
        distance.rolloffFactor = 0
        mixer.distanceModelParameters = distance
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let stream = PHASEPullStreamNodeDefinition(mixerDefinition: mixer, format: format, identifier: "probe-stream")
        stream.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
        _ = try engine.assetRegistry.registerSoundEventAsset(rootNode: stream, identifier: "probe-event")

        let parameters = PHASEMixerParameters()
        parameters.addSpatialMixerParameters(identifier: mixer.identifier, source: source, listener: listener)
        event = try PHASESoundEvent(engine: engine, assetIdentifier: "probe-event", mixerParameters: parameters)
        guard let node = event.pullStreamNodes["probe-stream"] else { throw ProbeError("no pull stream node") }
        node.renderHandler = signal.phaseHandler()
        try engine.start()
        event.start()
        summary = "PHASE output mode \(engine.outputSpatializationMode.rawValue), stream \(Int(format.sampleRate)) Hz mono"
    }

    func setPosition(_ p: SIMD3<Float>) {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(p, 1)
        source.transform = transform
    }

    func setHeadTracking(_ on: Bool) { listener.automaticHeadTrackingFlags = on ? [.orientation] : [] }

    func stop() {
        event.stopAndInvalidate()
        engine.stop()
        engine.assetRegistry.unregisterAsset(identifier: "probe-event", completion: nil)
    }
}

extension ProbeSignal {
    /// PHASE's render block takes `UnsafeMutablePointer<ObjCBool>` too, but
    /// is imported as its own type; built here for the same isolation reason.
    func phaseHandler() -> PHASEPullStreamRenderHandler {
        { isSilence, timestamp, count, output in
            self.render(isSilence: isSilence, timestamp: timestamp, count: count, output: output)
        }
    }
}

struct ProbeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Route

enum ProbeRoute {
    static func configureSession() -> String {
        let session = AVAudioSession.sharedInstance()
        var notes: [String] = []
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
            let maximum = session.maximumOutputNumberOfChannels
            try session.setPreferredOutputNumberOfChannels(maximum)
        } catch {
            notes.append("session: \(error.localizedDescription)")
        }
        return notes.joined(separator: "\n")
    }

    static func report() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { port in
            "\(port.portName) [\(port.portType.rawValue)] \(port.channels?.count ?? 0) ch, spatial=\(port.isSpatialAudioEnabled)"
        }
        return """
        route: \(outputs.joined(separator: "; "))
        channels: out \(session.outputNumberOfChannels), max \(session.maximumOutputNumberOfChannels), preferred \(session.preferredOutputNumberOfChannels), multichannel flag \(session.supportsMultichannelContent)
        rendering mode: \(renderingMode(session.renderingMode))
        latency: output \(ms(session.outputLatency)), io buffer \(ms(session.ioBufferDuration)), \(Int(session.sampleRate)) Hz
        """
    }

    private static func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }

    private static func renderingMode(_ mode: AVAudioSession.RenderingMode) -> String {
        switch mode {
        case .notApplicable: "n/a"
        case .monoStereo: "mono/stereo"
        case .surround: "surround"
        case .spatialAudio: "spatial audio"
        case .dolbyAudio: "Dolby audio"
        case .dolbyAtmos: "Dolby Atmos"
        @unknown default: "\(mode.rawValue)"
        }
    }
}

// MARK: - UI

struct SpatialProbeView: View {
    enum Motion: String, CaseIterable, Identifiable {
        case orbit = "Orbit (8 s)"
        case front = "Hold in front"
        case left = "Hold left"
        case above = "Front, raised"
        var id: String { rawValue }
    }

    @State private var backend: ProbeBackend?
    @State private var motion = Motion.orbit
    @State private var headTracking = true
    @State private var renderer: (any ProbeRenderer)?
    @State private var signal: ProbeSignal?
    @State private var route = ""
    @State private var backendSummary = ""
    @State private var callback = ""
    @State private var sessionNotes = ""

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Spatial audio probe").font(.title2.bold())
                ForEach(ProbeBackend.allCases) { candidate in
                    Button { start(candidate) } label: {
                        Label(candidate.rawValue, systemImage: backend == candidate ? "speaker.wave.3.fill" : "speaker")
                    }
                }
                Button("Stop", role: .destructive) { stop() }
                Divider()
                Picker("Source", selection: $motion) {
                    ForEach(Motion.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Head tracking", isOn: $headTracking)
            }
            .frame(width: 720)

            VStack(alignment: .leading, spacing: 18) {
                Text(route)
                if !sessionNotes.isEmpty { Text(sessionNotes).foregroundStyle(.red) }
                Text(backendSummary)
                Text(callback)
            }
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(80)
        .onChange(of: headTracking) { _, on in
            renderer?.setHeadTracking(on)
            log("head tracking \(on ? "on" : "off")")
        }
        .onChange(of: motion) { _, new in log("source: \(new.rawValue)") }
        .task {
            sessionNotes = ProbeRoute.configureSession()
            log("session configured. \(sessionNotes)")
            var lastLog = ContinuousClock.now
            let started = ContinuousClock.now
            while !Task.isCancelled {
                let t = Double((ContinuousClock.now - started).components.attoseconds) / 1e18
                    + Double((ContinuousClock.now - started).components.seconds)
                renderer?.setPosition(position(at: t))
                if ContinuousClock.now - lastLog > .seconds(1) {
                    lastLog = .now
                    route = ProbeRoute.report()
                    callback = callbackReport()
                    if renderer != nil, Int(t) % 5 == 0 { log(callback) }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            log("route changed\n\(ProbeRoute.report())")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.renderingModeChangeNotification)) { _ in
            log("rendering mode changed\n\(ProbeRoute.report())")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification)) { _ in
            log("spatial capabilities changed\n\(ProbeRoute.report())")
        }
    }

    /// Metres from the listener: −z toward the TV, +x right, +y up.
    private func position(at t: Double) -> SIMD3<Float> {
        let r: Float = 1.5
        switch motion {
        case .orbit:
            let a = Float(t / 8 * 2 * .pi)
            return SIMD3(sin(a) * r, 0, -cos(a) * r)
        case .front: return SIMD3(0, 0, -r)
        case .left: return SIMD3(-r, 0, 0)
        case .above: return SIMD3(0, r * 0.8, -r * 0.6)
        }
    }

    private func start(_ candidate: ProbeBackend) {
        stop()
        let signal = ProbeSignal(sampleRate: 48_000)
        do {
            let made: any ProbeRenderer = switch candidate {
            case .environmentBinaural: try EnvironmentRenderer(signal: signal, speakers: false)
            case .environmentSpeakers: try EnvironmentRenderer(signal: signal, speakers: true)
            case .phase: try PhaseRenderer(signal: signal)
            }
            made.setHeadTracking(headTracking)
            renderer = made
            self.signal = signal
            backend = candidate
            backendSummary = "\(candidate.rawValue)\n\(made.summary)"
            log("started \(backendSummary)\n\(ProbeRoute.report())")
        } catch {
            backendSummary = "\(candidate.rawValue) failed: \(error.localizedDescription)"
            log(backendSummary)
        }
    }

    private func stop() {
        guard let renderer else { return }
        renderer.stop()
        self.renderer = nil
        signal = nil
        log("stopped \(backend?.rawValue ?? "")")
        backend = nil
    }

    private func callbackReport() -> String {
        guard let signal else { return "callback: idle" }
        let flags = AudioTimeStampFlags(rawValue: signal.lastFlags.load(ordering: .relaxed))
        return String(format: "callback: %d renders, %d frames × %d buffers × %d ch, sampleTime %@ hostTime %@",
                      signal.renders.load(ordering: .relaxed), signal.lastFrames.load(ordering: .relaxed),
                      signal.lastBuffers.load(ordering: .relaxed), signal.lastChannels.load(ordering: .relaxed),
                      flags.contains(.sampleTimeValid) ? "valid" : "MISSING",
                      flags.contains(.hostTimeValid) ? "valid" : "MISSING")
    }

    private func log(_ line: String) {
        print("SpatialProbe: \(line.replacingOccurrences(of: "\n", with: "\nSpatialProbe:   "))")
    }
}
