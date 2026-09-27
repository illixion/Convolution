/*
 Hypnos - Nextcloud Settings Section

 Connect a Nextcloud server and choose which folder its library reads from.

 Sign-in is Login Flow v2: the user approves in the server's own web login, so
 the app never handles the account password and 2FA / SSO work unchanged. What
 comes back is a per-device app password, revocable from the server's
 Settings → Security under the name in `loginUserAgent` below.

 The root is a dropdown of the server's actual folders rather than a text
 field, because a typed path can only be guessed at and a wrong guess reads as
 an empty library rather than an error. It matters more than it looks: an
 unscoped search returns every image the account can see, which on a server
 that also hosts music means thousands of album-art JPEGs mixed into the
 photos.
 */

import NextcloudMedia
import SwiftUI

struct NextcloudSettingsSection: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    /// Shown to the user on the server's app-password list, so it needs to say
    /// what it is without further context.
    private static let loginUserAgent = "Hypnos (Apple Vision Pro)"

    private enum SignInState: Equatable {
        case idle
        case starting
        case awaitingApproval(URL)
        case failed(String)
    }

    @State private var signInState: SignInState = .idle
    @State private var signInTask: Task<Void, Never>?

    @State private var folders: [NextcloudFolder] = []
    @State private var isLoadingFolders = false
    @State private var folderError: String?

    @State private var verifyResult: String?

    var body: some View {
        @Bindable var appModel = appModel

        Section {
            if appModel.hasNextcloudServer {
                signedInRows
            } else {
                signedOutRows(appModel: appModel)
            }
        } header: {
            Text("Nextcloud")
        } footer: {
            Text("Browse a Nextcloud server's photos and videos. Signing in opens your server's own login page — Hypnos never sees your password, and the access it gets is listed under Settings → Security on the server, where you can revoke it.")
        }
        // Keyed on the server so the list refreshes when one is signed into or
        // replaced, rather than only on the sign-in that happened to be
        // performed from this screen.
        .task(id: appModel.nextcloudServerURL) {
            guard appModel.hasNextcloudServer else { return }
            await loadFolders()
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private func signedOutRows(appModel: AppModel) -> some View {
        @Bindable var appModel = appModel

        TextField("Server URL", text: $appModel.nextcloudServerURL)
            .textFieldStyle(.plain)
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            #endif
            #if !os(macOS)
            .keyboardType(.URL)
            #endif
            .disabled(signInState == .starting)

        switch signInState {
        case .idle, .failed:
            Button("Sign In") { startSignIn() }
                .disabled(appModel.nextcloudServerURL.trimmingCharacters(in: .whitespaces).isEmpty)

        case .starting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Contacting server…").foregroundStyle(.secondary)
            }

        case .awaitingApproval(let loginURL):
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for approval in your browser…").foregroundStyle(.secondary)
            }
            // The browser window can be dismissed or opened in the wrong place,
            // and the flow stays valid for about twenty minutes — so offer the
            // link again rather than making the user restart sign-in.
            Button("Open Login Page Again") { openURL(loginURL) }
            Button("Cancel", role: .cancel) { cancelSignIn() }
        }

        if case .failed(let message) = signInState {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var signedInRows: some View {
        LabeledContent("Signed in as", value: appModel.nextcloudUsername)
        LabeledContent("Server", value: displayServer)

        rootPicker

        if let folderError {
            Text(folderError)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Test Connection") { verify() }
        if let verifyResult {
            Text(verifyResult)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Sign Out", role: .destructive) { signOut() }
    }

    @ViewBuilder
    private var rootPicker: some View {
        @Bindable var appModel = appModel

        if isLoadingFolders && folders.isEmpty {
            HStack {
                Text("Library Folder")
                Spacer()
                ProgressView().controlSize(.small)
            }
        } else {
            #if os(tvOS)
            // Checkmarked rows rather than a Picker, as in `TVSettingsView`.
            ForEach([""] + rootOptions, id: \.self) { path in
                Button {
                    appModel.nextcloudRoot = path
                } label: {
                    HStack {
                        Text(path.isEmpty ? "All files" : label(forFolder: path))
                        Spacer()
                        if path == appModel.nextcloudRoot { Image(systemName: "checkmark") }
                    }
                }
            }
            #else
            Picker("Library Folder", selection: $appModel.nextcloudRoot) {
                Text("All files").tag("")
                ForEach(rootOptions, id: \.self) { path in
                    Text(label(forFolder: path)).tag(path)
                }
            }
            #endif
        }

        Text("Only this folder is searched. Pointing at the whole account pulls in anything else that happens to be an image — album art from a music library, most commonly.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Top-level folder paths, with the configured root kept in the list even
    /// when it isn't one of them.
    ///
    /// Without that a nested root (or one on a server that hasn't listed yet)
    /// would match no tag, and SwiftUI renders a Picker with no matching tag as
    /// blank — which reads as "no folder selected" when a folder very much is.
    private var rootOptions: [String] {
        var paths = folders.map(\.path)
        let current = appModel.nextcloudRoot
        if !current.isEmpty && !paths.contains(current) {
            paths.append(current)
        }
        return paths
    }

    /// Folder name with its size, when the server reported one.
    ///
    /// Worth the noise: a real account lists the media folder next to several
    /// empty ones (`Shared`, a stray project folder), and the names alone give
    /// no way to tell which holds 174 GB of photos and which holds nothing.
    private func label(forFolder path: String) -> String {
        guard let bytes = folders.first(where: { $0.path == path })?.totalBytes, bytes > 0 else {
            return path
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(path) — \(size)"
    }

    private var displayServer: String {
        URL(string: appModel.nextcloudServerURL)?.host ?? appModel.nextcloudServerURL
    }

    // MARK: - Actions

    private func startSignIn() {
        signInState = .starting
        verifyResult = nil
        let serverURL = appModel.nextcloudServerURL

        signInTask?.cancel()
        signInTask = Task {
            let flow = NextcloudLoginFlow(userAgent: Self.loginUserAgent)
            do {
                let session = try await flow.begin(serverURL: serverURL)
                guard !Task.isCancelled else { return }
                signInState = .awaitingApproval(session.loginURL)
                openURL(session.loginURL)

                let credentials = try await flow.awaitApproval(session)
                guard !Task.isCancelled else { return }

                // The server's own spelling of its address, which can differ
                // from what was typed (scheme added, trailing slash dropped,
                // `overwritehost` applied). Persisting that one keeps the host
                // matching what requests actually go out to — and so matching
                // the credential MediaAuthorization registers by host.
                appModel.nextcloudServerURL = credentials.server
                appModel.nextcloudUsername = credentials.loginName
                appModel.nextcloudAppPassword = credentials.appPassword
                signInState = .idle
                await loadFolders()
            } catch is CancellationError {
                signInState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                signInState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInState = .idle
    }

    private func signOut() {
        cancelSignIn()
        // Clearing the password alone would be enough to make
        // `hasNextcloudServer` false, but it would leave a host registered
        // with a stale credential and the URL sitting in the field looking
        // connected. The observers drop the credential and rebuild sources.
        appModel.nextcloudAppPassword = ""
        appModel.nextcloudUsername = ""
        appModel.nextcloudServerURL = ""
        folders = []
        folderError = nil
        verifyResult = nil
    }

    private func loadFolders() async {
        guard let client = appModel.nextcloudClient else { return }
        isLoadingFolders = true
        folderError = nil
        defer { isLoadingFolders = false }
        do {
            // Listed from the account root, not the current root: this is the
            // control for *changing* which folder the library reads, so it has
            // to show the alternatives rather than what's inside the choice
            // already made.
            folders = try await client.folders(in: "")
        } catch {
            folders = []
            folderError = "Could not list folders: \(error.localizedDescription)"
        }
    }

    private func verify() {
        verifyResult = nil
        guard let client = appModel.nextcloudClient else { return }
        Task {
            do {
                let count = try await client.verify()
                verifyResult = count > 0
                    ? "Connected — found media in this folder."
                    : "Connected, but this folder has no photos or videos in it."
            } catch {
                verifyResult = error.localizedDescription
            }
        }
    }
}
