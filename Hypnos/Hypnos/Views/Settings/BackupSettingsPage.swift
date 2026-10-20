/*
 Hypnos - Settings → Backup (visionOS, iOS, macOS)

 Export the settings to a JSON file and import one back. No Files app or
 document picker on tvOS to export to or import from, so this isn't built
 there.
 */

#if !os(tvOS)

import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var showExporter = false
    @State private var exportDocument: SettingsBackupDocument?
    @State private var isExporting = false
    /// Picker + confirmation + alerts, shared with the welcome flow.
    @State private var backupImporter = SettingsBackupImporter()

    var body: some View {
        SettingsPage("Backup") {
            Section {
                Button {
                    export()
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Preparing...")
                        }
                    } else {
                        Label("Export Settings", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)

                Button {
                    backupImporter.pickFile()
                } label: {
                    Label("Import Settings", systemImage: "square.and.arrow.down")
                }

                Button {
                    backupImporter.loadNewestFromDocuments()
                } label: {
                    Label("Import from Documents Folder", systemImage: "folder")
                }
            } footer: {
                // Says so up front: the file is shareable, and someone who
                // assumed it was complete would restore onto a server that
                // silently fails to authenticate.
                Text("Backups include your server addresses and display settings, but not passwords or API keys — re-enter those after restoring, or use Device Setup to move them to another device.")
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Convolution-Backup-\(Self.backupDateString()).json"
        ) { _ in
            exportDocument = nil
        }
        .settingsBackupImport(backupImporter)
    }

    private func export() {
        isExporting = true
        Task {
            let backup = await appModel.exportSettingsBackup()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(backup) {
                exportDocument = SettingsBackupDocument(data: data)
                showExporter = true
            }
            isExporting = false
        }
    }

    private static func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

#endif
