/*
 Hypnos - Video Window: playback info

 What the window's playback info panel shows (`PlaybackInfo`): the route the
 picture takes, why, and what it is. The route is read off the window's own
 state (renderer, remux, transcode, the Library stream's URL); the reasons
 are what failed on the way (`playbackRefusals`, noted where each fallback
 happens) and why a Library stream is at its level (`streamLevelReason`);
 the dynamic range is the frames' (`pictureFrameRange`, from the native
 player or the stereo engine) named with the source's metadata (Jellyfin's,
 or the remux's own reading of the file). For a server stream, Jellyfin's
 `/Sessions` says whether it copies or converts the video and the audio.
 */

import AVFoundation
import DebugTrace
import Foundation
import MatroskaRemux
import RAVEMedia

/// Why a Library stream plays below its original.
enum PlaybackLevelReason: Equatable {
    /// The viewer's Quality choice, or the saved preference it opened at.
    case chosen
    /// Auto stepped down after buffering.
    case autoBuffering
    /// AI 3D couldn't keep up at the full picture, or needs it at 1080p.
    case ai3D
}

extension VideoWindowModel {
    /// What the panel shows now.
    var playbackInfo: PlaybackInfo {
        let route = playbackRoute
        var reasons = playbackRefusals
        var severity = PlaybackInfo.Severity.normal
        var server: String?

        switch route {
        case .opening, .direct, .youTube:
            break
        case .deviceRemux:
            break
        case .webPlayer:
            severity = .issue
            if reasons.isEmpty { reasons = ["the native player can't open this file"] }
        case .serverRemux, .serverTranscode:
            server = libraryItemId != nil ? "Jellyfin" : "Stash"
            if ai3DUsesStashTier {
                severity = .chosen
                reasons.append("AI 3D plays the server's 1080p version")
            }
            if let level = streamLevel {
                let reason = streamLevelReason ?? .chosen
                switch reason {
                case .chosen:
                    reasons.append("quality set to \(level.title)")
                    if severity == .normal { severity = .chosen }
                case .autoBuffering:
                    reasons.insert("Auto lowered quality to \(level.title) after buffering", at: 0)
                    severity = .issue
                case .ai3D:
                    reasons.append("AI 3D plays at \(level.title) to keep up")
                    if severity == .normal { severity = .chosen }
                }
            } else if libraryItemId != nil, !usingTranscodedStream, playbackRefusals.isEmpty {
                // The plan itself was a server stream for the original.
                if let container = librarySource?.container?.lowercased(),
                   container.split(separator: ",").contains(where: { $0 == "mkv" || $0 == "matroska" }),
                   !JellyfinLibrary.remuxesOnDevice {
                    reasons.append("Play MKV Files on This Device is off")
                    severity = .chosen
                } else {
                    reasons.append("the native player can't open the original file")
                    severity = .issue
                }
            }
            if !playbackRefusals.isEmpty { severity = .issue }
            if let transcode = serverTranscode, let why = transcode.reasonsText {
                reasons.append("the server says: \(why)")
            }
        }

        let displaysHDR = AVPlayer.eligibleForHDRPlayback
        let sourceRange = playbackSourceRange
        var range = VideoDynamicRange.describe(frames: pictureFrameRange, source: sourceRange, displaysHDR: displaysHDR)
        if pictureFrameRange == nil, var named = range {
            named.note = [named.note, "as the file's metadata says; the player can't confirm it"]
                .compactMap { $0 }.joined(separator: "; ")
            range = named
        }

        return PlaybackInfo(route: route, severity: severity, server: server, reasons: reasons,
                            picture: pictureDetails, range: range, rangeFromFrames: pictureFrameRange != nil,
                            transcode: route.isServerConversion ? serverTranscode : nil,
                            source: librarySourceSummary)
    }

    /// The route the picture takes now.
    var playbackRoute: PlaybackInfo.Route {
        #if HYPNOS_YOUTUBE
        if youTubeID != nil { return playbackRenderer == .resolving ? .opening : .youTube }
        #endif
        switch playbackRenderer {
        case .resolving: return .opening
        case .webKit: return .webPlayer
        case .nativeMetal: break
        }
        if ai3DUsesStashTier { return .serverTranscode }
        if usingTranscodedStream {
            // Stash always re-encodes; Jellyfin's reserve may copy.
            guard libraryItemId != nil else { return .serverTranscode }
            return serverTranscode?.isVideoDirect == true ? .serverRemux : .serverTranscode
        }
        if remuxedStreamURL != nil { return .deviceRemux }
        if JellyfinLibrary.isServerStream(video.streamURL) {
            if let transcode = serverTranscode { return transcode.isVideoDirect ? .serverRemux : .serverTranscode }
            // Until the server says: a capped level is a transcode, the
            // original's stream copies its video.
            return streamLevel == nil ? .serverRemux : .serverTranscode
        }
        return .direct
    }

    /// What the source file is in dynamic range, as far as anything says.
    private var playbackSourceRange: VideoSourceRange? {
        if let range = librarySource?.range { return range }
        guard let remux = remuxedStreamURL, let summary = MatroskaRemuxService.shared.session(playing: remux)?.summary
        else { return nil }
        if let profile = summary.dolbyVisionProfile {
            return VideoSourceRange(kind: .dolbyVision(profile: profile, compatibility: summary.dolbyVisionCompatibility))
        }
        switch summary.videoRange {
        case "PQ": return VideoSourceRange(kind: .hdr10)
        case "HLG": return VideoSourceRange(kind: .hlg)
        default: return VideoSourceRange(kind: .sdr)
        }
    }

    /// "HEVC Main 10 · 10-bit · Dolby Vision 8.1 · 4.4 Mbps · MKV": the
    /// Library file as the server read it.
    private var librarySourceSummary: String? {
        guard let source = librarySource else { return nil }
        var parts: [String] = []
        if let codec = source.videoCodec {
            parts.append([Self.codecName(codec), source.videoProfile].compactMap { $0 }.joined(separator: " "))
        }
        if let depth = source.bitDepth, depth > 8 { parts.append("\(depth)-bit") }
        if let range = source.range { parts.append(range.label) }
        if let bitrate = source.bitrate, bitrate > 0 {
            parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000))
        }
        if let container = source.container?.split(separator: ",").first {
            parts.append(container.uppercased())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "HEVC", "H.264", "AV1", "E-AC-3": a codec id as people say it.
    static func codecName(_ id: String) -> String {
        switch id.lowercased() {
        case "hevc", "h265": "HEVC"
        case "h264", "avc": "H.264"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "aac": "AAC"
        case "ac3": "AC-3"
        case "eac3": "E-AC-3"
        case "truehd": "TrueHD"
        case "dts": "DTS"
        case "flac": "FLAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        default: id.uppercased()
        }
    }

    // MARK: - Noting what happens

    /// A renderer read its frames. The stereo players never apply a Dolby
    /// Vision RPU, so in 3D a Dolby Vision picture is its base layer.
    func notePictureFrameRange(_ range: VideoFrameRange, stereo: Bool) {
        var shown = range
        if stereo { shown.hasDolbyVisionRPU = false }
        guard shown != pictureFrameRange else { return }
        pictureFrameRange = shown
        AppLogger.videoWindow.info("Picture is \(shown.transfer.rawValue, privacy: .public)\(shown.hasDolbyVisionRPU ? " with a Dolby Vision RPU" : "", privacy: .public)\(stereo ? " (stereo)" : "", privacy: .public)")
    }

    /// Why the original isn't what plays natively, as found (code-defined
    /// text). Kept for this video, shown as the fallback's reason.
    func notePlaybackRefusal(_ reason: String) {
        guard !playbackRefusals.contains(reason) else { return }
        playbackRefusals.append(reason)
        AppLogger.videoWindow.info("Fallback: \(reason, privacy: .public)")
    }

    /// Forgets what was noted about the previous video's playback.
    func resetPlaybackInfo() {
        playbackRefusals = []
        pictureFrameRange = nil
        streamLevelReason = nil
        serverTranscode = nil
        serverTranscodeTask?.cancel()
        serverTranscodeTask = nil
    }

    /// Why a Library stream switched to `level`, from `switchStream`'s reason.
    func noteStreamLevel(_ level: LibraryStreamQuality?, reason: String, forAI3D: Bool) {
        guard level != nil else {
            streamLevelReason = nil
            return
        }
        switch reason {
        case "chosen": streamLevelReason = .chosen
        case "auto": streamLevelReason = .autoBuffering
        default: if forAI3D { streamLevelReason = .ai3D }
        }
    }

    // MARK: - The server's encoder

    /// Keeps `serverTranscode` current while a Jellyfin stream plays: the
    /// encoder's job reports to the session once it starts, and a seek or a
    /// new level starts another.
    func watchServerTranscode() {
        let serverStream = libraryItemId != nil
            && (JellyfinLibrary.isServerStream(activeStreamURL) || usingTranscodedStream)
            && playbackRenderer == .nativeMetal
        guard serverStream, let itemId = libraryItemId else {
            serverTranscodeTask?.cancel()
            serverTranscodeTask = nil
            if serverTranscode != nil { serverTranscode = nil }
            return
        }
        serverTranscodeTask?.cancel()
        serverTranscodeTask = Task { [weak self] in
            var delay = Duration.seconds(2)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let library = LibraryService.current() else { return }
                let info = await library.transcodingInfo(itemId: itemId)
                guard !Task.isCancelled, let self, self.libraryItemId == itemId else { return }
                if info != self.serverTranscode {
                    self.serverTranscode = info
                    if let info {
                        AppLogger.videoWindow.info("Server encoder: video \(info.isVideoDirect ? "copied" : "converted to \(info.videoCodec ?? "?")", privacy: .public), audio \(info.isAudioDirect ? "copied" : "converted to \(info.audioCodec ?? "?")", privacy: .public); \(info.reasonsText ?? "no reasons given", privacy: .public)")
                    }
                }
                delay = info == nil ? .seconds(5) : .seconds(15)
            }
        }
    }
}
