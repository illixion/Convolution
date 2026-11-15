/*
 On-screen text: speaking the cues as narration.

 Each upcoming cue is synthesized ahead of time (`AVSpeechSynthesizer.write`,
 so nothing plays until it is due) into PCM buffers, and played through an
 `AVAudioEngine` when the playhead reaches the cue's start. A line longer than
 the time it has (until the next cue, or a second past its own end) is sped up
 by a time-pitch unit, by at most 1.4x; at that speed it overruns rather than
 gabbles. In the prototype (Daniel Enhanced, 185 wpm) 3 lines in 65 needed it.

 The narration follows the video: it pauses with it, stops on a seek, and is
 spoken at the video's speed. While it speaks the host lowers the video's
 sound (`onDuck`), ramped, and restores it after.

 Voices are the system's (`AVSpeechSynthesisVoice.speechVoices()`): premium
 and enhanced voices the person downloaded in Settings, and their Personal
 Voice once they allow it. Siri's voices are not offered to apps.
 */

import AVFoundation
import Foundation

@MainActor
public final class OnScreenTextNarrator {
    public struct Settings: Sendable, Equatable {
        /// `AVSpeechSynthesisVoice.identifier`; nil for the system language's default.
        public var voiceIdentifier: String?
        /// Multiplies the default speaking rate (0.5...1.5).
        public var rate: Float
        /// The video's level while narration plays (0...1).
        public var duckLevel: Float
        public init(voiceIdentifier: String? = nil, rate: Float = 1, duckLevel: Float = 0.35) {
            self.voiceIdentifier = voiceIdentifier; self.rate = rate; self.duckLevel = duckLevel
        }
    }

    public var settings = Settings() {
        didSet { if settings.voiceIdentifier != oldValue.voiceIdentifier || settings.rate != oldValue.rate { prepared = [:] } }
    }
    /// The video's sound level to apply: 1 normally, `duckLevel` while speaking.
    public var onDuck: ((Float) -> Void)?
    /// Code-defined diagnostics; never the text spoken.
    public var onDiagnostic: ((String) -> Void)?
    /// The narration's own level (0...1): the host passes the player's volume
    /// so the slider governs both.
    public var volume: Float = 1 {
        didSet { engine?.mainMixerNode.outputVolume = volume }
    }
    /// How far ahead cues are synthesized, in media seconds.
    public var prepareAhead = 12.0

    private struct Prepared {
        var text: String
        var buffers: [AVAudioPCMBuffer]
        var duration: Double
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var prepared: [Int: Prepared] = [:]
    private var preparing: Int?
    private var spoken: Set<Int> = []
    private var speaking: Int?
    private var lastPlayhead: Double?
    private var paused = false
    private var reportedUnready: Int?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var engineFormat: AVAudioFormat?

    public init() {}

    /// Call often (10 Hz) with the player's state and the current cues.
    public func update(playhead: Double, playing: Bool, speed: Double, cues: [OnScreenTextCue]) {
        // A jump: drop what was playing, and don't speak what was skipped.
        if let last = lastPlayhead, playhead < last - 0.3 || playhead > last + 1.5 {
            stopSpeaking()
            spoken = Set(cues.filter { $0.start < playhead - 0.1 }.map(\.id))
        }
        lastPlayhead = playhead

        // Pause and resume with the video.
        if speaking != nil {
            if !playing, !paused { playerNode?.pause(); paused = true }
            if playing, paused { playerNode?.play(); paused = false }
            if playing { timePitch?.rate = Float(currentStretch * max(0.25, speed)) }
        }

        // Synthesize what's coming, nearest first, one at a time.
        if preparing == nil, let next = cues.first(where: { cue in
            cue.start >= playhead - 1 && cue.start <= playhead + prepareAhead
                && !spoken.contains(cue.id) && prepared[cue.id]?.text != cue.text
        }) {
            prepare(next)
        }

        // Speak the cue that is due.
        guard playing, speaking == nil else { return }
        guard let index = cues.firstIndex(where: { cue in
            !spoken.contains(cue.id) && playhead >= cue.start - 0.05 && playhead < cue.start + 1.0
        }) else { return }
        let cue = cues[index]
        guard let ready = prepared[cue.id], ready.text == cue.text else {
            if reportedUnready != cue.id {
                reportedUnready = cue.id
                onDiagnostic?(preparing == nil ? "Narration: a due line was never prepared" : "Narration: a due line is still being prepared")
            }
            return
        }
        let nextStart = index + 1 < cues.count ? cues[index + 1].start : cue.end + 1.0
        let slot = max(0.5, nextStart - 0.15 - playhead)
        speak(cue, ready, slot: slot, speed: speed)
    }

    /// Silences everything and forgets what was prepared and spoken.
    public func stop() {
        stopSpeaking()
        synthesizer.stopSpeaking(at: .immediate)
        prepared = [:]; preparing = nil; spoken = []; lastPlayhead = nil
        engine?.stop()
        engine = nil; playerNode = nil; timePitch = nil; engineFormat = nil
    }

    // MARK: Speaking

    private var currentStretch = 1.0

    private func speak(_ cue: OnScreenTextCue, _ ready: Prepared, slot: Double, speed: Double) {
        guard let format = ready.buffers.first?.format, let node = node(for: format) else { return }
        spoken.insert(cue.id)
        speaking = cue.id
        paused = false
        currentStretch = min(1.4, max(1, ready.duration / slot))
        timePitch?.rate = Float(currentStretch * max(0.25, speed))
        onDiagnostic?(String(format: "Narration: speaking a %.1f s line in %.1f s", ready.duration, slot))
        if currentStretch > 1.01 { onDiagnostic?(String(format: "Narration: line sped up %.2fx to fit", currentStretch)) }
        onDuck?(settings.duckLevel)
        let id = cue.id
        for (i, buffer) in ready.buffers.enumerated() {
            let last = i == ready.buffers.count - 1
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard last else { return }
                Task { @MainActor in self?.finished(id) }
            }
        }
        node.play()
    }

    private func finished(_ id: Int) {
        guard speaking == id else { return }
        speaking = nil
        paused = false
        onDuck?(1)
    }

    private func stopSpeaking() {
        guard speaking != nil else { return }
        speaking = nil
        paused = false
        playerNode?.stop()
        onDuck?(1)
    }

    /// The engine's player, connected for `format`; rebuilt for another one
    /// (a voice with a different sample rate).
    private func node(for format: AVAudioFormat) -> AVAudioPlayerNode? {
        if let playerNode, let engineFormat, engineFormat == format, engine?.isRunning == true { return playerNode }
        engine?.stop()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            onDiagnostic?("Narration: audio engine failed to start (code \((error as NSError).code))")
            return nil
        }
        engine.mainMixerNode.outputVolume = volume
        self.engine = engine; playerNode = node; timePitch = pitch; engineFormat = format
        return node
    }

    // MARK: Synthesis

    private func prepare(_ cue: OnScreenTextCue) {
        preparing = cue.id
        let utterance = AVSpeechUtterance(string: cue.text)
        if let id = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * settings.rate))
        let collector = BufferCollector()
        let id = cue.id, text = cue.text
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                collector.append(pcm)
                return
            }
            // A zero-length buffer ends the utterance.
            let finished = VoiceBuffers(buffers: collector.take())
            Task { @MainActor in self?.finishedPreparing(id, text: text, buffers: finished.buffers) }
        }
    }

    private func finishedPreparing(_ id: Int, text: String, buffers: [AVAudioPCMBuffer]) {
        guard preparing == id else { return }
        preparing = nil
        let playable = buffers.compactMap(Self.playable)
        guard !playable.isEmpty else {
            onDiagnostic?("Narration: the voice produced no audio")
            return
        }
        let frames = playable.reduce(0.0) { $0 + Double($1.frameLength) }
        prepared[id] = Prepared(text: text, buffers: playable, duration: frames / playable[0].format.sampleRate)
        if prepared.count == 1 {
            let format = playable[0].format
            onDiagnostic?(String(format: "Narration: first line ready, %.1f s at %.0f Hz, %d ch", frames / format.sampleRate, format.sampleRate, Int(format.channelCount)))
        }
    }

    /// The player node takes deinterleaved Float32; voices may write Int16.
    private static func playable(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved { return buffer }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: buffer.format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength) else { return nil }
        do { try converter.convert(to: output, from: buffer) } catch { return nil }
        return output
    }
}

/// Collects a voice's buffers on the synthesizer's thread.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { buffers.append(buffer) } }
    func take() -> [AVAudioPCMBuffer] { lock.withLock { defer { buffers = [] }; return buffers } }
}

/// A voice's finished buffers, handed from its thread to the main actor once.
private struct VoiceBuffers: @unchecked Sendable { let buffers: [AVAudioPCMBuffer] }
