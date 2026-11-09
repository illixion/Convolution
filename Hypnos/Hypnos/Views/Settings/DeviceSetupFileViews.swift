/*
 Hypnos - Device Setup through a file (visionOS, iOS, macOS; tvOS has no Files app)

 The QR route needs two devices on one network. A file also works between two apps on one
 device (Convolution and the copy of it inside Nexus), by AirDrop, or from a backup folder:

 - `DeviceSetupFileSaveSheet` picks the servers, seals them (RAVESDK's `RAVESealedFile`: five
   EFF words, Argon2id, ChaCha20-Poly1305, the same scheme as Apparition's `.apparitionkey`),
   shows the five words and saves the file. The words are not in the file and not stored.
 - `DeviceSetupFileOpenSheet` asks for the words, shows what the file holds, and applies it
   through the same setters the QR route uses (`DeviceSetupPayload.apply`).

 The file carries the same payload as the QR route: addresses and the sign-ins themselves, so
 the receiver uses the same keys as the sender.
 */

#if !os(tvOS)

import RAVEDeviceSetup
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

enum DeviceSetupFile {
    /// Names this kind of sealed file, so another app's is refused before anything is derived.
    static let format = "hypnos-setup-sealed"

    /// Who the file says it is from ("Convolution on Apple Vision Pro"), readable without the words.
    static var sender: String {
        #if canImport(UIKit)
        "Convolution on \(UIDevice.current.name)"
        #else
        "Convolution on \(Host.current().localizedName ?? "a Mac")"
        #endif
    }

    static var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Convolution-Setup-\(formatter.string(from: Date())).json"
    }

    /// A sealed setup file, by itself (a JSON document, like the settings backup).
    struct Document: FileDocument {
        static var readableContentTypes: [UTType] { [.json] }
        let data: Data

        init(data: Data) { self.data = data }

        init(configuration: ReadConfiguration) throws {
            guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            self.data = data
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: data)
        }
    }

    static func seal(_ payload: DeviceSetupPayload) async throws -> RAVESealedFile.Sealed {
        let plain = try JSONEncoder().encode(payload)
        return try await RAVESealedFile.seal(plain, format: format, from: sender)
    }

    static func open(_ file: Data, words: String) async throws -> DeviceSetupPayload {
        let plain = try await RAVESealedFile.open(file, format: format, words: words)
        do {
            return try JSONDecoder().decode(DeviceSetupPayload.self, from: plain)
        } catch {
            throw RAVESealedFile.Failure.damaged
        }
    }
}

// MARK: - Saving

struct DeviceSetupFileSaveSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case choosing, sealing, sealed(words: String), failed(String)
    }

    @State private var phase: Phase = .choosing
    @State private var includeStash = true
    @State private var includeNextcloud = true
    @State private var includeJellyfin = true
    @State private var document: DeviceSetupFile.Document?
    @State private var showExporter = false
    @State private var saved = false

    private var available: DeviceSetupPayload { DeviceSetupPayload.current(from: appModel) }

    private var chosen: DeviceSetupPayload {
        var payload = available
        if !includeStash { payload.stash = nil }
        if !includeNextcloud { payload.nextcloud = nil }
        if !includeJellyfin { payload.jellyfin = nil }
        return payload
    }

    var body: some View {
        NavigationStack {
            Form {
                let available = available
                if available.isEmpty {
                    Section {
                        Text("This device has no servers set up yet, so there's nothing to save. Set up Stash, Nextcloud or Jellyfin here first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    switch phase {
                    case .choosing, .failed, .sealing:
                        chooser(available)
                    case .sealed(let words):
                        sealed(words)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Save a Setup File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(saved ? "Done" : "Cancel") { dismiss() }
                }
            }
            .fileExporter(isPresented: $showExporter, document: document, contentType: .json,
                          defaultFilename: DeviceSetupFile.defaultFilename) { result in
                if case .success = result { saved = true }
            }
        }
    }

    @ViewBuilder
    private func chooser(_ available: DeviceSetupPayload) -> some View {
        Section {
            DeviceSetupServerToggles(available: available, includeStash: $includeStash,
                                     includeNextcloud: $includeNextcloud, includeJellyfin: $includeJellyfin)
        } header: {
            Text("What to Save")
        } footer: {
            Text("Addresses, sign-ins and keys go into the file, locked with five words that appear on the next screen. Whoever has the file and the words can use your servers, so keep them apart.")
        }

        Section {
            if case .sealing = phase {
                HStack {
                    ProgressView()
                    Text("Locking…").foregroundStyle(.secondary)
                }
            } else {
                Button("Lock with Five Words") { seal() }
                    .disabled(chosen.isEmpty)
            }
            if case .failed(let message) = phase {
                Text(message).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func sealed(_ words: String) -> some View {
        Section {
            Text(words)
                .font(.title2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("The Five Words")
        } footer: {
            Text("They open the file on the other end, and aren't saved anywhere: write them down or put them in a password manager before you close this. Case and punctuation don't matter, and the first three letters of each word are enough.")
        }

        Section {
            Button {
                showExporter = true
            } label: {
                Label(saved ? "Save Again…" : "Save the File…", systemImage: "square.and.arrow.down")
            }
            if saved {
                Label("Saved. Open it on the other device from Settings → Device Setup.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func seal() {
        let payload = chosen
        phase = .sealing
        Task {
            do {
                let sealed = try await DeviceSetupFile.seal(payload)
                document = DeviceSetupFile.Document(data: sealed.file)
                phase = .sealed(words: sealed.words)
                showExporter = true
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Opening

/// A picked file that is a Convolution setup file, waiting for its words.
struct DeviceSetupOpening: Identifiable {
    let id = UUID()
    let file: Data
    let sender: String
}

struct DeviceSetupFileOpenSheet: View {
    let opening: DeviceSetupOpening
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case typing, opening, review(DeviceSetupPayload), applied(DeviceSetupPayload), failed(String)
    }

    @State private var phase: Phase = .typing
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .typing, .opening, .failed:
                    wordsSection
                case .review(let payload):
                    reviewSection(payload)
                case .applied(let payload):
                    Section {
                        ForEach(payload.summary, id: \.self) { Text($0) }
                        Label("Applied. This device is set up.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Open a Setup File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .applied = phase { Button("Done") { dismiss() } } else { Button("Cancel") { dismiss() } }
                }
            }
        }
    }

    @ViewBuilder
    private var wordsSection: some View {
        Section {
            TextField("Five words", text: $typed, axis: .vertical)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .disabled(isOpening)
                .onSubmit { open() }
        } header: {
            Text("From \(opening.sender)")
        } footer: {
            Text("Type the five words the other device showed when it saved this file. Case and punctuation don't matter, and the first three letters of each word are enough.")
        }

        Section {
            if isOpening {
                HStack {
                    ProgressView()
                    Text("Opening…").foregroundStyle(.secondary)
                }
            } else {
                Button("Open") { open() }
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if case .failed(let message) = phase {
                Text(message).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func reviewSection(_ payload: DeviceSetupPayload) -> some View {
        Section {
            if payload.isEmpty {
                Text("This file holds no servers.").foregroundStyle(.secondary)
            } else {
                ForEach(payload.summary, id: \.self) { Text($0) }
            }
        } header: {
            Text("The File Holds")
        } footer: {
            Text("Applying sets these servers up on this device, replacing any of the same kind, and uses the same sign-ins as the device that saved them. Servers not listed here stay as they are.")
        }

        Section {
            Button("Apply") {
                payload.apply(to: appModel)
                phase = .applied(payload)
            }
            .disabled(payload.isEmpty)
        }
    }

    private var isOpening: Bool {
        if case .opening = phase { return true }
        return false
    }

    private func open() {
        guard !isOpening else { return }
        let file = opening.file
        let words = typed
        phase = .opening
        Task {
            do {
                phase = .review(try await DeviceSetupFile.open(file, words: words))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

#endif
