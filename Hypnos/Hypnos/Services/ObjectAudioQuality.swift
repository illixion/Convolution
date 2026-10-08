/*
 Hypnos - object-audio quality for the film player

 The plugin serves a film's object audio as lossless FLAC (about 3 Mbps for
 a dozen elements) or, per segment, as one compressed bundle with a mono AAC
 stream per channel (RAVEFilm's `FilmAudioBundle`). Auto stays lossless on
 an ordinary network and switches to AAC on an expensive or constrained one
 (cellular, a hotspot, Low Data Mode). A download always plays its FLAC.
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
        case .auto: "Lossless, compressed on cellular and Low Data Mode"
        case .lossless: "About 3 Mbps for a typical film"
        default: nil
        }
    }

    /// What to fetch with now, given the network.
    var encoding: FilmAudioEncoding {
        switch self {
        case .auto: NetworkCost.shared.isCostly ? .aac(bitrate: 64000) : .lossless
        case .lossless: .lossless
        case .high: .aac(bitrate: 96000)
        case .standard: .aac(bitrate: 64000)
        case .low: .aac(bitrate: 32000)
        }
    }
}

/// Whether the current network costs the user: an expensive (cellular,
/// hotspot) or constrained (Low Data Mode) path.
final class NetworkCost: @unchecked Sendable {
    static let shared = NetworkCost()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var costly = false

    var isCostly: Bool { lock.withLock { costly } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.costly = path.isExpensive || path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "com.illixion.hypnos.network-cost"))
    }
}
