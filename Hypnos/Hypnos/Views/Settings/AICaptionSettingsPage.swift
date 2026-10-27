import GeneratedCaptions
import Speech
import SwiftUI

struct AICaptionSettingsPage: View {
    @AppStorage("captions.locale") private var locale = Locale.preferredLanguages.first ?? "en-US"
    @AppStorage("captions.speakers") private var speakers = true
    @State private var locales: [Locale] = []
    var body: some View {
        SettingsPage("AI Captions") {
            Section {
                #if os(tvOS)
                ForEach(locales, id: \.identifier) { language in
                    Button {
                        locale = language.identifier
                    } label: {
                        HStack {
                            Text(Locale.current.localizedString(forIdentifier: language.identifier) ?? language.identifier)
                            Spacer()
                            if locale == language.identifier { Image(systemName: "checkmark") }
                        }
                    }
                }
                #else
                Picker("Spoken Language", selection: $locale) {
                    if !locales.contains(where: { $0.identifier == locale }) {
                        Text(Locale.current.localizedString(forIdentifier: locale) ?? locale).tag(locale)
                    }
                    ForEach(locales, id: \.identifier) { language in
                        Text(Locale.current.localizedString(forIdentifier: language.identifier) ?? language.identifier)
                            .tag(language.identifier)
                    }
                }
                #endif
                Toggle("Label Speakers", isOn: $speakers)
                    .disabled(!RAVESpeakerModel.shared.isInstalled)
            } footer: {
                Text("Choose AI Captions in a video's subtitle menu. Speech is recognized on this device. Apple downloads the selected language on first use. Language and speaker settings apply the next time AI Captions starts.")
            }
            SpeakerModelSection()
            Section {
                Text("Audio is analyzed ahead of the picture. Playback may briefly buffer both sound and picture to let captions catch up. Live streams need enough buffered audio and require OS 27 or later.")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            locales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
            let preferred = UserDefaults.standard.string(forKey: "captions.locale")
                ?? Locale.preferredLanguages.first ?? Locale.current.identifier
            if let match = matchingLocale(preferred, in: locales)
                ?? matchingLocale(Locale.current.identifier, in: locales)
                ?? matchingLocale("en-US", in: locales) {
                locale = match.identifier
            } else if let first = locales.first {
                locale = first.identifier
            }
        }
    }

    private func matchingLocale(_ identifier: String, in locales: [Locale]) -> Locale? {
        if let exact = locales.first(where: { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }) {
            return exact
        }
        let preferred = Locale.Language(identifier: identifier)
        guard let language = preferred.languageCode?.identifier(.alpha2) else { return nil }
        let candidates = locales.filter {
            Locale.Language(identifier: $0.identifier).languageCode?.identifier(.alpha2) == language
        }
        if let script = preferred.script?.identifier,
           let scriptMatch = candidates.first(where: { Locale.Language(identifier: $0.identifier).script?.identifier == script }) {
            return scriptMatch
        }
        return candidates.first
    }
}

/// Shared with the existing AI 3D model manager: one install/delete workflow.
struct SpeakerModelSection: View {
    @State private var model = RAVESpeakerModel.shared
    @State private var confirmDelete = false
    var body: some View {
        Section {
            if let progress = model.progress {
                ProgressView(value: progress) { Text("Downloading Speaker Labels…") }
                Button("Cancel Download") { model.cancel() }
            } else if model.isInstalled {
                LabeledContent("Speaker Labels", value: "Installed")
                Button("Delete Speaker Model", role: .destructive) { confirmDelete = true }
                    .disabled(model.isInUse)
            } else {
                Button("Download Speaker Labels (97 MB)") { model.download() }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            Link("Model details and license", destination: URL(string: "https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml")!)
        } header: { Text("Speaker Model") }
        footer: {
            Text("Optional download from FluidInference on Hugging Face. Labels up to four speakers. Close AI Captions before deleting an in-use model. No computer or model conversion is needed. " + RAVESpeakerModel.attribution)
        }
        .confirmationDialog("Delete the speaker model?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete() }
        }
    }
}
