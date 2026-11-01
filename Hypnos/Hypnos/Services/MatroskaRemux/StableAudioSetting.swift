/*
 Hypnos - Settings → Videos → Stable Audio

 A film's sound, levelled around its dialogue (`StableAudio.swift` in
 MatroskaRemux): quiet speech brought up, effects and music ducked under it
 while someone talks, loud passages brought down. It is an extra audio
 track of the on-device remux, made from a track the remux decodes, so it
 exists only where a track is decoded on the device: today DTS and TrueHD,
 in the sideload edition (`FFmpegRemuxDecoding.swift`).

 "Use by Default" makes it the track a player starts with, which is the
 only way to hear it in 3D: the stereo players have no audio menu
 (`VideoWindowModel+AudioTracks.swift`).
 */

import Foundation
import MatroskaRemux

enum StableAudioSetting: String, CaseIterable, Identifiable {
    case off, offered, preferred

    static let key = "video.stableAudio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .offered: "Offer as a Track"
        case .preferred: "Use by Default"
        }
    }

    var mode: StableAudioMode {
        switch self {
        case .off: .off
        case .offered: .offered
        case .preferred: .preferred
        }
    }
}

extension MatroskaRemuxService {
    /// Decoders for audio MP4 can't carry, where this build has any.
    static var audioDecoding: RemuxAudioDecoding? {
        #if HYPNOS_FFMPEG
        FFmpegRemuxDecoder.decoding
        #else
        nil
        #endif
    }

    /// Whether Stable Audio can do anything in this build.
    static var offersStableAudio: Bool { audioDecoding != nil }

    static var stableAudioMode: StableAudioMode {
        let stored = UserDefaults.standard.string(forKey: StableAudioSetting.key).flatMap(StableAudioSetting.init)
        return (stored ?? .offered).mode
    }
}
