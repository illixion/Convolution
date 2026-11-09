/*
 Hypnos - Settings → Device Setup (visionOS, iOS, macOS; tvOS has its own
 page, which can only receive)

 `DeviceSetupSettingsPage` offers both directions: send this device's
 servers to another one (scan its code from a photo; on iPhone and iPad the
 Camera works too), or show a code here to be set up from another device
 (`DeviceSetupReceiveView`). `DeviceSetupFileViews.swift` adds the same through a sealed file. `DeviceSetupSendSheet` is the confirmation for a
 scanned code (`DeviceSetup.pending`): one toggle per configured server, and
 the chosen ones are sent, keys included, sealed to the other device's key
 (RAVESDK's `RAVESetupSender`).
 */

#if !os(tvOS)

import RAVEDeviceSetup
import SwiftUI
import UniformTypeIdentifiers

/// One toggle per configured server, for the sheets that let the person choose what leaves this
/// device (the send sheet, and the one that saves a setup file).
struct DeviceSetupServerToggles: View {
    let available: DeviceSetupPayload
    @Binding var includeStash: Bool
    @Binding var includeNextcloud: Bool
    @Binding var includeJellyfin: Bool

    var body: some View {
        if let stash = available.stash {
            Toggle(isOn: $includeStash) { row("Stash", systemImage: LibrarySource.stash.symbolName, detail: host(stash.url)) }
        }
        if let nextcloud = available.nextcloud {
            Toggle(isOn: $includeNextcloud) {
                row("Nextcloud", systemImage: LibrarySource.nextcloud.symbolName,
                    detail: "\(nextcloud.username) on \(host(nextcloud.url))")
            }
        }
        if let jellyfin = available.jellyfin {
            Toggle(isOn: $includeJellyfin) {
                row("Jellyfin", systemImage: "film.stack",
                    detail: (jellyfin.session.map { "\($0.userName) on " } ?? "") + host(jellyfin.server))
            }
        }
    }

    private func row(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }
}

struct DeviceSetupSendSheet: View {
    let code: RAVESetupCode
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case choosing, sending, sent, failed(String)
    }

    @State private var phase: Phase = .choosing
    @State private var includeStash = true
    @State private var includeNextcloud = true
    @State private var includeJellyfin = true

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
                        Text("This device has no servers set up yet, so there's nothing to send. Set up Stash, Nextcloud or Jellyfin here first.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        DeviceSetupServerToggles(available: available, includeStash: $includeStash,
                                                 includeNextcloud: $includeNextcloud, includeJellyfin: $includeJellyfin)
                    } header: {
                        Text("Send to the Other Device")
                    } footer: {
                        Text("Addresses, sign-ins and keys are encrypted to the code on the other device's screen, so only that device can read them. It uses the same keys as this device.")
                    }

                    Section {
                        switch phase {
                        case .choosing, .failed:
                            Button("Send") { send() }
                                .disabled(chosen.isEmpty)
                        case .sending:
                            HStack {
                                ProgressView()
                                Text("Sending…").foregroundStyle(.secondary)
                            }
                        case .sent:
                            Label("Sent. The other device is set up.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if case .failed(let message) = phase {
                            Text(message).foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set Up Another Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .sent ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private func send() {
        let payload = chosen
        phase = .sending
        Task {
            do {
                try await RAVESetupSender.send(payload, to: code)
                phase = .sent
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

extension View {
    /// Presents `DeviceSetupSendSheet` whenever a setup code is scanned.
    /// Applied to the main window root.
    func deviceSetupSheet(appModel: AppModel) -> some View {
        modifier(DeviceSetupSheetPresenter(appModel: appModel))
    }
}

private struct DeviceSetupSheetPresenter: ViewModifier {
    let appModel: AppModel
    @Bindable private var setup = DeviceSetup.shared

    func body(content: Content) -> some View {
        content.sheet(item: $setup.pending) { code in
            DeviceSetupSendSheet(code: code)
                .environment(appModel)
        }
    }
}

struct DeviceSetupSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var scanError: String?
    @State private var showSaveSheet = false
    @State private var showFilePicker = false
    @State private var opening: DeviceSetupOpening?
    @State private var fileError: String?

    var body: some View {
        SettingsPage("Device Setup") {
            Section {
                RAVESetupScanPhotoButton(service: DeviceSetup.service, onResult: scanned) {
                    Label("Scan a Photo of the Code", systemImage: "qrcode.viewfinder")
                }
                if let scanError {
                    Text(scanError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Set Up Another Device")
            } footer: {
                Text(sendFooter)
            }

            Section {
                NavigationLink {
                    DeviceSetupReceiveView()
                } label: {
                    Label("Show Setup Code", systemImage: "qrcode")
                }
            } header: {
                Text("Set Up This Device")
            } footer: {
                Text("Shows a code another device running Convolution can send its servers to. This device listens on the local network only while the code is on screen.")
            }

            Section {
                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save a Setup File…", systemImage: "doc.badge.arrow.up")
                }
                Button {
                    fileError = nil
                    showFilePicker = true
                } label: {
                    Label("Open a Setup File…", systemImage: "doc.badge.plus")
                }
                if let fileError {
                    Text(fileError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Through a File")
            } footer: {
                Text("For two apps on one device (Convolution and the copy inside Nexus), or devices that can't see each other: AirDrop the file, or keep it in Files. It holds your servers and sign-ins, locked with five words shown when you save it; the other end asks for them.")
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            DeviceSetupFileSaveSheet().environment(appModel)
        }
        .sheet(item: $opening) { opening in
            DeviceSetupFileOpenSheet(opening: opening).environment(appModel)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json]) { result in
            picked(result)
        }
    }

    private func picked(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            fileError = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                fileError = "Couldn't read that file."
                return
            }
            guard let sender = RAVESealedFile.sender(of: data, format: DeviceSetupFile.format) else {
                fileError = "That isn't a Convolution setup file. Setup files are saved from Settings → Device Setup; a settings backup is opened under Backup."
                return
            }
            // The picker is still closing: a sheet presented in the same turn is dropped (see
            // `SettingsBackupImporter`).
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                opening = DeviceSetupOpening(file: data, sender: sender)
            }
        }
    }

    private func scanned(_ result: Result<RAVESetupCode, RAVESetupScanFailure>) {
        switch result {
        case .success(let code):
            scanError = nil
            DeviceSetup.shared.pending = code
        case .failure(let failure):
            scanError = failure.localizedDescription
        }
    }

    private var sendFooter: String {
        #if os(iOS)
        "Sends this device's server addresses and sign-ins, so you don't have to type them again. On the other device (an Apple TV, iPhone, iPad, Mac or Vision Pro), open Convolution → Settings → Device Setup, then point the Camera app at its code. Or take a photo of the code and pick it here."
        #else
        "Sends this device's server addresses and sign-ins, so you don't have to type them again. On the other device (an Apple TV, iPhone, iPad, Mac or Vision Pro), open Convolution → Settings → Device Setup, take a photo of its code, and pick it here."
        #endif
    }
}

#endif
