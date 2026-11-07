import DebugTrace
import Foundation
import RAVECompanion
#if canImport(UIKit)
import UIKit
#endif

/// Pairing with a Vergence analysis coordinator (`vergenced pair`, or the
/// Vergence desktop app's Headsets tab) with RAVECompanion's six-digit
/// comparison, and the paired channel it gives: the coordinator's HTTP API
/// over TLS 1.2 with an external PSK on port 8421, keyed from the token the
/// pairing minted for this device (`docs/plans/analysis-workers.md`, "The
/// paired channel"). The token stays in the Keychain and never crosses the
/// network; what the coordinator is called and where it answered stay in
/// defaults.
enum AnalysisPairing {
    /// Vergence's own namespace, so Longwave's companion never answers.
    static let namespace = RAVECompanionNamespace(serviceStem: "vergence", labelPrefix: "Vergence", urlScheme: "vergence",
                                                  defaultPairPort: 4869, hostAppName: "Vergence")
    /// The API channel: PSK identity `VergenceAPI/v1/<device id>`,
    /// PSK = HKDF-SHA256(token, "Vergence-API-PSK-v1", "psk").
    static let channel = RAVECompanionChannel(identityBase: "VergenceAPI/v1", salt: "Vergence-API-PSK-v1")
    static let defaultPort: UInt16 = 8421

    static let recordKey = "analysisCoordinatorPairing"
    static let deviceIDKey = "analysisCoordinatorDeviceID"

    /// What a coordinator may let this device do; a headset asks for `play`.
    enum Grant: String, Codable, Hashable, Sendable { case play, work, admin }

    /// The coordinator this device paired with (no secret in it).
    struct Record: Codable, Equatable, Sendable {
        var deviceID: String
        var hostID: String
        var hostName: String
        /// The address the pairing ran over first, then the ones the coordinator listed.
        var addresses: [String]
        var port: UInt16
        var grants: [String]
    }

    /// This device's identity towards coordinators: random, kept in defaults.
    static var deviceID: String { RAVECompanionLocator.persistentDeviceID(key: deviceIDKey) }

    @MainActor static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    static func record() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: recordKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// The paired coordinator's HTTP client, or nil when this device isn't paired.
    static func client() -> RAVECompanionHTTPClient? {
        guard let record = record(), !record.addresses.isEmpty,
              let token = KeychainStore.string(for: .analysisCoordinatorPairingToken), !token.isEmpty else { return nil }
        return Clients.shared.client(record: record, token: token)
    }

    /// Keeps a finished pairing: the token in the Keychain, the rest in defaults.
    static func save(_ grant: RAVEPairingGrant, deviceID: String, connectedAddress: String?) {
        var addresses = [connectedAddress].compactMap { $0 } + grant.addresses
        var seen = Set<String>()
        addresses = addresses.filter { seen.insert($0).inserted }
        let record = Record(deviceID: deviceID, hostID: grant.macID, hostName: grant.macName, addresses: addresses,
                            port: defaultPort, grants: grant.grants ?? [])
        KeychainStore.set(grant.token, for: .analysisCoordinatorPairingToken)
        UserDefaults.standard.set(try? JSONEncoder().encode(record), forKey: recordKey)
        AppLogger.settings.info("Paired with an analysis server (\(addresses.count, privacy: .public) addresses)")
    }

    /// Forgets the pairing on this side (the coordinator keeps its record until it's removed there).
    static func forget() {
        KeychainStore.set("", for: .analysisCoordinatorPairingToken)
        UserDefaults.standard.removeObject(forKey: recordKey)
        Clients.shared.removeAll()
    }

    /// What to dial for pairing: a pasted `vergence://pair?…` link, or an
    /// address typed as it is (`192.168.1.20`, `studio.local`, with or
    /// without `http://` or a port, which pairing doesn't use).
    static func link(from text: String) -> RAVECompanionPairLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let link = RAVECompanionPairLink(namespace, url: url) { return link }
        var host = trimmed
        if let url = URL(string: trimmed), url.scheme != nil, let urlHost = url.host() { host = urlHost }
        if host.hasPrefix("[") { host = String(host.dropFirst().prefix { $0 != "]" }) }
        else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { return nil }
        return RAVECompanionPairLink(namespace, macID: "", name: "", addresses: [host])
    }

    /// One client per pairing, so its kept-alive connections serve every request.
    private final class Clients: @unchecked Sendable {
        static let shared = Clients()
        private let lock = NSLock()
        private var clients: [String: RAVECompanionHTTPClient] = [:]

        func client(record: Record, token: String) -> RAVECompanionHTTPClient {
            let key = "\(record.deviceID)|\(record.hostID)|\(record.addresses.joined(separator: ","))|\(record.port)|\(token.hashValue)"
            return lock.withLock {
                if let existing = clients[key] { return existing }
                let client = RAVECompanionHTTPClient(
                    channel: channel, credential: RAVECompanionCredential(token: token, deviceID: record.deviceID),
                    hosts: record.addresses, port: record.port, timeout: .seconds(15))
                clients = [key: client]
                return client
            }
        }

        func removeAll() {
            let old = lock.withLock { () -> [RAVECompanionHTTPClient] in
                defer { clients.removeAll() }
                return Array(clients.values)
            }
            for client in old { Task { await client.closeAll() } }
        }
    }
}
