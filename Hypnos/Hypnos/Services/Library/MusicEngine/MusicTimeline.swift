/*
 Hypnos - the music engine's sample timeline: one song after another, joined or crossfaded.

 Pure and synchronous (no clock, no renderer), so `scripts/check-music-engine.sh` runs it on files and
 checks the seams. `MusicPlaybackEngine` asks it for output a chunk at a time.

 - A **gapless** join is the next song's first frame right after this song's last, in the same chunk.
 - A **crossfade** of F frames starts when F frames of this song are left: the two are mixed on an
   equal-power curve (cos/sin), so the level holds through the blend. The end of the song has to be
   known before it is played, so while a crossfade is planned the deck decodes F frames ahead; the
   container's frame count (`totalFrames`) says where the end is, and when it can't, reaching the end of
   the decoder does. A fade never takes more than half of either song.
 - **Sound Check** is a per-song gain applied as each deck hands out its frames, ramped over a chunk when
   it changes, so two songs in a crossfade each keep their own level.

 Positions are output frames. `markers` say where each song's audio begins in the output (and from which
 of its own frames), which is how the engine turns the renderer's clock into "which song, how far in".
 */

import Foundation

nonisolated final class MusicTimeline {
    struct Song {
        let token: UUID
        let file: MusicSongFile
        var gain: Float
        /// The server's running time, for knowing the end is near before the container has said where it is.
        let estimatedSeconds: Double
    }

    enum Transition: Equatable, Sendable {
        case gapless
        case crossfade(seconds: Double)
    }

    struct Marker: Equatable {
        let outputFrame: Int64
        let token: UUID
        /// The song's own frame (output rate) at `outputFrame`.
        let songFrame: Int64
    }

    enum Status: Equatable {
        case audio
        /// A decoder is waiting for its file: nothing more until it arrives.
        case starving
        /// The last song ended and nothing follows.
        case finished
        case failed(UUID, String)
    }

    /// Chunks the decoders are asked for.
    static let decodeChunk = 4096

    private(set) var format: MusicOutputFormat?
    /// Output frames rendered so far.
    private(set) var outputFrame: Int64 = 0
    private(set) var markers: [Marker] = []

    private var current: Deck
    /// The song fading in over `current`.
    private var incoming: Deck?
    private var fade: (length: Int64, done: Int64)?
    /// What follows the last song committed to the output.
    private var planned: (song: Song, transition: Transition)?
    /// The planned song's deck, opened ahead of its start so its first frames are ready at the seam.
    private var prepared: Deck?

    /// Every song this run has played, for a seek back into one the output has already left.
    private var played: [UUID: Song] = [:]

    init(song: Song, at seconds: Double = 0, format: MusicOutputFormat? = nil) {
        self.format = format
        played[song.token] = song
        current = Deck(song: song, startSeconds: seconds)
        markers = [Marker(outputFrame: 0, token: song.token, songFrame: 0)]
        startSeconds = seconds
    }

    /// Where the first song started, for the first marker once the rate is known.
    private var startSeconds: Double

    /// The song the output reaches last: the one fading in, else the one playing.
    var lastCommitted: UUID { incoming?.song.token ?? current.song.token }
    var tokens: [UUID] { [current.song.token] + (incoming.map { [$0.song.token] } ?? []) }

    /// Plans what follows `token` (which must be the last song committed). False when it isn't any more.
    @discardableResult
    func setNext(_ song: Song?, transition: Transition, after token: UUID) -> Bool {
        guard token == lastCommitted else { return false }
        if let song {
            if prepared?.song.token != song.token { prepared = nil }
            planned = (song, transition)
        } else {
            planned = nil
            prepared = nil
        }
        return true
    }

    func setGain(_ gain: Float, for token: UUID) {
        for deck in [current, incoming, prepared].compactMap({ $0 }) where deck.song.token == token { deck.song.gain = gain }
        if planned?.song.token == token { planned?.song.gain = gain }
    }

    /// The song's length in seconds, when its container has said.
    func duration(of token: UUID) -> Double? {
        guard let format else { return nil }
        let deck = [current, incoming].compactMap { $0 }.first { $0.song.token == token }
        return deck?.decoder.totalFrames.map { Double($0) / format.sampleRate }
    }

    /// Starts `token` (playing or fading in) again from `seconds`, alone, at output frame 0.
    /// What was planned after it is dropped (the caller plans again).
    func seek(_ token: UUID, to seconds: Double) {
        guard let song = [current, incoming].compactMap({ $0 }).first(where: { $0.song.token == token })?.song ?? played[token] else { return }
        current = Deck(song: song, startSeconds: seconds)
        incoming = nil
        fade = nil
        planned = nil
        prepared = nil
        outputFrame = 0
        startSeconds = seconds
        markers = [Marker(outputFrame: 0, token: current.song.token, songFrame: format.map { Int64(seconds * $0.sampleRate) } ?? 0)]
    }

    // MARK: - Rendering

    /// Up to `maxFrames` of output (interleaved stereo), and why it stopped short if it did.
    func render(maxFrames: Int) -> (samples: [Float], status: Status) {
        var out: [Float] = []
        out.reserveCapacity(maxFrames * 2)
        var status = Status.audio
        if format == nil {
            if let failure = current.fill(Self.decodeChunk, format: &format) { return ([], .failed(current.song.token, failure)) }
            guard let format else { return ([], .starving) }
            markers = [Marker(outputFrame: 0, token: current.song.token, songFrame: Int64(startSeconds * format.sampleRate))]
        }
        guard let format else { return ([], .starving) }

        loop: while out.count / 2 < maxFrames {
            let room = maxFrames - out.count / 2
            if let fade, let incoming {
                // Mixing the end of one song into the start of the next.
                let step = Int(min(Int64(room), fade.length - fade.done))
                _ = current.fill(step, format: &self.format)
                if let failure = incoming.fill(step, format: &self.format) { status = .failed(incoming.song.token, failure); break loop }
                if incoming.buffered < step, !incoming.ended { status = .starving; break loop }
                let fromA = current.take(min(step, current.buffered))
                let fromB = incoming.take(min(step, incoming.buffered))
                let frames = max(fromA.count, fromB.count) / 2
                guard frames > 0 else {
                    // Both ran dry together: the fade is over.
                    finishFade()
                    continue loop
                }
                for i in 0 ..< frames {
                    let t = Float(Double(fade.done + Int64(i)) / Double(fade.length)) * .pi / 2
                    let gA = cos(t), gB = sin(t)
                    for c in 0 ..< 2 {
                        let a = 2 * i + c < fromA.count ? fromA[2 * i + c] : 0
                        let b = 2 * i + c < fromB.count ? fromB[2 * i + c] : 0
                        out.append(a * gA + b * gB)
                    }
                }
                self.fade = (fade.length, fade.done + Int64(frames))
                if fade.done + Int64(frames) >= fade.length { finishFade() }
                continue loop
            }

            // One song playing.
            let fadeFrames = plannedFadeFrames(format: format)
            if let failure = current.fill(max(Self.decodeChunk, fadeFrames + Self.decodeChunk), format: &self.format) {
                status = .failed(current.song.token, failure); break loop
            }
            prepareNextIfNear(format: format)
            if fadeFrames > 0, let remaining = current.remaining, remaining <= Int64(fadeFrames) {
                beginFade(frames: max(1, remaining), at: outputFrame + Int64(out.count / 2))
                continue loop
            }
            var allowed = current.buffered
            if fadeFrames > 0 {
                if let remaining = current.remaining {
                    allowed = Int(min(Int64(allowed), remaining - Int64(fadeFrames)))
                } else if current.buffered <= fadeFrames, !current.ended, current.song.estimatedSeconds > 0 {
                    // The end isn't known and the fade's worth isn't decoded yet. Near the end, wait for it
                    // rather than spend frames the fade needs; earlier, play on (a slow start).
                    let left = current.song.estimatedSeconds * format.sampleRate - Double(current.position)
                    if left < Double(fadeFrames) + 5 * format.sampleRate { status = .starving; break loop }
                }
            }
            if allowed <= 0 {
                if current.ended, current.buffered == 0 {
                    // The song is over: the next one starts on the very next frame, or nothing does.
                    guard let next = planned else { status = .finished; break loop }
                    let deck = takePrepared(next.song)
                    planned = nil
                    current = deck
                    markers.append(Marker(outputFrame: outputFrame + Int64(out.count / 2), token: deck.song.token, songFrame: 0))
                    continue loop
                }
                status = .starving
                break loop
            }
            out += current.take(min(allowed, room))
        }
        outputFrame += Int64(out.count / 2)
        return (out, out.isEmpty ? status : (status == .finished || status == .audio ? .audio : status))
    }

    private func plannedFadeFrames(format: MusicOutputFormat) -> Int {
        guard let planned, case .crossfade(let seconds) = planned.transition, seconds > 0 else { return 0 }
        var frames = seconds * format.sampleRate
        // Never more than half of either song.
        if let total = current.decoder.totalFrames { frames = min(frames, Double(total) / 2) }
        if current.song.estimatedSeconds > 0 { frames = min(frames, current.song.estimatedSeconds * format.sampleRate / 2) }
        if planned.song.estimatedSeconds > 0 { frames = min(frames, planned.song.estimatedSeconds * format.sampleRate / 2) }
        return max(0, Int(frames))
    }

    /// The planned song starts fading in at output frame `frame`.
    private func beginFade(frames: Int64, at frame: Int64) {
        guard let next = planned else { return }
        let deck = takePrepared(next.song)
        planned = nil
        incoming = deck
        fade = (frames, 0)
        markers.append(Marker(outputFrame: frame, token: deck.song.token, songFrame: 0))
    }

    private func finishFade() {
        if let incoming { current = incoming }
        incoming = nil
        fade = nil
    }

    private func takePrepared(_ song: Song) -> Deck {
        played[song.token] = song
        if played.count > 8 { played = played.filter { tokens.contains($0.key) || $0.key == song.token } }
        if let prepared, prepared.song.token == song.token {
            self.prepared = nil
            prepared.song.gain = song.gain
            return prepared
        }
        prepared = nil
        return Deck(song: song, startSeconds: 0)
    }

    /// Opens the next song's decoder a few seconds before it's needed and decodes its first chunk.
    private func prepareNextIfNear(format: MusicOutputFormat) {
        guard let planned, prepared == nil else {
            if let prepared, prepared.buffered < Self.decodeChunk { var f = self.format; _ = prepared.fill(Self.decodeChunk, format: &f) }
            return
        }
        let estimate = current.song.estimatedSeconds > 0 ? current.song.estimatedSeconds * format.sampleRate - Double(current.position) : 0
        let left = current.remaining.map { Double($0) } ?? estimate
        guard left < 20 * format.sampleRate else { return }
        let deck = Deck(song: planned.song, startSeconds: 0)
        var f = self.format
        _ = deck.fill(Self.decodeChunk, format: &f)
        prepared = deck
    }
}

// MARK: - One song's decoder and its decoded-ahead frames

extension MusicTimeline {
    final class Deck {
        var song: Song
        private(set) var decoder: MusicDecoding
        private var startSeconds: Double
        private var samples: [Float] = []
        private var head = 0
        /// The decoder has handed out its last frame.
        private(set) var ended = false
        /// Song frames handed to the output (output rate), counting from where it started.
        private(set) var position: Int64 = 0
        private var appliedGain: Float
        private var failure: String?

        init(song: Song, startSeconds: Double) {
            self.song = song
            self.startSeconds = startSeconds
            appliedGain = song.gain
            decoder = Self.decoder(for: song.file, startSeconds: startSeconds)
        }

        /// A complete file is read with AVAudioFile (exact seeks); one still arriving is parsed as it comes.
        static func decoder(for file: MusicSongFile, startSeconds: Double) -> MusicDecoding {
            if file.progress.complete, let decoder = MusicFileDecoder(url: file.fileURL, startSeconds: startSeconds) { return decoder }
            return MusicStreamDecoder(file: file, startSeconds: startSeconds)
        }

        var buffered: Int { (samples.count - head) / 2 }

        /// Frames left in the song, once that's known: from the end having been reached, or the container.
        var remaining: Int64? {
            if ended { return Int64(buffered) }
            guard let total = decoder.totalFrames, let format = runFormat else { return nil }
            let start = Int64((startSeconds * format.sampleRate).rounded())
            return max(Int64(buffered), total - start - position)
        }

        private var runFormat: MusicOutputFormat?

        /// Decodes until `frames` are buffered, the song ends, or the file has to arrive first. A failure's message.
        func fill(_ frames: Int, format: inout MusicOutputFormat?) -> String? {
            if let failure { return failure }
            while buffered < frames, !ended {
                if let stream = decoder as? MusicStreamDecoder, stream.needsWholeFile {
                    // An MPEG-4 file with its index at the end: only the whole file can be read.
                    guard song.file.progress.complete else {
                        if let failure = song.file.progress.failure { self.failure = failure; return failure }
                        return nil
                    }
                    guard let file = MusicFileDecoder(url: song.file.fileURL, startSeconds: startSeconds) else {
                        failure = "This song's file can't be read on the device."
                        return failure
                    }
                    decoder = file
                }
                switch decoder.read(maxFrames: MusicTimeline.decodeChunk, output: &format) {
                case .audio(let chunk):
                    runFormat = format
                    if head > 0, head >= samples.count / 2 {
                        samples.removeFirst(head)
                        head = 0
                    }
                    samples += chunk
                case .waiting:
                    runFormat = format
                    return nil
                case .end:
                    runFormat = format
                    ended = true
                case .failed(let message):
                    failure = message
                    return message
                }
            }
            return nil
        }

        /// The next `count` frames (fewer if fewer are buffered), with the song's gain.
        func take(_ count: Int) -> [Float] {
            let n = min(count, buffered)
            guard n > 0 else { return [] }
            var chunk = Array(samples[head ..< head + 2 * n])
            head += 2 * n
            position += Int64(n)
            let target = song.gain
            if appliedGain == 1, target == 1 { return chunk }
            let from = appliedGain
            chunk.withUnsafeMutableBufferPointer { buffer in
                for i in 0 ..< n {
                    let g = from == target ? target : from + (target - from) * Float(i + 1) / Float(n)
                    buffer[2 * i] *= g
                    buffer[2 * i + 1] *= g
                }
            }
            appliedGain = target
            return chunk
        }
    }
}
