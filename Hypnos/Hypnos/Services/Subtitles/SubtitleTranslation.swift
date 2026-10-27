/*
 Hypnos - translated subtitles (iOS and macOS only)

 Apple's Translation framework is unavailable on visionOS and tvOS (checked
 against the 27.0 SDKs, 2026-10-27), so the feature exists only where it
 can run; `SubtitleTranslator` is a no-op shell elsewhere so the controller
 needs no `#if`.

 What is translated is a *source* the viewer picks in the Translate sheet:
 - a YouTube video's automatic captions (the whole track, read once), or
 - AI Captions, which grow while the film plays.
 Either way the source cues are translated a batch at a time, nearest the
 playhead first, and the translated track is republished after each batch.
 Translations are cached by source text, so AI Captions' revisions and
 repeats cost nothing the second time.

 The languages are downloaded by the system in the sheet
 (`.translationTask` + `prepareTranslation`, which shows Apple's consent
 UI); the translating itself runs headless on a
 `TranslationSession(installedSource:target:)`.
 */

import DebugTrace
import Foundation
import Observation
import RAVEUI

#if os(iOS) || os(macOS)
import GeneratedCaptions
import Translation
#endif

/// The viewer's choices in the Translate sheet.
struct SubtitleTranslationRequest {
    enum Captions { case youTubeAuto, ai }
    var captions: Captions
    var source: Locale.Language
    /// AI Captions only: the speech locale to recognize, as `captions.locale` holds it.
    var speechLocale: String?
    var target: Locale.Language
}

@MainActor
@Observable
final class SubtitleTranslator {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Source cues already translated, and how many there are so far.
    private(set) var translatedCount = 0
    private(set) var sourceCount = 0

    var isActive: Bool { phase != .idle }

    #if os(iOS) || os(macOS)
    private struct SourceCue {
        var start: Double
        var end: Double
        var text: String
        var prefix: String
    }

    @ObservationIgnored private weak var controller: SubtitleController?
    @ObservationIgnored private var session: TranslationSession?
    @ObservationIgnored private var track: LibrarySubtitleTrack?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var loader: Task<Void, Never>?
    @ObservationIgnored private var sources: [SourceCue] = []
    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored private var inflight: Set<String> = []

    private static let batchSize = 40
    private static let speechLocaleKey = "captions.locale"

    /// Starts translating. The languages must be installed already
    /// (`SubtitleTranslationSupport.status`), or this throws.
    func start(_ request: SubtitleTranslationRequest, controller: SubtitleController) throws {
        stop()
        let session = try TranslationSession(installedSource: request.source, target: request.target)
        self.controller = controller
        self.session = session
        let title = Locale.current.localizedString(forIdentifier: request.target.minimalIdentifier) ?? request.target.minimalIdentifier
        let track = LibrarySubtitleTrack(id: -20000, sourceId: "translated", language: nil, name: "Translated to \(title)")
        self.track = track
        phase = .running
        translatedCount = 0
        sourceCount = 0
        controller.beginTranslated(track)

        switch request.captions {
        case .youTubeAuto:
            loader = Task { [weak self] in
                do {
                    let cues = try await controller.autoCaptionCues()
                    guard let self, !Task.isCancelled else { return }
                    self.setSources(cues.map { SourceCue(start: $0.start, end: $0.end, text: $0.plainText, prefix: "") })
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.fail(error)
                }
            }
        case .ai:
            // `RAVEGeneratedCaptions.start` reads the speech locale before it
            // does anything else: lend it the sheet's choice for that call.
            let defaults = UserDefaults.standard
            let previous = defaults.string(forKey: Self.speechLocaleKey)
            if let speech = request.speechLocale { defaults.set(speech, forKey: Self.speechLocaleKey) }
            controller.generated.start()
            if previous != nil { defaults.set(previous, forKey: Self.speechLocaleKey) } else { defaults.removeObject(forKey: Self.speechLocaleKey) }
        }
    }

    func stop() {
        worker?.cancel()
        loader?.cancel()
        worker = nil
        loader = nil
        session?.cancel()
        session = nil
        track = nil
        sources = []
        cache = [:]
        inflight = []
        phase = .idle
        translatedCount = 0
        sourceCount = 0
    }

    /// AI Captions changed (new lines, or the last one revised).
    func generatedChanged(_ captions: [RAVEGeneratedCaption]) {
        guard track != nil, loader == nil else { return }
        setSources(captions.map {
            SourceCue(start: $0.start, end: $0.end, text: $0.text, prefix: $0.speaker.map { "Speaker \($0): " } ?? "")
        })
    }

    private func setSources(_ new: [SourceCue]) {
        sources = new
        sourceCount = new.count
        publish()
        pump()
    }

    private func pump() {
        guard worker == nil, session != nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, let session = self.session {
                let box = SessionBox(session: session)
                let batch = self.nextBatch()
                if batch.isEmpty { break }
                self.inflight.formUnion(batch)
                do {
                    let translated = try await Self.translate(batch, with: box)
                    guard !Task.isCancelled else { return }
                    for (source, target) in translated { self.cache[source] = target }
                    self.inflight.subtract(batch)
                    self.publish()
                } catch {
                    self.inflight.subtract(batch)
                    if !Task.isCancelled { self.fail(error) }
                    self.worker = nil
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.worker = nil
            // Lines that arrived while the last batch was out.
            if self.hasPending { self.pump() }
        }
    }

    /// The session is only ever used one batch at a time, from the worker.
    private struct SessionBox: @unchecked Sendable { let session: TranslationSession }

    private nonisolated static func translate(_ texts: [String], with box: SessionBox) async throws -> [String: String] {
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $1, clientIdentifier: String($0))
        }
        var result: [String: String] = [:]
        for response in try await box.session.translations(from: requests) {
            if let index = response.clientIdentifier.flatMap(Int.init), texts.indices.contains(index) {
                result[texts[index]] = response.targetText
            }
        }
        return result
    }

    /// Text with no letters ("♪", "...") is shown as it is: the framework
    /// refuses a request with nothing to translate.
    private static func needsTranslating(_ text: String) -> Bool {
        text.contains { $0.isLetter }
    }

    private var hasPending: Bool {
        sources.contains { cache[$0.text] == nil && !inflight.contains($0.text) }
    }

    private func nextBatch() -> [String] {
        let playhead = controller?.playhead() ?? 0
        var seen = Set<String>()
        let pending = sources
            .filter { cache[$0.text] == nil && !inflight.contains($0.text) }
            .sorted { Self.distance($0.start, from: playhead) < Self.distance($1.start, from: playhead) }
        var batch: [String] = []
        for cue in pending where seen.insert(cue.text).inserted {
            if Self.needsTranslating(cue.text) {
                batch.append(cue.text)
                if batch.count == Self.batchSize { break }
            } else {
                cache[cue.text] = cue.text
            }
        }
        return batch
    }

    /// What is ahead of the playhead comes first, in order; then what is behind.
    private static func distance(_ start: Double, from playhead: Double) -> Double {
        start >= playhead - 5 ? start - playhead : 1_000_000 + (playhead - start)
    }

    private func publish() {
        guard let controller, let track, controller.selected == track else { return }
        let cues = sources.compactMap { cue -> RAVESubtitleCue? in
            guard let translated = cache[cue.text] else { return nil }
            return RAVESubtitleCue(start: cue.start, end: cue.end, text: AttributedString(cue.prefix + translated))
        }
        translatedCount = cues.count
        controller.showTranslated(RAVESubtitleTrack(cues: cues))
    }

    private func fail(_ error: Error) {
        AppLogger.subtitles.error("Subtitle translation failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        worker?.cancel()
        worker = nil
        phase = .failed(error.localizedDescription)
    }
    #else
    func start(_ request: SubtitleTranslationRequest, controller: SubtitleController) throws {}
    func stop() {}
    #endif
}

#if os(iOS) || os(macOS)
/// Where translation can run, which languages it offers and the viewer's
/// destination (Settings → AI Captions → Translate To).
enum SubtitleTranslationSupport {
    /// `UserDefaults` key; empty means the system's language.
    static let targetKey = "translation.target"

    static var systemLanguage: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// The supported language closest to `wanted`: same code and region, else
    /// same code and script, else the first with the same code.
    static func bestMatch(for wanted: Locale.Language, in languages: [Locale.Language]) -> Locale.Language? {
        if let exact = languages.first(where: { $0 == wanted }) { return exact }
        let code = wanted.languageCode
        let sameCode = languages.filter { $0.languageCode == code }
        return sameCode.first { $0.region == wanted.region && wanted.region != nil }
            ?? sameCode.first { $0.script == wanted.script && wanted.script != nil }
            ?? sameCode.first
    }

    /// The saved destination, or the system's, among `languages`.
    static func target(in languages: [Locale.Language]) -> Locale.Language? {
        let saved = UserDefaults.standard.string(forKey: targetKey) ?? ""
        let wanted = saved.isEmpty ? systemLanguage : Locale.Language(identifier: saved)
        return bestMatch(for: wanted, in: languages) ?? bestMatch(for: systemLanguage, in: languages)
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages.sorted { name(of: $0) < name(of: $1) }
    }
}
#endif
