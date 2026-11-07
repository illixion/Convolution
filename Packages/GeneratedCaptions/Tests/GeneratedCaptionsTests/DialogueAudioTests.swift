import AVFoundation
import Foundation
import Testing
@testable import GeneratedCaptions

/// The channel speech recognition hears, and where in it the speech starts.
@Suite struct DialogueAudioTests {
    private static let rate = 48000.0

    /// One second of 5.1 in the given layout, channel `c` a sine of amplitude `levels[c]`.
    private func buffer(layout tag: AudioChannelLayoutTag, levels: [Float], seconds: Double = 1) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: tag)!
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channelLayout: layout)
        let frames = AVAudioFrameCount(Self.rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<levels.count {
            let data = buffer.floatChannelData![c]
            let hz = 200.0 + 100.0 * Double(c)
            for i in 0..<Int(frames) { data[i] = levels[c] * Float(sin(2 * .pi * hz * Double(i) / Self.rate)) }
        }
        return buffer
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let data = buffer.floatChannelData![0]
        let n = Int(buffer.frameLength)
        return ((0..<n).reduce(Float(0)) { $0 + data[$1] * data[$1] } / Float(n)).squareRoot()
    }

    @Test func labelsComeFromTheLayout() {
        let d = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_D)!)
        #expect(DialogueMixer.labels(of: d) == [kAudioChannelLabel_Center, kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                                                kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen])
    }

    @Test func aCentreThatCarriesSoundIsHeardAlone() {
        // MPEG 5.1 A: L R C LFE Ls Rs. Loud music in the front pair, dialogue in the centre.
        var mixer = DialogueMixer()
        let input = buffer(layout: kAudioChannelLayoutTag_MPEG_5_1_A, levels: [0.5, 0.5, 0.1, 0.5, 0.5, 0.5])
        let mono = mixer.mono(input)!
        #expect(mono.format.channelCount == 1)
        #expect(!mixer.usesFrontPair)
        #expect(abs(rms(mono) - 0.1 / Float(2).squareRoot()) < 0.002)
    }

    @Test func anEmptyCentreFallsBackToTheFrontPair() {
        // MPEG 5.1 D: C L R Ls Rs LFE, silent centre: stereo carried as 5.1.
        var mixer = DialogueMixer()
        let input = buffer(layout: kAudioChannelLayoutTag_MPEG_5_1_D, levels: [0, 0.2, 0.2, 0.3, 0.3, 0.5])
        let mono = mixer.mono(input)!
        #expect(mixer.usesFrontPair)
        // Two different tones averaged: each at half level, uncorrelated.
        #expect(abs(rms(mono) - 0.1) < 0.005)
    }

    @Test func stereoIsAveraged() {
        var mixer = DialogueMixer()
        let input = buffer(layout: kAudioChannelLayoutTag_Stereo, levels: [0.2, 0.2])
        let mono = mixer.mono(input)!
        #expect(abs(rms(mono) - 0.1) < 0.005)
    }

    /// Low noise, then a tone from `onset` on, as 16 kHz mono.
    private func signal(onset: Double, through end: Double, total: Double, level: Float = 0.1) -> [Float] {
        let rate = 16000.0
        return (0..<Int(total * rate)).map { i in
            let t = Double(i) / rate
            let noise = Float.random(in: -0.0005...0.0005)
            return noise + (t >= onset && t < end ? level * Float(sin(2 * .pi * 220 * t)) : 0)
        }
    }

    @Test func onsetIsWhereTheVoiceStarts() {
        var voice = VoiceActivity()
        let samples = signal(onset: 1.5, through: 3, total: 4)
        // Fed in packets, as the decoder delivers them.
        for start in stride(from: 0, to: samples.count, by: 1024) {
            let piece = Array(samples[start..<min(samples.count, start + 1024)])
            piece.withUnsafeBufferPointer { voice.add($0, sampleRate: 16000, at: 10 + Double(start) / 16000) }
        }
        let onset = voice.onset(from: 10, through: 14)
        #expect(onset != nil)
        #expect(abs((onset ?? 0) - 11.5) < 0.05)
        // Already talking when the range opens: the range's own start.
        #expect(voice.onset(from: 12, through: 14) == 12)
        // Nothing said after the tone.
        #expect(voice.onset(from: 13.1, through: 14) == nil)
    }

    @Test func aClickIsNotSpeech() {
        var voice = VoiceActivity()
        let samples = signal(onset: 0.5, through: 0.54, total: 2, level: 0.5)
        samples.withUnsafeBufferPointer { voice.add($0, sampleRate: 16000, at: 0) }
        #expect(voice.onset(from: 0, through: 2) == nil)
    }
}
