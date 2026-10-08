/*
 Hypnos - object-audio quality for the film player

 The plugin serves a film's object audio as lossless FLAC (about 3 Mbps for
 a dozen elements) or, per segment, as one compressed bundle with a mono AAC
 stream per channel (RAVEFilm's `FilmAudioBundle`), at 64 kbps per channel on
 average, shared out by the plugin: dialogue and the front stage get more,
 the low-frequency channel and quiet ones less. A download always plays its
 FLAC.

 Auto follows the connection rather than reading it once: RAVEFilm's
 `FilmAudioGovernor` takes what the link has carried, a step down at once
 when it can't keep up and a step back up when it can, and never more than
 the path allows (lossless on an unmetered one, 64 kbps on cellular or a
 hotspot, 32 on Low Data Mode). It carries over from one film to the next
 until the path changes interface.
 */

import Foundation
import Network
import RAVEFilm

enum ObjectAudioQuality: String, CaseIterable, Sendable {
    case auto
    case lossless
    case high
    case standard
    case low

    static let defaultsKey = "filmPlayer.objectAudioQuality"

    static var preferred: ObjectAudioQuality {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .lossless: "Lossless"
        case .high: "High · 96 kbps per channel"
        case .standard: "Standard · 64 kbps per channel"
        case .low: "Low · 32 kbps per channel"
        }
    }

    var detail: String? {
        switch self {
        case .auto: "Follows your connection: lossless when it can, smaller on cellular or a slow link"
        case .lossless: "About 3 Mbps for a typical film"
        default: nil
        }
    }

    /// The fixed encoding; under Auto, what the governor falls back on.
    var encoding: FilmAudioEncoding {
        switch self {
        case .auto, .lossless: .lossless
        case .high: .aac(bitrate: 96000)
        case .standard: .aac(bitrate: 64000)
        case .low: .aac(bitrate: 32000)
        }
    }

    /// Picks each segment's encoding under Auto; nil for a fixed choice.
    var governor: FilmAudioGovernor? { self == .auto ? Self.autoGovernor : nil }

    /// One for the app: what it learned of the link on one film holds for the next.
    static let autoGovernor = FilmAudioGovernor(codec: .aac, link: { NetworkCost.shared.link })

    /// Sets how `client` fetches object audio.
    func apply(to client: inout FilmServerClient) {
        client.encoding = encoding
        client.governor = governor
    }
}

/// What the current network path costs the user: an expensive (cellular,
/// hotspot) or constrained (Low Data Mode) path, and a generation that
/// changes when the path switches interface or cost.
final class NetworkCost: @unchecked Sendable {
    static let shared = NetworkCost()

    private struct Signature: Equatable {
        var interfaces: [NWInterface.InterfaceType]
        var expensive: Bool
        var constrained: Bool
    }

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var signature: Signature?
    private var generation = 0

    var link: FilmAudioGovernor.Link {
        lock.withLock {
            FilmAudioGovernor.Link(isExpensive: signature?.expensive ?? false, isConstrained: signature?.constrained ?? false,
                                   generation: generation)
        }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular, .loopback, .other]
                .filter { path.usesInterfaceType($0) }
            let current = Signature(interfaces: interfaces, expensive: path.isExpensive, constrained: path.isConstrained)
            self.lock.withLock {
                // The first report is the starting point, not a change.
                if let known = self.signature, known != current { self.generation += 1 }
                self.signature = current
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.illixion.hypnos.network-cost"))
    }
}
