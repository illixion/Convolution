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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CAPTION_FRAGMENT_FIXTURE"] != nil), arguments: [0, 7])
    func fragmentedAudioKeepsAbsoluteTimeAndDecodesAcrossBoundaries(first: Int) async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CAPTION_FRAGMENT_FIXTURE"]))
        let fragments = CaptionFragmentFixture(directory: directory, indices: Array(first ..< first + 3))
        let source = RAVECaptionAudioSource.fragmentedMP4 { try await fragments.next() }
        var firstTime: Double?
        var through = 0.0
        var energy = 0.0
        while let chunk = try await source.next() {
            if firstTime == nil { firstTime = chunk.time }
            else { #expect(abs(chunk.time - through) < 0.05) }
            through = chunk.time + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            if let values = chunk.buffer.floatChannelData {
                for channel in 0..<Int(chunk.buffer.format.channelCount) {
                    energy += UnsafeBufferPointer(start: values[channel], count: Int(chunk.buffer.frameLength)).reduce(0) { $0 + Double($1 * $1) }
                }
            }
        }
        #expect(abs(try #require(firstTime) - Double(first * 4)) < 0.05)
        #expect(through > Double((first + 3) * 4) - 0.1)
        #expect(energy > 0.1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CAPTION_FRAGMENT_FIXTURE"] != nil)) @MainActor
    func fragmentedAudioGeneratesCaptionsWithoutAnHLSOutput() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CAPTION_FRAGMENT_FIXTURE"]))
        let session = RAVEGeneratedCaptions()
        session.bindExternal(position: { 28 }, duration: { 60 }, speed: { 1 }, playing: { false }, source: { _ in
            let fragments = CaptionFragmentFixture(directory: directory, indices: Array(7..<13))
            return .fragmentedMP4 { try await fragments.next() }
        })
        defer { session.stop() }
        // Each restart opens a fresh reader near the playhead; no player seek
        // or sample-buffer output is needed to escape the caption startup hold.
        for _ in 0..<2 {
            session.start()
            let deadline = Date.now + 25
            while (session.captions.isEmpty || session.isBuffering), session.error == nil, Date.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(session.error == nil)
            #expect(!session.captions.isEmpty)
            #expect(session.captions.allSatisfy { $0.start >= 28 })
            #expect(!session.isBuffering)
            session.stop()
        }
    }
    @Test(.timeLimit(.minutes(2))) @MainActor func failedSourceReleasesSessionAndCanRetry() async throws {
        let captions = RAVEGeneratedCaptions()
        captions.bindExternal(position: { 0 }, duration: { 60 }, speed: { 1 }, playing: { true },
                              source: { _ in throw URLError(.cannotDecodeContentData) })
        for _ in 0..<2 {
            captions.start()
            let deadline = Date.now.addingTimeInterval(30)
            while captions.error == nil, Date.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(captions.error != nil)
            #expect(!captions.enabled)
            #expect(!captions.isBuffering)
        }
        captions.stop()
    }
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
    /// The recognizer's volatile guesses and the final results that settle
    /// them overlap in time; no sentence may show twice, with speaker
    /// detection on or off.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true]) func overlappingResultsDoNotRepeatWords(speakers: Bool) async throws {
        guard #available(macOS 26, *) else { return }
        let path = try #require(ProcessInfo.processInfo.environment["CAPTION_FIXTURE"])
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let worker = CaptionWorker(transcriber: transcriber)
        let model: URL? = speakers ? try await Self.installedSpeakerModel() : nil
        try await worker.prepare(asset: asset, item: AVPlayerItem(asset: asset), start: 0, speakerModel: model, selectedAudioTrackID: nil)
        let results = Task {
            for try await result in transcriber.results { await worker.receive(result) }
        }
        defer { results.cancel(); Task { await worker.cancel() } }
        var state = try await worker.advance(playhead: 0, rate: 1)
        let deadline = Date.now.addingTimeInterval(90)
        var playhead = 0.0
        while !state.finished, Date.now < deadline {
            // Play along, as a player would: the playhead moves, results keep arriving.
            playhead = min(playhead + 0.5, max(0, state.readyThrough - 1))
            state = try await worker.advance(playhead: playhead, rate: 1)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .milliseconds(500))
        let captions = await worker.snapshot(near: 0)
        // No sentence may appear twice in a row.
        for caption in captions {
            // Punctuation can be all that separates the copies ("okay.I'll").
            let words = caption.text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
            for length in 3 ... max(3, words.count / 2) where words.count >= length * 2 {
                for index in 0 ... words.count - length * 2 {
                    #expect(Array(words[index ..< index + length]) != Array(words[index + length ..< index + length * 2]),
                            "repeated: \(caption.text)")
                }
            }
        }
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
        // The item only feeds the output it had at its latest seek, so a
        // restart must reuse that output rather than attach another.
        session.start()
        let restartDeadline = Date.now.addingTimeInterval(25)
        while (session.captions.isEmpty || session.isBuffering), session.error == nil, Date.now < restartDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.error == nil)
        #expect(!session.captions.isEmpty)
        #expect(item.outputs.filter { $0 is AVPlayerItemSampleBufferOutput }.count == 1)
        // A seek renumbers an HLS item's tracks; analysis must follow the
        // playhead rather than treat that as an audio-track change.
        await player.seek(to: CMTime(seconds: 30, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let seekDeadline = Date.now.addingTimeInterval(25)
        while !session.captions.contains(where: { $0.start >= 29 }), session.error == nil, Date.now < seekDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.error == nil)
        #expect(session.captions.contains { $0.start >= 29 })
        #expect(item.outputs.filter { $0 is AVPlayerItemSampleBufferOutput }.count == 1)
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

private actor CaptionFragmentFixture {
    let directory: URL
    var indices: [Int]
    init(directory: URL, indices: [Int]) { self.directory = directory; self.indices = indices }
    func next() throws -> Data? {
        guard !indices.isEmpty else { return nil }
        let index = indices.removeFirst()
        return try Data(contentsOf: directory.appendingPathComponent("init.mp4"))
            + Data(contentsOf: directory.appendingPathComponent("audio\(index).m4s"))
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
