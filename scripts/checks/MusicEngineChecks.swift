import AudioToolbox
import AVFoundation
import Foundation

// The music engine on files made by ffmpeg: decoders, gapless joins, crossfades, seeks, seam detection and the
// transition rules, then a short run through the real renderer. See scripts/check-music-engine.sh.

/// The fields of a Jellyfin song the engine and the rules read.
struct JellyfinMusicItem {
    let Id: String
    var Container: String? = nil
    var AlbumId: String? = nil
    var IndexNumber: Int? = nil
    var ParentIndexNumber: Int? = nil
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let work = fixtures.appendingPathComponent("work")

func pass(_ name: String) { print("\(name): PASS") }
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { print("FAIL: \(message())"); exit(1) }
}

func songFile(_ name: String) -> MusicSongFile {
    let url = fixtures.appendingPathComponent(name)
    let ext = url.pathExtension
    let hint: AudioFileTypeID = ext == "flac" ? kAudioFileFLACType : ext == "mp3" ? kAudioFileMP3Type
        : ext == "wav" ? kAudioFileWAVEType : kAudioFileM4AType
    let file = MusicSongFile(itemID: name + UUID().uuidString, source: .original, remoteURL: url, typeHint: hint, directory: work)
    file.start()
    for _ in 0 ..< 500 where !file.progress.complete { usleep(10_000) }
    check(file.progress.complete, "\(name) never arrived")
    return file
}

func drain(_ decoder: MusicDecoding, format: inout MusicOutputFormat?) -> [Float] {
    var out: [Float] = []
    for _ in 0 ..< 100_000 {
        switch decoder.read(maxFrames: 4096, output: &format) {
        case .audio(let s): out += s
        case .waiting: usleep(1000)
        case .end: return out
        case .failed(let m): check(false, "decode failed: \(m)")
        }
    }
    check(false, "decoder never ended"); return out
}

/// Renders a timeline to its end.
func renderAll(_ timeline: MusicTimeline, plan: ((MusicTimeline) -> Void)? = nil) -> [Float] {
    var out: [Float] = []
    for _ in 0 ..< 100_000 {
        plan?(timeline)
        let (samples, status) = timeline.render(maxFrames: 2048)
        out += samples
        switch status {
        case .finished: return out
        case .starving: usleep(1000)
        case .failed(_, let m): check(false, "timeline failed: \(m)")
        case .audio: break
        }
    }
    check(false, "timeline never finished"); return out
}

func song(_ name: String, gain: Float = 1, seconds: Double) -> MusicTimeline.Song {
    MusicTimeline.Song(token: UUID(), file: songFile(name), gain: gain, estimatedSeconds: seconds)
}

func rms(_ s: ArraySlice<Float>) -> Double {
    guard !s.isEmpty else { return -120 }
    return 10 * log10(s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count) + 1e-12)
}

@main struct MusicEngineChecks {
    static func main() async {
        setbuf(stdout, nil)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let rate = 44_100.0
        var reference: [Float] = []
        var f: MusicOutputFormat?
        reference = drain(MusicFileDecoder(url: fixtures.appendingPathComponent("whole.flac"))!, format: &f)
        let cuts = [0, 3 * 44_100 + 17, 6 * 44_100 + 5_001, reference.count / 2]

        // A. Both decoders, every container: the same samples and exactly the source's frames.
        for (name, frames) in [("t1.flac", cuts[1]), ("t1.mp3", cuts[1]), ("t1-fast.m4a", cuts[1]), ("t1.wav", cuts[1]),
                               ("t1-24.wav", cuts[1]), ("mono22.wav", 3 * 22_050), ("hires.flac", 3 * 96_000)] {
            var fs: MusicOutputFormat?, ff: MusicOutputFormat?
            let stream = drain(MusicStreamDecoder(file: songFile(name)), format: &fs)
            let file = drain(MusicFileDecoder(url: fixtures.appendingPathComponent(name))!, format: &ff)
            check(stream.count / 2 == frames, "\(name): stream decoder gave \(stream.count / 2) frames, expected \(frames)")
            check(file.count / 2 == frames, "\(name): file decoder gave \(file.count / 2) frames, expected \(frames)")
            check(stream == file, "\(name): the two decoders differ")
        }
        let slow = MusicStreamDecoder(file: songFile("t1-slow.m4a"))
        var fslow: MusicOutputFormat?
        _ = slow.read(maxFrames: 4096, output: &fslow)
        check(slow.needsWholeFile, "An MPEG-4 file indexed at its end should need the whole file")
        pass("Every container decodes to its exact frames, streamed or from the file, and both agree")

        // B. Three FLACs cut from one recording, joined gaplessly: the recording, bit for bit.
        let parts = (1 ... 3).map { song("t\($0).flac", seconds: Double(cuts[$0] - cuts[$0 - 1]) / rate) }
        var next = 1
        let timeline = MusicTimeline(song: parts[0])
        let joined = renderAll(timeline) { t in
            if next < 3, t.lastCommitted == parts[next - 1].token {
                t.setNext(parts[next], transition: .gapless, after: parts[next - 1].token); next += 1
            }
        }
        check(joined.count == reference.count, "Gapless FLAC: \(joined.count / 2) frames, expected \(reference.count / 2)")
        check(joined == reference, "Gapless FLAC differs from the recording it was cut from")
        check(timeline.markers.map(\.outputFrame) == [0, Int64(cuts[1]), Int64(cuts[2])], "Markers at \(timeline.markers.map(\.outputFrame))")
        pass("A gapless FLAC join reproduces the recording sample for sample, with each song's marker at its cut")

        // C. The same cut as MP3 and AAC (each part encoded alone): exact length, no gap at the seams.
        for ext in ["mp3", "m4a"] {
            let lossy = (1 ... 3).map { song("t\($0)-fast.\(ext)".replacingOccurrences(of: "-fast.mp3", with: ".mp3"), seconds: 3) }
            var n = 1
            let out = renderAll(MusicTimeline(song: lossy[0])) { t in
                if n < 3, t.lastCommitted == lossy[n - 1].token { t.setNext(lossy[n], transition: .gapless, after: lossy[n - 1].token); n += 1 }
            }
            check(out.count == reference.count, "Gapless \(ext): \(out.count / 2) frames, expected \(reference.count / 2)")
            for cut in cuts[1 ... 2] {
                let window = (cut - 441) ..< (cut + 441)
                let error = window.map { abs(out[2 * $0] - reference[2 * $0]) }.max() ?? 1
                check(error < 0.08, "\(ext) seam at \(cut) is off the recording by up to \(error)")
                let quiet = window.filter { abs(out[2 * $0]) < 1e-4 }.count
                check(quiet < 30, "\(ext) seam at \(cut) has \(quiet) silent frames")
            }
        }
        pass("Lossy songs cut from one recording join at the right length with no gap (encoder priming trimmed)")

        // D. Crossfade: length, where the next song starts, level through the blend, and each song's own gain.
        let a = song("a.flac", seconds: 6), b = song("b.flac", gain: 0.5, seconds: 6)
        let fadeTimeline = MusicTimeline(song: a)
        fadeTimeline.setNext(b, transition: .crossfade(seconds: 2), after: a.token)
        let faded = renderAll(fadeTimeline)
        check(faded.count / 2 == Int(10 * rate), "Crossfade: \(faded.count / 2) frames, expected \(Int(10 * rate))")
        check(fadeTimeline.markers.map(\.outputFrame) == [0, Int64(4 * rate)], "Crossfade markers \(fadeTimeline.markers.map(\.outputFrame))")
        let window = Int(0.1 * rate) * 2
        let before = rms(faded[Int(3 * rate) * 2 ..< Int(3 * rate) * 2 + window])
        let after = rms(faded[Int(8 * rate) * 2 ..< Int(8 * rate) * 2 + window])
        check(abs(after - (before - 6.02)) < 0.3, "Sound Check gain 0.5 should be −6 dB: \(before) → \(after)")
        for t in stride(from: 4.0, to: 6.0, by: 0.1) {
            let level = rms(faded[Int(t * rate) * 2 ..< Int(t * rate) * 2 + window])
            check(level > after - 1.5 && level < before + 1.5, "Level dips or swells mid-fade at \(t) s: \(level) dB")
        }
        pass("A crossfade overlaps exactly its length, starts the next song where it says, holds the level and keeps each song's gain")

        let shortB = song("short.flac", seconds: 2)
        let a2 = song("a.flac", seconds: 6)
        let clamped = MusicTimeline(song: a2)
        clamped.setNext(shortB, transition: .crossfade(seconds: 4), after: a2.token)
        check(renderAll(clamped).count / 2 == Int(7 * rate), "A fade longer than half the next song should shrink to 1 s")
        pass("A crossfade never takes more than half of either song")

        // E. Planning: a plan replaced before the seam is the one played; after the seam, too late.
        let p1 = song("a.flac", seconds: 6), p2 = song("b.flac", seconds: 6), p3 = song("short.flac", seconds: 2)
        let planning = MusicTimeline(song: p1)
        check(planning.setNext(p2, transition: .gapless, after: p1.token), "A plan after the playing song is accepted")
        check(planning.setNext(p3, transition: .gapless, after: p1.token), "A plan can be replaced")
        _ = renderAll(planning)
        check(planning.markers.map(\.token) == [p1.token, p3.token], "The replaced plan should play")
        check(!planning.setNext(p2, transition: .gapless, after: p1.token), "A plan after a song already left is refused")
        pass("What follows a song can change until the output reaches it, and not after")

        // F. A seek lands on its exact frame.
        let seekSong = song("whole.flac", seconds: 9)
        let seeking = MusicTimeline(song: seekSong)
        _ = seeking.render(maxFrames: 2048)
        seeking.seek(seekSong.token, to: 3.5)
        let fromSeek = renderAll(seeking)
        let at = Int(3.5 * rate) * 2
        check(Array(fromSeek.prefix(4096)) == Array(reference[at ..< at + 4096]), "A seek to 3.5 s doesn't start at its frame")
        check(seeking.markers.first?.songFrame == Int64(3.5 * rate), "The seek's marker says \(seeking.markers.first?.songFrame ?? -1)")
        pass("A seek starts on the exact frame and says where it is")

        // G. Seams: a cut recording runs on; songs that fade out don't.
        let cut1 = MusicSeams.edges(of: fixtures.appendingPathComponent("t1.flac"))!
        let cut2 = MusicSeams.edges(of: fixtures.appendingPathComponent("t2.flac"))!
        let fadeA = MusicSeams.edges(of: fixtures.appendingPathComponent("faded1.m4a"))!
        let fadeB = MusicSeams.edges(of: fixtures.appendingPathComponent("faded2.m4a"))!
        check(MusicTransitionRules.seam(cut1, cut2) == .continuous, "A cut recording should be continuous: \(cut1) \(cut2)")
        check(MusicTransitionRules.seam(fadeA, fadeB) == .separate, "Faded songs should be separate: \(fadeA) \(fadeB)")
        check(MusicTransitionRules.seam(fadeA, cut2) == .separate, "A fade-out then a hard start is separate")
        pass("The seam detector hears a continuous album and an ordinary one")

        // H. The rules.
        let t1 = JellyfinMusicItem(Id: "1", AlbumId: "al", IndexNumber: 1, ParentIndexNumber: 1)
        let t2 = JellyfinMusicItem(Id: "2", AlbumId: "al", IndexNumber: 2, ParentIndexNumber: 1)
        let d2 = JellyfinMusicItem(Id: "3", AlbumId: "al", IndexNumber: 1, ParentIndexNumber: 2)
        let t4 = JellyfinMusicItem(Id: "4", AlbumId: "al", IndexNumber: 4, ParentIndexNumber: 1)
        let other = JellyfinMusicItem(Id: "5", AlbumId: "zz", IndexNumber: 2)
        check(MusicTransitionRules.isAlbumSequence(t1, t2) && MusicTransitionRules.isAlbumSequence(t2, d2)
              && MusicTransitionRules.isAlbumSequence(t4, d2) && !MusicTransitionRules.isAlbumSequence(t1, t4)
              && !MusicTransitionRules.isAlbumSequence(t1, other), "Album order")
        func rule(_ a: JellyfinMusicItem, _ b: JellyfinMusicItem, _ seconds: Double, _ albums: MusicAlbumCrossfade,
                  _ seam: MusicSeam?, seamless: Bool = false, one: Bool = false) -> MusicTimeline.Transition {
            MusicTransitionRules.transition(from: a, to: b, crossfadeSeconds: seconds, albums: albums, seam: seam,
                                            albumIsSeamless: seamless, repeatingOne: one)
        }
        let fade6 = MusicTimeline.Transition.crossfade(seconds: 6)
        check(rule(t1, other, 0, .always, nil) == .gapless, "Crossfade off is gapless")
        check(rule(t1, other, 6, .never, nil) == fade6, "Different albums crossfade")
        check(rule(t1, t2, 6, .never, .separate) == .gapless, "Never within an album")
        check(rule(t1, t2, 6, .always, .continuous) == fade6, "Always crossfades albums")
        check(rule(t1, t2, 6, .unlessSeamless, .continuous) == .gapless, "A continuous seam is gapless")
        check(rule(t1, t2, 6, .unlessSeamless, .separate) == fade6, "A separate seam in an album crossfades")
        check(rule(t1, t2, 6, .unlessSeamless, nil) == .gapless, "An unmeasured seam stays gapless")
        check(rule(t1, t2, 6, .unlessSeamless, .separate, seamless: true) == .gapless, "A seamless album stays gapless throughout")
        check(rule(t1, t4, 6, .unlessSeamless, .continuous) == fade6, "An album out of order crossfades")
        check(rule(t1, t1, 6, .always, nil, one: true) == .gapless, "Repeat One loops without a fade")
        pass("Crossfade rules: off, across albums, within albums by setting and by seam, Repeat One")

        // I. The real renderer: the next song is heard after the first, then the end, on the clock.
        await engineRun()
        exit(0)
    }

    @MainActor static func engineRun() async {
        let engine = MusicPlaybackEngine(processor: nil)
        engine.setVolume(0)
        let first = song("short.flac", seconds: 2), second = song("short.flac", seconds: 2)
        var started: [(UUID, Date)] = []
        var finished: Date?
        let begin = Date()
        engine.onSongStarted = { token in started.append((token, Date())) }
        engine.onFinished = { _ in finished = Date() }
        engine.start(first)
        engine.setNext(second, transition: .gapless, after: first.token)
        for _ in 0 ..< 100 where finished == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let finished, let heard = started.first(where: { $0.0 == second.token })?.1 else {
            check(false, "The engine never reached the second song or the end"); return
        }
        let join = heard.timeIntervalSince(begin), end = finished.timeIntervalSince(begin)
        check(join > 1.9 && join < 2.8, "The second song was heard \(join) s in, expected about 2 s")
        check(end > 3.9 && end < 4.8, "The end came \(end) s in, expected about 4 s")
        engine.stop()
        pass("Through the renderer the next song starts as the first ends, and the end is reported on time")
    }
}
