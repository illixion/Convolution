/*
 Hypnos - the music engine's ties to the rest of the app: the equalizer on its output and its log.
 Kept apart from the engine so `scripts/check-music-player.sh` can compile the engine without RAVEMedia
 or DebugTrace (the checks stub this file).
 */

import Foundation
import DebugTrace
import RAVEMedia

extension EQProcessor: MusicSampleProcessor {}

@MainActor
enum MusicEngineHooks {
    /// The app's equalizer, following its settings, for the engine's mixed output.
    static func makeProcessor() -> MusicSampleProcessor? { RAVEMediaPolicy.audioEQ?.makeProcessor() }
    static var hasEqualizer: Bool { RAVEMediaPolicy.audioEQ != nil }

    /// The engine's messages are its own wording, HTTP statuses and codec codes: never a URL or a name.
    static func log(failure message: String) {
        AppLogger.library.error("Music engine: \(message, privacy: .public)")
    }
}
