/*
 Hypnos - Stable Audio: the switch in the volume popover

 A film's sound, levelled around its dialogue (`StableAudio.swift` in
 MatroskaRemux): quiet speech brought up, effects and music ducked under it
 while someone talks, loud passages brought down. The on-device remux makes
 it as a second copy of each audio track ("English (Stable)"), decoded on
 the device: AAC, AC-3 and E-AC-3 with the system's decoders in every build
 (`SystemAudioDecoding`), DTS and TrueHD with FFmpeg in the sideload edition
 (`FFmpegRemuxDecoding.swift`).

 The copies never appear in the Audio menu. The switch beside the volume
 slider picks between each track and its copy in whichever player plays
 (`VideoWindowModel.setStableAudio`), in 2D and 3D alike, and is remembered
 for every video; while it is on, a remux lists the copies first, so a
 player starts on them.
 */

import Foundation
import MatroskaRemux

enum StableAudioSetting {
    static let key = "video.stableAudioOn"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension MatroskaRemuxService {
    /// The decoders the remux may use: FFmpeg's for DTS and TrueHD where
    /// this build has them, the system's for the rest.
    static var audioDecoding: RemuxAudioDecoding {
        #if HYPNOS_FFMPEG
        SystemAudioDecoding.combined(with: FFmpegRemuxDecoder.decoding)
        #else
        SystemAudioDecoding.decoding
        #endif
    }

    /// Every remux offers Stable copies; the switch decides which plays
    /// first.
    static var stableAudioMode: StableAudioMode {
        StableAudioSetting.isOn ? .preferred : .offered
    }
}
