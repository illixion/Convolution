/*
 MatroskaRemux - the file's head: what's in it and where its Cues are

 Reads only the head and the elements the SeekHead points at, never the
 clusters, so opening a UHD remux over HTTP is a handful of small range
 reads. Ported from the Jellyfin plugin's `MatroskaCues.ReadVideoKeyframes`
 (SeekHead → Info → Tracks → Cues), extended to:

 - follow every SeekHead, including the second one mkvmerge writes at the
   end of a file and points to from the first;
 - read Info and Tracks wherever the SeekHead puts them, when they are not
   ahead of the first Cluster;
 - parse each TrackEntry fully (codec private data, colour and mastering
   metadata, content encodings, block addition mappings);
 - keep every cue point's cluster position, which is what the segment
   index is cut from;
 - stop cleanly at an element of unknown size (a live stream's Segment or
   Cluster), with no Cues, which the caller then indexes by scanning.
 */

import Foundation

public struct CuePoint: Sendable, Equatable {
    /// In the file's timestamp ticks.
    public var time: Int64
    public var track: UInt64
    /// Absolute byte offset of the Cluster holding the block.
    public var clusterPosition: Int64
    /// Offset of the block inside the cluster's body, when given.
    public var relativePosition: Int64?
}

public struct MatroskaHeader: Sendable {
    /// "matroska" or "webm".
    public var docType = "matroska"
    /// Offset of the Segment's body, which every SeekPosition and
    /// CueClusterPosition is relative to.
    public var segmentDataStart: Int64 = 0
    /// Offset just past the Segment, when its size is known.
    public var segmentEnd: Int64?
    /// Nanoseconds per timestamp tick (Info's TimestampScale).
    public var timestampScale: Int64 = 1_000_000
    /// The duration in ticks (Info's Duration is a float), when written.
    public var duration: Double?
    public var tracks: [MatroskaTrack] = []
    public var cues: [CuePoint] = []
    public var firstClusterPosition: Int64?
    /// The source's length, when known.
    public var sourceLength: Int64?

    /// Where the Segment's content ends: its own end, else the source's.
    public var contentEnd: Int64? { segmentEnd ?? sourceLength }

    public func nanoseconds(ticks: Int64) -> Int64 { ticks * timestampScale }
    public var durationNanoseconds: Int64? { duration.map { Int64(($0 * Double(timestampScale)).rounded()) } }
}

public enum MatroskaHeaderReader {
    static let headLength: Int64 = 256 * 1024

    public static func read(_ source: any ByteSource) async throws -> MatroskaHeader {
        let length = try await source.length()
        var reader = HeadReader(source: source, length: length)
        try await reader.load(0 ..< min(headLength, length ?? headLength))

        var header = MatroskaHeader()
        header.sourceLength = length

        // EBML header: the magic, and a DocType we read.
        guard let ebml = try await reader.element(at: 0), ebml.id == MatroskaID.ebml, let ebmlSize = ebml.size else {
            throw RemuxError.notMatroska
        }
        let ebmlBody = try await reader.body(of: ebml)
        var docTypeReader = EBMLReader(ebmlBody)
        while let child = docTypeReader.next() {
            if child.id == MatroskaID.docType { header.docType = docTypeReader.string(child) }
        }
        guard header.docType == "matroska" || header.docType == "webm" else {
            throw RemuxError.declined("document type \(header.docType)")
        }

        // The Segment, skipping anything (Void) between it and the EBML header.
        var position = ebml.bodyStart + Int64(ebmlSize)
        var segment: ElementHeader?
        while let element = try await reader.element(at: position) {
            if element.id == MatroskaID.segment { segment = element; break }
            guard let size = element.size else { break }
            position = element.bodyStart + Int64(size)
        }
        guard let segment else { throw RemuxError.malformed("no Segment") }
        header.segmentDataStart = segment.bodyStart
        header.segmentEnd = segment.size.map { segment.bodyStart + Int64($0) }
        let segmentEnd = header.segmentEnd ?? length ?? Int64.max

        var seekTargets: [UInt32: [Int64]] = [:]
        var visited = Set<Int64>()
        var haveInfo = false, haveTracks = false, haveCues = false

        func handle(_ element: ElementHeader) async throws {
            visited.insert(element.start)
            switch element.id {
            case MatroskaID.seekHead:
                let body = try await reader.body(of: element)
                for (id, target) in parseSeekHead(body) {
                    seekTargets[id, default: []].append(header.segmentDataStart + target)
                }
            case MatroskaID.info:
                parseInfo(try await reader.body(of: element), into: &header)
                haveInfo = true
            case MatroskaID.tracks:
                header.tracks = parseTracks(try await reader.body(of: element))
                haveTracks = true
            case MatroskaID.cues:
                header.cues = parseCues(try await reader.body(of: element), segmentDataStart: header.segmentDataStart)
                haveCues = true
            default:
                break
            }
        }

        // Top-level elements up to the first Cluster.
        position = segment.bodyStart
        while position < segmentEnd, let element = try await reader.element(at: position) {
            if element.id == MatroskaID.cluster {
                header.firstClusterPosition = element.start
                break
            }
            try await handle(element)
            guard let size = element.size else { break }
            position = element.bodyStart + Int64(size)
        }

        // What the SeekHeads point at that wasn't ahead of the clusters:
        // further SeekHeads first (they can add targets), then the rest.
        for _ in 0 ..< 4 {
            let pending = (seekTargets[MatroskaID.seekHead] ?? []).filter { !visited.contains($0) }
            guard !pending.isEmpty else { break }
            for target in pending {
                visited.insert(target)
                if let element = try await reader.element(at: target), element.id == MatroskaID.seekHead {
                    try await handle(element)
                }
            }
        }
        for (id, done) in [(MatroskaID.info, haveInfo), (MatroskaID.tracks, haveTracks), (MatroskaID.cues, haveCues)] where !done {
            for target in seekTargets[id] ?? [] where !visited.contains(target) {
                if let element = try await reader.element(at: target), element.id == id {
                    try await handle(element)
                    break
                }
            }
        }
        if header.firstClusterPosition == nil, let target = seekTargets[MatroskaID.cluster]?.min(),
           let element = try await reader.element(at: target), element.id == MatroskaID.cluster {
            header.firstClusterPosition = target
        }

        guard !header.tracks.isEmpty else { throw RemuxError.malformed("no Tracks") }
        return header
    }

    // MARK: - Element bodies

    static func parseSeekHead(_ body: [UInt8]) -> [(UInt32, Int64)] {
        var result: [(UInt32, Int64)] = []
        var reader = EBMLReader(body)
        while let seek = reader.next() {
            guard seek.id == MatroskaID.seek else { continue }
            var id: UInt32?
            var position: Int64?
            for child in reader.children(of: seek) {
                switch child.id {
                case MatroskaID.seekID: id = UInt32(truncatingIfNeeded: reader.uint(child))
                case MatroskaID.seekPosition: position = Int64(clamping: reader.uint(child))
                default: break
                }
            }
            if let id, let position { result.append((id, position)) }
        }
        return result
    }

    static func parseInfo(_ body: [UInt8], into header: inout MatroskaHeader) {
        var reader = EBMLReader(body)
        while let element = reader.next() {
            switch element.id {
            case MatroskaID.timestampScale:
                let scale = Int64(clamping: reader.uint(element))
                if scale > 0 { header.timestampScale = scale }
            case MatroskaID.duration:
                let duration = reader.float(element)
                if duration > 0, duration.isFinite { header.duration = duration }
            default: break
            }
        }
    }

    static func parseTracks(_ body: [UInt8]) -> [MatroskaTrack] {
        var reader = EBMLReader(body)
        var tracks: [MatroskaTrack] = []
        while let entry = reader.next() {
            guard entry.id == MatroskaID.trackEntry else { continue }
            tracks.append(parseTrackEntry(reader, entry))
        }
        return tracks
    }

    static func parseTrackEntry(_ reader: EBMLReader, _ entry: EBMLElement) -> MatroskaTrack {
        var track = MatroskaTrack()
        for child in reader.children(of: entry) {
            switch child.id {
            case MatroskaID.trackNumber: track.number = reader.uint(child)
            case MatroskaID.trackType: track.kind = MatroskaTrack.Kind(rawValue: reader.uint(child))
            case MatroskaID.flagEnabled: track.isEnabled = reader.uint(child) != 0
            case MatroskaID.flagDefault: track.isDefault = reader.uint(child) != 0
            case MatroskaID.flagForced: track.isForced = reader.uint(child) != 0
            case MatroskaID.flagHearingImpaired: track.isHearingImpaired = reader.uint(child) != 0
            case MatroskaID.defaultDuration:
                let duration = reader.uint(child)
                if duration > 0 { track.defaultDuration = duration }
            case MatroskaID.name: track.name = reader.string(child)
            case MatroskaID.language: track.language = reader.string(child)
            case MatroskaID.languageBCP47: track.languageBCP47 = reader.string(child)
            case MatroskaID.codecID: track.codecID = reader.string(child)
            case MatroskaID.codecPrivate: track.codecPrivate = reader.data(child)
            case MatroskaID.codecDelay: track.codecDelay = reader.uint(child)
            case MatroskaID.seekPreRoll: track.seekPreRoll = reader.uint(child)
            case MatroskaID.video: track.video = parseVideo(reader, child)
            case MatroskaID.audio: track.audio = parseAudio(reader, child)
            case MatroskaID.contentEncodings:
                for encoding in reader.children(of: child) where encoding.id == MatroskaID.contentEncoding {
                    track.contentEncodings.append(parseContentEncoding(reader, encoding))
                }
            case MatroskaID.blockAdditionMapping:
                var mapping = MatroskaTrack.BlockAdditionMapping()
                for field in reader.children(of: child) {
                    switch field.id {
                    case MatroskaID.blockAddIDValue: mapping.idValue = reader.uint(field)
                    case MatroskaID.blockAddIDType: mapping.idType = UInt32(truncatingIfNeeded: reader.uint(field))
                    case MatroskaID.blockAddIDExtraData: mapping.extraData = reader.data(field)
                    default: break
                    }
                }
                track.blockAdditionMappings.append(mapping)
            default: break
            }
        }
        // Header stripping can cover CodecPrivate too (scope 2).
        for encoding in track.contentEncodings
        where encoding.type == 0 && encoding.compressionAlgorithm == 3 && encoding.scope & 2 != 0 {
            track.codecPrivate = encoding.compressionSettings + track.codecPrivate
        }
        return track
    }

    static func parseVideo(_ reader: EBMLReader, _ element: EBMLElement) -> MatroskaTrack.Video {
        var video = MatroskaTrack.Video()
        for child in reader.children(of: element) {
            switch child.id {
            case MatroskaID.pixelWidth: video.pixelWidth = Int(clamping: reader.uint(child))
            case MatroskaID.pixelHeight: video.pixelHeight = Int(clamping: reader.uint(child))
            case MatroskaID.displayWidth: video.displayWidth = Int(clamping: reader.uint(child))
            case MatroskaID.displayHeight: video.displayHeight = Int(clamping: reader.uint(child))
            case MatroskaID.displayUnit: video.displayUnit = Int(clamping: reader.uint(child))
            case MatroskaID.colour: video.colour = parseColour(reader, child)
            default: break
            }
        }
        return video
    }

    static func parseColour(_ reader: EBMLReader, _ element: EBMLElement) -> MatroskaTrack.Colour {
        var colour = MatroskaTrack.Colour()
        func int(_ e: EBMLElement) -> Int { Int(clamping: reader.uint(e)) }
        for child in reader.children(of: element) {
            switch child.id {
            case MatroskaID.matrixCoefficients: colour.matrixCoefficients = int(child)
            case MatroskaID.bitsPerChannel: colour.bitsPerChannel = int(child)
            case MatroskaID.chromaSubsamplingHorz: colour.chromaSubsamplingHorz = int(child)
            case MatroskaID.chromaSubsamplingVert: colour.chromaSubsamplingVert = int(child)
            case MatroskaID.chromaSitingHorz: colour.chromaSitingHorz = int(child)
            case MatroskaID.chromaSitingVert: colour.chromaSitingVert = int(child)
            case MatroskaID.range: colour.range = int(child)
            case MatroskaID.transferCharacteristics: colour.transferCharacteristics = int(child)
            case MatroskaID.primaries: colour.primaries = int(child)
            case MatroskaID.maxCLL: colour.maxCLL = int(child)
            case MatroskaID.maxFALL: colour.maxFALL = int(child)
            case MatroskaID.masteringMetadata:
                var mastering = MatroskaTrack.Colour.Mastering()
                var values: [UInt32: Double] = [:]
                for field in reader.children(of: child) { values[field.id] = reader.float(field) }
                func pair(_ x: UInt32, _ y: UInt32) -> (x: Double, y: Double)? {
                    guard let vx = values[x], let vy = values[y] else { return nil }
                    return (vx, vy)
                }
                mastering.red = pair(MatroskaID.primaryRChromaticityX, MatroskaID.primaryRChromaticityY)
                mastering.green = pair(MatroskaID.primaryGChromaticityX, MatroskaID.primaryGChromaticityY)
                mastering.blue = pair(MatroskaID.primaryBChromaticityX, MatroskaID.primaryBChromaticityY)
                mastering.whitePoint = pair(MatroskaID.whitePointChromaticityX, MatroskaID.whitePointChromaticityY)
                mastering.luminanceMax = values[MatroskaID.luminanceMax]
                mastering.luminanceMin = values[MatroskaID.luminanceMin]
                colour.mastering = mastering
            default: break
            }
        }
        return colour
    }

    static func parseAudio(_ reader: EBMLReader, _ element: EBMLElement) -> MatroskaTrack.Audio {
        var audio = MatroskaTrack.Audio()
        for child in reader.children(of: element) {
            switch child.id {
            case MatroskaID.samplingFrequency: audio.samplingFrequency = reader.float(child)
            case MatroskaID.outputSamplingFrequency: audio.outputSamplingFrequency = reader.float(child)
            case MatroskaID.channels: audio.channels = Int(clamping: reader.uint(child))
            case MatroskaID.bitDepth: audio.bitDepth = Int(clamping: reader.uint(child))
            default: break
            }
        }
        return audio
    }

    static func parseContentEncoding(_ reader: EBMLReader, _ element: EBMLElement) -> MatroskaTrack.ContentEncoding {
        var encoding = MatroskaTrack.ContentEncoding()
        for child in reader.children(of: element) {
            switch child.id {
            case MatroskaID.contentEncodingOrder: encoding.order = Int(clamping: reader.uint(child))
            case MatroskaID.contentEncodingScope: encoding.scope = Int(clamping: reader.uint(child))
            case MatroskaID.contentEncodingType: encoding.type = Int(clamping: reader.uint(child))
            case MatroskaID.contentCompression:
                for field in reader.children(of: child) {
                    switch field.id {
                    case MatroskaID.contentCompAlgo: encoding.compressionAlgorithm = Int(clamping: reader.uint(field))
                    case MatroskaID.contentCompSettings: encoding.compressionSettings = reader.data(field)
                    default: break
                    }
                }
            case MatroskaID.contentEncryption:
                encoding.type = 1
            default: break
            }
        }
        return encoding
    }

    static func parseCues(_ body: [UInt8], segmentDataStart: Int64) -> [CuePoint] {
        var reader = EBMLReader(body)
        var cues: [CuePoint] = []
        while let point = reader.next() {
            guard point.id == MatroskaID.cuePoint else { continue }
            var time: Int64?
            var positions: [(track: UInt64, cluster: Int64, relative: Int64?)] = []
            for child in reader.children(of: point) {
                switch child.id {
                case MatroskaID.cueTime: time = Int64(clamping: reader.uint(child))
                case MatroskaID.cueTrackPositions:
                    var track: UInt64?, cluster: Int64?, relative: Int64?
                    for field in reader.children(of: child) {
                        switch field.id {
                        case MatroskaID.cueTrack: track = reader.uint(field)
                        case MatroskaID.cueClusterPosition: cluster = Int64(clamping: reader.uint(field))
                        case MatroskaID.cueRelativePosition: relative = Int64(clamping: reader.uint(field))
                        default: break
                        }
                    }
                    if let track, let cluster { positions.append((track, cluster, relative)) }
                default: break
                }
            }
            guard let time else { continue }
            for position in positions {
                cues.append(CuePoint(time: time, track: position.track,
                                     clusterPosition: segmentDataStart + position.cluster,
                                     relativePosition: position.relative))
            }
        }
        return cues
    }
}

/// An element header read from a source.
struct ElementHeader {
    let id: UInt32
    let start: Int64
    let bodyStart: Int64
    let size: UInt64?
}

/// The file's head in memory, plus single-element reads anywhere else.
struct HeadReader {
    let source: any ByteSource
    let length: Int64?
    private var buffer: [UInt8] = []
    private var bufferStart: Int64 = 0

    init(source: any ByteSource, length: Int64?) {
        self.source = source
        self.length = length
    }

    mutating func load(_ range: Range<Int64>) async throws {
        buffer = [UInt8](try await source.read(range))
        bufferStart = range.lowerBound
    }

    private func bytes(_ range: Range<Int64>) async throws -> [UInt8] {
        if range.lowerBound >= bufferStart, range.upperBound <= bufferStart + Int64(buffer.count) {
            return Array(buffer[Int(range.lowerBound - bufferStart) ..< Int(range.upperBound - bufferStart)])
        }
        return [UInt8](try await source.read(range))
    }

    /// The element header at `position`; nil past the end or on bytes that
    /// aren't one.
    func element(at position: Int64) async throws -> ElementHeader? {
        if let length, position >= length { return nil }
        let head = try await bytes(position ..< position + 12)
        guard let (id, idLength) = EBML.id(head, at: 0, end: head.count),
              let (size, sizeLength) = EBML.size(head, at: idLength, end: head.count) else { return nil }
        return ElementHeader(id: id, start: position, bodyStart: position + Int64(idLength + sizeLength), size: size)
    }

    /// A known-size element's body. Bodies over 64 MB are refused: nothing
    /// the head reader reads (SeekHead, Info, Tracks, Cues) is that big in a
    /// real file.
    func body(of element: ElementHeader) async throws -> [UInt8] {
        guard let size = element.size else { throw RemuxError.malformed("unknown-size \(String(element.id, radix: 16))") }
        guard size <= 64 << 20 else { throw RemuxError.malformed("oversized \(String(element.id, radix: 16))") }
        return try await bytes(element.bodyStart ..< element.bodyStart + Int64(size))
    }
}
