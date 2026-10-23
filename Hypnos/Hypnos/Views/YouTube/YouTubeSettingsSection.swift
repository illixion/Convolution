/*
 Hypnos - YouTube settings (sideload builds only: `HYPNOS_YOUTUBE`)

 The account (signed in to YouTube's site on this device), the optional
 backend (web-yt-dlp) and SponsorBlock. Shared by every platform's Settings
 screen, like `JellyfinServerSection`. Absent until the YouTube tab's
 one-time approval (`YouTubeConsent`): there is nothing to set up before
 then, and no off switch after it, since leaving the tab alone sends
 nothing.
 */

#if HYPNOS_YOUTUBE

import SwiftUI


import RAVEUI
struct YouTubeSettingsSection: View {
    @Bindable private var backend = YouTubeBackend.shared
    @State private var tokenDraft = ""
    @AppStorage(SponsorBlock.enabledKey) private var sponsorBlockEnabled = true
    @AppStorage(YouTubeQuality.defaultsKey) private var quality: YouTubeQuality = .auto
    @State private var categoryModes: [SponsorBlockCategory: SponsorBlockCategory.Mode] =
        Dictionary(uniqueKeysWithValues: SponsorBlockCategory.allCases.map { ($0, $0.mode) })
    @State private var account = YouTubeAccount.shared
    @State private var browser: YouTubeBrowserPurpose?
    @AppStorage(YouTubeConsent.defaultsKey) private var consentGranted = false

    var body: some View {
        if consentGranted {
            sections
        }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            // The one row that is always there carries the sheet and the
            // check, so neither goes away when the account changes.
            LabeledContent("Account", value: account.isSignedIn == true ? "Signed in" : "Signed out")
                .task { await account.refresh() }
                .youTubeBrowser($browser) {
                    Task { await account.refresh() }
                }
            if account.isSignedIn == true {
                Button("Sign Out", role: .destructive) {
                    Task { await account.signOut() }
                }
            } else {
                Button("Sign In to YouTube…") { browser = .signIn }
            }
        } header: {
            Text("YouTube Account")
        } footer: {
            Text("Signing in adds your home page, subscriptions, Watch Later and history to the YouTube tab. They come from YouTube's own site, which keeps the account in this device's web storage; videos still play signed out. Signing out forgets it here; Google lists the session under your account's devices until you remove it there.")
        }

        Section {
            TextField("Backend (https://host/yt)", text: $backend.endpoint)
                .textFieldTapTarget()
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField(backend.hasToken ? "Token (saved)" : "Token", text: $tokenDraft)
                .textFieldTapTarget()
                .onSubmit(saveToken)
            if !tokenDraft.isEmpty {
                Button("Save Token", action: saveToken)
            } else if backend.hasToken {
                Button("Remove Token", role: .destructive) { backend.token = "" }
            }
            Toggle("Surround Sound from Backend", isOn: $backend.prefersSurround)
                .disabled(!backend.isConfigured)
            #if os(tvOS)
            // tvOS: checkmarked rows, never a Picker (see TVSettingsView).
            ForEach(YouTubeQuality.allCases) { level in
                Button {
                    quality = level
                } label: {
                    HStack {
                        Text("Picture Quality: \(level.title)")
                        Spacer()
                        if level == quality { Image(systemName: "checkmark") }
                    }
                }
            }
            #else
            Picker("Picture Quality", selection: $quality) {
                ForEach(YouTubeQuality.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            #endif
        } header: {
            Text("YouTube")
        } footer: {
            Text("Videos play from YouTube directly on this device. A web-yt-dlp backend is optional: it adds 5.1 surround sound where YouTube has it, and plays videos the device can't, such as ones made for kids. Picture Quality is what a video opens at, or the nearest below it the video has; the player's Quality menu lists each video's own. Auto takes the best the connection allows and lowers it if 3D can't keep up.")
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
