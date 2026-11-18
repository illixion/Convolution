/*
 FFmpegDecoders - VP8 to pictures, for the sideload edition

 FFmpeg's own VP8 decoder (not libvpx), in the same HypnosFFmpeg.framework
 as the audio decoders and looked up the same way (`FFmpegAudioDecoder.handle`):
 nothing links it, and without the framework (or with one built before VP8
 was added) no decoder opens.

 Frames go in as stored, in decode order, each with a tag; pictures come out
 with the tag of the frame they were decoded from, 8-bit 4:2:0 in three
 planes, and are only valid inside the callback that receives them (the
 decoder reuses them). A frame that shows nothing (an alt-ref) gives none.
 */

@_exported import CFFmpegShim
import Darwin
import Foundation

public enum FFmpegVideoCodec: Int32, Sendable {
    // The shim's hyp_ff_video_codec values.
    case vp8 = 1

    /// The codec for a Matroska CodecID, when this package decodes it.
    public init?(matroskaCodecID id: String) {
        switch id {
        case "V_VP8": self = .vp8
        default: return nil
        }
    }
}

public final class FFmpegVideoDecoder {
    fileprivate struct Symbols: @unchecked Sendable {
        typealias Open = @convention(c) (Int32, UnsafePointer<UInt8>?, Int32, Int32) -> OpaquePointer?
        typealias Send = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int32, Int64) -> Int32
        typealias Receive = @convention(c) (OpaquePointer?, UnsafeMutablePointer<hyp_ff_picture>?) -> Int32
        typealias Errors = @convention(c) (OpaquePointer?) -> Int32
        typealias Close = @convention(c) (OpaquePointer?) -> Void
        typealias Copy = @convention(c) (UnsafePointer<hyp_ff_picture>?, UnsafeMutablePointer<UInt8>?, Int32,
                                         UnsafeMutablePointer<UInt8>?, Int32) -> Void
        let open: Open, send: Send, receive: Receive, errors: Errors, close: Close, copy: Copy
    }

    private static let symbols: Symbols? = {
        guard let handle = FFmpegAudioDecoder.handle else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let open = symbol("hyp_ff_video_open", Symbols.Open.self),
              let send = symbol("hyp_ff_video_send", Symbols.Send.self),
              let receive = symbol("hyp_ff_video_receive", Symbols.Receive.self),
              let errors = symbol("hyp_ff_video_errors", Symbols.Errors.self),
              let close = symbol("hyp_ff_video_close", Symbols.Close.self),
              let copy = symbol("hyp_ff_picture_copy_nv12", Symbols.Copy.self) else { return nil }
        return Symbols(open: open, send: send, receive: receive, errors: errors, close: close, copy: copy)
    }()

    /// Whether the framework is here and has the video decoder (one built
    /// before it has only the audio decoders).
    public static var isAvailable: Bool { symbols != nil }

    /// One decoded picture, valid only inside the callback it is handed to.
    public struct Picture {
        let raw: UnsafePointer<hyp_ff_picture>
        fileprivate let copy: Symbols.Copy

        public var width: Int { Int(raw.pointee.width) }
        public var height: Int { Int(raw.pointee.height) }
        /// The tag of the frame it was decoded from.
        public var tag: Int64 { raw.pointee.tag }
        public var isFullRange: Bool { raw.pointee.full_range != 0 }
        public var isKeyframe: Bool { raw.pointee.key_frame != 0 }
        /// Plane 0 Y, 1 Cb, 2 Cr (chroma half size, rounded up).
        public func plane(_ index: Int) -> (base: UnsafePointer<UInt8>, stride: Int) {
            let p = raw.pointee
            switch index {
            case 0: return (p.planes.0!, Int(p.strides.0))
            case 1: return (p.planes.1!, Int(p.strides.1))
            default: return (p.planes.2!, Int(p.strides.2))
            }
        }

        /// Copies the picture into NV12 planes (a 420v/420f CVPixelBuffer's).
        public func copyNV12(luma: UnsafeMutablePointer<UInt8>, lumaStride: Int,
                             chroma: UnsafeMutablePointer<UInt8>, chromaStride: Int) {
            copy(raw, luma, Int32(lumaStride), chroma, Int32(chromaStride))
        }
    }

    private let symbols: Symbols
    private let decoder: OpaquePointer

    /// `threads` 0 lets FFmpeg pick.
    public init?(codec: FFmpegVideoCodec, extradata: [UInt8] = [], threads: Int = 0) {
        guard let symbols = Self.symbols else { return nil }
        let opened = extradata.withUnsafeBufferPointer {
            symbols.open(codec.rawValue, $0.baseAddress, Int32($0.count), Int32(threads))
        }
        guard let opened else { return nil }
        self.symbols = symbols
        decoder = opened
    }

    deinit { symbols.close(decoder) }

    /// Decodes one stored frame, handing each picture that is ready to
    /// `output`. False when the frame was refused.
    @discardableResult
    public func decode(_ frame: [UInt8], tag: Int64, output: (Picture) -> Void) -> Bool {
        guard !frame.isEmpty else { return false }
        var status: Int32
        repeat {
            status = frame.withUnsafeBufferPointer { symbols.send(decoder, $0.baseAddress, Int32($0.count), tag) }
            if status == -EAGAIN { drain(output) }
        } while status == -EAGAIN
        drain(output)
        return status >= 0
    }

    /// Hands out every picture still held (frame threading keeps a few).
    public func finish(output: (Picture) -> Void) {
        _ = symbols.send(decoder, nil, 0, 0)
        drain(output)
    }

    /// Frames that failed to decode.
    public var errorCount: Int { Int(symbols.errors(decoder)) }

    private func drain(_ output: (Picture) -> Void) {
        var picture = hyp_ff_picture()
        while symbols.receive(decoder, &picture) == 1 {
            withUnsafePointer(to: &picture) { output(Picture(raw: $0, copy: symbols.copy)) }
        }
    }
}
