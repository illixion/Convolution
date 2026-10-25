/*
 MatroskaRemux - EBML, the binary XML Matroska is written in

 An element is an ID (a variable-length integer that keeps its marker bits),
 a size (a variable-length integer without them; all ones means "unknown",
 which live muxers use for Segment and Cluster) and a body. Masters hold
 child elements; leaves hold an unsigned or signed integer, a float, a
 string or binary.

 Two readers share the vint rules here: `EBMLReader` walks a buffer already
 in memory (the file's head, the Cues, a TrackEntry), and `ByteCursor`
 streams clusters from a `ByteSource`. The element IDs are the subset of
 the Matroska schema the remuxer reads, ported from the Jellyfin plugin's
 `MatroskaCues.cs` and extended.
 */

import Foundation

enum MatroskaID {
    static let ebml: UInt32 = 0x1A45DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x18538067
    static let seekHead: UInt32 = 0x114D9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654AE6B
    static let cues: UInt32 = 0x1C53BB6B
    static let chapters: UInt32 = 0x1043A770
    static let tags: UInt32 = 0x1254C367
    static let attachments: UInt32 = 0x1941A469
    static let cluster: UInt32 = 0x1F43B675
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF

    // TrackEntry
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagEnabled: UInt32 = 0xB9
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let flagHearingImpaired: UInt32 = 0x55AB
    static let defaultDuration: UInt32 = 0x23E383
    static let name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let codecDelay: UInt32 = 0x56AA
    static let seekPreRoll: UInt32 = 0x56BB
    static let blockAdditionMapping: UInt32 = 0x41E4
    static let blockAddIDValue: UInt32 = 0x41F0
    static let blockAddIDType: UInt32 = 0x41E7
    static let blockAddIDExtraData: UInt32 = 0x41ED
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingOrder: UInt32 = 0x5031
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let contentEncryption: UInt32 = 0x5035

    // Video
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let displayUnit: UInt32 = 0x54B2
    static let colour: UInt32 = 0x55B0
    static let matrixCoefficients: UInt32 = 0x55B1
    static let bitsPerChannel: UInt32 = 0x55B2
    static let chromaSubsamplingHorz: UInt32 = 0x55B3
    static let chromaSubsamplingVert: UInt32 = 0x55B4
    static let chromaSitingHorz: UInt32 = 0x55B7
    static let chromaSitingVert: UInt32 = 0x55B8
    static let range: UInt32 = 0x55B9
    static let transferCharacteristics: UInt32 = 0x55BA
    static let primaries: UInt32 = 0x55BB
    static let maxCLL: UInt32 = 0x55BC
    static let maxFALL: UInt32 = 0x55BD
    static let masteringMetadata: UInt32 = 0x55D0
    static let primaryRChromaticityX: UInt32 = 0x55D1
    static let primaryRChromaticityY: UInt32 = 0x55D2
    static let primaryGChromaticityX: UInt32 = 0x55D3
    static let primaryGChromaticityY: UInt32 = 0x55D4
    static let primaryBChromaticityX: UInt32 = 0x55D5
    static let primaryBChromaticityY: UInt32 = 0x55D6
    static let whitePointChromaticityX: UInt32 = 0x55D7
    static let whitePointChromaticityY: UInt32 = 0x55D8
    static let luminanceMax: UInt32 = 0x55D9
    static let luminanceMin: UInt32 = 0x55DA

    // Audio
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264

    // Cues
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cueRelativePosition: UInt32 = 0xF0

    // Cluster
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFB

    /// Level-1 elements: one of these (or a new EBML header or Segment)
    /// ends a Cluster of unknown size.
    static let topLevel: Set<UInt32> = [
        seekHead, info, tracks, cues, chapters, tags, attachments, cluster, ebml, segment,
    ]
}

enum EBML {
    /// Bytes in the vint whose first byte is `first`; nil for 0x00 (a vint
    /// longer than eight bytes, which Matroska never writes).
    @inline(__always)
    static func vintLength(_ first: UInt8) -> Int? {
        first == 0 ? nil : first.leadingZeroBitCount + 1
    }

    /// An element ID at `index` (marker bits kept) and its length. IDs are at
    /// most four bytes.
    static func id(_ bytes: [UInt8], at index: Int, end: Int) -> (id: UInt32, length: Int)? {
        guard index < end, let length = vintLength(bytes[index]), length <= 4, index + length <= end else { return nil }
        var value = UInt32(bytes[index])
        for i in 1 ..< length { value = value << 8 | UInt32(bytes[index + i]) }
        return (value, length)
    }

    /// An element size at `index` and its length; `size` is nil for the
    /// reserved "unknown" value (all value bits set).
    static func size(_ bytes: [UInt8], at index: Int, end: Int) -> (size: UInt64?, length: Int)? {
        guard index < end, let length = vintLength(bytes[index]), index + length <= end else { return nil }
        var value = UInt64(bytes[index]) & (0xFF >> UInt64(length))
        var allOnes = value == (0xFF >> UInt64(length))
        for i in 1 ..< length {
            value = value << 8 | UInt64(bytes[index + i])
            allOnes = allOnes && bytes[index + i] == 0xFF
        }
        return (allOnes ? nil : value, length)
    }

    /// A signed vint (EBML lacing's size differences): the unsigned value
    /// minus the midpoint of its range.
    static func signedVint(_ bytes: [UInt8], at index: Int, end: Int) -> (value: Int64, length: Int)? {
        guard let (raw, length) = size(bytes, at: index, end: end) else { return nil }
        let unsigned = raw ?? (UInt64(1) << UInt64(7 * length)) - 1
        let bias = (Int64(1) << Int64(7 * length - 1)) - 1
        return (Int64(unsigned) - bias, length)
    }

    static func uint(_ bytes: [UInt8], _ range: Range<Int>) -> UInt64 {
        var value: UInt64 = 0
        for i in range.prefix(8) { value = value << 8 | UInt64(bytes[i]) }
        return value
    }

    static func int(_ bytes: [UInt8], _ range: Range<Int>) -> Int64 {
        guard !range.isEmpty else { return 0 }
        var value = Int64(Int8(bitPattern: bytes[range.lowerBound]))
        for i in range.dropFirst().prefix(7) { value = value << 8 | Int64(bytes[i]) }
        return value
    }

    static func float(_ bytes: [UInt8], _ range: Range<Int>) -> Double {
        switch range.count {
        case 4: Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(bytes, range))))
        case 8: Double(bitPattern: uint(bytes, range))
        default: 0
        }
    }

    static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        let trimmed = bytes[range].prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }
}

/// One element in a buffer.
struct EBMLElement {
    let id: UInt32
    /// Where its header starts.
    let start: Int
    /// Where its body starts.
    let bodyStart: Int
    /// Body size; nil when unknown.
    let size: Int?

    func body(clampedTo end: Int) -> Range<Int> {
        bodyStart ..< min(end, size.map { bodyStart + $0 } ?? end)
    }
}

/// Walks the elements of a buffer already in memory.
struct EBMLReader {
    let bytes: [UInt8]
    private(set) var position: Int
    let end: Int

    init(_ bytes: [UInt8], range: Range<Int>? = nil) {
        self.bytes = bytes
        position = range?.lowerBound ?? 0
        end = range?.upperBound ?? bytes.count
    }

    /// The next element, skipping past its body. Nil at the end or on a
    /// header that doesn't parse (a corrupt or truncated buffer).
    mutating func next() -> EBMLElement? {
        guard let (id, idLength) = EBML.id(bytes, at: position, end: end),
              let (size, sizeLength) = EBML.size(bytes, at: position + idLength, end: end) else { return nil }
        let bodyStart = position + idLength + sizeLength
        let element = EBMLElement(id: id, start: position, bodyStart: bodyStart, size: size.map { Int(clamping: $0) })
        if let size = element.size {
            position = min(end, bodyStart + size)
        } else {
            position = end
        }
        return element
    }

    /// The children of `element`, in order.
    func children(of element: EBMLElement) -> [EBMLElement] {
        var reader = EBMLReader(bytes, range: element.body(clampedTo: end))
        var result: [EBMLElement] = []
        while let child = reader.next() { result.append(child) }
        return result
    }

    func uint(_ element: EBMLElement) -> UInt64 { EBML.uint(bytes, element.body(clampedTo: end)) }
    func int(_ element: EBMLElement) -> Int64 { EBML.int(bytes, element.body(clampedTo: end)) }
    func float(_ element: EBMLElement) -> Double { EBML.float(bytes, element.body(clampedTo: end)) }
    func string(_ element: EBMLElement) -> String { EBML.string(bytes, element.body(clampedTo: end)) }
    func data(_ element: EBMLElement) -> [UInt8] { Array(bytes[element.body(clampedTo: end)]) }
}
