/*
 Hypnos - On-Screen Text on the debug server

 `GET /onScreenText` reports, per video window, what the burned-in subtitle
 reader is doing: on or off, its status, how far ahead it has read, the
 recognizer's counts, and the cues by time and length. Never the text read
 (it is the video's dialogue). `POST /onScreenTextSelect` turns it on or off
 for the first video window, as the subtitle menu does.
 */

import DebugTrace
import Foundation
import OnScreenText

@MainActor
enum OnScreenTextDebugEndpoints {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        DebugSurface.shared.register([
            .query("onScreenText", "Each video window's On-Screen Text reader: enabled, status, seconds read ahead, "
                   + "buffering, error, area, narration on, and its cues as start/end/characters. No text.") { _ in
                VideoWindowModel.withNativePlayers.allObjects.map { model -> [String: JSONValue] in
                    let reader = model.subtitles.onScreen
                    let cues: [JSONValue] = reader.cues.map { cue in
                        .object(["start": .double(cue.start), "end": .double(cue.end), "characters": .double(Double(cue.text.count))])
                    }
                    return [
                        "available": .bool(model.subtitles.canReadScreen),
                        "enabled": .bool(reader.enabled),
                        "status": .string(reader.status),
                        "readAheadSeconds": .double(reader.readAheadSeconds),
                        "buffering": .bool(reader.isBuffering),
                        "error": reader.error.map(JSONValue.string) ?? .null,
                        "area": .string(OnScreenTextSettings.area.rawValue),
                        "narrates": .bool(OnScreenTextSettings.narrates),
                        "narrating": .bool(model.subtitles.isNarrating),
                        "playhead": .double(model.currentTime),
                        "muted": .bool(model.isMuted),
                        "cues": .array(cues),
                        "scout": .object(reader.scoutState.mapValues(JSONValue.string)),
                    ]
                }
            },
            .command("onScreenTextSelect", "Turns On-Screen Text on or off in the first video window that can read its picture.",
                     parameters: [.boolean("on", "true to read the picture, false for no subtitles", required: true)]) { args in
                guard let model = VideoWindowModel.withNativePlayers.allObjects.first(where: { $0.subtitles.canReadScreen }) else {
                    return ["available": false]
                }
                let on = args.bool("on") ?? true
                if on != model.subtitles.onScreen.enabled {
                    if on { model.subtitles.selectOnScreenText() } else { model.subtitles.select(nil) }
                }
                return ["available": true, "enabled": model.subtitles.onScreen.enabled]
            },
        ])
    }
}
