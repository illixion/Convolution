/*
 MatroskaRemux - the HLS playlists

 One video variant, and each kept audio track as its own
 `EXT-X-MEDIA TYPE=AUDIO` rendition in one group, so the player's audio menu
 lists the file's tracks and switching is the player's own. Segments are
 demuxed, as Apple's authoring spec prefers.

 What the audio menus show. AVKit's menus (tvOS AVPlayerViewController,
 macOS AVPlayerView) list each option's `displayName`, which AVFoundation
 makes from LANGUAGE alone (measured on macOS 27 against a loopback
 master): the language's name in the user's locale ("English", "Anglais"),
 plus "AD" and the like for CHARACTERISTICS. NAME never shows; it is only
 the option's common title metadata (`m3u8/NAME`). Without LANGUAGE the
 option is "Unknown"; "und" reads "Unknown language", "mul" "Multiple
 languages", "zxx" "No linguistic content", and the valid tags that name no
 language read as code ("qaa", "x-surround", "Root (Private-Use:
 surround)"). A LANGUAGE value AVFoundation can't read as a language is
 shown as it is. So a rendition whose track has a language keeps it (the
 player then also selects it by the user's preferred languages), and one
 without carries its NAME there: the track's name, else codec and layout
 ("AC-3 5.1"), never a language the file doesn't state. Where tracks share
 a language, the default one (else the first) keeps the tag and the others
 show their NAME, so the menu doesn't list "English" twice. A NAME that
 would itself read as a language code ("de") gets its layout added.

 The variant says what a player needs to choose and present it right:
 CODECS for every format in it, RESOLUTION, FRAME-RATE when the video is
 constant-rate, and VIDEO-RANGE, without which a PQ or HLG picture is shown
 as SDR. BANDWIDTH is the peak over segments of the bytes each segment's
 clusters span (every track's, so an overestimate where tracks were
 dropped), AVERAGE-BANDWIDTH the whole file's.

 Audio and video playlists share the segment boundaries, so each segment
 number names the same stretch of the file in every rendition.

 A file still being indexed (a server's file without Cues,
 `ProgressiveIndex.swift`) gets EVENT media playlists listing the segments
 known so far, with a target duration fixed when the session opened, and
 `EXT-X-ENDLIST` once the index is done. They carry
 `EXT-X-START:TIME-OFFSET=0`: without it AVPlayer starts an EVENT playlist
 three target durations from its end (210 s into a 240 s one, measured),
 with it at 0 (a playlist still that short also gets an error-log entry,
 -16831 "START-TIME is too close to live", and plays from 0 all the same).
 The master's BANDWIDTH is estimated from the segments known then and the
 file's average when Info has a Duration.
 */

import Foundation

enum Playlists {
    /// A media playlist: VOD, or (with `eventTargetDuration`) EVENT, ended
    /// once the index is complete.
    static func media(index: SegmentIndex, timestampScale: Int64, prefix: String,
                      eventTargetDuration: Int? = nil) -> String {
        let durations = (0 ..< index.count).map { k in
            Double(index.endTime(k) - index.startTime(k)) * Double(timestampScale) / 1e9
        }
        let target = eventTargetDuration ?? Int((durations.max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, target))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(eventTargetDuration == nil ? "VOD" : "EVENT")",
        ]
        if eventTargetDuration != nil { lines.append("#EXT-X-START:TIME-OFFSET=0") }
        lines += [
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(prefix)/init.mp4\"",
        ]
        for (k, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.6f,", max(0.001, duration)))
            lines.append("\(prefix)/\(k).m4s")
        }
        if index.isComplete { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The target duration a growing index's playlists keep: its longest
    /// segment so far, and no less than the longest segments are cut to.
    static func targetDuration(index: SegmentIndex, timestampScale: Int64) -> Int {
        let longest = (0 ..< index.count).map { k in
            Double(index.endTime(k) - index.startTime(k)) * Double(timestampScale) / 1e9
        }.max() ?? 0
        return Int(max(longest, SegmentIndex.maximumSeconds).rounded(.up))
    }

    /// The track the group plays first: the first one flagged default,
    /// else the first.
    static func defaultAudio(_ audio: [AudioPlan]) -> AudioPlan? {
        audio.first { $0.track.isDefault } ?? audio.first
    }

    static func layout(_ channels: Int) -> String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) channels"
        }
    }

    /// The audio renditions in the master's order: each track's NAME,
    /// unique within the group (the track's own name, else its language's,
    /// else codec and layout; tracks that would share one told apart by
    /// layout, then by number), and the LANGUAGE that makes the player show
    /// something sensible (see the top of this file).
    static func renditions(_ audio: [AudioPlan]) -> [AudioRendition] {
        let defaultTrack = defaultAudio(audio)?.track.number
        func describe(_ plan: AudioPlan) -> String {
            let objects = if case .eac3(let info) = plan.codec, info.objectComplexity != nil { " with object audio" } else { "" }
            return "\(plan.codecName) \(layout(plan.channels))\(objects)"
        }
        var base: [UInt64: String] = [:]
        var described: Set<UInt64> = []
        for plan in audio {
            if let name = plan.track.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                base[plan.track.number] = name
            } else if let language = plan.track.bcp47Language,
                      let display = Locale.current.localizedString(forLanguageCode: language) {
                base[plan.track.number] = display.prefix(1).uppercased() + display.dropFirst()
            } else {
                base[plan.track.number] = describe(plan)
                described.insert(plan.track.number)
            }
        }
        var names = base
        for (name, plans) in Dictionary(grouping: audio, by: { base[$0.track.number]! }) where plans.count > 1 {
            for plan in plans where !described.contains(plan.track.number) {
                names[plan.track.number] = "\(name) (\(layout(plan.channels)))"
            }
        }
        var seen: [String: Int] = [:]
        for plan in audio {
            let name = names[plan.track.number]!
            seen[name, default: 0] += 1
            if seen[name]! > 1 { names[plan.track.number] = "\(name) \(seen[name]!)" }
        }

        // LANGUAGE: the track's, for the default first; else what to show.
        var tagged: Set<String> = []
        var languages: [UInt64: String] = [:]
        for plan in audio.sorted(by: { ($0.track.number == defaultTrack ? 0 : 1) < ($1.track.number == defaultTrack ? 0 : 1) }) {
            let name = names[plan.track.number]!
            if let language = plan.track.bcp47Language, tagged.insert(language.lowercased()).inserted {
                languages[plan.track.number] = language
            } else if Locale.current.localizedString(forLanguageCode: name) != nil {
                languages[plan.track.number] = "\(name) (\(layout(plan.channels)))"
            } else {
                languages[plan.track.number] = name
            }
        }
        return audio.map { plan in
            var objects = false
            if case .eac3(let info) = plan.codec { objects = info.objectComplexity != nil }
            return AudioRendition(trackNumber: plan.track.number, name: names[plan.track.number]!,
                                  language: plan.track.bcp47Language, playlistLanguage: languages[plan.track.number]!,
                                  codec: plan.codecName, codecs: plan.codecs, channels: plan.channels,
                                  layout: layout(plan.channels), hasObjectAudio: objects,
                                  isDefault: plan.track.number == defaultTrack, uri: "audio-\(plan.track.number).m3u8")
        }
    }

    static func master(index: SegmentIndex, header: MatroskaHeader, video: VideoPlan, audio: [AudioPlan],
                       renditions: [AudioRendition]) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for (plan, rendition) in zip(audio, renditions) {
            var attributes = ["TYPE=AUDIO", "GROUP-ID=\"audio\"", "NAME=\"\(quoted(rendition.name))\""]
            attributes.append("LANGUAGE=\"\(quoted(rendition.playlistLanguage))\"")
            attributes.append("DEFAULT=\(rendition.isDefault ? "YES" : "NO")")
            attributes.append("AUTOSELECT=YES")
            attributes.append("CHANNELS=\"\(plan.hlsChannels)\"")
            attributes.append("URI=\"\(rendition.uri)\"")
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
        var average = totalSeconds > 0 ? totalBytes * 8 / totalSeconds : 0
        // A growing index: the whole file's average, where Info says how
        // long it is.
        if !index.isComplete, let duration = header.durationNanoseconds, duration > 0, let end = header.contentEnd,
           let start = index.boundaries.first?.clusterPosition, end > start {
            average = max(average, Double(end - start) * 8 / (Double(duration) / 1e9))
        }
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

/// One audio rendition of a session's master playlist: what an app needs to
/// build its own audio menu. `name` is the rendition's NAME, unique in the
/// group, and comes back from AVFoundation as the `AVMediaSelectionOption`'s
/// common title metadata, which is how to tell which option is which.
public struct AudioRendition: Sendable, Equatable {
    public var trackNumber: UInt64
    public var name: String
    /// The track's language as the file states it (BCP 47); nil when it
    /// states none (or "und").
    public var language: String?
    /// The playlist's LANGUAGE: `language`, or what the player should show
    /// in its place (see `Playlists`), which is what AVFoundation's
    /// `displayName` reads back.
    public var playlistLanguage: String
    /// "AC-3", "HE-AAC", "Opus".
    public var codec: String
    /// Its CODECS string.
    public var codecs: String
    public var channels: Int
    /// "Mono", "Stereo", "5.1", "7.1", "N channels".
    public var layout: String
    /// E-AC-3 with object audio (HLS CHANNELS "16/JOC").
    public var hasObjectAudio: Bool
    /// The rendition the player starts with (DEFAULT=YES).
    public var isDefault: Bool
    /// The rendition's media playlist, relative to the master.
    public var uri: String
}
