/*
 Hypnos - YouTube picture quality (sideload builds only: `HYPNOS_YOUTUBE`)

 YouTube's master playlist offers every rendition up to 2160p and the player
 picks by bandwidth, so on a fast link it plays 4K even when that is more
 than AI 3D can convert in time. A cap goes on the player item
 (`preferredMaximumResolution`), which the player honours from its next
 variant switch, without a reload. `auto` leaves it to the player, and the
 video window lowers the cap when 3D can't keep up.
 */

#if HYPNOS_YOUTUBE

import CoreGraphics
import Foundation

enum YouTubeQuality: String, CaseIterable, Identifiable, Sendable {
    case auto, p2160, p1440, p1080, p720, p480

    static let defaultsKey = "youtube.quality"

    static var preferred: YouTubeQuality {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var id: String { rawValue }

    /// The picture's height at this level; nil for auto.
    var height: Int? {
        switch self {
        case .auto: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .p2160: "2160p (4K)"
        default: "\(height ?? 0)p"
        }
    }

    var detail: String? {
        self == .auto ? "The best the connection allows, lowered if 3D can't keep up" : nil
    }

    /// The cap for a picture `height` high: a square as wide as a 16:9
    /// picture of that height, so a portrait video at the same level (1080
    /// wide, 1920 high for 1080p) fits under it too.
    static func maximumResolution(height: Int?) -> CGSize {
        guard let height else { return .zero }
        let side = (Double(height) * 16 / 9).rounded()
        return CGSize(width: side, height: side)
    }

    /// The level for a picture `height` high (the closest at or below it).
    static func level(height: Int) -> YouTubeQuality {
        allCases.first { ($0.height ?? .max) <= height } ?? .p480
    }
}

#endif
