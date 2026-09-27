/*
 Hypnos - tvOS Settings tab

 A remote-friendly subset of `SettingsTabView`: servers, library source and
 cache — the things a TV-only install actually needs to configure.
 Deliberately leaves out everything that's either free-form-slider-shaped
 (display adjustments, slideshow tuning) or belongs to a feature that isn't
 on tvOS at all (spatial 3D, depth models, backup import/export — no Files
 app to pick a file from). See `Hypnos/CLAUDE.md` "tvOS".

 Laid out like the tvOS Settings app: a short top page of rows, each showing
 its current value and opening its own page. tvOS has no disclosure groups,
 and one long form buried the cache under every server's fields.

 Choices are full-width checkmarked rows, never a `Picker`. Its default
 style pushes a list that stalls on a blank page inside the tab bar (tvOS 27,
 "_UIReplicantView as a subview of UIHostingController.view"), and its menu
 style draws a pill sized to its label that the focus engine can't move
 past. For the same reason no row carries a trailing button: moving down the
 list only reaches controls that span it. `CacheSettingsSection`,
 `NextcloudSettingsSection` and `JellyfinServerSection` follow this on tvOS.
 */

#if os(tvOS)

import SwiftUI

struct TVSettingsView: View {
    private enum Page: Hashable {
        case librarySource, jellyfin, stash, nextcloud, cache
    }

    @Environment(AppModel.self) private var appModel
    @Bindable private var film = FilmSession.shared
    @Bindable private var jellyfin = JellyfinAuth.shared
    @State private var path: [Page] = []
    @State private var cachePreset = CacheBudget.preset

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    row(.librarySource, "Library Source", systemImage: appModel.effectiveLibrarySource.symbolName,
                        value: appModel.effectiveLibrarySource.displayName)
                }
                Section("Servers") {
                    row(.jellyfin, "Jellyfin", systemImage: "film.stack", value: jellyfinStatus)
                    row(.stash, "Stash", systemImage: LibrarySource.stash.symbolName,
                        value: appModel.hasStashServer ? host(appModel.stashServerURL) : "Not set")
                    row(.nextcloud, "Nextcloud", systemImage: LibrarySource.nextcloud.symbolName,
                        value: appModel.hasNextcloudServer ? host(appModel.nextcloudServerURL) : "Not set")
                }
                Section {
                    row(.cache, "Cache", systemImage: "internaldrive", value: cachePreset.label)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Page.self) { page in
                Form { content(for: page) }
                    .navigationTitle(title(for: page))
            }
            // The preset isn't observable; pick up a change made on the
            // Cache page when coming back.
            .onAppear { cachePreset = CacheBudget.preset }
        }
    }

    private func row(_ page: Page, _ title: String, systemImage: String, value: String) -> some View {
        NavigationLink(value: page) {
            LabeledContent {
                Text(value)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private var jellyfinStatus: String {
        if let user = jellyfin.session { return user.userName }
        return film.server.isEmpty ? "Not set" : host(film.server)
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private func title(for page: Page) -> String {
        switch page {
        case .librarySource: "Library Source"
        case .jellyfin: "Jellyfin"
        case .stash: "Stash"
        case .nextcloud: "Nextcloud"
        case .cache: "Cache"
        }
    }

    @ViewBuilder
    private func content(for page: Page) -> some View {
        switch page {
        case .librarySource: TVLibrarySourceSection { path.removeLast() }
        case .jellyfin: JellyfinServerSection()
        case .stash: TVStashServerSection()
        case .nextcloud: NextcloudSettingsSection()
        case .cache: CacheSettingsSection()
        }
    }
}

/// One checkmarked row per available source; choosing one goes back.
private struct TVLibrarySourceSection: View {
    @Environment(AppModel.self) private var appModel
    let onChoose: () -> Void

    var body: some View {
        Section {
            ForEach(appModel.availableLibrarySources, id: \.self) { source in
                Button {
                    appModel.librarySource = source
                    onChoose()
                } label: {
                    HStack {
                        Label(source.displayName, systemImage: source.symbolName)
                        Spacer()
                        if source == appModel.effectiveLibrarySource {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } footer: {
            Text("Local Files browses files placed in this app's Documents folder. Stash and Nextcloud appear once their server is set up.")
        }
    }
}

private struct TVStashServerSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var connectionTestResult: ConnectionTestOutcome?

    var body: some View {
        Section {
            TextField("Server URL", text: Binding(
                get: { appModel.stashServerURL },
                set: { appModel.stashServerURL = $0 }
            ))
            .autocorrectionDisabled()

            SecureField("API Key (optional)", text: Binding(
                get: { appModel.stashAPIKey },
                set: { appModel.stashAPIKey = $0 }
            ))

            Button("Apply & Test Connection") {
                appModel.updateAPIClient()
                connectionTestResult = nil
                Task { await testConnection() }
            }

            if let connectionTestResult {
                if connectionTestResult.isFailure {
                    Label(connectionTestResult.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    Text(connectionTestResult.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Server-Side Transcoding", isOn: Binding(
                get: { appModel.enableStashTranscoding },
                set: { appModel.enableStashTranscoding = $0 }
            ))
        } footer: {
            Text("Connects to a self-hosted Stash server to browse and convert its library.")
        }
    }

    private func testConnection() async {
        do {
            let count = try await appModel.verifyStashServer(
                url: appModel.stashServerURL,
                apiKey: appModel.stashAPIKey
            )
            connectionTestResult = .success("Connected — \(count) image\(count == 1 ? "" : "s")")
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
        }
    }
}

#endif
