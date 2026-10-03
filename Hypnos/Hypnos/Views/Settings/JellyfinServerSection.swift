/*
 Hypnos - Jellyfin server settings (all platforms)

 Server address, username/password sign-in, and an API-key fallback for
 anyone who'd rather paste a key than sign in. Shared by every platform's
 Settings screen (`SettingsTabView` on visionOS/iOS, `TVSettingsView`,
 `MacSettingsView`) — the same Jellyfin server config file/keychain entries
 back both the Library tab and the older Film Player tuning controls
 (`FilmPlayerSection`), via `FilmSession.shared`.

 Sign-in matters beyond convenience: watch-progress reporting
 (`JellyfinLibrary.reportPlaybackProgress` etc., `/Sessions/Playing*`) has
 been confirmed to silently no-op against a plain API key — Jellyfin's
 session manager needs a real signed-in session to attribute the report to
 (see `scripts/dev-jellyfin.sh`'s `session_token`/Hypnos/CLAUDE.md's
 "Library feature dev data" section for how that was found). API-key mode
 still works for browsing; it just won't sync watch state reliably.
 */

import SwiftUI

struct JellyfinServerSection: View {
    @Bindable private var session = FilmSession.shared
    @Bindable private var auth = JellyfinAuth.shared
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Section {
            TextField("Server (https://host/jellyfin)", text: $session.server)
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            if let user = auth.session {
                #if os(tvOS)
                // Its own row: a trailing button is off the focus engine's
                // path when moving down the list.
                Label("Signed in as \(user.userName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Sign Out") { auth.signOut(revokingOn: URL(string: session.server)) }
                #else
                HStack {
                    Label("Signed in as \(user.userName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out") { auth.signOut(revokingOn: URL(string: session.server)) }
                }
                #endif
            } else {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $password)
                Button("Sign In") {
                    Task { await signIn() }
                }
                .disabled(auth.isAuthenticating || session.server.isEmpty || username.isEmpty || password.isEmpty)

                if auth.isAuthenticating {
                    Text("Signing in…").font(.caption).foregroundStyle(.secondary)
                }
                if let error = auth.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                platformDisclosureGroup("Use an API key instead") {
                    SecureField("API key", text: $session.apiKey)
                    Text("Browsing works with just a key. Watch-progress sync (resume points, played/unplayed) needs a signed-in user, so it won't update reliably in this mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Jellyfin Server")
        } footer: {
            Text("Powers the Library tab and Film Player. Needs the Convolution Object Audio plugin on the server for a film's object audio; other items play through direct/transcoded streaming.")
        }
    }

    private func signIn() async {
        guard let url = URL(string: session.server) else { return }
        await auth.signIn(serverURL: url, username: username, password: password)
        if auth.session != nil {
            password = ""
        }
    }
}
