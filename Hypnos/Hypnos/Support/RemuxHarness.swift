/*
 Hypnos - Matroska remux: end-to-end harness (macOS, DEBUG only)

 Plays files through the app's real path (`MatroskaRemuxService`: sniff,
 session, loopback server, decode probe) in AVFoundation and prints one
 `HARNESS:` line per check, then exits. Like `LibraryHarness`, it exists
 because the package's tests stop at the MP4 it writes; this is the HLS
 player's view: the playlists, the renditions, seeking, audio switching.

     Hypnos.app/Contents/MacOS/Hypnos -RemuxHarness <file or URL>... \
         [-RemuxHarnessForm master|muxed] [-RemuxHarnessHold <seconds>] \
        [-RemuxHarnessPlay <seconds>]

 Per input: whether it was remuxed and how fast, the decode probe, each
 track's format description (codec, transfer function, mastering and
 light-level metadata), 3 s of playback (time advancing, frames arriving
 from an AVPlayerItemVideoOutput), a seek to 70 % and 3 s more, the
 audio renditions (listed, then switched to another and played), and each
 embedded subtitle track's cues near the start and near 70 %, read the way
 the players read them (`MatroskaSubtitles`).
 `-RemuxHarnessHold` keeps the loopback server up afterwards and prints each
 URL, for decoding the served HLS with ffmpeg. `-RemuxHarnessPlay` plays
 that long instead of 3 s, before and after the seek, for measuring what a
 server file costs in reads (have the server log the ranges it sends).

 Point it at local files or the disposable dev Stash
 (`scripts/dev-stash.sh`, http://127.0.0.1:9998), never at a real server.
 */

#if DEBUG && os(macOS)

import AVFoundation
import CoreMedia
import Foundation
import MatroskaRemux
import os

enum RemuxHarness {
    private static let launchFlag = "-RemuxHarness"

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: launchFlag) else { return }
        let inputs = arguments[(flag + 1)...].prefix { !$0.hasPrefix("-") }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let form: MatroskaRemuxService.Form = switch value("-RemuxHarnessForm") {
        case "master": .master
        case "muxed": .muxed
        default: .automatic
        }
        let hold = value("-RemuxHarnessHold").flatMap(Double.init) ?? 0
        let play = value("-RemuxHarnessPlay").flatMap(Double.init) ?? 3
        Task { @MainActor in
            playSeconds = play
            log("eligibleForHDRPlayback=\(AVPlayer.eligibleForHDRPlayback)")
            var served: [URL] = []
            for input in inputs {
                if let url = await run(input, form: form) { served.append(url) }
            }
            if hold > 0 {
                for url in served { log("serving \(url.absoluteString)") }
                log("holding \(Int(hold)) s")
                try? await Task.sleep(for: .seconds(hold))
            }
            log("done")
            exit(0)
        }
    }

    @MainActor private static var playSeconds = 3.0

    private static func log(_ line: String) {
        print("HARNESS: \(line)")
        fflush(stdout)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }

    @MainActor
    private static func run(_ input: String, form: MatroskaRemuxService.Form) async -> URL? {
        let source = input.hasPrefix("http") ? URL(string: input)! : URL(fileURLWithPath: input)
        let name = source.lastPathComponent
        log("== \(name)")
        let started = ContinuousClock.now
        guard let hls = await MatroskaRemuxService.shared.playlistURL(for: source, fileName: nil, form: form) else {
            log("\(name): not remuxed (declined or unplayable)")
            return nil
        }
        log("\(name): remuxed in \(ContinuousClock.now - started) → \(hls.lastPathComponent)")
        log("\(name): probe canPlayNatively=\(await NativeVideoDecodeProbe.canPlayNatively(url: hls))")

        let asset = MediaAuthorization.shared.asset(for: hls)
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }

        for _ in 0 ..< 200 where item.status == .unknown { try? await Task.sleep(for: .milliseconds(50)) }
        guard item.status == .readyToPlay else {
            let error = item.error as NSError?
            log("\(name): FAIL status=\(item.status.rawValue) error=\(error.map { "\($0.domain) \($0.code)" } ?? "-")")
            return hls
        }
        log("\(name): ready, duration=\(String(format: "%.3f", item.duration.seconds))")
        await checkSubtitles(name, source: source, duration: item.duration.seconds)

        player.play()
        await watch(name, label: "play", player: player, item: item, output: output, seconds: playSeconds,
                    describe: true)

        // Audio renditions: list, switch, play on.
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            let options = group.options.map { "\($0.displayName)[\($0.extendedLanguageTag ?? "-")]" }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            log("\(name): audio options \(options) selected=\(selected?.displayName ?? "nil")")
            if let other = group.options.first(where: { $0 != selected }) {
                item.select(other, in: group)
                await watch(name, label: "after audio switch", player: player, item: item, output: output, seconds: 2,
                            describe: false)
                let now = item.currentMediaSelection.selectedMediaOption(in: group)
                log("\(name): audio now \(now?.displayName ?? "nil") \(now == other ? "OK" : "FAIL")")
            }
        } else {
            log("\(name): no audible group")
        }

        // Seek to 70 % and play again.
        let target = CMTime(seconds: item.duration.seconds * 0.7, preferredTimescale: 600)
        let sought = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        log("\(name): seek to \(String(format: "%.2f", target.seconds)) finished=\(sought) at \(String(format: "%.3f", item.currentTime().seconds))")
        player.play()
        await watch(name, label: "after seek", player: player, item: item, output: output,
                    seconds: min(playSeconds, item.duration.seconds * 0.3 - 0.3), describe: false)
        // The end: from 2 s before it, the item has to finish (a rendition
        // that runs out early stalls an HLS player instead).
        let ended = OSAllocatedUnfairLock(initialState: false)
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                              queue: nil) { _ in ended.withLock { $0 = true } }
        await player.seek(to: CMTime(seconds: max(0, item.duration.seconds - 2), preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        for _ in 0 ..< 80 where !ended.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(50)) }
        NotificationCenter.default.removeObserver(observer)
        log("\(name): played to the end \(ended.withLock { $0 } ? "OK" : "FAIL") at \(String(format: "%.3f", item.currentTime().seconds))")

        if let error = item.error as NSError? { log("\(name): FAIL item error \(error.domain) \(error.code)") }
        return hls
    }

    /// Each subtitle track's first cues read near the start and near 70 %.
    @MainActor
    private static func checkSubtitles(_ name: String, source: URL, duration: Double) async {
        guard let session = MatroskaRemuxService.shared.session(for: source) else { return }
        for track in session.subtitleTracks {
            let listed = MatroskaSubtitles.libraryTrack(track)
            guard listed.isPlayable else {
                log("\(name): subtitles \(listed.title) [\(track.codecID)] not playable (\(track.unsupportedReason ?? "-"))")
                continue
            }
            for at in [0, duration * 0.7] {
                let started = ContinuousClock.now
                var cues = MatroskaSubtitles.cues(session, track: track, playhead: { at }).makeAsyncIterator()
                guard let first = await cues.next() else { continue }
                let near = first.cues.first { $0.end >= at }
                let what = near.map { cue in
                    String(format: "%.3f–%.3f ", cue.start, cue.end) + (cue.image != nil ? "<image>" : "\"\(cue.plainText)\"")
                } ?? "none"
                log("\(name): subtitles \(listed.title) [\(track.codecID)\(track.isIndexed ? ", indexed" : "")] near \(Int(at)) s: \(first.cues.count) cues in \(ContinuousClock.now - started), first \(what)")
            }
        }
    }

    /// Plays for `seconds`, counting new frames and how far time advanced.
    @MainActor
    private static func watch(_ name: String, label: String, player: AVPlayer, item: AVPlayerItem,
                              output: AVPlayerItemVideoOutput, seconds: Double, describe: Bool) async {
        let start = item.currentTime().seconds
        var frames = 0
        var firstFrame: String?
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(8))
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            frames += 1
            if firstFrame == nil {
                let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
                firstFrame = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) transfer=\(transfer ?? "nil")"
            }
        }
        let advanced = item.currentTime().seconds - start
        let ok = advanced > seconds * 0.6 && frames > Int(seconds * 5) && item.status != .failed
        log("\(name): \(label): time \(String(format: "%.2f", start))→\(String(format: "%.2f", item.currentTime().seconds)) (+\(String(format: "%.2f", advanced))), frames=\(frames), first=\(firstFrame ?? "none") \(ok ? "OK" : "FAIL")")
        guard describe else { return }
        for track in item.tracks {
            guard let assetTrack = track.assetTrack,
                  let descriptions = try? await assetTrack.load(.formatDescriptions) else { continue }
            for description in descriptions {
                var line = "\(name): track \(assetTrack.mediaType.rawValue) \(fourCC(CMFormatDescriptionGetMediaSubType(description)))"
                if let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] {
                    for key in [kCVImageBufferTransferFunctionKey as String, kCVImageBufferColorPrimariesKey as String,
                                kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String,
                                kCMFormatDescriptionExtension_ContentLightLevelInfo as String] where extensions[key] != nil {
                        line += " \(key)=\(extensions[key] is Data ? "<\((extensions[key] as! Data).count) bytes>" : "\(extensions[key]!)")"
                    }
                    if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] {
                        line += " atoms=\(atoms.keys.sorted())"
                    }
                }
                if let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    line += " \(Int(audio.mSampleRate)) Hz \(audio.mChannelsPerFrame) ch"
                }
                log(line)
            }
        }
    }
}

#endif
