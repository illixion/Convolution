/*
 Stable Audio (`StableAudio.swift`): what the processing does to a cinema
 mix, that segments processed apart join without a seam, and the "(Stable)"
 rendition a decoded track gets (`RemuxOptions.stableAudio`).
 */

import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Stable Audio")
struct StableAudioTests {
    static let rate = 48000

    /// A film-like 5.1 stretch (ALAC order C L R Ls Rs LFE): quiet dialogue
    /// in the centre (a voice-band tone in 300 ms syllables, -40 dBFS
    /// while on), a steady bed at -24 dBFS, and an effect burst near full
    /// scale every 4 s.
    static func cinemaMix(seconds: Int) -> [[Float]] {
        let n = seconds * rate
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 1) % 2_000_001 - 1_000_000) / 1_000_000
        }
        var channels = [[Float]](repeating: [Float](repeating: 0, count: n), count: 6)
        let speech = Float(0.01 * 2.0.squareRoot()) // -40 dBFS RMS
        let bed: Float = 0.063 * 1.7 // about -24 dBFS RMS of uniform noise
        for i in 0 ..< n {
            let t = Double(i) / Double(rate)
            let talking = t.truncatingRemainder(dividingBy: 0.5) < 0.3
            channels[0][i] = talking ? speech * Float(sin(2 * .pi * 1000 * t)) : 0
            let burst = t.truncatingRemainder(dividingBy: 4) < 0.4
            for c in 1 ... 4 { channels[c][i] = noise() * bed * (burst ? 12 : 1) }
            channels[5][i] = Float(sin(2 * .pi * 50 * t)) * (burst ? 0.8 : 0.05)
        }
        return channels
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
    }

    static func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }

    @Test func dialogueComesUpAndTheBedMakesRoom() {
        let input = Self.cinemaMix(seconds: 20)
        var output = input
        StableAudio.process(&output, sampleRate: Self.rate)

        // Past the first few seconds (the envelopes settling).
        let from = 3 * Self.rate
        let peak = output.map { $0[from...].map(abs).max()! }.max()!
        #expect(peak <= 0.892, "peaks held to -1 dBFS (got \(Self.db(peak)))")

        // During speech, away from bursts: 2.0-2.3 s of each 4 s cycle.
        func speechWindows(_ channels: [[Float]], _ c: Int) -> Float {
            var sum: Float = 0, count = 0
            for cycle in 1 ..< 5 {
                let start = (cycle * 4 + 2) * Self.rate
                let slice = channels[c][start ..< start + Self.rate * 3 / 10]
                sum += slice.reduce(0) { $0 + $1 * $1 }
                count += slice.count
            }
            return (sum / Float(count)).squareRoot()
        }
        let dialogueIn = Self.db(speechWindows(input, 0)), dialogueOut = Self.db(speechWindows(output, 0))
        let bedIn = Self.db(speechWindows(input, 1)), bedOut = Self.db(speechWindows(output, 1))
        #expect(dialogueOut - dialogueIn > 4, "quiet dialogue lifted: \(dialogueIn) → \(dialogueOut) dB")
        #expect((bedOut - dialogueOut) < (bedIn - dialogueIn) - 3,
                "bed relative to dialogue: \(bedIn - dialogueIn) → \(bedOut - dialogueOut) dB")

        // The bursts come down relative to the dialogue.
        func burst(_ channels: [[Float]]) -> Float {
            Self.db(Self.rms(channels[1][(8 * Self.rate + 4800) ..< (8 * Self.rate + 14400)]))
        }
        #expect(burst(output) - dialogueOut < burst(input) - dialogueIn - 10,
                "burst over dialogue: \(burst(input) - dialogueIn) → \(burst(output) - dialogueOut) dB")
    }

    @Test func roomToneIsNotPumpedUp() {
        let n = 6 * Self.rate
        var state: UInt32 = 1
        let quiet = (0 ..< n).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.0005 // about -75 dBFS
        }
        var channels = [[Float]](repeating: quiet, count: 6)
        StableAudio.process(&channels, sampleRate: Self.rate)
        let gain = Self.db(Self.rms(channels[1][(3 * Self.rate)...])) - Self.db(Self.rms(quiet[(3 * Self.rate)...]))
        #expect(gain < 1, "room tone gained \(gain) dB")
    }

    @Test func stereoIsLevelledWithoutDucking() {
        let mix = Self.cinemaMix(seconds: 8)
        var stereo = [mix[1].indices.map { mix[1][$0] + mix[0][$0] }, mix[2].indices.map { mix[2][$0] + mix[0][$0] }]
        StableAudio.process(&stereo, sampleRate: Self.rate)
        let peak = stereo.map { $0.map(abs).max()! }.max()!
        #expect(peak <= 0.892)
        #expect(stereo[0] != mix[1])
    }

    /// A segment processed on its own after `primingSeconds` of what came
    /// before it, as the session does, against the same stretch processed
    /// straight through: the difference is well below the signal.
    @Test func segmentsJoinWithoutASeam() {
        let whole = Self.cinemaMix(seconds: 16)
        var straight = whole
        StableAudio.process(&straight, sampleRate: Self.rate)

        let segmentStart = 9 * Self.rate
        let priming = Int(StableAudio.primingSeconds * Double(Self.rate))
        var piece = whole.map { Array($0[(segmentStart - priming)...]) }
        StableAudio.process(&piece, sampleRate: Self.rate)

        // The first 200 ms after the seam, where a difference would be.
        for c in 0 ..< 6 {
            let a = straight[c][segmentStart ..< segmentStart + 9600]
            let b = piece[c][priming ..< priming + 9600]
            let difference = zip(a, b).map { $0 - $1 }
            let ratio = Self.db(Self.rms(difference[...])) - Self.db(max(Self.rms(a), 1e-6))
            #expect(ratio < -30, "channel \(c): difference \(ratio) dB below the signal")
        }
    }

    @Test func sameInputSameOutput() {
        var a = Self.cinemaMix(seconds: 3), b = a
        StableAudio.process(&a, sampleRate: Self.rate)
        StableAudio.process(&b, sampleRate: Self.rate)
        #expect(a == b)
    }
}

#if canImport(AVFoundation) && os(macOS)

import AVFoundation
import FFmpegDecoders

@Suite("Stable Audio renditions", .serialized)
struct StableRenditionTests {
    static func options(_ mode: StableAudioMode) -> RemuxOptions {
        var options = RemuxOptions()
        options.audioDecoding = FFmpegRemuxDecoder.decoding
        options.stableAudio = mode
        return options
    }

    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: TranscodeTests.fixtures)
    func offeredBesideTheTrack(_ name: String) async throws {
        let session = try await Fixtures.open(name, options: Self.options(.offered))
        let tracks = session.summary.audio
        #expect(tracks.count == 2)
        #expect(tracks.map(\.isStable) == [false, true])
        #expect(tracks[0].isDefault && !tracks[1].isDefault)
        #expect(tracks[1].number == tracks[0].number | AudioPlan.stableFlag)
        #expect(session.audioRenditions[1].name.hasSuffix("(Stable)"))
        #expect(session.masterPlaylist.contains("(Stable)"))
        #expect(session.audioRenditions[1].isStable)
        // The track keeps its language; the copy is told apart by its NAME.
        #expect(session.audioRenditions[0].playlistLanguage == "en")
        #expect(session.audioRenditions[1].playlistLanguage == session.audioRenditions[1].name)
    }

    @Test(.enabled(if: FFmpegRemuxDecoder.loaded))
    func preferredPlaysFirst() async throws {
        let session = try await Fixtures.open("dts-51.mkv", options: Self.options(.preferred))
        let tracks = session.summary.audio
        #expect(tracks.map(\.isStable) == [true, false])
        #expect(tracks[0].isDefault)
        let stableLine = try #require(session.masterPlaylist.split(separator: "\n").first { $0.contains("(Stable)") })
        #expect(stableLine.contains("DEFAULT=YES"))
        // The player's choice by language lands on the Stable copy; the
        // track keeps its plain name (a player lists only the track).
        let renditions = session.audioRenditions
        #expect(renditions[0].playlistLanguage == "en")
        #expect(renditions[0].name.hasSuffix(AudioRendition.stableSuffix))
        #expect(!renditions[1].name.contains("("))
        #expect(renditions[1].playlistLanguage == renditions[1].name)
    }

    /// A player left to choose (as the 3D players, which have no audio
    /// menu, are) starts with the Stable copy when it is preferred, and with
    /// the track when it is only offered.
    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: [StableAudioMode.preferred, .offered])
    func aPlayerStartsWithTheRightCopy(_ mode: StableAudioMode) async throws {
        let session = try await Fixtures.open("dts-51.mkv", options: Self.options(mode))
        let (server, base) = try await LoopbackServer.start(session)
        defer { server.stop() }
        let asset = AVURLAsset(url: base.appendingPathComponent("master.m3u8"))
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0 ..< 100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
        #expect(item.status == .readyToPlay)
        let group = try #require(try await asset.loadMediaSelectionGroup(for: .audible))
        let selected = try #require(item.currentMediaSelection.selectedMediaOption(in: group))
        let title = AVMetadataItem.metadataItems(from: selected.commonMetadata,
                                                 filteredByIdentifier: .commonIdentifierTitle).first
        let name = try await title?.load(.stringValue) ?? ""
        #expect(name.hasSuffix("(Stable)") == (mode == .preferred), "started with \(name)")
        player.replaceCurrentItem(with: nil)
    }

    @Test(.enabled(if: FFmpegRemuxDecoder.loaded))
    func notOfferedWhenOff() async throws {
        let session = try await Fixtures.open("dts-51.mkv", options: Self.options(.off))
        #expect(session.summary.audio.count == 1)
        #expect(!session.masterPlaylist.contains("(Stable)"))
    }

    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: TranscodeTests.fixtures)
    func segmentsAreTheSameBytesEveryTime(_ name: String) async throws {
        let first = try await Fixtures.open(name, options: Self.options(.offered))
        let number = try #require(first.summary.audio.first { $0.isStable }).number
        let second = try await Fixtures.open(name, options: Self.options(.offered))
        for k in (0 ..< first.segmentCount).reversed() {
            let a = try #require(try await first.audioSegment(track: number, k))
            let b = try #require(try await second.audioSegment(track: number, k))
            #expect(a == b, "segment \(k)")
        }
    }

    /// AVFoundation plays the rendition, every channel keeps its own tone,
    /// and the processing changed the levels.
    @Test(.enabled(if: FFmpegRemuxDecoder.loaded), arguments: TranscodeTests.fixtures)
    func playsWithEachChannelInPlace(_ name: String) async throws {
        let session = try await Fixtures.open(name, options: Self.options(.offered))
        let original = try #require(session.summary.audio.first { !$0.isStable }).number
        let stable = try #require(session.summary.audio.first { $0.isStable }).number
        let plain = try await Self.read(session, original)
        let processed = try await Self.read(session, stable)
        #expect(abs(processed.count - plain.count) <= 6 * 4096, "\(processed.count) vs \(plain.count) samples")
        let frames = min(plain.count, processed.count) / 6
        #expect(frames > 48000)
        for c in 0 ..< 6 {
            #expect(TranscodeTests.tone(processed, channel: c, frames: frames) == [300, 500, 700, 900, 1100, 60][c])
        }
        #expect(processed != plain)
    }

    /// Tracks that play as they are get a Stable copy decoded by the
    /// system (`SystemAudioDecoding`), in every build; the track itself is
    /// untouched.
    @Test(arguments: ["aac-51-tones.mkv", "ac3-51-tones.mkv", "eac3-51-tones.mkv"])
    func systemDecodedCopyPlaysWithEachChannelInPlace(_ name: String) async throws {
        var options = RemuxOptions()
        options.audioDecoding = SystemAudioDecoding.decoding
        options.stableAudio = .offered
        let session = try await Fixtures.open(name, options: options)
        let tracks = session.summary.audio
        #expect(tracks.map(\.isStable) == [false, true])
        #expect(tracks[0].codec == tracks[1].codec)
        let plain = try await Self.read(session, tracks[0].number)
        let processed = try await Self.read(session, tracks[1].number)
        // The whole 9 s (AVFoundation reads the AC-3 track itself a
        // decoder's latency short, so it isn't the measure).
        #expect(abs(processed.count / 6 - 9 * 48000) <= 4096, "\(processed.count / 6) samples")
        let frames = min(plain.count, processed.count) / 6
        #expect(frames > 48000)
        for c in 0 ..< 6 {
            #expect(TranscodeTests.tone(processed, channel: c, frames: frames) == [300, 500, 700, 900, 1100, 60][c],
                    "channel \(c)")
        }
        // The same bytes every time.
        let again = try await Fixtures.open(name, options: options)
        for k in 0 ..< session.segmentCount {
            let a = try await session.audioSegment(track: tracks[1].number, k)
            let b = try await again.audioSegment(track: tracks[1].number, k)
            #expect(a == b, "segment \(k)")
        }
    }

    /// The copy plays in time with its track: a click a second, found at
    /// the same samples in both as AVFoundation plays them. (The system's
    /// AC-3 decoder holds 288 samples back and AAC's priming is trimmed
    /// from the track by the player; both were off before.)
    @Test(arguments: ["aac-51-clicks.mkv", "eac3-51-clicks.mkv"])
    func systemDecodedCopyKeepsTime(_ name: String) async throws {
        var options = RemuxOptions()
        options.audioDecoding = SystemAudioDecoding.decoding
        options.stableAudio = .offered
        let session = try await Fixtures.open(name, options: options)
        let tracks = session.summary.audio
        let plain = Self.clicks(try await Self.read(session, tracks[0].number))
        let processed = Self.clicks(try await Self.read(session, tracks[1].number))
        #expect(plain.count >= 8)
        #expect(plain == processed, "track \(plain), Stable copy \(processed)")
    }

    /// Where the left channel's clicks are: each first sample at a quarter
    /// of the peak, half a second apart at least.
    static func clicks(_ pcm: [Int32]) -> [Int] {
        let frames = pcm.count / 6
        let peak = (0 ..< frames).map { abs(Int(pcm[$0 * 6 + 1])) }.max() ?? 0
        var out: [Int] = [], i = 0
        while i < frames {
            if abs(Int(pcm[i * 6 + 1])) * 4 >= peak, peak > 0 { out.append(i); i += 24000 } else { i += 1 }
        }
        return out
    }

    static func read(_ session: RemuxSession, _ number: UInt64) async throws -> [Int32] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stable-\(UUID().uuidString).mp4")
        try await session.concatenated("audio-\(number)").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_D
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 6, AVSampleRateKey: 48000, AVChannelLayoutKey: layoutData,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Int32] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                        dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Int32.self, capacity: length / 4) {
                samples += UnsafeBufferPointer(start: $0, count: length / 4).map { $0 >> 8 }
            }
        }
        #expect(reader.status == .completed)
        return samples
    }
}

#endif
