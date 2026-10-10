/*
 Hypnos - picture quality for the film player

 The plugin serves an object-audio film's picture as the film's own video,
 copied (a UHD remux runs 50-90 Mbps), and, for a film larger than 1440p or
 1080p, those lower tiers as HEVC transcodes cut on the same keyframe index
 (RAVEFilm's `FilmVideoIndex.pictureHeights`), so the player can change tier
 at the playhead without moving it.

 Auto plays the original and, on visionOS, steps straight to 1080p when
 the 3D picture can't keep up (`FilmPlayerView.noteStereoPerformance`), for
 that film only: on a Vision Pro 1440p still dropped frames in 3D (Baby
 Driver, 2026-10-10), so a stop there only delayed the step that works. Original and the tiers are fixed and never step. A
 download plays its original whatever this says.
 */

import Foundation

enum FilmPictureQuality: String, CaseIterable, Sendable {
    case auto
    case original
    case p1440
    case p1080

    static let defaultsKey = "filmPlayer.pictureQuality"

    static var preferred: FilmPictureQuality {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The tier asked of the plugin; nil is the film's own picture.
    var height: Int? {
        switch self {
        case .auto, .original: nil
        case .p1440: 1440
        case .p1080: 1080
        }
    }

    init?(height: Int) {
        guard let match = Self.allCases.first(where: { $0.height == height }) else { return nil }
        self = match
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .original: "Original"
        case .p1440: "1440p"
        case .p1080: "1080p"
        }
    }

    /// The choices a film offering `heights` (largest first) gets: Auto
    /// only where it can step (visionOS 3D), the original, and its tiers.
    static func choices(offering heights: [Int]) -> [FilmPictureQuality] {
        #if os(visionOS)
        let automatic: [FilmPictureQuality] = [.auto]
        #else
        let automatic: [FilmPictureQuality] = []
        #endif
        return automatic + [.original] + heights.compactMap(FilmPictureQuality.init(height:))
    }

    /// The tier Auto steps to for 3D from `current` (nil: the original):
    /// 1080p when offered, else the smallest tier below `current`; nil at
    /// the bottom.
    static func stepDown(from current: Int?, offering heights: [Int]) -> Int? {
        let lower = heights.filter { tier in current.map { tier < $0 } ?? true }
        return lower.contains(1080) ? 1080 : lower.min()
    }

    /// What a menu shows as chosen from the stored raw value: Auto where it
    /// isn't offered is the original.
    static func selected(stored: String, offering heights: [Int]) -> FilmPictureQuality {
        let quality = FilmPictureQuality(rawValue: stored) ?? .auto
        return choices(offering: heights).contains(quality) ? quality : .original
    }

    static func name(of height: Int?) -> String {
        height.map { "\($0)p" } ?? "Original"
    }
}
