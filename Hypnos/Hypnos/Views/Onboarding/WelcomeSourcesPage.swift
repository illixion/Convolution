/*
 Hypnos - Welcome Sources Page

 The second welcome screen: three ways to give the app something to show.

 They are deliberately **peers**, not a ranked funnel with a "skip" underneath.
 The app is equally at home converting the photos already on the device, acting
 as a client for a Stash server, or being restored from a backup of a previous
 install — and which of those a given person came for is not knowable here. So
 each is a card with its own affordance, any number can be completed, and the
 flow ends when the user says it does. Choosing one does not dismiss the screen,
 because someone restoring a backup very often also wants to grant photo access.

 The server fields are held as a **local draft** and written to `AppModel` only
 once the server answers. Binding them straight to the model, as the Settings
 tab does, would fire `stashServerURL`'s observer on every keystroke — each one
 rebuilding the sources and kicking a gallery reload against a half-typed URL.
 Tolerable when editing a working server; not something to do while someone
 types their first one.
 */

import Photos
import SwiftUI

import RAVEUI
struct WelcomeSourcesPage: View {
    @Environment(AppModel.self) private var appModel

    let onSourceConfigured: () -> Void

    /// Cached so the card re-renders after a grant; the live status is a
    /// synchronous PhotoKit read and would not itself trigger an update.
    @State private var photosStatus = PhotosAuthorization.status
    @State private var isRequestingPhotos = false

    @State private var isServerExpanded = false
    @State private var draftServerURL = ""
    @State private var draftAPIKey = ""
    @State private var serverState = ServerState.idle

    @State private var backupImporter = SettingsBackupImporter()

    private enum ServerState: Equatable {
        case idle
        case connecting
        case connected(Int)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Where should we look?")
                    .font(.system(size: 30, weight: .semibold))
                Text("Set up as many as you like — you can change any of this later in Settings.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                VStack(spacing: 16) {
                    // Identified on the containers, not the buttons inside
                    // them: a card whose source is already set up shows a
                    // status line and no button at all, and "all three options
                    // are offered as peers" is the claim this screen makes.
                    photosCard
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(A11y.Welcome.photosCard)
                    serverCard
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(A11y.Welcome.serverCard)
                    backupCard
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(A11y.Welcome.backupCard)
                }
                .frame(maxWidth: 720)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            draftServerURL = appModel.stashServerURL
            draftAPIKey = appModel.stashAPIKey
        }
        .settingsBackupImport(backupImporter) {
            onSourceConfigured()
        }
    }

    // MARK: - Photos

    private var photosCard: some View {
        WelcomeSetupCard(
            symbol: "photo.on.rectangle.angled",
            title: "Your Photos",
            summary: "Browse the library on this device and convert anything in it.",
            isDone: PhotosAuthorization.isReadable(photosStatus)
        ) {
            switch photosStatus {
            case .authorized:
                statusLine("Full library access granted", symbol: "checkmark.circle.fill", tint: .green)
            case .limited:
                statusLine("Access limited to the photos you picked", symbol: "checkmark.circle", tint: .yellow)
                Text("Choose more any time in Settings → Privacy & Security → Photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .denied, .restricted:
                statusLine("Access denied", symbol: "xmark.circle", tint: .red)
                Text("Grant access in Settings → Privacy & Security → Photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Button {
                    Task { await requestPhotos() }
                } label: {
                    if isRequestingPhotos {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Allow Access to Photos")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequestingPhotos)
                .accessibilityIdentifier(A11y.Welcome.photosAllow)
            }
        }
    }

    private func requestPhotos() async {
        isRequestingPhotos = true
        await appModel.requestPhotosAccessAndReload()
        photosStatus = PhotosAuthorization.status
        isRequestingPhotos = false
        guard PhotosAuthorization.isReadable(photosStatus) else { return }
        // Granting access is a statement about what the user wants to look at,
        // so it also selects the library — otherwise someone who restores a
        // backup with a server in it and then grants photo access lands on the
        // server they have not mentioned.
        appModel.librarySource = .photos
        onSourceConfigured()
    }

    // MARK: - Stash server

    private var serverCard: some View {
        WelcomeSetupCard(
            symbol: "server.rack",
            title: "A Media Server",
            summary: "Point the app at a Stash server to browse and convert its library.",
            isDone: isServerConnected
        ) {
            if isServerExpanded {
                serverForm
            } else {
                Button("Set Up a Server") { isServerExpanded = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var isServerConnected: Bool {
        if case .connected = serverState { return true }
        return false
    }

    @ViewBuilder
    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("http://stash.local:9999", text: $draftServerURL)
                .textFieldTapTarget()
                .accessibilityIdentifier(A11y.Welcome.serverURLField)
                .roundedTextFieldStyle()
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                #if !os(macOS)
                .keyboardType(.URL)
                #endif
                .onSubmit { Task { await connectServer() } }

            SecureField("API key (optional)", text: $draftAPIKey)
                .textFieldTapTarget()
                .accessibilityIdentifier(A11y.Welcome.serverKeyField)
                .roundedTextFieldStyle()
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { Task { await connectServer() } }

            HStack(spacing: 12) {
                Button {
                    Task { await connectServer() }
                } label: {
                    if serverState == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(A11y.Welcome.serverConnect)
                .disabled(serverState == .connecting
                          || draftServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                switch serverState {
                case .connected(let count):
                    statusLine("Connected — \(count) image\(count == 1 ? "" : "s")",
                               symbol: "checkmark.circle.fill", tint: .green)
                case .failed(let message):
                    statusLine(message, symbol: "exclamationmark.triangle.fill", tint: .orange)
                case .idle, .connecting:
                    EmptyView()
                }
            }
        }
    }

    private func connectServer() async {
        serverState = .connecting
        do {
            let count = try await appModel.verifyStashServer(url: draftServerURL, apiKey: draftAPIKey)
            appModel.commitStashServer(url: draftServerURL, apiKey: draftAPIKey)
            serverState = .connected(count)
            onSourceConfigured()
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Backup

    private var backupCard: some View {
        WelcomeSetupCard(
            symbol: "arrow.down.document",
            title: "Restore a Backup",
            summary: "Bring over the settings, filters and window layouts from another install.",
            isDone: backupImporter.didImport
        ) {
            if backupImporter.didImport {
                statusLine("Settings restored", symbol: "checkmark.circle.fill", tint: .green)
            } else {
                Button("Choose Backup File…") { backupImporter.pickFile() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(A11y.Welcome.backupChoose)
            }
        }
    }

    // MARK: - Shared bits

    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
    }
}

// MARK: - Card

/// One setup option: an icon, a claim, and whatever it takes to act on it.
struct WelcomeSetupCard<Content: View>: View {
    let symbol: String
    let title: String
    let summary: String
    let isDone: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .frame(width: 44)
                .foregroundStyle(isDone ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(isDone ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2)
        }
        .animation(.smooth(duration: 0.25), value: isDone)
    }
}
