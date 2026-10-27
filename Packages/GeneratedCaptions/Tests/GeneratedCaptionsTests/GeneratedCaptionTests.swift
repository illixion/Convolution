import AVFoundation
import CoreML
import Foundation
import Speech
import Testing
@testable import GeneratedCaptions

struct GeneratedCaptionBufferTests {
    @Test func reserveHasHysteresisAndScalesWithSpeed() {
        let policy = RAVEAnalysisBufferPolicy()
        #expect(policy.needsHold(playhead: 10, readyThrough: 10.2, duration: 100, rate: 1, alreadyHolding: false, finished: false))
        #expect(!policy.needsHold(playhead: 10, readyThrough: 11, duration: 100, rate: 1, alreadyHolding: false, finished: false))
        #expect(policy.needsHold(playhead: 10, readyThrough: 11, duration: 100, rate: 1, alreadyHolding: true, finished: false))
        #expect(!policy.needsHold(playhead: 10, readyThrough: 12.5, duration: 100, rate: 1, alreadyHolding: true, finished: false))
        #expect(policy.needsHold(playhead: 10, readyThrough: 12.5, duration: 100, rate: 2, alreadyHolding: true, finished: false))
        #expect(!policy.needsHold(playhead: 10, readyThrough: 11.25, duration: 100, rate: 0.5, alreadyHolding: true, finished: false))
    }
    @Test func liveUnknownDurationStillBuffersAndEOFReleases() {
        let policy = RAVEAnalysisBufferPolicy()
        #expect(policy.needsHold(playhead: 10, readyThrough: 10, duration: .nan, rate: 1, alreadyHolding: true, finished: false))
        #expect(!policy.needsHold(playhead: 10, readyThrough: 10, duration: .nan, rate: 1, alreadyHolding: true, finished: true))
        #expect(!policy.needsHold(playhead: 99.9, readyThrough: 100, duration: 100, rate: 1, alreadyHolding: true, finished: false))
    }
}

/// Integration runs use generated speech fixtures: CAPTION_FIXTURE and
/// CAPTION_TWO_SPEAKERS; CAPTION_HLS_FIXTURE is an optional local HLS fixture.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CAPTION_INTEGRATION"] == "1"))
struct GeneratedCaptionIntegrationTests {
    @MainActor private static func installedSpeakerModel() async throws -> URL {
        let store = RAVESpeakerModel.shared
        if !store.isInstalled { store.download() }
        let deadline = Date.now.addingTimeInterval(120)
        while store.progress != nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(store.error == nil)
        try #require(store.isInstalled)
        return store.modelURL
    }
    @Test func downloadedSpeakerModelIsLoadable() async throws {
        let url = try await Self.installedSpeakerModel()
        let model = try await MLModel.load(contentsOf: url)
        #expect(model.modelDescription.inputDescriptionsByName["chunk"] != nil)
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true]) func timestampedSpeechDecodesAheadAndFinalizes(speakers: Bool) async throws {
        guard #available(macOS 26, *) else { return }
        let path = try #require(ProcessInfo.processInfo.environment["CAPTION_FIXTURE"])
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        #expect(SpeechTranscriber.isAvailable)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let item = AVPlayerItem(asset: asset)
        let worker = CaptionWorker(transcriber: transcriber)
        let model: URL?
        if speakers {
            model = try await Self.installedSpeakerModel()
        } else { model = nil }
        try await worker.prepare(asset: asset, item: item, start: 0, speakerModel: model, selectedAudioTrackID: nil)
        let results = Task {
            for try await result in transcriber.results { await worker.receive(result) }
        }
        defer { results.cancel(); Task { await worker.cancel() } }
        var state = try await worker.advance(playhead: 0, rate: 1)
        let deadline = Date.now.addingTimeInterval(30)
        while state.readyThrough < 2.5, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            state = try await worker.advance(playhead: 0, rate: 1)
        }
        #expect(state.readyThrough >= 2.5) // must work before the player moves
        #expect(!state.finished) // bounded lookahead, not a whole-file pass
        while !state.finished, Date.now < deadline {
            state = try await worker.advance(playhead: max(0, state.readyThrough - 2), rate: 1)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.finished)
        try await Task.sleep(for: .milliseconds(200))
        let captions = await worker.snapshot(near: 0)
        #expect(!captions.isEmpty)
        #expect(captions.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        #expect(captions.map(\.text).joined().lowercased().contains("caption"))
        if speakers { #expect(captions.contains { $0.speaker != nil }) }
    }
    @Test(.timeLimit(.minutes(2))) func diarizationDistinguishesTwoVoices() async throws {
        guard #available(macOS 26, *) else { return }
        let path = try #require(ProcessInfo.processInfo.environment["CAPTION_TWO_SPEAKERS"])
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let item = AVPlayerItem(asset: asset)
        let worker = CaptionWorker(transcriber: transcriber)
        try await worker.prepare(asset: asset, item: item, start: 0,
                                 speakerModel: try await Self.installedSpeakerModel(), selectedAudioTrackID: nil)
        let results = Task {
            for try await result in transcriber.results { await worker.receive(result) }
        }
        defer { results.cancel(); Task { await worker.cancel() } }
        var state = try await worker.advance(playhead: 0, rate: 1)
        let deadline = Date.now.addingTimeInterval(90)
        while !state.finished, Date.now < deadline {
            state = try await worker.advance(playhead: max(0, state.readyThrough - 2), rate: 1)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.finished)
        try await Task.sleep(for: .milliseconds(300))
        let speakers = Set((await worker.snapshot(near: 0)).compactMap(\.speaker))
        #expect(speakers.count >= 2)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CAPTION_HLS_FIXTURE"] != nil)) @MainActor
    func hlsAudioCanBeAnalyzedWhilePlaybackIsPaused() async throws {
        guard #available(macOS 27, *) else { return }
        let url = URL(string: try #require(ProcessInfo.processInfo.environment["CAPTION_HLS_FIXTURE"]))!
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        let player = AVPlayer(playerItem: item); player.isMuted = true
        player.play()
        let deadline = Date.now.addingTimeInterval(25)
        while item.status != .readyToPlay, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(item.status == .readyToPlay)
        player.pause()
        let session = RAVEGeneratedCaptions()
        session.bind(player: player)
        session.onBuffering = { held in if held { player.pause() } }
        session.start()
        defer { session.stop() }
        while (session.captions.isEmpty || session.isBuffering), session.error == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.error == nil)
        #expect(!session.captions.isEmpty)
        #expect(!session.isBuffering)
        #expect(player.rate == 0)
        session.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(item.outputs.filter { $0 is AVPlayerItemSampleBufferOutput }.isEmpty)
    }

    @Test func silenceAdvancesReadinessWithoutInventingCaptions() async throws {
        guard #available(macOS 26, *) else { return }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        let worker = CaptionWorker(transcriber: transcriber)
        let source = SilentCaptionAudio()
        try await worker.prepare(asset: nil, item: nil, start: 0, speakerModel: nil, selectedAudioTrackID: nil,
                                 external: RAVECaptionAudioSource { await source.next() })
        defer { Task { await worker.cancel() } }
        var state = try await worker.advance(playhead: 0, rate: 1)
        let deadline = Date.now.addingTimeInterval(10)
        while state.readyThrough < 2.5, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            state = try await worker.advance(playhead: 0, rate: 1)
        }
        #expect(state.readyThrough >= 2.5)
        #expect(state.captions.isEmpty)
        #expect(!state.finished)
    }

}


private actor SilentCaptionAudio {
    var time: Double = 0
    func next() -> RAVECaptionAudioChunk? {
        guard time < 30 else { return nil }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)!
        buffer.frameLength = 4000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 4000)
        defer { time += 0.25 }
        return .init(buffer: buffer, time: time)
    }
}
