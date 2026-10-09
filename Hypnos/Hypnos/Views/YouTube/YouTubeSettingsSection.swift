/*
 Hypnos - YouTube settings (sideload builds only: `HYPNOS_YOUTUBE`)

 The optional backend (web-yt-dlp) and SponsorBlock. Shared by every
 platform's Settings screen, like `JellyfinServerSection`.
 */

#if HYPNOS_YOUTUBE

import SwiftUI

struct YouTubeSettingsSection: View {
    @Bindable private var backend = YouTubeBackend.shared
    @State private var tokenDraft = ""
    @AppStorage(SponsorBlock.enabledKey) private var sponsorBlockEnabled = true
    @State private var categoryModes: [SponsorBlockCategory: SponsorBlockCategory.Mode] =
        Dictionary(uniqueKeysWithValues: SponsorBlockCategory.allCases.map { ($0, $0.mode) })

    var body: some View {
        Section {
            TextField("Backend (https://host/yt)", text: $backend.endpoint)
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField(backend.hasToken ? "Token (saved)" : "Token", text: $tokenDraft)
                .onSubmit(saveToken)
            if !tokenDraft.isEmpty {
                Button("Save Token", action: saveToken)
            } else if backend.hasToken {
                Button("Remove Token", role: .destructive) { backend.token = "" }
            }
            Toggle("Surround Sound from Backend", isOn: $backend.prefersSurround)
                .disabled(!backend.isConfigured)
        } header: {
            Text("YouTube")
        } footer: {
            Text("Videos play from YouTube directly on this device. A web-yt-dlp backend is optional: it adds 5.1 surround sound where YouTube has it, and plays videos the device can't, such as ones made for kids.")
        }

        Section {
            Toggle("SponsorBlock", isOn: $sponsorBlockEnabled)
            if sponsorBlockEnabled {
                ForEach(SponsorBlockCategory.allCases) { category in
                    Picker(category.displayName, selection: modeBinding(category)) {
                        ForEach(SponsorBlockCategory.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
            }
        } footer: {
            Text("Skips sponsor reads and other segments marked by the SponsorBlock community. Only a short prefix of the video's hash is sent, so SponsorBlock can't tell which video you're watching.")
        }
    }

    private func modeBinding(_ category: SponsorBlockCategory) -> Binding<SponsorBlockCategory.Mode> {
        Binding(
            get: { categoryModes[category] ?? category.mode },
            set: { category.mode = $0; categoryModes[category] = $0 }
        )
    }

    private func saveToken() {
        guard !tokenDraft.isEmpty else { return }
        backend.token = tokenDraft
        tokenDraft = ""
    }
}

#endif
