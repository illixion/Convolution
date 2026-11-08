import RAVECompanion
import SwiftUI

/// Settings for a Vergence analysis server (`AnalysisCoordinator`): pairing
/// with it (`AnalysisPairing`, the six digits compared on both screens), or
/// its address and a token `vergenced token add NAME --grants play` printed.
struct AnalysisServerSection: View {
    @AppStorage(AnalysisCoordinator.urlKey) private var address = ""
    @State private var token = KeychainStore.string(for: .analysisCoordinatorToken) ?? ""
    @State private var paired = AnalysisPairing.record()
    @State private var pairAddress = ""
    @State private var pairing: RAVEPairingClient<AnalysisPairing.Grant>?
    @State private var pairingDeviceID = ""
    @State private var message: String?
    @State private var checking = false

    var body: some View {
        Section {
            if let paired {
                LabeledContent("Paired with", value: paired.hostName.isEmpty ? "Vergence" : paired.hostName)
                Button(checking ? "Checking…" : "Check Connection") { check() }
                    .disabled(checking)
                Button("Forget Analysis Server", role: .destructive) {
                    AnalysisPairing.forget()
                    self.paired = nil
                    message = nil
                }
            } else {
                pairRows
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Analysis Server")
        } footer: {
            Text("A Vergence analysis server lets other computers prepare a Library title's Smooth Motion, AI 3D depth and AI HDR highlights while it plays, starting where you are watching. Pair with it by its address (run `vergenced pair`, or Pair a Headset in the Vergence app): both screens show the same six digits. Leave it unpaired and empty to use only what the Jellyfin plugin prepared overnight.")
        }
        if paired == nil {
            Section {
                TextField("Server (http://host:8420)", text: $address)
                    .textFieldTapTarget()
                    .textContentType(.URL)
                    #if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Token", text: $token)
                    .textFieldTapTarget()
                    .onChange(of: token) { _, value in
                        KeychainStore.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: .analysisCoordinatorToken)
                    }
            } header: {
                Text("Analysis Server Token")
            } footer: {
                Text("Instead of pairing: the server's address and a play token from `vergenced token add`. Pairing is used when both are set.")
            }
        }
    }

    @ViewBuilder private var pairRows: some View {
        switch pairing?.state {
        case .waitingForHost:
            HStack {
                ProgressView()
                Text("Reaching the computer…")
            }
            Button("Cancel", role: .cancel) { stopPairing() }
        case .confirming(let code):
            VStack(alignment: .leading, spacing: 6) {
                Text(spaced(code)).font(.system(.largeTitle, design: .monospaced)).bold()
                Text("Check that the computer shows the same code, then choose Pair there.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { stopPairing() }
        default:
            TextField("Computer's address, or a vergence:// link", text: $pairAddress)
                .textFieldTapTarget()
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .onAppear { if pairAddress.isEmpty { pairAddress = URL(string: address)?.host() ?? "" } }
            Button("Pair") { startPairing() }
                .disabled(AnalysisPairing.link(from: pairAddress) == nil)
        }
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private func startPairing() {
        guard let link = AnalysisPairing.link(from: pairAddress) else { return }
        message = nil
        let deviceID = AnalysisPairing.deviceID
        let locator = RAVECompanionLocator(namespace: AnalysisPairing.namespace, deviceID: deviceID,
                                           deviceName: { AnalysisPairing.deviceName })
        let client = RAVEPairingClient<AnalysisPairing.Grant>(locator: locator, link: link,
                                                              deviceName: AnalysisPairing.deviceName, requested: [.play])
        pairing = client
        pairingDeviceID = deviceID
        client.start()
        watch(client)
    }

    /// Follows the client's state until it pairs or fails.
    private func watch(_ client: RAVEPairingClient<AnalysisPairing.Grant>) {
        withObservationTracking {
            _ = client.state
        } onChange: {
            Task { @MainActor in
                guard pairing === client else { return }
                switch client.state {
                case .paired(let grant):
                    AnalysisPairing.save(grant, deviceID: pairingDeviceID, connectedAddress: client.connectedAddress)
                    paired = AnalysisPairing.record()
                    pairing = nil
                    message = "Paired. Library titles now ask this server for help with AI features."
                case .failed(let reason):
                    pairing = nil
                    message = reason
                case .idle:
                    pairing = nil
                default:
                    watch(client)
                }
            }
        }
    }

    private func stopPairing() {
        pairing?.cancel()
        pairing = nil
    }

    private func check() {
        guard let coordinator = AnalysisCoordinator.current() else { return }
        checking = true
        Task {
            let result: String
            do {
                result = try await coordinator.check() ? "Connected." : "The server refused this device: pair it again."
            } catch {
                result = "Couldn't reach the server: \(error.localizedDescription)"
            }
            checking = false
            message = result
        }
    }
}
