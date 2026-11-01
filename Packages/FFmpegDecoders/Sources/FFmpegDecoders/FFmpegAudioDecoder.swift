/*
 FFmpegDecoders - DTS and TrueHD/MLP to PCM, for the sideload edition

 The decoders are in HypnosFFmpeg.framework (Shim/ and
 scripts/build-ffmpeg-decoders.sh), which nothing links against: it is
 looked for when first needed (`isAvailable`), in the app's Frameworks
 folder, where only a sideload build puts it. Found, its functions are
 looked up by name; not found, nothing decodes and the caller keeps its
 fallback. That is what keeps FFmpeg out of App Store builds entirely.

 One decoder decodes one stretch of a stream: feed it the stored frames in
 order, `finish()`, then read the PCM. It keeps no state worth carrying
 between stretches, which is what lets the remux decode each segment on its
 own and still give the same bytes every time a segment is asked for.
 */

import Darwin
import Foundation

public enum FFmpegAudioCodec: Int32, Sendable {
    // The shim's hyp_ff_codec values.
    case dts = 1, trueHD = 2, mlp = 3

    /// The codec for a Matroska CodecID, when this package decodes it.
    public init?(matroskaCodecID id: String) {
        switch id {
        case "A_DTS", "A_DTS/EXPRESS", "A_DTS/LOSSLESS": self = .dts
        case "A_TRUEHD": self = .trueHD
        case "A_MLP": self = .mlp
        default: return nil
        }
    }
}

/// Where a decoded channel plays, by FFmpeg's channel ids.
public enum FFmpegChannel: Int, Sendable {
    case frontLeft = 0, frontRight, frontCenter, lowFrequency, backLeft, backRight,
         frontLeftOfCenter, frontRightOfCenter, backCenter, sideLeft, sideRight,
         topCenter, topFrontLeft, topFrontCenter, topFrontRight, topBackLeft, topBackCenter, topBackRight
}

public final class FFmpegAudioDecoder {
    /// The framework's functions (Shim/CFFmpegShim.h).
    struct Symbols: @unchecked Sendable {
        typealias Open = @convention(c) (Int32, UnsafePointer<UInt8>?, Int32) -> OpaquePointer?
        typealias Feed = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int32) -> Int32
        typealias IntOf = @convention(c) (OpaquePointer?) -> Int32
        typealias Channel = @convention(c) (OpaquePointer?, Int32) -> Int32
        typealias Frames = @convention(c) (OpaquePointer?) -> Int64
        typealias Samples = @convention(c) (OpaquePointer?) -> UnsafePointer<Int32>?
        typealias Close = @convention(c) (OpaquePointer?) -> Void

        let open: Open, feed: Feed, channels: IntOf, sampleRate: IntOf, channel: Channel
        let frames: Frames, samples: Samples, errors: IntOf, close: Close

        init?(handle: UnsafeMutableRawPointer) {
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let open = symbol("hyp_ff_open", Open.self), let feed = symbol("hyp_ff_feed", Feed.self),
                  let channels = symbol("hyp_ff_channels", IntOf.self),
                  let sampleRate = symbol("hyp_ff_sample_rate", IntOf.self),
                  let channel = symbol("hyp_ff_channel", Channel.self),
                  let frames = symbol("hyp_ff_frames", Frames.self),
                  let samples = symbol("hyp_ff_samples", Samples.self),
                  let errors = symbol("hyp_ff_errors", IntOf.self),
                  let close = symbol("hyp_ff_close", Close.self) else { return nil }
            self.open = open; self.feed = feed; self.channels = channels; self.sampleRate = sampleRate
            self.channel = channel; self.frames = frames; self.samples = samples; self.errors = errors
            self.close = close
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: Symbols?
    nonisolated(unsafe) private static var searched = false

    /// Loads the framework from a given path (tests, tools); true when its
    /// functions are there. Once one has loaded, later calls change nothing.
    @discardableResult
    public static func load(path: String) -> Bool {
        lock.withLock { loadLocked(path: path) }
    }

    private static func loadLocked(path: String) -> Bool {
        if loaded != nil { return true }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let symbols = Symbols(handle: handle) else {
            return false
        }
        loaded = symbols
        return true
    }

    /// The framework's functions, looked for once in the app's Frameworks
    /// folder (where only a sideload build puts it).
    static var symbols: Symbols? {
        lock.withLock {
            if loaded == nil, !searched {
                searched = true
                if let frameworks = Bundle.main.privateFrameworksPath {
                    _ = loadLocked(path: frameworks + "/HypnosFFmpeg.framework/HypnosFFmpeg")
                }
            }
            return loaded
        }
    }

    /// Whether the decoders are here at all.
    public static var isAvailable: Bool { symbols != nil }

    private let symbols: Symbols
    private let decoder: OpaquePointer

    public init?(codec: FFmpegAudioCodec, extradata: [UInt8] = []) {
        guard let symbols = Self.symbols else { return nil }
        let opened = extradata.withUnsafeBufferPointer { buffer in
            symbols.open(codec.rawValue, buffer.baseAddress, Int32(buffer.count))
        }
        guard let opened else { return nil }
        self.symbols = symbols
        decoder = opened
    }

    deinit { symbols.close(decoder) }

    /// Feeds one stored frame (or several access units).
    public func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        _ = bytes.withUnsafeBufferPointer { symbols.feed(decoder, $0.baseAddress, Int32($0.count)) }
    }

    /// Decodes what the parser still holds (the last frame waits for the
    /// next one's start otherwise).
    public func finish() {
        _ = symbols.feed(decoder, nil, 0)
    }

    public var channelCount: Int { Int(symbols.channels(decoder)) }
    public var sampleRate: Int { Int(symbols.sampleRate(decoder)) }
    public var channels: [FFmpegChannel?] {
        (0 ..< channelCount).map { FFmpegChannel(rawValue: Int(symbols.channel(decoder, Int32($0)))) }
    }
    /// Decoded frames (one sample per channel each).
    public var frameCount: Int { Int(symbols.frames(decoder)) }
    public var errorCount: Int { Int(symbols.errors(decoder)) }

    /// The PCM so far, interleaved, 24-bit values in 32-bit integers.
    public func withSamples<R>(_ body: (UnsafeBufferPointer<Int32>) throws -> R) rethrows -> R {
        let count = frameCount * channelCount
        guard count > 0, let base = symbols.samples(decoder) else {
            return try body(UnsafeBufferPointer(start: nil, count: 0))
        }
        return try body(UnsafeBufferPointer(start: base, count: count))
    }
}
