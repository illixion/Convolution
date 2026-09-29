/*
 Hypnos - Settings Backup Import

 The "pick a settings backup and apply it" flow, as one component.

 It exists because there are now two places that offer it — the Settings tab
 and the welcome flow's third setup peer — and the flow is more than a file
 picker: a confirmation (importing replaces everything), a decode that can
 fail, a success acknowledgement, and the 600ms wait before presenting anything
 on top of a just-dismissed picker. Written twice, the second copy is where the
 confirmation or the wait quietly goes missing.

 The wait is not superstition: presenting an alert in the same runloop turn that
 dismisses `fileImporter` drops the alert entirely, and the user is left staring
 at a picker that closed and did nothing.
 */

import DebugTrace
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SettingsBackupImporter {

    /// Drives the file picker.
    var isPickingFile = false
    /// Drives the "this replaces your settings" confirmation.
    var isConfirming = false
    /// Drives the success acknowledgement.
    var isShowingSuccess = false
    /// Non-nil drives the failure alert.
    var errorMessage: String?

    private(set) var pendingData: Data?
    /// Whether an import has actually been applied, for callers that want to
    /// reflect it (the welcome flow marks its card done).
    private(set) var didImport = false

    func pickFile() {
        isPickingFile = true
    }

    /// Offers data for confirmation. `afterPickerDismissal` delays presentation
    /// so the alert is not swallowed by the closing picker.
    func offer(_ data: Data, afterPickerDismissal: Bool) {
        pendingData = data
        present(afterPickerDismissal: afterPickerDismissal) { self.isConfirming = true }
    }

    func fail(_ message: String, afterPickerDismissal: Bool) {
        present(afterPickerDismissal: afterPickerDismissal) { self.errorMessage = message }
    }

    func discard() {
        pendingData = nil
    }

    /// Decodes and applies the pending backup.
    func apply(to appModel: AppModel) async {
        guard let data = pendingData else { return }
        pendingData = nil
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(SettingsBackup.self, from: data)
            await appModel.importSettingsBackup(backup)
            didImport = true
            isShowingSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Picks up the newest JSON sitting in the Documents folder — the path for
    /// a backup pushed onto the device rather than picked from Files.
    func loadNewestFromDocuments() {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            errorMessage = "Could not locate the Documents folder."
            return
        }
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: documents,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let newest = contents
                .filter { $0.pathExtension.lowercased() == "json" }
                .max { lhs, rhs in modified(lhs) < modified(rhs) }

            guard let newest else {
                errorMessage = "No JSON files found in the Documents folder. Place a settings backup there and try again."
                return
            }
            pendingData = try Data(contentsOf: newest)
            isConfirming = true
            AppLogger.settings.info("Found settings backup in Documents: \(newest.lastPathComponent)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func present(afterPickerDismissal: Bool, _ action: @escaping () -> Void) {
        guard afterPickerDismissal else {
            action()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            action()
        }
    }
}

// MARK: - Presentation

private struct SettingsBackupImportModifier: ViewModifier {
    @Environment(AppModel.self) private var appModel
    let importer: SettingsBackupImporter
    let onImported: (() -> Void)?

    func body(content: Content) -> some View {
        content
            // `fileImporter` doesn't exist on tvOS — no Files app / document
            // picker to pick a backup from. `isPickingFile` simply never gets
            // set there (the Settings → Backup section that would set it is
            // itself hidden from the tvOS Settings tab).
            #if !os(tvOS)
            .fileImporter(
                isPresented: Binding(get: { importer.isPickingFile },
                                     set: { importer.isPickingFile = $0 }),
                allowedContentTypes: [.json]
            ) { result in
                switch result {
                case .success(let url):
                    // startAccessing legitimately returns false for URLs that
                    // aren't security-scoped (e.g. files already in our own
                    // container) — read regardless, only balance a successful
                    // start with a stop.
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    do {
                        importer.offer(try Data(contentsOf: url), afterPickerDismissal: true)
                    } catch {
                        importer.fail(error.localizedDescription, afterPickerDismissal: true)
                    }
                case .failure(let error):
                    importer.fail(error.localizedDescription, afterPickerDismissal: true)
                }
            }
            #endif
            .alert("Import Settings?", isPresented: Binding(get: { importer.isConfirming },
                                                           set: { importer.isConfirming = $0 })) {
                Button("Import", role: .destructive) {
                    Task {
                        await importer.apply(to: appModel)
                        if importer.didImport { onImported?() }
                    }
                }
                Button("Cancel", role: .cancel) { importer.discard() }
            } message: {
                Text("This will replace your current settings with the imported backup. This cannot be undone.")
            }
            .alert("Import Successful", isPresented: Binding(get: { importer.isShowingSuccess },
                                                            set: { importer.isShowingSuccess = $0 })) {
                Button("OK") {}
            } message: {
                Text("Settings have been restored from backup.")
            }
            .alert("Import Failed", isPresented: Binding(get: { importer.errorMessage != nil },
                                                        set: { if !$0 { importer.errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(importer.errorMessage ?? "")
            }
    }
}

extension View {
    /// Installs the backup-import picker, confirmation and alerts.
    func settingsBackupImport(_ importer: SettingsBackupImporter,
                              onImported: (() -> Void)? = nil) -> some View {
        modifier(SettingsBackupImportModifier(importer: importer, onImported: onImported))
    }
}
