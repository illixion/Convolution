/*
 FFmpegDecoders - Dolby Vision RPUs, for the sideload edition (HYPNOS_DOVI)

 FFmpeg's RPU reader and writer, in the same HypnosFFmpeg.framework as the
 audio decoders and looked up the same way (`FFmpegAudioDecoder.handle`):
 nothing links it, and without it every call here returns nil.

 - `convertToProfile81` rewrites a profile 7 RPU as a single-layer profile
   8.1 one, as dovi_tool's mode 2 does (Shim/CFFmpegShim.h has the details).
 - `parse` reads an RPU into `hyp_ff_dovi_rpu`, the shim's flat C struct, for
   applying it without FFmpeg (its header documents every field's units).

 Both take an RPU as a NAL unit (0x7C 0x01, escaped) or as a bare payload
 from the 0x19 prefix (escaped or not), and keep no state between calls, so
 the same bytes always give the same result.
 */

/// Re-exported for `hyp_ff_dovi_rpu` and its member types.
@_exported import CFFmpegShim
import Darwin
import Foundation

public enum FFmpegDolbyVision {
    private struct Symbols: @unchecked Sendable {
        typealias Convert = @convention(c) (UnsafePointer<UInt8>?, Int32, UnsafeMutablePointer<UInt8>?, Int32, Int32,
                                            UnsafeMutablePointer<Int32>?) -> Int32
        typealias Parse = @convention(c) (UnsafePointer<UInt8>?, Int32, UnsafeMutablePointer<hyp_ff_dovi_rpu>?) -> Int32
        let convert: Convert
        let parse: Parse
    }

    private static let symbols: Symbols? = {
        guard let handle = FFmpegAudioDecoder.handle,
              let convert = dlsym(handle, "hyp_ff_dovi_convert_to_81"),
              let parse = dlsym(handle, "hyp_ff_dovi_parse") else { return nil }
        return Symbols(convert: unsafeBitCast(convert, to: Symbols.Convert.self),
                       parse: unsafeBitCast(parse, to: Symbols.Parse.self))
    }()

    /// Whether the framework is here and has the RPU functions (one built
    /// before them has only the audio decoders).
    public static var isAvailable: Bool { symbols != nil }

    public enum EnhancementLayer: Int32, Sendable {
        case none = 0, minimal = 1, full = 2
    }

    /// One RPU rewritten as profile 8.1, in the input's form, and what the
    /// source's enhancement layer was; nil when it can't be read.
    /// `keepFullLayerMapping` keeps a FEL's reshaping curves instead of
    /// making them identity (dovi_tool's "8.1, mapping preserved").
    public static func convertToProfile81(_ rpu: [UInt8], keepFullLayerMapping: Bool = false)
        -> (rpu: [UInt8], sourceLayer: EnhancementLayer)? {
        guard let symbols, !rpu.isEmpty else { return nil }
        let flags: Int32 = keepFullLayerMapping ? 1 : 0
        var capacity = rpu.count + 64
        for _ in 0 ..< 2 {
            var out = [UInt8](repeating: 0, count: capacity)
            var layer: Int32 = 0
            let written = rpu.withUnsafeBufferPointer { input in
                out.withUnsafeMutableBufferPointer { output in
                    symbols.convert(input.baseAddress, Int32(input.count), output.baseAddress, Int32(output.count),
                                    flags, &layer)
                }
            }
            guard written > 0 else { return nil }
            if Int(written) <= capacity {
                out.removeLast(capacity - Int(written))
                return (out, EnhancementLayer(rawValue: layer) ?? .none)
            }
            capacity = Int(written)
        }
        return nil
    }

    /// Everything one RPU says (`hyp_ff_dovi_rpu`), or nil when it can't be
    /// read.
    public static func parse(_ rpu: [UInt8]) -> hyp_ff_dovi_rpu? {
        guard let symbols, !rpu.isEmpty else { return nil }
        var out = hyp_ff_dovi_rpu()
        out.struct_size = UInt32(MemoryLayout<hyp_ff_dovi_rpu>.size)
        let status = rpu.withUnsafeBufferPointer { symbols.parse($0.baseAddress, Int32($0.count), &out) }
        return status == 0 ? out : nil
    }
}
