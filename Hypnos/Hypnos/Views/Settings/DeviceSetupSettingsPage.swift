/*
 Hypnos - Settings → Device Setup (visionOS, iOS, macOS; tvOS has its own
 page, which can only receive)

 `DeviceSetupSettingsPage` offers both directions: send this device's
 servers to another one (scan its code from a photo; on iPhone and iPad the
 Camera works too), or show a code here to be set up from another device
 (`DeviceSetupReceiveView`). `DeviceSetupSendSheet` is the confirmation for a
 scanned code (`DeviceSetup.pending`): one toggle per configured server, and
 the chosen ones are sent, keys included, sealed to the other device's key
 (RAVESDK's `RAVESetupSender`).
 */

#if !os(tvOS)

import RAVEDeviceSetup
import SwiftUI

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

    private func row(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
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
    @State private var scanError: String?

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
