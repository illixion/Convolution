/*
 Hypnos - the Translate sheet of the subtitle menu (iOS and macOS only; see
 `SubtitleTranslation.swift` for why not visionOS and tvOS)

 Pick what to translate (the video's YouTube automatic captions, or AI
 Captions), the language it is spoken in, and the language to read it in
 (Settings → AI Captions → Translate To sets what this starts with).
 Languages the system hasn't downloaded yet are fetched here through
 `.translationTask`, which shows Apple's own consent prompt.
 */

#if os(iOS) || os(macOS)

import Speech
import SwiftUI
import Translation

struct SubtitleTranslateSheet: View {
    let controller: SubtitleController
    @Environment(\.dismiss) private var dismiss

    @State private var captions: SubtitleTranslationRequest.Captions = .ai
    @State private var speechLocales: [Locale] = []
    @State private var speechLocale = ""
    @State private var languages: [Locale.Language] = []
    @State private var target: Locale.Language?
    @State private var configuration: TranslationSession.Configuration?
    @State private var request: SubtitleTranslationRequest?
    @State private var isWorking = false
    @State private var errorText: String?

    private var hasAuto: Bool { controller.hasAutoCaptions }
    private var hasAI: Bool { controller.canGenerate }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Captions", selection: $captions) {
                        if hasAuto { Text("YouTube Auto Captions").tag(SubtitleTranslationRequest.Captions.youTubeAuto) }
                        if hasAI { Text("AI Captions").tag(SubtitleTranslationRequest.Captions.ai) }
                    }
                    if captions == .youTubeAuto {
                        LabeledContent("From", value: autoLanguageName)
                    } else {
                        Picker("From", selection: $speechLocale) {
                            ForEach(speechLocales, id: \.identifier) { locale in
                                Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                    .tag(locale.identifier)
                            }
                        }
                    }
                    Picker("To", selection: Binding(get: { target }, set: { target = $0 })) {
                        ForEach(languages, id: \.self) { language in
                            Text(SubtitleTranslationSupport.name(of: language)).tag(Optional(language))
                        }
                    }
                } footer: {
                    Text(captions == .youTubeAuto
                         ? "YouTube's automatic captions are translated on this device, nearest the playhead first."
                         : "AI Captions are recognized and translated on this device while the video plays. Set the default language in Settings.")
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Translate Subtitles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { begin() } label: {
                        if isWorking { ProgressView().controlSize(.small) } else { Text("Translate") }
                    }
                    .disabled(isWorking || target == nil || sourceLanguage == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
        .task { await load() }
        .translationTask(configuration) { session in
            // The languages are not on the device yet: the system asks, then
            // downloads them.
            await prepare(session)
        }
    }

    private var autoLanguageName: String {
        controller.autoCaptionLanguage.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 } ?? "Unknown"
    }

    private var sourceLanguage: Locale.Language? {
        switch captions {
        case .youTubeAuto: controller.autoCaptionLanguage.map { Locale.Language(identifier: $0) }
        case .ai: speechLocale.isEmpty ? nil : Locale.Language(identifier: speechLocale)
        }
    }

    private func load() async {
        captions = hasAuto ? .youTubeAuto : .ai
        languages = await SubtitleTranslationSupport.supportedLanguages()
        target = SubtitleTranslationSupport.target(in: languages)
        speechLocales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
        let saved = UserDefaults.standard.string(forKey: "captions.locale") ?? Locale.preferredLanguages.first ?? "en-US"
        let wanted = Locale(identifier: saved)
        speechLocale = speechLocales.first { $0.identifier == wanted.identifier }?.identifier
            ?? speechLocales.first { $0.language.languageCode == wanted.language.languageCode }?.identifier
            ?? speechLocales.first?.identifier ?? ""
    }

    private func begin() {
        guard let source = sourceLanguage, let target else { return }
        errorText = nil
        isWorking = true
        let chosen = SubtitleTranslationRequest(captions: captions, source: source,
                                                speechLocale: captions == .ai ? speechLocale : nil, target: target)
        request = chosen
        Task {
            switch await LanguageAvailability().status(from: source, to: target) {
            case .installed:
                finish()
            case .supported:
                configuration = TranslationSession.Configuration(source: source, target: target)
            case .unsupported:
                errorText = "\(SubtitleTranslationSupport.name(of: source)) to \(SubtitleTranslationSupport.name(of: target)) isn't available."
                isWorking = false
            @unknown default:
                isWorking = false
            }
        }
    }

    @MainActor
    private func prepare(_ session: sending TranslationSession) async {
        do {
            try await session.prepareTranslation()
            finish()
        } catch {
            errorText = error.localizedDescription
            isWorking = false
        }
    }

    private func finish() {
        guard let request else { return }
        do {
            try controller.translator.start(request, controller: controller)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        isWorking = false
    }
}

#endif
