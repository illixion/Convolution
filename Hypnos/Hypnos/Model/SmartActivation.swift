/*
 Hypnos - Smart Activation (Settings → AI Features)

 When Smooth Motion and AI Upscaling turn themselves on, as a list of rules
 the viewer edits. Each feature has a default (Settings → AI Features) that
 applies to every video; with Smart Activation on for the feature, its rules
 are read first:

 - Rules are checked top to bottom and the first enabled one whose
   conditions all hold decides: it turns the feature on or off for that video.
 - A video no rule fits follows the default.
 - A condition left on "Any" is not checked; one that needs a measurement the
   player does not have yet (the frame rate of a stream still opening) does
   not hold.

 "Boost videos to 60 but not to 120" is one rule, On for videos at 24-30 fps
 (or: at most 60 fps once boosted), and no rule for 50-60 fps. A viewer who
 wants Smooth Motion everywhere except 120 Hz-class sources turns the default
 on and adds an Off rule for 50-60 fps.

 A window decides once per video, when its first measurements arrive
 (`VideoWindowModel.latchSmartConditions`): turning a feature on mid-play
 would reload the 3D pipeline, and a thermal blip should not flap it. The
 video's View Mode menu overrides all of it.
 */

import Foundation

/// How big a picture is, by the name its long side goes by.
enum SmartResolution: Int, Codable, CaseIterable, Identifiable {
    case sd = 854, hd720 = 1280, hd1080 = 1920, qhd = 2560, uhd = 3840

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .sd: "480p"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .qhd: "1440p"
        case .uhd: "4K"
        }
    }

    /// Whether a picture this wide (its longer side) is no bigger than this tier.
    func contains(longSide: Int) -> Bool { longSide <= rawValue + 8 }
}

/// One rule: turn a feature on or off for the videos its conditions fit.
struct SmartRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var isEnabled = true
    /// What the rule does when it fits.
    var turnsOn = true
    /// The video's own frame rate, between these (either end open).
    var minFrameRate: Double?
    var maxFrameRate: Double?
    /// Smooth Motion only: the rate the video would play at once boosted
    /// (twice its own), at most this.
    var maxBoostedFrameRate: Double?
    /// The picture's long side, at most this tier.
    var maxResolution: SmartResolution?
    /// Only for pictures that are not HDR.
    var sdrOnly = false
    /// nil: either way. true: only in Low Power Mode or while the device is
    /// hot. false: only while it has power and heat to spare.
    var whenStrained: Bool?

    /// What a video is, as far as the rules ask.
    struct Subject {
        var frameRate: Double?
        var longSide: Int?
        var isSDR: Bool?
        var strained: Bool
    }

    func fits(_ video: Subject) -> Bool {
        if minFrameRate != nil || maxFrameRate != nil || maxBoostedFrameRate != nil {
            guard let rate = video.frameRate else { return false }
            // Standard rates are 23.976 and 29.97, so the ends are loose.
            if let minFrameRate, rate < minFrameRate - 0.5 { return false }
            if let maxFrameRate, rate > maxFrameRate + 0.5 { return false }
            if let maxBoostedFrameRate, rate * 2 > maxBoostedFrameRate + 1 { return false }
        }
        if let maxResolution {
            guard let side = video.longSide, maxResolution.contains(longSide: side) else { return false }
        }
        // A picture whose range is not known yet reads as SDR, as the players do.
        if sdrOnly, video.isSDR == false { return false }
        if let whenStrained, whenStrained != video.strained { return false }
        return true
    }

    /// "On · 24–30 fps · SDR only": the row's text.
    func summary(boosts: Bool) -> String {
        var parts: [String] = []
        switch (minFrameRate, maxFrameRate) {
        case let (low?, high?): parts.append(Self.rateRange(low, high) + " fps")
        case let (low?, nil): parts.append("\(Self.rate(low)) fps or more")
        case let (nil, high?): parts.append("\(Self.rate(high)) fps or less")
        default: break
        }
        if boosts, let maxBoostedFrameRate { parts.append("boosted to \(Self.rate(maxBoostedFrameRate)) fps or less") }
        if let maxResolution { parts.append("up to \(maxResolution.label)") }
        if sdrOnly { parts.append("SDR only") }
        switch whenStrained {
        case true?: parts.append("in Low Power Mode or when hot")
        case false?: parts.append("with power to spare")
        case nil: break
        }
        return parts.isEmpty ? "every video" : parts.joined(separator: " · ")
    }

    private static func rate(_ value: Double) -> String { String(Int(value.rounded())) }
    private static func rateRange(_ low: Double, _ high: Double) -> String {
        low == high ? rate(low) : "\(rate(low))–\(rate(high))"
    }

    /// Frame rates the editor offers.
    static let frameRateChoices: [Double] = [24, 25, 30, 48, 50, 60, 100, 120]
    static let boostedRateChoices: [Double] = [48, 50, 60, 100, 120]
}

/// A rule list for each feature.
struct SmartRules: Codable, Equatable {
    var smoothMotion: [SmartRule]
    var upscaling: [SmartRule]

    /// What a viewer starts with, and what "Restore Suggested Rules" brings
    /// back: hold back when the device is strained, then the videos each
    /// feature helps most. Smooth Motion takes 24-30 fps, whose pans judder;
    /// 50-60 fps already moves in small steps, so it is left alone. Upscaling
    /// takes pictures of 720p and below.
    static let suggested = SmartRules(
        smoothMotion: [
            SmartRule(turnsOn: false, whenStrained: true),
            SmartRule(minFrameRate: 24, maxFrameRate: 30),
        ],
        upscaling: [
            SmartRule(turnsOn: false, whenStrained: true),
            SmartRule(maxResolution: .hd720, sdrOnly: true),
        ])
}

enum SmartActivation {
    /// What the device is doing when a video starts.
    struct Conditions: Equatable {
        var lowPowerMode: Bool
        var thermalState: ProcessInfo.ThermalState

        /// The device as it is now.
        static var current: Conditions {
            Conditions(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                       thermalState: ProcessInfo.processInfo.thermalState)
        }

        /// Low Power Mode, or serious or critical heat.
        var isStrained: Bool {
            lowPowerMode || thermalState == .serious || thermalState == .critical
        }
    }

    /// What the first enabled rule that fits says; nil when none fits.
    static func decision(_ rules: [SmartRule], for video: SmartRule.Subject) -> Bool? {
        rules.first { $0.isEnabled && $0.fits(video) }?.turnsOn
    }
}
