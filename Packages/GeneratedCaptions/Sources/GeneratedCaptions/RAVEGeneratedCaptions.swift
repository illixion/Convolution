import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Observation
import Speech

/// Decoded audio on the original media timeline; only read by analysis.
public struct RAVECaptionAudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let time: Double
    public init(buffer: AVAudioPCMBuffer, time: Double) { self.buffer = buffer; self.time = time }
}
public struct RAVECaptionAudioSource: Sendable {
    public let next: @Sendable () async throws -> RAVECaptionAudioChunk?
    public init(next: @escaping @Sendable () async throws -> RAVECaptionAudioChunk?) { self.next = next }
}

public struct RAVEGeneratedCaption: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: Int?
}

/// One player's caption analysis, on the same media timeline as its picture.
/// Audio is decoded ahead, never played here. Holding the host transport holds
/// sound and picture together; seeking starts a new analysis generation.
@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
@MainActor @Observable
public final class RAVEGeneratedCaptions {
    public private(set) var captions: [RAVEGeneratedCaption] = []
    public private(set) var status = ""
    public private(set) var error: String?
    public private(set) var isBuffering = false
    /// Decoded audio available ahead of the current playhead.
    public private(set) var audioBufferedSeconds = 0.0
    /// Audio the recognizer (and optional diarizer) has finished analyzing.
    public private(set) var analysisBufferedSeconds = 0.0
    /// Readiness relative to the 2.5-second normal resume target.
    public private(set) var lookaheadProgress = 0.0
    public private(set) var enabled = false
    public var onChange: (() -> Void)?
    /// Host preserves user play/pause intent while applying this hold.
    public var onBuffering: ((Bool) -> Void)?
    private weak var player: AVPlayer?
    private weak var bufferingItem: AVPlayerItem?
    private var originalForwardBufferDuration: TimeInterval?
    private var externalSource: (@Sendable (Double) async throws -> RAVECaptionAudioSource)?
    private var playerAudioSource: (@MainActor (AVPlayerItem, Double) async throws -> RAVECaptionAudioSource?)?
    /// Code-defined route/progress diagnostics; never contains URLs or dialogue.
    public var onDiagnostic: ((String) -> Void)?
    private var externalPosition: (() -> Double)?
    private var externalDuration: (() -> Double)?
    private var externalSpeed: (() -> Double)?
    private var externalPlaying: (() -> Bool)?
    public var isBound: Bool { player != nil || externalSource != nil }
    public func bindExternal(position: @escaping () -> Double, duration: @escaping () -> Double,
                             speed: @escaping () -> Double, playing: @escaping () -> Bool,
                             source: @escaping @Sendable (Double) async throws -> RAVECaptionAudioSource) {
        stop(); player = nil; playerAudioSource = nil
        externalPosition = position; externalDuration = duration
        externalSpeed = speed; externalPlaying = playing; externalSource = source
    }
    private var task: Task<Void, Never>?
    private var worker: CaptionWorker?
    private var holdWatchdog: Task<Void, Never>?
    private var holdsSpeakerModel = false
    private var generation = UUID()
    public init() {}

    public func bind(player: AVPlayer?, audioSource: (@MainActor (AVPlayerItem, Double) async throws -> RAVECaptionAudioSource?)? = nil) {
        guard self.player !== player || externalSource != nil else { return }
        let restart = enabled
        stop()
        self.player = player
        self.playerAudioSource = audioSource
        externalSource = nil; externalPosition = nil; externalDuration = nil
        externalSpeed = nil; externalPlaying = nil
        enabled = restart
        if restart, player != nil { start() }
    }
    public func start() {
        guard isBound else { return }
        let player = player
        let item = player?.currentItem
        let selectedAudioTrackID = item?.tracks.first(where: {
            $0.isEnabled && $0.assetTrack?.mediaType == .audio
        })?.assetTrack?.trackID
        let externalSource = externalSource
        let playerAudioSource = playerAudioSource
        // HLS audio comes from the item's own output, which follows whatever
        // the player renders; its track IDs are renumbered on every seek.
        let followsAudioTrack = externalSource == nil && !isHLS(item?.asset)
        let position: () -> Double = externalPosition ?? { [weak player] in player?.currentTime().seconds ?? 0 }
        let duration: () -> Double = externalDuration ?? { [weak player] in player?.currentItem?.duration.seconds ?? .nan }
        let speed: () -> Double = externalSpeed ?? { [weak player] in Double(player?.defaultRate ?? 1) }
        let playing: () -> Bool = externalPlaying ?? { [weak player] in (player?.rate ?? 0) > 0 }
        let isCurrent: () -> Bool = { [weak player] in externalSource != nil || (player != nil && player?.currentItem === item) }
        let localeIdentifier = UserDefaults.standard.string(forKey: "captions.locale")
            ?? Locale.preferredLanguages.first ?? Locale.current.identifier
        let locale = Locale(identifier: localeIdentifier)
        let speakerPreference = UserDefaults.standard.object(forKey: "captions.speakers") as? Bool ?? true
        let useSpeakers = speakerPreference && RAVESpeakerModel.shared.isInstalled
        let model = useSpeakers ? RAVESpeakerModel.shared.modelURL : nil
        stop()
        enabled = true
        if model != nil {
            RAVESpeakerModel.shared.beginUsing()
            holdsSpeakerModel = true
        }
        if let item {
            bufferingItem = item
            originalForwardBufferDuration = item.preferredForwardBufferDuration
            item.preferredForwardBufferDuration = max(8, item.preferredForwardBufferDuration)
        }
        let token = UUID(); generation = token
        status = "Preparing AI captions…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard SpeechTranscriber.isAvailable,
                      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    throw CaptionFailure("Speech recognition is unavailable for this device or language.")
                }
                let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                    reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    status = "Downloading speech language…"
                    try await request.downloadAndInstall()
                }
                try Task.checkCancellation()
                guard generation == token, isCurrent() else { return }
                let worker = CaptionWorker(transcriber: transcriber)
                self.worker = worker
                defer { Task { await worker.cancel() } }
                let begin = max(0, position())
                let audioGroup = try? await item?.asset.loadMediaSelectionGroup(for: .audible)
                let audioOption = audioGroup.flatMap { item?.currentMediaSelection.selectedMediaOption(in: $0) }
                let source: RAVECaptionAudioSource?
                if let externalSource { source = try await externalSource(begin) }
                else if let item { source = try await playerAudioSource?(item, begin) }
                else { source = nil }
                onDiagnostic?(source != nil ? "AI captions: independent audio decoder" : (isHLS(item?.asset) ? "AI captions: OS HLS audio output" : "AI captions: file audio reader"))
                try await worker.prepare(asset: item?.asset, item: item, start: begin,
                    speakerModel: model, selectedAudioTrackID: selectedAudioTrackID, external: source)
                try Task.checkCancellation()
                setBuffering(true)
                let resultTask = Task {
                    do {
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            guard self.generation == token else { return }
                            await worker.receive(result)
                            let snapshot = await worker.snapshot(near: position())
                            guard !Task.isCancelled, self.generation == token else { return }
                            self.captions = snapshot
                            self.onChange?()
                        }
                    } catch is CancellationError { }
                    catch { await worker.noteFailure(error.localizedDescription) }
                }
                defer { resultTask.cancel() }
                var previous = position()
                var lastWall = Date.now
                var holdingSince: Date?
                var reportedAudio = false
                while !Task.isCancelled, generation == token, isCurrent() {
                    if source != nil, let audioGroup,
                       item?.currentMediaSelection.selectedMediaOption(in: audioGroup) != audioOption {
                        start(); return
                    }
                    // A file reader is tied to one track. Follow an audio
                    // selection made while captions are already running.
                    if followsAudioTrack, item?.tracks.first(where: {
                        $0.isEnabled && $0.assetTrack?.mediaType == .audio
                    })?.assetTrack?.trackID != selectedAudioTrackID {
                        start(); return
                    }
                    let now = position()
                    let elapsed = Date.now.timeIntervalSince(lastWall)
                    // Compare elapsed media time, not a fixed threshold: fast
                    // playback and a busy main thread must not look like seeks.
                    let expected = previous + elapsed * (playing() ? speed() : 0)
                    if now < previous - 0.25 || abs(now - expected) > max(0.75, elapsed * 0.5) {
                        start(); return
                    }
                    previous = now; lastWall = .now
                    let state = try await worker.advance(playhead: now, rate: speed(), duration: duration())
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    captions = state.captions
                    onChange?()
                    var policy = RAVEAnalysisBufferPolicy()
                    if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                        policy.resumeSeconds = 4
                    }
                    audioBufferedSeconds = max(0, state.audioThrough - now)
                    if !reportedAudio, audioBufferedSeconds > 0 {
                        reportedAudio = true
                        onDiagnostic?("AI captions: decoded audio arriving")
                    }
                    analysisBufferedSeconds = max(0, state.readyThrough - now)
                    lookaheadProgress = min(1, analysisBufferedSeconds / max(0.25, policy.resumeSeconds * max(0.25, speed())))
                    let needsHold = policy.needsHold(playhead: now, readyThrough: state.readyThrough,
                        duration: duration(), rate: speed(), alreadyHolding: isBuffering, finished: state.finished)
                    if needsHold {
                        holdingSince = holdingSince ?? .now
                        // Unsupported/protected streams and failed analysis must
                        // never leave playback held indefinitely.
                        if Date.now.timeIntervalSince(holdingSince!) > 12 {
                            throw CaptionFailure(audioBufferedSeconds < 0.25
                                ? "This stream isn't providing decoded audio to AI captions. Try another stream or use its built-in subtitles."
                                : "Speech recognition couldn't analyze this audio quickly enough to stay ahead. Try another stream or turn AI captions off.")
                        }
                    } else { holdingSince = nil }
                    if isBuffering, !needsHold { onDiagnostic?("AI captions: analysis ready") }
                    setBuffering(needsHold)
                    status = needsHold ? "Buffering AI captions…" : "AI captions"
                    try await Task.sleep(for: .milliseconds(100))
                }
                if !Task.isCancelled, generation == token, isBound { start() }
            } catch is CancellationError { }
            catch is CaptionSequenceRestart { if generation == token { start() } }
            catch {
                guard generation == token else { return }
                let message = error.localizedDescription
                onDiagnostic?("AI captions: failed (code \((error as NSError).code)); audio ahead \(audioBufferedSeconds), analysis ahead \(analysisBufferedSeconds)")
                // Release the reader, model lease, forward-buffer override and
                // playback hold on every failure, not only when switched off.
                stop()
                self.error = message
                status = "AI captions failed"
            }
        }
    }
    public func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        let releaseSpeakerModel = holdsSpeakerModel
        holdsSpeakerModel = false
        if let worker {
            Task {
                await worker.cancel()
                if releaseSpeakerModel { RAVESpeakerModel.shared.endUsing() }
            }
        } else if releaseSpeakerModel {
            RAVESpeakerModel.shared.endUsing()
        }
        worker = nil
        enabled = false
        if let bufferingItem, let originalForwardBufferDuration {
            bufferingItem.preferredForwardBufferDuration = originalForwardBufferDuration
        }
        bufferingItem = nil
        originalForwardBufferDuration = nil
        captions = []; status = ""; error = nil
        audioBufferedSeconds = 0; analysisBufferedSeconds = 0; lookaheadProgress = 0
        setBuffering(false)
        onChange?()
    }
    private func setBuffering(_ value: Bool) {
        guard isBuffering != value else { return }
        isBuffering = value
        holdWatchdog?.cancel(); holdWatchdog = nil
        if value {
            holdWatchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard let self, self.isBuffering else { return }
                let message = self.audioBufferedSeconds < 0.25
                    ? "This stream isn't providing decoded audio to AI captions. Try another stream or use its built-in subtitles."
                    : "Speech recognition couldn't analyze this audio quickly enough to stay ahead. Try another stream or turn AI captions off."
                self.onDiagnostic?("AI captions: hold timed out; audio ahead \(self.audioBufferedSeconds), analysis ahead \(self.analysisBufferedSeconds)")
                self.stop()
                self.error = message
                self.status = "AI captions failed"
            }
        }
        onBuffering?(value)
    }
}

private func isHLS(_ asset: AVAsset?) -> Bool {
    (asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8"
}

private enum CaptionSequenceRestart: Error { case changed }

private struct CaptionFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// CMSampleBuffer/AVAudioPCMBuffer are exclusively consumed on the worker actor.
private struct CaptionAudioPacket: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var time: Double
    var restarted = false
}

@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
actor CaptionWorker {
    struct State: Sendable {
        var captions: [RAVEGeneratedCaption]
        var readyThrough: Double
        var audioThrough: Double
        var finished: Bool
    }
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Error>?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var externalPull: (@Sendable () async throws -> RAVECaptionAudioChunk?)?
    private var hlsPull: (@Sendable () throws -> CaptionAudioPacket?)?
    private var converter: AVAudioConverter?
    private var speechFormat: AVAudioFormat?
    private var diarizer: SortformerDiarizer?
    private var speakerConverter: AVAudioConverter?
    private var speakerOrigin: Double?
    private var begin: Double = 0
    private var speechEnd: CMTime?
    private var fedThrough: Double = 0
    private var analyzedThrough: Double = 0
    private var speakerThrough: Double = .infinity
    private var ended = false
    private var words: [RAVEGeneratedCaption] = []
    private var volatileWords: [RAVEGeneratedCaption] = []
    /// Where the volatile guess's result starts: a final that reaches past it settles the whole guess.
    private var volatileStart: Double?
    private var speakers: [(start: Double, end: Double, id: Int)] = []
    private var analysisError: String?

    init(transcriber: SpeechTranscriber) {
        AppLogger.minimumLevel = .fault
        AppLogger.mirrorsToConsole = false
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }
    func prepare(asset: AVAsset?, item: AVPlayerItem?, start: Double, speakerModel: URL?,
                 selectedAudioTrackID: CMPersistentTrackID?, external: RAVECaptionAudioSource? = nil) async throws {
        begin = start; fedThrough = start; analyzedThrough = start
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptionFailure("No supported speech audio format.")
        }
        speechFormat = format
        if let speakerModel {
            var config = SortformerConfig.fastV2_1
            config.precision = .palettized
            var timeline = DiarizerTimelineConfig.sortformerDefault
            timeline.maxStoredFrames = 1500; timeline.storeSegments = false
            let diarizer = SortformerDiarizer(config: config, timelineConfig: timeline)
            let mlconfig = MLModelConfiguration(); mlconfig.computeUnits = .all
            let ml = try await MLModel.load(contentsOf: speakerModel, configuration: mlconfig)
            let models = try SortformerModels(config: config, main: ml)
            diarizer.initialize(models: models)
            self.diarizer = diarizer
            speakerThrough = start
        }
        if let external { externalPull = external.next }
        else if let asset, let item {
        if isHLS(asset) {
            if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *) {
                hlsPull = await Self.attachHLS(to: item)
            } else { throw CaptionFailure("AI captions for HLS streams require OS 27 or later.") }
        } else {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first(where: { $0.trackID == selectedAudioTrackID }) ?? tracks.first else {
                throw CaptionFailure("This video has no readable audio track.")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16000), duration: .positiveInfinity)
            guard reader.startReading() else { throw reader.error ?? CaptionFailure("Cannot decode this video's audio.") }
            self.reader = reader; self.output = output
        }
        } else { throw CaptionFailure("No readable audio source.") }
        await analyzer.setVolatileRangeChangedHandler { [weak self] range, _, _ in
            Task { await self?.noteAnalyzed(range.end.seconds) }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.continuation = continuation
        try await analyzer.prepareToAnalyze(in: format)
        let analyzer = analyzer
        analysisTask = Task { [weak self] in
            do { _ = try await analyzer.analyzeSequence(stream) }
            catch { await self?.noteFailure(error.localizedDescription); throw error }
        }
    }
    func noteFailure(_ message: String) { analysisError = message }
    private func noteAnalyzed(_ time: Double) {
        if time.isFinite { analyzedThrough = max(analyzedThrough, time) }
    }
    /// A volatile result is the recognizer's current guess for everything
    /// not yet final, from the last final on, as one run spanning the whole
    /// stretch; each one replaces the one before. A final result arrives word
    /// by word over a narrower range than the guess it settles, so removing
    /// only the words inside its range left that guess behind, and the line
    /// showed twice ("I'll be your proxy… I'll be a proxy…").
    func receive(_ result: SpeechTranscriber.Result) {
        let start = result.range.start.seconds, end = result.range.end.seconds
        guard start.isFinite, end.isFinite else { return }
        var fresh: [RAVEGeneratedCaption] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let text = String(result.text[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // A result can open with the punctuation of a word it dropped
            // ("..", then " it ends here"); that is no caption.
            if fresh.isEmpty, !text.contains(where: { $0.isLetter || $0.isNumber }) { continue }
            // A final arrives a word to a run; a volatile guess is ONE run over
            // its whole range, which put the whole guess on screen at once and
            // moved words between lines when the finals replaced it.
            fresh += Self.timedWords(text, from: range.start.seconds, through: range.end.seconds)
        }
        if fresh.isEmpty { fresh.append(.init(start: start, end: end, text: String(result.text.characters), speaker: nil)) }
        if result.isFinal {
            words.removeAll { $0.start >= start - 0.001 && $0.end <= end + 0.001 }
            // The guess for this stretch is settled; what the recognizer
            // still guesses beyond it comes with its next volatile result.
            // A guess is one result, so one that starts inside the final goes
            // whole (its words carry estimated times, not the recognizer's).
            if let volatileStart, volatileStart < end - 0.001 { volatileWords = [] }
            volatileWords.removeAll { $0.start < end - 0.001 }
            words += fresh
            words.sort { $0.start < $1.start }
        } else {
            volatileWords = fresh
            volatileStart = start
        }
        noteAnalyzed(end)
    }
    func snapshot(near time: Double) -> [RAVEGeneratedCaption] {
        words.removeAll { $0.end < time - 60 }
        volatileWords.removeAll { $0.end < time - 60 }
        speakers.removeAll { $0.end < time - 60 }
        // Final words, then the guess after the last of them.
        var sequence = (words + volatileWords).sorted { $0.start < $1.start }
        for index in sequence.indices {
            let word = sequence[index]
            sequence[index].speaker = speakers.max { overlap($0, word) < overlap($1, word) }.flatMap { overlap($0, word) > 0 ? $0.id : nil }
        }
        return Self.lines(from: sequence)
    }

    /// The words as caption lines. They break where the speech does (a pause,
    /// another speaker, the end of a sentence), so the breaks anchor to the
    /// speech and don't move when older words fall out of the window; the
    /// greedy cut from the head of the list they replaced shifted every line
    /// after it. Only a sentence too long for a line is cut, in even parts at
    /// its commas, never leaving a word or two alone at the end.
    static func lines(from words: [RAVEGeneratedCaption]) -> [RAVEGeneratedCaption] {
        var units: [[RAVEGeneratedCaption]] = []
        for word in words {
            if let unit = units.last, let last = unit.last, !startsUnit(word, after: unit, last: last) {
                units[units.count - 1].append(word)
            } else {
                units.append([word])
            }
        }
        return units.flatMap(split)
    }

    private static func startsUnit(_ word: RAVEGeneratedCaption, after unit: [RAVEGeneratedCaption], last: RAVEGeneratedCaption) -> Bool {
        if last.speaker != word.speaker || word.start - last.end >= 0.7 { return true }
        // After a sentence. A short one ("Okay.") keeps the next with it, so it
        // doesn't flash by alone.
        return endsSentence(last.text) && unit.reduce(0) { $0 + $1.text.count } >= 24
    }

    private static let maxLineCharacters = 90
    private static let maxLineSeconds = 4.0

    private static func split(_ unit: [RAVEGeneratedCaption]) -> [RAVEGeneratedCaption] {
        func line(_ part: ArraySlice<RAVEGeneratedCaption>) -> RAVEGeneratedCaption {
            var text = part.first!.text.drop { $0.isWhitespace }.description
            for word in part.dropFirst() { text = join(text, word.text) }
            return .init(start: part.first!.start, end: part.map(\.end).max()!, text: text, speaker: part.first!.speaker)
        }
        let whole = line(unit[...])
        guard unit.count > 1, whole.text.count >= maxLineCharacters || whole.end - whole.start >= maxLineSeconds else { return [whole] }
        let parts = min(unit.count, max(Int((Double(whole.text.count) / Double(maxLineCharacters - 10)).rounded(.up)),
                                        Int(((whole.end - whole.start) / (maxLineSeconds - 0.3)).rounded(.up)), 2))
        // Characters up to and including each word.
        var through: [Int] = []
        var count = 0
        for word in unit { count += word.text.count; through.append(count) }
        var lines: [RAVEGeneratedCaption] = []
        var from = 0
        for part in 1..<parts {
            let target = Double(count) * Double(part) / Double(parts)
            // Break after word `index`, leaving a word for every part to come.
            var best = from
            var bestScore = Double.infinity
            for index in from ..< (unit.count - (parts - part)) {
                let clause = endsSentence(unit[index].text) || endsClause(unit[index].text)
                let score = abs(Double(through[index]) - target) - (endsSentence(unit[index].text) ? Double(count) * 0.4 : clause ? Double(count) * 0.12 : 0)
                if score < bestScore { bestScore = score; best = index }
            }
            lines.append(line(unit[from ... best]))
            from = best + 1
        }
        lines.append(line(unit[from...]))
        return lines
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let end = text.last(where: { !$0.isWhitespace }) else { return false }
        return ".?!…。？！".contains(end)
    }

    private static func endsClause(_ text: String) -> Bool {
        guard let end = text.last(where: { !$0.isWhitespace }) else { return false }
        return ",;:，、；".contains(end)
    }

    /// `a` and `b` as one line. The recognizer's runs carry a leading space
    /// ("Today", " we"), except a volatile guess's first word, which came out
    /// bare ("show." + "the headset": "show.the headset"). A space goes where
    /// neither side has one, but not where the text isn't written with spaces
    /// (Chinese, Japanese, Thai) or the next piece is closing punctuation.
    static func join(_ a: String, _ b: String) -> String {
        guard let tail = a.last, let head = b.first, !tail.isWhitespace, !head.isWhitespace,
              !".,!?;:)]}…%".contains(head), !"([{".contains(tail),
              !(tail.isUnspaced || head.isUnspaced) else { return a + b }
        return a + " " + b
    }

    /// A volatile guess's words with times. The recognizer gives the guess one
    /// range, which runs on past the speech (to wherever audio has been fed),
    /// so the words are spread at a speaking pace from its start, squeezed
    /// only if that would pass its end. A run that is one word, as every final
    /// word is, and text written without spaces stay as they are.
    static func timedWords(_ text: String, from start: Double, through end: Double) -> [RAVEGeneratedCaption] {
        var pieces: [String] = []
        var piece = ""
        var seenText = false
        for character in text {
            if character.isWhitespace, seenText { pieces.append(piece); piece = ""; seenText = false }
            piece.append(character)
            if !character.isWhitespace { seenText = true }
        }
        if !piece.isEmpty { pieces.append(piece) }
        guard pieces.count > 1, end > start else { return [.init(start: start, end: end, text: text, speaker: nil)] }
        let durations = pieces.map { 0.05 + 0.055 * Double($0.trimmingCharacters(in: .whitespaces).count) }
        let paced = durations.reduce(0, +)
        let scale = min(1, (end - start) / paced)
        var time = start
        return zip(pieces, durations).map { piece, duration in
            defer { time += duration * scale }
            return .init(start: time, end: time + duration * scale, text: piece, speaker: nil)
        }
    }

    private func overlap(_ segment: (start: Double, end: Double, id: Int), _ word: RAVEGeneratedCaption) -> Double {
        max(0, min(segment.end, word.end) - max(segment.start, word.start))
    }
    func advance(playhead: Double, rate: Double, duration: Double = .nan) async throws -> State {
        if let analysisError { throw CaptionFailure(analysisError) }
        // Bound both decoded audio and recognizer backlog. Never decode a movie
        // in full while paused. Audio ahead is cheap; full-resolution eyes aren't.
        let target = playhead + 8 * max(1, rate)
        var count = 0
        while !ended, fedThrough < target, fedThrough - analyzedThrough < 10 * max(1, rate), count < 16 {
            try Task.checkCancellation()
            let packet: CaptionAudioPacket?
            if let pull = externalPull {
                if let chunk = try await pull() { packet = CaptionAudioPacket(buffer: chunk.buffer, time: chunk.time) }
                else { packet = nil; ended = true }
            }
            else if let pull = hlsPull {
                packet = try pull()
                if packet == nil, duration.isFinite, duration > 0, fedThrough >= duration - 0.1 { ended = true }
            }
            else if let sample = output?.copyNextSampleBuffer() { packet = try Self.pcm(sample) }
            else {
                if let reader, reader.status == .failed { throw reader.error ?? CaptionFailure("Audio decoding failed.") }
                packet = nil
                if reader?.status == .completed { ended = true }
            }
            guard let packet else {
                if ended {
                    continuation?.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    if let diarizer, let update = try diarizer.finalizeSession() {
                        updateSpeakers(update, origin: speakerOrigin ?? begin)
                    }
                    analyzedThrough = fedThrough; speakerThrough = .infinity
                }
                break
            }
            if packet.restarted, fedThrough > begin + 0.05 { throw CaptionSequenceRestart.changed }
            count += 1
            guard packet.time + 0.05 >= begin else { continue }
            fedThrough = packet.time + Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
            guard let speechFormat else { break }
            let speech = try Self.convert(packet.buffer, to: speechFormat, converter: &converter)
            // Resampling may round a packet by one output sample. Keep
            // adjacent inputs non-overlapping using exact sample durations.
            let decodedTime = CMTime(seconds: packet.time, preferredTimescale: 1_000_000_000)
            let speechTime = speechEnd.map { CMTimeMaximum($0, decodedTime) } ?? decodedTime
            speechEnd = speechTime + CMTime(value: Int64(speech.frameLength), timescale: Int32(speechFormat.sampleRate))
            let input = AnalyzerInput(buffer: speech, bufferStartTime: speechTime)
            if case .dropped = continuation?.yield(input) { throw CaptionFailure("Speech recognition could not keep up.") }
            if let diarizer {
                speakerOrigin = speakerOrigin ?? packet.time
                let origin = speakerOrigin ?? begin
                let mono = try Self.convert(packet.buffer, to: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, converter: &speakerConverter)
                if let data = mono.floatChannelData {
                    if let update = try diarizer.process(samples: UnsafeBufferPointer(start: data[0], count: Int(mono.frameLength))) {
                        updateSpeakers(update, origin: origin)
                    }
                    speakerThrough = origin + Double(diarizer.timeline.finalizedDuration)
                }
            }
        }
        return State(captions: snapshot(near: playhead), readyThrough: min(analyzedThrough, speakerThrough),
                     audioThrough: fedThrough, finished: ended)
    }
    private func updateSpeakers(_ update: DiarizerTimelineUpdate, origin: Double) {
        let boundary = origin + Double(update.chunkResult.startFrame) * 0.08
        speakers.removeAll { $0.end >= boundary }
        speakers += (update.finalizedSegments + update.tentativeSegments).map {
            (origin + Double($0.startTime), origin + Double($0.endTime), $0.speakerIndex + 1)
        }
    }
    func cancel() async {
        continuation?.finish(); analysisTask?.cancel()
        reader?.cancelReading()
        await analyzer.cancelAndFinishNow()
    }
    private static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat, converter: inout AVAudioConverter?) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        if converter?.inputFormat != input.format || converter?.outputFormat != format { converter = AVAudioConverter(from: input.format, to: format) }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 64) else {
            throw CaptionFailure("Cannot convert decoded audio.")
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if result == .error { throw error ?? CaptionFailure("Audio conversion failed.") }
        return output
    }
    private static func pcm(_ sample: CMSampleBuffer) throws -> CaptionAudioPacket? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw CaptionFailure("Cannot read decoded audio (\(status)).") }
        return CaptionAudioPacket(buffer: buffer, time: CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds)
    }
    /// An HLS item feeds decoded audio only to the output it had at its latest
    /// seek: a second output, even one added after the first was removed, gets
    /// nothing until the item seeks again. So one output stays attached for the
    /// item's life, and a restart seeks the item to where it is, which resets
    /// that output to the playhead and drops what the last analysis read ahead.
    /// The seek is nudged 1 ms: a seek to exactly the current time is a no-op
    /// while paused and leaves the output where the last analysis stopped.
    @available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
    @MainActor private static func attachHLS(to item: AVPlayerItem) async -> @Sendable () throws -> CaptionAudioPacket? {
        let output: AVPlayerItemSampleBufferOutput
        if let attached = item.outputs.lazy.compactMap({ $0 as? AVPlayerItemSampleBufferOutput }).first {
            output = attached
            _ = await item.seek(to: item.currentTime() + CMTime(value: 1, timescale: 1000),
                                toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let configuration = AVPlayerItemSampleBufferOutputAudioConfiguration()
            configuration.requestedAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!.formatDescription
            output = AVPlayerItemSampleBufferOutput(configuration: configuration)
            // Keep AVPlayer rendering sound; this is an analysis copy only.
            item.add(output)
        }
        return {
            guard let next = output.nextAvailableSampleBuffer() else { return nil }
            var packet = try next.sampleBuffer.withUnsafeSampleBuffer { try pcm($0) }
            packet?.restarted = next.sequenceWasRestarted
            return packet
        }
    }
}

private extension Character {
    /// Written without spaces between words: Han, kana and Thai.
    var isUnspaced: Bool {
        guard let value = unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(value) || (0x3400...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x0E00...0x0E7F).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }
}
