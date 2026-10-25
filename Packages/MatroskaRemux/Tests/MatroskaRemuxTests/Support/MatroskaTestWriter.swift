/*
 Test support: writes Matroska files, for the shapes no current muxer
 produces (or none installed here does): header stripping, which mkvmerge
 dropped in v61; legacy `A_AAC/MPEG4/LC` ids without CodecPrivate; fixed-size
 lacing; BlockGroups with ReferenceBlock; a Dolby Vision configuration
 record; encrypted and zlib-compressed tracks; audio with a gap.

 Input is a real fixture's tracks and frames, rewritten; a remux of the
 rewrite should then match the remux of the original.
 */

import Foundation
@testable import MatroskaRemux

struct MatroskaTestWriter {
    struct Frame {
        var track: UInt64
        /// Ticks.
        var timestamp: Int64
        var isKeyframe: Bool
        var data: [UInt8]
    }

    var timestampScale: Int64 = 1_000_000
    var duration: Double?
    var tracks: [MatroskaTrack]
    /// In file order.
    var frames: [Frame]
    /// Tracks whose frames go in BlockGroups (a ReferenceBlock on
    /// non-keyframes) instead of SimpleBlocks.
    var blockGroupTracks: Set<UInt64> = []
    /// Tracks whose consecutive frames of one size are put in fixed-size
    /// laces of this many.
    var fixedLacing: [UInt64: Int] = [:]
    /// Bytes to strip from the front of every frame of a track, recorded as
    /// header-stripping compression.
    var strippedHeaders: [UInt64: [UInt8]] = [:]

    /// Reads a fixture's tracks and every frame (laces split, each frame
    /// with its block's timestamp).
    static func load(_ data: Data) async throws -> MatroskaTestWriter {
        let source = DataByteSource(data)
        let header = try await MatroskaHeaderReader.read(source)
        var modes: [UInt64: ClusterReader.Mode] = [:]
        for track in header.tracks { modes[track.number] = .frames }
        var reader = ClusterReader(source: source, start: header.firstClusterPosition!,
                                   limit: header.contentEnd ?? Int64.max, modes: modes)
        var frames: [Frame] = []
        while let frame = try await reader.next() {
            frames.append(Frame(track: frame.track, timestamp: frame.blockTimestamp, isKeyframe: frame.isKeyframe,
                                data: frame.data))
        }
        return MatroskaTestWriter(timestampScale: header.timestampScale, duration: header.duration,
                                  tracks: header.tracks, frames: frames)
    }

    func write() -> Data {
        var tracks = self.tracks
        for (number, prefix) in strippedHeaders {
            guard let i = tracks.firstIndex(where: { $0.number == number }) else { continue }
            var encoding = MatroskaTrack.ContentEncoding()
            encoding.compressionAlgorithm = 3
            encoding.compressionSettings = prefix
            tracks[i].contentEncodings.append(encoding)
        }
        let videoNumber = tracks.first { $0.kind == .video }?.number

        // Clusters, one per video keyframe, with offsets relative to the
        // Segment's body (filled in once the head's size is known).
        var clusters: [[UInt8]] = []
        var clusterTimes: [Int64] = []
        var cues: [(time: Int64, cluster: Int)] = []
        var current: [UInt8] = []
        var clusterTime: Int64 = 0
        var i = 0
        func flush() {
            guard !current.isEmpty else { return }
            clusters.append(E.element(MatroskaID.cluster, E.uint(MatroskaID.clusterTimestamp, UInt64(clusterTime)) + current))
            clusterTimes.append(clusterTime)
            current = []
        }
        while i < frames.count {
            let frame = frames[i]
            if frame.track == videoNumber, frame.isKeyframe || clusters.isEmpty && current.isEmpty {
                flush()
                clusterTime = frame.timestamp
                if frame.isKeyframe { cues.append((frame.timestamp, clusters.count)) }
            } else if current.isEmpty, clusters.isEmpty {
                clusterTime = frame.timestamp
            }
            let prefix = strippedHeaders[frame.track] ?? []
            func stripped(_ data: [UInt8]) -> [UInt8] {
                precondition(data.starts(with: prefix), "frame doesn't start with the stripped header")
                return Array(data.dropFirst(prefix.count))
            }
            // Fixed lacing: this frame and the next frames of the track with
            // the same size, up to the lace length.
            if let lace = fixedLacing[frame.track] {
                var laced = [frame]
                var j = i + 1
                while laced.count < lace, j < frames.count, frames[j].track == frame.track,
                      frames[j].data.count == frame.data.count {
                    laced.append(frames[j])
                    j += 1
                }
                if laced.count > 1 {
                    var body = E.vint(frame.track) + E.int16(frame.timestamp - clusterTime) + [0x80 | 0x04, UInt8(laced.count - 1)]
                    for f in laced { body += stripped(f.data) }
                    current += E.element(MatroskaID.simpleBlock, body)
                    i = j
                    continue
                }
            }
            let payload = stripped(frame.data)
            if blockGroupTracks.contains(frame.track) {
                var group = E.element(MatroskaID.block, E.vint(frame.track) + E.int16(frame.timestamp - clusterTime) + [0] + payload)
                if !frame.isKeyframe { group += E.sint(MatroskaID.referenceBlock, -1) }
                current += E.element(MatroskaID.blockGroup, group)
            } else {
                let flags: UInt8 = frame.isKeyframe ? 0x80 : 0
                current += E.element(MatroskaID.simpleBlock, E.vint(frame.track) + E.int16(frame.timestamp - clusterTime) + [flags] + payload)
            }
            i += 1
        }
        flush()

        let ebmlHeader = E.element(MatroskaID.ebml, E.uint(0x4286, 1) + E.uint(0x42F7, 1) + E.uint(0x42F2, 4)
            + E.uint(0x42F3, 8) + E.string(MatroskaID.docType, "matroska") + E.uint(0x4287, 4) + E.uint(0x4285, 2))
        var info = E.uint(MatroskaID.timestampScale, UInt64(timestampScale))
        if let duration { info += E.float(MatroskaID.duration, duration) }
        let infoElement = E.element(MatroskaID.info, info)
        let tracksElement = E.element(MatroskaID.tracks, tracks.flatMap(Self.trackEntry))
        // SeekHead entries use fixed eight-byte positions, so its size is
        // known before the positions are.
        let seekHeadSize = E.element(MatroskaID.seekHead, Self.seek(MatroskaID.info, 0) + Self.seek(MatroskaID.tracks, 0)
            + Self.seek(MatroskaID.cues, 0)).count
        let infoPosition = UInt64(seekHeadSize)
        let tracksPosition = infoPosition + UInt64(infoElement.count)
        var clusterPositions: [UInt64] = []
        var position = tracksPosition + UInt64(tracksElement.count)
        for cluster in clusters {
            clusterPositions.append(position)
            position += UInt64(cluster.count)
        }
        let cuesPosition = position
        var cuePoints: [UInt8] = []
        for cue in cues {
            let positions = E.uint(MatroskaID.cueTrack, videoNumber ?? 1)
                + E.uint(MatroskaID.cueClusterPosition, clusterPositions[cue.cluster])
            cuePoints += E.element(MatroskaID.cuePoint, E.uint(MatroskaID.cueTime, UInt64(cue.time))
                + E.element(MatroskaID.cueTrackPositions, positions))
        }
        let seekHead = E.element(MatroskaID.seekHead, Self.seek(MatroskaID.info, infoPosition)
            + Self.seek(MatroskaID.tracks, tracksPosition) + Self.seek(MatroskaID.cues, cuesPosition))
        var segmentBody = seekHead + infoElement + tracksElement
        for cluster in clusters { segmentBody += cluster }
        segmentBody += E.element(MatroskaID.cues, cuePoints)
        return Data(ebmlHeader + E.element(MatroskaID.segment, segmentBody))
    }

    private static func seek(_ id: UInt32, _ position: UInt64) -> [UInt8] {
        E.element(MatroskaID.seek, E.binary(MatroskaID.seekID, E.idBytes(id))
            + E.id(MatroskaID.seekPosition) + [0x88] + (0 ..< 8).reversed().map { UInt8(position >> (8 * UInt64($0)) & 0xFF) })
    }

    static func trackEntry(_ track: MatroskaTrack) -> [UInt8] {
        var body = E.uint(MatroskaID.trackNumber, track.number) + E.uint(0x73C5, track.number)
            + E.uint(MatroskaID.trackType, track.kind?.rawValue ?? 1)
        if !track.isEnabled { body += E.uint(MatroskaID.flagEnabled, 0) }
        body += E.uint(MatroskaID.flagDefault, track.isDefault ? 1 : 0)
        if let duration = track.defaultDuration { body += E.uint(MatroskaID.defaultDuration, duration) }
        if let name = track.name { body += E.string(MatroskaID.name, name) }
        if let language = track.language { body += E.string(MatroskaID.language, language) }
        if let tag = track.languageBCP47 { body += E.string(MatroskaID.languageBCP47, tag) }
        body += E.string(MatroskaID.codecID, track.codecID)
        if !track.codecPrivate.isEmpty { body += E.binary(MatroskaID.codecPrivate, track.codecPrivate) }
        if track.codecDelay > 0 { body += E.uint(MatroskaID.codecDelay, track.codecDelay) }
        if track.seekPreRoll > 0 { body += E.uint(MatroskaID.seekPreRoll, track.seekPreRoll) }
        for mapping in track.blockAdditionMappings {
            var fields: [UInt8] = []
            if let value = mapping.idValue { fields += E.uint(MatroskaID.blockAddIDValue, value) }
            if let type = mapping.idType { fields += E.uint(MatroskaID.blockAddIDType, UInt64(type)) }
            fields += E.binary(MatroskaID.blockAddIDExtraData, mapping.extraData)
            body += E.element(MatroskaID.blockAdditionMapping, fields)
        }
        if let video = track.video {
            var fields = E.uint(MatroskaID.pixelWidth, UInt64(video.pixelWidth)) + E.uint(MatroskaID.pixelHeight, UInt64(video.pixelHeight))
            if let w = video.displayWidth { fields += E.uint(MatroskaID.displayWidth, UInt64(w)) }
            if let h = video.displayHeight { fields += E.uint(MatroskaID.displayHeight, UInt64(h)) }
            if let colour = video.colour { fields += colourElement(colour) }
            body += E.element(MatroskaID.video, fields)
        }
        if let audio = track.audio {
            var fields = E.float(MatroskaID.samplingFrequency, audio.samplingFrequency) + E.uint(MatroskaID.channels, UInt64(audio.channels))
            if let output = audio.outputSamplingFrequency { fields += E.float(MatroskaID.outputSamplingFrequency, output) }
            if let depth = audio.bitDepth { fields += E.uint(MatroskaID.bitDepth, UInt64(depth)) }
            body += E.element(MatroskaID.audio, fields)
        }
        if !track.contentEncodings.isEmpty {
            var encodings: [UInt8] = []
            for encoding in track.contentEncodings {
                var fields = E.uint(MatroskaID.contentEncodingOrder, UInt64(encoding.order))
                    + E.uint(MatroskaID.contentEncodingScope, UInt64(encoding.scope))
                    + E.uint(MatroskaID.contentEncodingType, UInt64(encoding.type))
                if encoding.type == 1 {
                    fields += E.element(MatroskaID.contentEncryption, E.uint(0x47E1, 5))
                } else {
                    var compression = E.uint(MatroskaID.contentCompAlgo, UInt64(encoding.compressionAlgorithm))
                    if !encoding.compressionSettings.isEmpty {
                        compression += E.binary(MatroskaID.contentCompSettings, encoding.compressionSettings)
                    }
                    fields += E.element(MatroskaID.contentCompression, compression)
                }
                encodings += E.element(MatroskaID.contentEncoding, fields)
            }
            body += E.element(MatroskaID.contentEncodings, encodings)
        }
        return E.element(MatroskaID.trackEntry, body)
    }

    private static func colourElement(_ colour: MatroskaTrack.Colour) -> [UInt8] {
        var fields: [UInt8] = []
        func add(_ id: UInt32, _ value: Int?) { if let value { fields += E.uint(id, UInt64(value)) } }
        add(MatroskaID.matrixCoefficients, colour.matrixCoefficients)
        add(MatroskaID.bitsPerChannel, colour.bitsPerChannel)
        add(MatroskaID.chromaSitingHorz, colour.chromaSitingHorz)
        add(MatroskaID.range, colour.range)
        add(MatroskaID.transferCharacteristics, colour.transferCharacteristics)
        add(MatroskaID.primaries, colour.primaries)
        add(MatroskaID.maxCLL, colour.maxCLL)
        add(MatroskaID.maxFALL, colour.maxFALL)
        if let m = colour.mastering {
            var mastering: [UInt8] = []
            func pair(_ x: UInt32, _ y: UInt32, _ value: (x: Double, y: Double)?) {
                guard let value else { return }
                mastering += E.float(x, value.x) + E.float(y, value.y)
            }
            pair(MatroskaID.primaryRChromaticityX, MatroskaID.primaryRChromaticityY, m.red)
            pair(MatroskaID.primaryGChromaticityX, MatroskaID.primaryGChromaticityY, m.green)
            pair(MatroskaID.primaryBChromaticityX, MatroskaID.primaryBChromaticityY, m.blue)
            pair(MatroskaID.whitePointChromaticityX, MatroskaID.whitePointChromaticityY, m.whitePoint)
            if let v = m.luminanceMax { mastering += E.float(MatroskaID.luminanceMax, v) }
            if let v = m.luminanceMin { mastering += E.float(MatroskaID.luminanceMin, v) }
            fields += E.element(MatroskaID.masteringMetadata, mastering)
        }
        return E.element(MatroskaID.colour, fields)
    }
}

/// EBML element encoding.
private enum E {
    static func idBytes(_ id: UInt32) -> [UInt8] {
        let bytes = (0 ..< 4).reversed().map { UInt8(id >> (8 * UInt32($0)) & 0xFF) }
        return Array(bytes.drop { $0 == 0 })
    }

    static func id(_ id: UInt32) -> [UInt8] { idBytes(id) }

    /// An eight-byte size, so lengths never need a second pass.
    static func size(_ size: Int) -> [UInt8] {
        [0x01] + (0 ..< 7).reversed().map { UInt8(UInt64(size) >> (8 * UInt64($0)) & 0xFF) }
    }

    static func element(_ id: UInt32, _ body: [UInt8]) -> [UInt8] { idBytes(id) + size(body.count) + body }

    static func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        var bytes = (0 ..< 8).reversed().map { UInt8(value >> (8 * UInt64($0)) & 0xFF) }
        while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
        return element(id, bytes)
    }

    static func sint(_ id: UInt32, _ value: Int64) -> [UInt8] {
        element(id, (0 ..< 2).reversed().map { UInt8(UInt64(bitPattern: value) >> (8 * UInt64($0)) & 0xFF) })
    }

    static func float(_ id: UInt32, _ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return element(id, (0 ..< 8).reversed().map { UInt8(bits >> (8 * UInt64($0)) & 0xFF) })
    }

    static func string(_ id: UInt32, _ value: String) -> [UInt8] { element(id, Array(value.utf8)) }
    static func binary(_ id: UInt32, _ value: [UInt8]) -> [UInt8] { element(id, value) }

    /// A block's track number (a one-byte vint here).
    static func vint(_ value: UInt64) -> [UInt8] { [0x80 | UInt8(value)] }

    static func int16(_ value: Int64) -> [UInt8] {
        let v = UInt16(bitPattern: Int16(value))
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
}
