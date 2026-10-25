/*
 MatroskaRemux - the HLS playlists

 One video variant, and each kept audio track as its own
 `EXT-X-MEDIA TYPE=AUDIO` rendition in one group, so the player's audio menu
 lists the file's tracks by name and language and switching is the
 player's own. Segments are demuxed, as Apple's authoring spec prefers.

 The variant says what a player needs to choose and present it right:
 CODECS for every format in it, RESOLUTION, FRAME-RATE when the video is
 constant-rate, and VIDEO-RANGE, without which a PQ or HLG picture is shown
 as SDR. BANDWIDTH is the peak over segments of the bytes each segment's
 clusters span (every track's, so an overestimate where tracks were
 dropped), AVERAGE-BANDWIDTH the whole file's.

 Audio and video playlists share the segment boundaries, so each segment
 number names the same stretch of the file in every rendition.
 */

import Foundation

enum Playlists {
    static func media(index: SegmentIndex, timestampScale: Int64, prefix: String) -> String {
        let durations = (0 ..< index.count).map { k in
            Double(index.endTime(k) - index.startTime(k)) * Double(timestampScale) / 1e9
        }
        let target = Int((durations.max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, target))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(prefix)/init.mp4\"",
        ]
        for (k, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.6f,", max(0.001, duration)))
            lines.append("\(prefix)/\(k).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The track the group plays first: the first one flagged default,
    /// else the first.
    static func defaultAudio(_ audio: [AudioPlan]) -> AudioPlan? {
        audio.first { $0.track.isDefault } ?? audio.first
    }

    /// Each audio track's NAME, unique within the group: the track's own
    /// name, else its language's, else a number; tracks that would share one
    /// are told apart by their channels, then by number.
    static func renditionNames(_ audio: [AudioPlan]) -> [UInt64: String] {
        func layout(_ channels: Int) -> String {
            switch channels {
            case 1: "Mono"
            case 2: "Stereo"
            case 6: "5.1"
            case 8: "7.1"
            default: "\(channels) channels"
            }
        }
        var base: [UInt64: String] = [:]
        for (i, plan) in audio.enumerated() {
            if let name = plan.track.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                base[plan.track.number] = name
            } else if let language = plan.track.bcp47Language,
                      let display = Locale.current.localizedString(forLanguageCode: language) {
                base[plan.track.number] = display.prefix(1).uppercased() + display.dropFirst()
            } else {
                base[plan.track.number] = audio.count == 1 ? layout(plan.channels) : "Track \(i + 1)"
            }
        }
        var names = base
        let counts = Dictionary(grouping: audio, by: { base[$0.track.number]! })
        for (name, plans) in counts where plans.count > 1 {
            for plan in plans { names[plan.track.number] = "\(name) (\(layout(plan.channels)))" }
        }
        var seen: [String: Int] = [:]
        for plan in audio {
            let name = names[plan.track.number]!
            seen[name, default: 0] += 1
            if seen[name]! > 1 { names[plan.track.number] = "\(name) \(seen[name]!)" }
        }
        return names
    }

    static func master(index: SegmentIndex, header: MatroskaHeader, video: VideoPlan, audio: [AudioPlan],
                       names: [UInt64: String]) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        let defaultTrack = defaultAudio(audio)?.track.number
        for plan in audio {
            var attributes = ["TYPE=AUDIO", "GROUP-ID=\"audio\"", "NAME=\"\(quoted(names[plan.track.number] ?? "Audio"))\""]
            if let language = plan.track.bcp47Language { attributes.append("LANGUAGE=\"\(quoted(language))\"") }
            attributes.append("DEFAULT=\(plan.track.number == defaultTrack ? "YES" : "NO")")
            attributes.append("AUTOSELECT=YES")
            attributes.append("CHANNELS=\"\(plan.hlsChannels)\"")
            attributes.append("URI=\"audio-\(plan.track.number).m3u8\"")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }

        let scale = Double(header.timestampScale)
        var peak = 0.0, totalBytes = 0.0, totalSeconds = 0.0
        for k in 0 ..< index.count {
            let seconds = Double(index.endTime(k) - index.startTime(k)) * scale / 1e9
            let bytes = Double(index.byteLength(k))
            totalBytes += bytes
            totalSeconds += seconds
            if seconds > 0.5 { peak = max(peak, bytes * 8 / seconds) }
        }
        let average = totalSeconds > 0 ? totalBytes * 8 / totalSeconds : 0
        peak = max(peak, average)

        var codecs = [video.codecs]
        for plan in audio where !codecs.contains(plan.codecs) { codecs.append(plan.codecs) }
        var attributes = [
            "BANDWIDTH=\(max(64000, Int(peak.rounded(.up))))",
            "AVERAGE-BANDWIDTH=\(max(64000, Int(average.rounded(.up))))",
            "CODECS=\"\(codecs.joined(separator: ","))\"",
        ]
        if let supplemental = video.supplementalCodecs { attributes.append("SUPPLEMENTAL-CODECS=\"\(supplemental)\"") }
        attributes.append("RESOLUTION=\(video.displayWidth)x\(video.displayHeight)")
        if let rate = video.framesPerSecond { attributes.append(String(format: "FRAME-RATE=%.3f", rate)) }
        attributes.append("VIDEO-RANGE=\(video.videoRange)")
        if !audio.isEmpty { attributes.append("AUDIO=\"audio\"") }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Attribute values can't hold a double quote or a line break.
    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
    }
}
