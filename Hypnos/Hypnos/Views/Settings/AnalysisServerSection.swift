import RAVECompanion
import SwiftUI

/// Settings for a Vergence analysis server (`AnalysisCoordinator`): pairing
/// with it (`AnalysisPairing`, the six digits compared on both screens), or
/// its address and a token `vergenced token add NAME --grants play` printed.
struct AnalysisServerSection: View {
    @AppStorage(AnalysisCoordinator.urlKey, store: HypnosDefaults.store) private var address = ""
    @State private var token = KeychainStore.string(for: .analysisCoordinatorToken) ?? ""
    @State private var paired = AnalysisPairing.record()
    @State private var pairAddress = ""
    @State private var pairing: RAVEPairingClient<AnalysisPairing.Grant>?
    /// Finds Vergence computers announcing themselves on this network, and carries a pairing request to one.
    @State private var locator = RAVECompanionLocator(
        namespace: AnalysisPairing.namespace, deviceID: AnalysisPairing.deviceID, deviceName: { AnalysisPairing.deviceName })
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
            Text("A Vergence analysis server lets other computers prepare a Library title's Smooth Motion, AI 3D depth and AI HDR highlights while it plays, starting where you are watching. Pair with a computer listed nearby, or by its address: both screens show the same six digits. A computer running the Vergence app appears here by itself. Leave it unpaired and empty to use only what the Jellyfin plugin prepared overnight.")
        }
        // Browsing only while there is nobody paired to find, and the screen is up.
        .onAppear { if paired == nil { locator.startBrowsing() } }
        .onDisappear { locator.stopBrowsing() }
        .onChange(of: paired) { _, now in
            if now == nil { locator.startBrowsing() } else { locator.stopBrowsing() }
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
            nearbyRows
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

    /// The computers announcing themselves here: tapping one asks it to pair, and it shows a code.
    @ViewBuilder private var nearbyRows: some View {
        if locator.nearby.isEmpty {
            HStack {
                ProgressView()
                Text("Looking for computers running Vergence…").foregroundStyle(.secondary)
            }
        } else {
            ForEach(locator.nearby) { host in
                Button { startPairing(host: host) } label: {
                    HStack {
                        Text(host.name)
                        Spacer()
                        Text("Pair").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private func startPairing() {
        guard let link = AnalysisPairing.link(from: pairAddress) else { return }
        begin(RAVEPairingClient<AnalysisPairing.Grant>(locator: locator, link: link,
                                                       deviceName: AnalysisPairing.deviceName, requested: [.play]))
    }

    /// A computer found nearby: one that lists a pairing port is dialled, and any other is asked
    /// to open a listener for this device (its Mac-style knock).
    private func startPairing(host: RAVECompanionLocator.NearbyHost) {
        if let link = host.directPairLink(AnalysisPairing.namespace) {
            begin(RAVEPairingClient<AnalysisPairing.Grant>(locator: locator, link: link,
                                                           deviceName: AnalysisPairing.deviceName, requested: [.play]))
        } else {
            begin(RAVEPairingClient<AnalysisPairing.Grant>(locator: locator, host: host,
                                                           deviceName: AnalysisPairing.deviceName, requested: [.play]))
        }
    }

    private func begin(_ client: RAVEPairingClient<AnalysisPairing.Grant>) {
        message = nil
        pairing = client
        pairingDeviceID = locator.deviceID
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
