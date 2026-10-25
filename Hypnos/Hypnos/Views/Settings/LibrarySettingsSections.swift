/*
 Hypnos - Settings: the library sources that aren't a whole page of their own

 Stash, the photo library and Local Files, shared by every platform's
 Settings (`SettingsTabView` on visionOS, iOS and macOS, `TVSettingsView`).
 Stash used to have a separate copy per platform; tvOS's needs are met by
 the same rows, since none of them is a picker or a trailing button.
 */

import DebugTrace
import Photos
import RAVEUI
import SwiftUI

struct StashServerSection: View {
    @Environment(AppModel.self) private var appModel
    /// Outcome of the last "Apply & Test Connection", shown in place. A
    /// failure needs to read as a failure — a plain caption is easy to miss,
    /// and this is exactly the kind of check whose whole point is catching a
    /// server credential that looks fine (GraphQL still answers) but leaves
    /// every image/video/thumbnail broken (see `verifyStashServer`).
    @State private var connectionTestResult: ConnectionTestOutcome?

    var body: some View {
        @Bindable var appModel = appModel
        Section {
            TextField("Server URL", text: $appModel.stashServerURL)
                .textFieldTapTarget()
                .textFieldStyle(.plain)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit { appModel.updateAPIClient() }

            SecureField("API Key (optional)", text: $appModel.stashAPIKey)
                .textFieldTapTarget()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { appModel.updateAPIClient() }

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
        } footer: {
            Text("Connects to a self-hosted Stash server to browse and convert its library.")
        }

        Section {
            Toggle("Server-Side Transcoding", isOn: $appModel.enableStashTranscoding)
        } footer: {
            Text("Keep the Stash server's HLS transcode in reserve. Scenes always play their original file first; the transcode is used only if that file can't be played here, or when a feature needs it (AI 3D, live and immersive 3D, depth pre-processing). Turn off to never transcode. Applies to newly loaded scenes.")
        }
    }

    /// Verifies the server fields as typed. Goes through the model's shared
    /// check rather than `imageSource`, which on a Photos library would have
    /// been testing the photo library and reporting success either way.
    private func testConnection() async {
        do {
            let count = try await appModel.verifyStashServer(url: appModel.stashServerURL,
                                                            apiKey: appModel.stashAPIKey)
            connectionTestResult = .success("Connected — \(count) image\(count == 1 ? "" : "s")")
            AppLogger.settings.info("Connection successful, \(count, privacy: .public) images")
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
            AppLogger.settings.error("Connection failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }
}

struct PhotoLibrarySection: View {
    @Environment(AppModel.self) private var appModel

    /// The short form, for the row that opens this page.
    static var statusLabel: String {
        switch PhotosAuthorization.status {
        case .authorized: "Full Access"
        case .limited: "Selected Photos"
        case .denied, .restricted: "No Access"
        default: "Not Allowed Yet"
        }
    }

    var body: some View {
        Section {
            switch PhotosAuthorization.status {
            case .authorized:
                Label("Full library access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .limited:
                Label("Access limited to selected photos", systemImage: "checkmark.circle")
                    .foregroundStyle(.yellow)
                Text("Convolution can only see the photos you picked. Choose more in Settings → Privacy & Security → Photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .denied, .restricted:
                Label("Access denied", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                Text("Grant access in Settings → Privacy & Security → Photos to browse your library here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Button("Allow Access to Photos") {
                    Task { await appModel.requestPhotosAccessAndReload() }
                }
            }
        } footer: {
            Text("Browse and convert the photos already on this device.")
        }
    }
}

struct LocalFilesSection: View {
    var body: some View {
        // No toggle — needs no permission and no setup, so unlike Photos or
        // a media server there is nothing to gate. This is purely where
        // "where do I put files" gets explained.
        Section {
            #if os(macOS)
            Text("Browse and convert files placed in this app's Documents folder: pictures in its Photos folder, videos in Videos.")
            Button("Show in Finder") {
                for folder in [LocalMediaSource.photosDirectory, LocalMediaSource.videosDirectory] {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.activateFileViewerSelecting([LocalMediaSource.photosDirectory,
                                                                LocalMediaSource.videosDirectory])
            }
            #else
            Text("Browse and convert files you place in this app's Documents folder — in the Files app, under \"On My \(PlatformCapabilities.deviceFamilyName)\" → Convolution. Pictures go in its Photos folder, videos in Videos.")
            #endif
        } footer: {
            Text("Always available as a library alongside Photos and any server.")
        }
    }
}
