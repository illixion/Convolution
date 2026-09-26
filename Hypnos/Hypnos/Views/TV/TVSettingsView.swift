/*
 Hypnos - tvOS Settings tab

 A remote-friendly subset of `SettingsTabView`: servers, library source and
 cache — the three things a TV-only install actually needs to configure.
 Deliberately leaves out everything that's either free-form-slider-shaped
 (display adjustments, slideshow tuning) or belongs to a feature that isn't
 on tvOS at all (spatial 3D, depth models, backup import/export — no Files
 app to pick a file from). See `Hypnos/CLAUDE.md` "tvOS".

 `CacheSettingsSection` and `NextcloudSettingsSection` are reused verbatim —
 neither uses a `Slider`/`DisclosureGroup`/anything else touch-only, so they
 already read fine with the focus engine.
 */

#if os(tvOS)

import SwiftUI

struct TVSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var connectionTestResult: ConnectionTestOutcome?

    var body: some View {
        NavigationStack {
            Form {
                Section("Library") {
                    Picker("Library Source", selection: Binding(
                        get: { appModel.librarySource },
                        set: { appModel.librarySource = $0 }
                    )) {
                        ForEach(appModel.availableLibrarySources, id: \.self) { source in
                            Label(source.displayName, systemImage: source.symbolName).tag(source)
                        }
                    }
                }

                JellyfinServerSection()

                Section {
                    Text("Browse and convert files placed in this app's Documents folder. Always available alongside Photos and any media server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Local Files")
                }

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
                } header: {
                    Text("Media Server")
                } footer: {
                    Text("Connects to a self-hosted Stash server to browse and convert its library.")
                }

                NextcloudSettingsSection()

                CacheSettingsSection()
            }
            .navigationTitle("Settings")
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
