/*
 MatroskaRemux - any window of an audio track, decoded to PCM

 For a player that mixes the sound itself rather than handing a stream to
 AVPlayer: Convolution's film player plays a 3D Blu-ray remux's own sound this
 way when the server has no object audio for it (its picture is decoded on
 the device, so there is no HLS to carry the audio).

 A window is read the way the remux reads a segment's audio: from the Cue at
 or before its start less a quarter second of priming (a fresh DTS
 filterbank or TrueHD decoder needs it, see `AudioTranscode.swift`), with a
 new decoder each time, so a window read twice is the same samples. The
 decoded PCM is laid over the frames' span from its end, which is where the
 first frame after the last one fed starts (or the last frame's own end):
 a decoder primed or delayed by a frame lines up either way.

 Decoders come from the caller, as for the remux (`RemuxAudioDecoding`:
 the system's AAC/AC-3/E-AC-3 everywhere, FFmpeg's DTS/TrueHD in the
 sideload edition). FLAC, Opus and the rest aren't offered: no decoder here
 hands back their PCM.
 */

import Foundation

public final class MatroskaAudioReader: Sendable {
    public struct Track: Sendable, Equatable {
        public var number: UInt64
        public var codecID: String
        public var language: String?
        public var name: String?
        public var channels: Int
        public var sampleRate: Int
        public var isDefault: Bool
    }

    /// A window's PCM: one plane per channel, in `speakers` order.
    public struct Window: Sendable {
        public var sampleRate: Int
        public var speakers: [RemuxSpeaker]
        public var planes: [[Float]]
    }

    public let tracks: [Track]
    /// Seconds, when the file says.
    public let durationSeconds: Double?
    private let source: any ByteSource
    private let header: MatroskaHeader
    private let decoding: RemuxAudioDecoding
    private let origins = Origins()
    private static let primingSeconds = 0.25

    /// Each track's first frame time, read once: where its sample grid starts.
    private final class Origins: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks: [UInt64: Int64] = [:]
        func get(_ track: UInt64) -> Int64? { lock.withLock { ticks[track] } }
        func set(_ track: UInt64, _ value: Int64) { lock.withLock { ticks[track] = value } }
    }

    /// Reads the file's header and Cues; offers the audio tracks `decoding`
    /// decodes.
    public static func open(source: any ByteSource, decoding: RemuxAudioDecoding) async throws -> MatroskaAudioReader {
        MatroskaAudioReader(source: source, header: try await MatroskaHeaderReader.read(source), decoding: decoding)
    }

    private init(source: any ByteSource, header: MatroskaHeader, decoding: RemuxAudioDecoding) {
        self.source = source
        self.header = header
        self.decoding = decoding
        durationSeconds = header.durationNanoseconds.map { Double($0) / 1e9 }
        tracks = header.tracks.compactMap { track in
            guard track.kind == .audio, track.isEnabled, track.unreadableEncoding == nil,
                  decoding.decodes(track.codecID), let audio = track.audio else { return nil }
            return Track(number: track.number, codecID: track.codecID, language: track.bcp47Language, name: track.name,
                         channels: audio.channels,
                         sampleRate: Int((audio.outputSamplingFrequency ?? audio.samplingFrequency).rounded()),
                         isDefault: track.isDefault)
        }
    }

    /// `frames` samples of `track` from `start` seconds of the file's time.
    /// What the track doesn't cover (before it starts, past its end, a frame
    /// that didn't decode) is silence; a window that decodes nothing throws.
    public func read(track number: UInt64, from start: Double, frames: Int) async throws -> Window {
        guard let track = header.tracks.first(where: { $0.number == number }),
              let decoder = decoding.make(track.codecID, track.codecPrivate) else {
            throw RemuxError.declined("no decoder for audio track \(number)")
        }
        let scale = Double(header.timestampScale)
        let ticks = { (seconds: Double) in Int64((seconds * 1e9 / scale).rounded(.down)) }
        let seconds = { (ticks: Int64) in Double(ticks) * scale / 1e9 }
        let from = start - Self.primingSeconds
        let nominalRate = Double(track.audio.map { $0.outputSamplingFrequency ?? $0.samplingFrequency } ?? 48_000)
        let end = start + Double(frames) / nominalRate
        // The Cue at or before where reading starts (Cues name the video
        // track's clusters, which hold the audio stored with them).
        let cue = header.cues.last { $0.time <= ticks(from) }
        var reader = ClusterReader(source: source, start: cue?.clusterPosition ?? header.firstClusterPosition ?? header.segmentDataStart,
                                   limit: header.contentEnd ?? Int64.max,
                                   modes: [number: .frames], strippedHeaders: [number: track.strippedHeader])
        var first: Double?
        var spanEnd: Double?
        var fed = 0
        var fedTimes: [(ticks: Int64, lace: Int)] = []
        while let frame = try await reader.next() {
            // Laced frames share their block's time; the next block's says
            // where they end.
            let time = seconds(frame.blockTimestamp)
            if time < from - 0.05 { continue }
            if time >= end {
                spanEnd = time
                break
            }
            if first == nil { first = time }
            decoder.feed(frame.data)
            fed += 1
            fedTimes.append((frame.blockTimestamp, frame.laceIndex))
            if let duration = frame.blockDuration, frame.laceIndex == frame.laceCount - 1 {
                spanEnd = time + seconds(duration)
            } else {
                spanEnd = nil
            }
        }
        decoder.finish()
        let sampleRate = decoder.sampleRate > 0 ? decoder.sampleRate : Int(nominalRate)
        let speakers = decoder.speakers
        guard fed > 0, first != nil, !speakers.isEmpty, decoder.frameCount > 0 else {
            if fed == 0 {
                // Before the track starts or past its end: silence.
                let channels = track.audio?.channels ?? 2
                return Window(sampleRate: Int(nominalRate), speakers: Array(repeating: .other, count: channels),
                              planes: Array(repeating: [Float](repeating: 0, count: frames), count: channels))
            }
            throw RemuxError.declined("audio track \(number) decoded nothing")
        }
        let decoded = decoder.frameCount
        let rate = Double(sampleRate)
        let pcmStart: Double
        if decoded % fed == 0, case let perFrame = decoded / fed, perFrame > 0,
           let origin = try await firstFrameTicks(of: track) {
            // Constant-length frames (AAC, AC-3, DTS): on the track's own
            // sample grid, from its first frame. Block times are rounded to
            // a tick (a millisecond), which is up to 24 samples off for
            // AAC's 21.3 ms and DTS's 10.7 ms frames, and differently for
            // every window; the grid is the same for all of them.
            let estimates = fedTimes.enumerated().map { i, t in
                Int64((seconds(t.ticks) * rate).rounded()) + Int64((t.lace - i) * perFrame)
            }.sorted()
            let estimate = estimates[estimates.count / 2]
            let gridStart = Int64((seconds(origin) * rate).rounded())
            let step = Double(estimate - gridStart) / Double(perFrame)
            pcmStart = Double(gridStart + Int64(step.rounded()) * Int64(perFrame)) / rate
        } else {
            // Lined up at the end of what was fed; at the file's end, with no
            // frame after, at the start of it.
            pcmStart = spanEnd.map { $0 - Double(decoded) / rate } ?? first ?? 0
        }
        let offset = Int(((start - pcmStart) * rate).rounded())
        let channels = speakers.count
        var planes = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        decoder.withSamples { samples in
            let available = samples.count / channels
            for i in 0 ..< frames {
                let s = offset + i
                guard s >= 0, s < available else { continue }
                for c in 0 ..< channels { planes[c][i] = Float(samples[s * channels + c]) / 8_388_608 }
            }
        }
        return Window(sampleRate: sampleRate, speakers: speakers, planes: planes)
    }

    /// The track's first frame, from the first Cluster on (within 64 MB).
    private func firstFrameTicks(of track: MatroskaTrack) async throws -> Int64? {
        if let known = origins.get(track.number) { return known }
        let start = header.firstClusterPosition ?? header.segmentDataStart
        var reader = ClusterReader(source: source, start: start, limit: min(header.contentEnd ?? Int64.max, start + (64 << 20)),
                                   chunkSize: 256 << 10, modes: [track.number: .headers])
        guard let frame = try await reader.next() else { return nil }
        origins.set(track.number, frame.blockTimestamp)
        return frame.blockTimestamp
    }
}
