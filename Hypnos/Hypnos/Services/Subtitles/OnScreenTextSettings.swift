/*
 Hypnos - On-Screen Text settings

 On-Screen Text reads a video's burned-in subtitles off the picture and can
 speak them (`OnScreenText` in Packages/GeneratedCaptions; chosen in a video's
 subtitle menu). These are its saved choices: whether to narrate, the voice,
 how fast, and where in the picture to look. Read on every pass of the
 reader's loop, so a change applies to the next line; never written during
 playback (see "Never write to HypnosDefaults.store" in CLAUDE.md).
 */

import AVFoundation
import Foundation
import OnScreenText

enum OnScreenTextSettings {
    static let narrateKey = "onScreenText.narrate"
    static let voiceKey = "onScreenText.voice"
    static let rateKey = "onScreenText.rate"
    static let areaKey = "onScreenText.area"
    static let customTopKey = "onScreenText.customTop"
    static let customBottomKey = "onScreenText.customBottom"

    /// Where to look for subtitles.
    enum Area: String, CaseIterable, Identifiable {
        case bottom, top, whole, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bottom: "Bottom"
            case .top: "Top"
            case .whole: "Whole Picture"
            case .custom: "Custom"
            }
        }
    }

    static var narrates: Bool {
        HypnosDefaults.store.object(forKey: narrateKey) as? Bool ?? true
    }

    static var area: Area {
        HypnosDefaults.store.string(forKey: areaKey).flatMap(Area.init) ?? .bottom
    }

    /// The custom band, as fractions of the picture from the top.
    static var customTop: Double { HypnosDefaults.store.object(forKey: customTopKey) as? Double ?? 0.55 }
    static var customBottom: Double { HypnosDefaults.store.object(forKey: customBottomKey) as? Double ?? 1 }

    static var region: OnScreenTextRegion {
        switch area {
        case .bottom: .bottom
        case .top: .top
        case .whole: .wholePicture
        case .custom:
            OnScreenTextRegion(top: min(customTop, customBottom - 0.05), bottom: max(customBottom, customTop + 0.05))
        }
    }

    static var narratorSettings: OnScreenTextNarrator.Settings {
        let defaults = HypnosDefaults.store
        let rate = defaults.object(forKey: rateKey) as? Double ?? 1
        return OnScreenTextNarrator.Settings(voiceIdentifier: defaults.string(forKey: voiceKey),
                                             rate: Float(min(max(rate, 0.5), 1.5)))
    }

    /// The voices worth offering: the system's, best quality first, the
    /// viewer's language before others, novelty voices left out.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let base = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                let ar = rank(a, base), br = rank(b, base)
                if ar != br { return ar < br }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice, _ base: String) -> Int {
        let personal = voice.voiceTraits.contains(.isPersonalVoice) ? 0 : 1
        let sameLanguage = voice.language.hasPrefix(base) ? 0 : 1
        let quality = 3 - voice.quality.rawValue   // premium 3, enhanced 2, default 1
        return personal * 100 + sameLanguage * 10 + quality
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.voiceTraits.contains(.isPersonalVoice) { return "Personal Voice" }
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}
