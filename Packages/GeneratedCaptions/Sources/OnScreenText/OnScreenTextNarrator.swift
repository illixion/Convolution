/*
 On-screen text: speaking the cues as narration.

 Each upcoming cue is synthesized ahead of time (`AVSpeechSynthesizer.write`,
 so nothing plays until it is due) into PCM buffers, and played through an
 `AVAudioEngine` when the playhead reaches the cue's start. A line longer than
 the time it has (until the next cue, or a second past its own end) is sped up
 by a time-pitch unit, by at most 1.8x; at that speed it overruns rather than
 gabbles. Lines that queue up behind a long one are spoken in order, up to four
 seconds late, and skipped after that. In the prototype (Daniel Enhanced, 185 wpm) 3 lines in 65 needed it.

 The narration follows the video: it pauses with it, stops on a seek, and is
 spoken at the video's speed. While it speaks the host lowers the video's
 sound (`onDuck`), ramped, and restores it after.

 Voices are the system's (`AVSpeechSynthesisVoice.speechVoices()`): premium
 and enhanced voices the person downloaded in Settings, and their Personal
 Voice once they allow it. Siri's voices are not offered to apps. Or a Kokoro
 voice (`OnScreenTextKokoro`, identifier `kokoro:<pack>`), once its models are
 downloaded; if it fails, the line is spoken in the system voice instead.
 */

import AVFoundation
import Foundation

@MainActor
public final class OnScreenTextNarrator {
    public struct Settings: Sendable, Equatable {
        /// `AVSpeechSynthesisVoice.identifier`, or `kokoro:<pack>` for a
        /// Kokoro voice; nil for the system language's default.
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
    /// The voice turns with the head instead of staying in the room (visionOS;
    /// the player's Head-Locked Sound). The host sets it from the same rule it
    /// applies to the video's own sound.
    public var headLocked = false {
        didSet { if headLocked != oldValue, let engine { applySpatialExperience(to: engine) } }
    }
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
    /// Kokoro's models are loaded for this narration (released by `stop`).
    private var usedKokoro = false
    /// Kokoro failed this narration: the system voice speaks instead.
    private var kokoroFailed = false
    private var kokoroTask: Task<Void, Never>?

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

        // Synthesize what's coming, nearest first, one at a time. A line that
        // is a little late is still worth preparing: fast text queues up.
        if preparing == nil, let next = cues.first(where: { cue in
            cue.start >= playhead - Self.maxLateness && cue.start <= playhead + prepareAhead
                && !spoken.contains(cue.id) && prepared[cue.id]?.text != cue.text
        }) {
            prepare(next)
        }

        // Speak the cue that is due. Text that changes faster than it can be
        // read aloud queues up: lines are spoken in order, each as soon as the
        // one before ends, so long as they are not too late to matter; older
        // ones than that are skipped, so the voice catches up instead of
        // trailing the picture further and further.
        guard playing, speaking == nil else { return }
        let due = cues.indices.filter { index in
            let cue = cues[index]
            return !spoken.contains(cue.id) && playhead >= cue.start - 0.05
        }
        guard !due.isEmpty else { return }
        for index in due where playhead >= cues[index].start + Self.maxLateness {
            spoken.insert(cues[index].id)
            onDiagnostic?("Narration: skipped a line that came too late to speak")
        }
        guard let index = due.first(where: { !spoken.contains(cues[$0].id) }) else { return }
        let cue = cues[index]
        guard let ready = prepared[cue.id], ready.text == cue.text else {
            if reportedUnready != cue.id {
                reportedUnready = cue.id
                onDiagnostic?(preparing == nil ? "Narration: a due line was never prepared" : "Narration: a due line is still being prepared")
            }
            return
        }
        // The time it has: until the next cue, or a second past its own end;
        // less as lines queue behind it, so a backlog is spoken faster.
        var nextStart = index + 1 < cues.count ? cues[index + 1].start : cue.end + 1.0
        // A subtitle still on screen has no end yet (its `end` is how far it
        // has been seen): nothing says it won't stay as long as it takes.
        if index + 1 >= cues.count, cue.isOpen { nextStart = max(nextStart, playhead + ready.duration + 0.15) }
        let queued = due.filter { $0 > index && !spoken.contains(cues[$0].id) }.count
        var slot = max(0.5, nextStart - 0.15 - playhead)
        if queued > 0 { slot = max(0.5, min(slot, ready.duration / (1 + 0.25 * Double(queued)))) }
        speak(cue, ready, slot: slot, speed: speed)
    }

    /// Starts loading a Kokoro voice's models, when one is chosen, so the
    /// first line isn't held up by it (the first load after a download
    /// compiles them, about 20 to 30 s). `stop` releases them.
    public func preload() {
        guard !usedKokoro, OnScreenTextKokoro.voice(forIdentifier: settings.voiceIdentifier) != nil,
              OnScreenTextKokoro.isDownloaded else { return }
        usedKokoro = true
        onDiagnostic?("Narration: loading the Kokoro voice")
        OnScreenTextKokoro.shared.retain()
        Task { try? await OnScreenTextKokoro.shared.prepare() }
    }

    /// Silences everything and forgets what was prepared and spoken.
    public func stop() {
        stopSpeaking()
        synthesizer.stopSpeaking(at: .immediate)
        prepared = [:]; preparing = nil; spoken = []; lastPlayhead = nil
        kokoroTask?.cancel(); kokoroTask = nil; kokoroFailed = false
        if usedKokoro {
            usedKokoro = false
            OnScreenTextKokoro.shared.release()
        }
        engine?.stop()
        engine = nil; playerNode = nil; timePitch = nil; engineFormat = nil
    }

    // MARK: Speaking

    private var currentStretch = 1.0
    /// The most a line is sped up to fit: past it speech stops being clear.
    private static let maxStretch = 1.8
    /// How late (seconds after its start) a line can still be spoken.
    private static let maxLateness = 4.0

    private func speak(_ cue: OnScreenTextCue, _ ready: Prepared, slot: Double, speed: Double) {
        guard let format = ready.buffers.first?.format, let node = node(for: format) else { return }
        spoken.insert(cue.id)
        speaking = cue.id
        paused = false
        currentStretch = min(Self.maxStretch, max(1, ready.duration / slot))
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
        applySpatialExperience(to: engine)
        self.engine = engine; playerNode = node; timePitch = pitch; engineFormat = format
        return node
    }

    /// An `AVAudioEngine`'s output is placed in the room like any app sound;
    /// head-locked sound plays it unspatialized instead.
    private func applySpatialExperience(to engine: AVAudioEngine) {
        #if os(visionOS)
        if headLocked {
            engine.outputNode.intendedSpatialExperience = .bypassed
        } else {
            engine.outputNode.intendedSpatialExperience = .automatic
        }
        #endif
    }

    // MARK: Synthesis

    private func prepare(_ cue: OnScreenTextCue) {
        preparing = cue.id
        if !kokoroFailed, let voice = OnScreenTextKokoro.voice(forIdentifier: settings.voiceIdentifier),
           OnScreenTextKokoro.isDownloaded {
            prepareWithKokoro(cue, voice: voice)
            return
        }
        prepareWithSystemVoice(cue)
    }

    private func prepareWithKokoro(_ cue: OnScreenTextCue, voice: OnScreenTextKokoro.Voice) {
        preload()
        let id = cue.id, text = cue.text, spoken = Self.spokenForm(cue.text), speed = settings.rate
        kokoroTask = Task { [weak self] in
            do {
                let buffer = try await OnScreenTextKokoro.shared.synthesize(spoken, voice: voice.id, speed: speed)
                guard !Task.isCancelled else { return }
                self?.finishedPreparing(id, text: text, buffers: [buffer])
            } catch {
                guard !Task.isCancelled, let self, self.preparing == id else { return }
                self.onDiagnostic?("Narration: the Kokoro voice failed (code \((error as NSError).code)); using the system voice")
                self.kokoroFailed = true
                self.prepareWithSystemVoice(cue)
            }
        }
    }

    private func prepareWithSystemVoice(_ cue: OnScreenTextCue) {
        let utterance = AVSpeechUtterance(string: Self.spokenForm(cue.text))
        if let id = settings.voiceIdentifier, !id.hasPrefix(OnScreenTextKokoro.identifierPrefix),
           let voice = AVSpeechSynthesisVoice(identifier: id) {
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

    /// What is handed to the voice. A line written in capitals (a channel
    /// that subtitles in all caps) has its words spelled out letter by letter
    /// by voices that take an unknown capitalised word for an acronym
    /// ("MAKES" said "em ay kay ee ess"), so it is lowercased, keeping short
    /// vowelless tokens (NYC, NPCS, TV) that are acronyms. A line with any
    /// lowercase letter is left as it is: its capitals mean something.
    static func spokenForm(_ text: String) -> String {
        guard !text.contains(where: \.isLowercase), text.contains(where: \.isUppercase) else { return text }
        let vowels = Set("AEIOUaeiou")
        return text.split(separator: " ", omittingEmptySubsequences: false).map { token in
            let letters = token.filter(\.isLetter)
            if letters.count >= 2, letters.count <= 4, !letters.contains(where: { vowels.contains($0) }) { return String(token) }
            return token.lowercased()
        }.joined(separator: " ")
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
