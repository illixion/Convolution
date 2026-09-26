/*
 Hypnos - macOS Settings section

 Mirrors `TVSettingsView`: library source, Stash server + test connection,
 a Local Files note, `NextcloudSettingsSection` and `CacheSettingsSection`
 reused verbatim — both are already plain `Form`/`TextField`/`Toggle` content
 with no touch- or remote-specific assumptions, so nothing about them needed
 changing for a pointer-and-keyboard Mac. Leaves out the same things TV does
 (display adjustments, depth models, Backup import/export) as out of scope
 for this pass rather than platform-impossible — SwiftUI's `fileExporter`/
 `fileImporter` do work on macOS, unlike tvOS. See `Hypnos/CLAUDE.md` "macOS".
 */

#if os(macOS)

import SwiftUI

struct MacSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var connectionTestResult: ConnectionTestOutcome?

    var body: some View {
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
        .formStyle(.grouped)
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
