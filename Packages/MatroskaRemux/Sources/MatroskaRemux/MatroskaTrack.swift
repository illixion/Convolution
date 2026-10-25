/*
 MatroskaRemux - one TrackEntry, as much of it as the remuxer uses
 */

import Foundation

public struct MatroskaTrack: Sendable {
    public enum Kind: UInt64, Sendable {
        case video = 1
        case audio = 2
        case complex = 3
        case logo = 0x10
        case subtitle = 0x11
        case buttons = 0x12
        case control = 0x20
        case metadata = 0x21
    }

    /// Matroska's Colour element (all optional; the codes are ITU-T H.273's).
    public struct Colour: Sendable, Equatable {
        public var matrixCoefficients: Int?
        public var bitsPerChannel: Int?
        public var chromaSubsamplingHorz: Int?
        public var chromaSubsamplingVert: Int?
        public var chromaSitingHorz: Int?
        public var chromaSitingVert: Int?
        /// 1 limited, 2 full.
        public var range: Int?
        public var transferCharacteristics: Int?
        public var primaries: Int?
        public var maxCLL: Int?
        public var maxFALL: Int?
        public var mastering: Mastering?

        public struct Mastering: Sendable, Equatable {
            public var red: (x: Double, y: Double)?
            public var green: (x: Double, y: Double)?
            public var blue: (x: Double, y: Double)?
            public var whitePoint: (x: Double, y: Double)?
            public var luminanceMax: Double?
            public var luminanceMin: Double?

            public static func == (a: Mastering, b: Mastering) -> Bool {
                a.red?.x == b.red?.x && a.red?.y == b.red?.y && a.green?.x == b.green?.x && a.green?.y == b.green?.y
                    && a.blue?.x == b.blue?.x && a.blue?.y == b.blue?.y && a.whitePoint?.x == b.whitePoint?.x
                    && a.whitePoint?.y == b.whitePoint?.y && a.luminanceMax == b.luminanceMax
                    && a.luminanceMin == b.luminanceMin
            }

            /// Every chromaticity and both luminances are present.
            var isComplete: Bool {
                red != nil && green != nil && blue != nil && whitePoint != nil && luminanceMax != nil && luminanceMin != nil
            }
        }
    }

    public struct Video: Sendable {
        public var pixelWidth: Int = 0
        public var pixelHeight: Int = 0
        public var displayWidth: Int?
        public var displayHeight: Int?
        /// 0 pixels (the default), 1 cm, 2 inches, 3 aspect ratio.
        public var displayUnit: Int = 0
        public var colour: Colour?
    }

    public struct Audio: Sendable {
        public var samplingFrequency: Double = 8000
        public var outputSamplingFrequency: Double?
        public var channels: Int = 1
        public var bitDepth: Int?
    }

    /// One ContentEncoding. Only header stripping (compression algorithm 3)
    /// is undone; anything else makes the track unusable here.
    public struct ContentEncoding: Sendable {
        public var order: Int = 0
        /// 1 frames, 2 CodecPrivate, 4 the next encoding.
        public var scope: Int = 1
        /// 0 compression, 1 encryption.
        public var type: Int = 0
        /// 0 zlib, 1 bzlib, 2 lzo1x, 3 header stripping.
        public var compressionAlgorithm: Int = 0
        public var compressionSettings: [UInt8] = []
    }

    /// A BlockAdditionMapping: how a block addition, or a codec
    /// configuration riding on the track (Dolby Vision's dvcC/dvvC), is read.
    public struct BlockAdditionMapping: Sendable {
        public var idValue: UInt64?
        /// A four-character code as a number ("dvvC" is 0x64767643).
        public var idType: UInt32?
        public var extraData: [UInt8] = []
    }

    public var number: UInt64 = 0
    public var kind: Kind?
    public var isEnabled = true
    public var isDefault = true
    public var isForced = false
    /// Nanoseconds per frame, when constant.
    public var defaultDuration: UInt64?
    public var name: String?
    /// ISO 639-2 ("eng"); Matroska's default when absent is English.
    public var language: String?
    public var languageBCP47: String?
    public var codecID = ""
    public var codecPrivate: [UInt8] = []
    /// Nanoseconds the decoder adds in front (Opus pre-skip).
    public var codecDelay: UInt64 = 0
    public var seekPreRoll: UInt64 = 0
    public var video: Video?
    public var audio: Audio?
    public var contentEncodings: [ContentEncoding] = []
    public var blockAdditionMappings: [BlockAdditionMapping] = []

    /// Bytes stripped from the front of every frame, to put back. Empty when
    /// the track has no header stripping.
    public var strippedHeader: [UInt8] {
        contentEncodings
            .filter { $0.type == 0 && $0.compressionAlgorithm == 3 && $0.scope & 1 != 0 }
            .sorted { $0.order > $1.order }
            .flatMap(\.compressionSettings)
    }

    /// Why the track's frames can't be read as stored, if they can't:
    /// encrypted, or compressed with anything but header stripping.
    public var unreadableEncoding: String? {
        for encoding in contentEncodings {
            if encoding.type == 1 { return "encrypted" }
            if encoding.type == 0, encoding.compressionAlgorithm != 3 {
                return ["zlib", "bzlib", "lzo1x"][safe: encoding.compressionAlgorithm].map { "\($0)-compressed" }
                    ?? "compressed"
            }
        }
        return nil
    }

    /// The language as BCP 47 ("en", "pt-BR"): the BCP 47 element when the
    /// file has one, else the ISO 639-2 code mapped to its two-letter form
    /// where there is one. Nil for "und" and absent languages.
    public var bcp47Language: String? {
        if let tag = languageBCP47, !tag.isEmpty, tag != "und" { return tag }
        let code = (language ?? "eng").lowercased()
        guard code != "und", !code.isEmpty else { return nil }
        return LanguageCodes.bcp47(fromISO6392: code)
    }
}

enum LanguageCodes {
    /// ISO 639-2 (bibliographic or terminology) to the BCP 47 primary tag:
    /// the 639-1 two-letter code where one exists, else the three letters.
    static func bcp47(fromISO6392 code: String) -> String {
        if let alpha2 = Locale.LanguageCode(code).identifier(.alpha2) { return alpha2 }
        // Foundation knows the terminology codes; Matroska files often carry
        // the bibliographic ones.
        let bibliographic = [
            "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl",
            "fre": "fr", "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi",
            "may": "ms", "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
        ]
        return bibliographic[code] ?? code
    }

    /// The ISO 639-2/T code for an `mdhd` box (three lowercase letters);
    /// "und" when there's none.
    static func iso6392T(fromBCP47 tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return "und" }
        let primary = String(tag.split(separator: "-").first ?? "")
        if let alpha3 = Locale.LanguageCode(primary).identifier(.alpha3), alpha3.count == 3 { return alpha3 }
        return primary.count == 3 ? primary.lowercased() : "und"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
