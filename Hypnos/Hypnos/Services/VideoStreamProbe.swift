/*
 Hypnos - why a remote video stalls, on the debug server

 `videoStreamProbe` answers "is the network too slow for this video, or is
 the file laid out so that it can't stream?" for the first video window with
 a player, from three sources:
 - the player's own access and error logs (AVFoundation's measured bitrate,
   stall count, bytes moved; error codes without their URLs);
 - the file's top-level container boxes, walked with ranged reads of each
   box header (where `moov`, the index, sits: after `mdat` means the player
   must fetch the end of the file before it can play the start);
 - a timed download from the server at the playhead's share of the file,
   counted and thrown away, as Mbit/s against the file's average bitrate.

 No pixels are read or decoded, and nothing personal is reported: no title,
 URL, host or credential, only sizes, rates, codes and box names.
 */

import AVFoundation
import DebugTrace
import Foundation

@MainActor
enum VideoStreamProbe {
    struct Reply: Encodable {
        var available: Bool
        var note: String?
        var player: Player?
        var accessLog: [AccessEvent] = []
        var errorLog: [ErrorEvent] = []
        var file: File?
        var download: Download?
    }

    struct Player: Encodable {
        var status: String
        var timeControl: String
        var waitingReason: String?
        var playhead: Double?
        var duration: Double?
        var bufferedAhead: Double?
        var likelyToKeepUp: Bool
        var bufferEmpty: Bool
        var loopback: Bool
    }

    struct AccessEvent: Encodable {
        var playbackType: String?
        var stalls: Int
        var observedMbps: Double
        var indicatedMbps: Double
        var averageVideoMbps: Double
        var bytesTransferred: Int64
        var transferSeconds: Double
        var mediaRequests: Int
        var startupSeconds: Double
        var watchedSeconds: Double
        var downloadOverdue: Int
    }

    struct ErrorEvent: Encodable {
        var statusCode: Int
        var domain: String
        var comment: String?
    }

    struct File: Encodable {
        var httpStatus: Int?
        var contentType: String?
        var acceptsRanges: Bool
        var totalBytes: Int64?
        var averageMbps: Double?
        var firstByteMilliseconds: Double?
        /// Top-level boxes in file order: name, offset, size.
        var boxes: [Box]
        var indexAfterMedia: Bool?
    }

    struct Box: Encodable {
        var type: String
        var offset: Int64
        var size: Int64
    }

    struct Download: Encodable {
        var fromOffset: Int64
        var bytes: Int64
        var seconds: Double
        var mbps: Double
        var firstByteMilliseconds: Double?
        var httpStatus: Int?
        var error: String?
    }

    static func register() {
        DebugSurface.shared.register([
            .command("videoStreamProbe", "Why a remote video stalls: the first video window's player state, "
                     + "AVFoundation's access log (measured bitrate, stalls, bytes) and error codes, the file's "
                     + "top-level container boxes (is the index after the media?), and a timed download from the "
                     + "server at the playhead (counted and discarded) in Mbit/s against the file's average "
                     + "bitrate. No pixels, titles, URLs or credentials.",
                     parameters: [.number("seconds", "Download test length (default 8; 0 skips it)", range: 0 ... 30)]) { args in
                await probe(seconds: args.double("seconds") ?? 8)
            },
        ])
    }

    static func probe(seconds: Double) async -> Reply {
        guard let model = VideoWindowModel.withNativePlayers.allObjects.first(where: { $0.audioPlayer?.currentItem != nil }),
              let player = model.audioPlayer, let item = player.currentItem else {
            return Reply(available: false, note: "No video window has a player")
        }
        var reply = Reply(available: true)
        reply.player = playerState(player, item)
        reply.accessLog = (item.accessLog()?.events ?? []).suffix(6).map { event in
            AccessEvent(playbackType: event.playbackType, stalls: event.numberOfStalls,
                        observedMbps: event.observedBitrate / 1e6, indicatedMbps: event.indicatedBitrate / 1e6,
                        averageVideoMbps: event.averageVideoBitrate / 1e6,
                        bytesTransferred: event.numberOfBytesTransferred, transferSeconds: event.transferDuration,
                        mediaRequests: event.numberOfMediaRequests, startupSeconds: event.startupTime,
                        watchedSeconds: event.durationWatched, downloadOverdue: event.downloadOverdue)
        }
        reply.errorLog = (item.errorLog()?.events ?? []).suffix(10).map {
            ErrorEvent(statusCode: $0.errorStatusCode, domain: $0.errorDomain, comment: nil)
        }
        guard let url = (item.asset as? AVURLAsset)?.url, !url.isFileURL else {
            reply.note = "The player reads a local file"
            return reply
        }
        guard url.host != "127.0.0.1" else {
            reply.note = "The player reads a loopback stream (a device remux or composed master); the file probe needs the server's URL"
            return reply
        }
        let headers = MediaAuthorization.shared.headerFields(for: url)
        let target = MediaAuthorization.shared.authorizedURL(url)
        if url.pathExtension.lowercased() == "m3u8" {
            reply.note = "HLS: the access log is the measure; the file probe reads single files only"
            return reply
        }
        let file = await fileLayout(target, headers: headers)
        reply.file = file
        let duration = item.duration.seconds
        if let total = file.totalBytes, duration.isFinite, duration > 0 {
            reply.file?.averageMbps = Double(total) * 8 / duration / 1e6
        }
        if seconds > 0 {
            let playhead = player.currentTime().seconds
            var offset: Int64 = 0
            if let total = file.totalBytes, duration.isFinite, duration > 0, playhead.isFinite {
                offset = Int64(Double(total) * min(max(playhead / duration, 0), 0.98))
            }
            reply.download = await timedDownload(target, headers: headers, from: offset, seconds: seconds)
        }
        return reply
    }

    private static func playerState(_ player: AVPlayer, _ item: AVPlayerItem) -> Player {
        let playhead = player.currentTime().seconds
        let ahead = item.loadedTimeRanges.map(\.timeRangeValue)
            .first { $0.start.seconds <= playhead + 0.5 && $0.end.seconds >= playhead }
            .map { $0.end.seconds - playhead }
        let control = switch player.timeControlStatus {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown"
        }
        return Player(status: ["unknown", "readyToPlay", "failed"][item.status.rawValue], timeControl: control,
                      waitingReason: player.reasonForWaitingToPlay?.rawValue,
                      playhead: playhead.isFinite ? playhead : nil,
                      duration: item.duration.seconds.isFinite ? item.duration.seconds : nil,
                      bufferedAhead: ahead, likelyToKeepUp: item.isPlaybackLikelyToKeepUp,
                      bufferEmpty: item.isPlaybackBufferEmpty,
                      loopback: (item.asset as? AVURLAsset)?.url.host == "127.0.0.1")
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static func request(_ url: URL, headers: [String: String], range: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
        return request
    }

    /// Walks the top-level boxes with a 16-byte ranged read each (at most 12).
    private static func fileLayout(_ url: URL, headers: [String: String]) async -> File {
        var file = File(acceptsRanges: false, boxes: [])
        var offset: Int64 = 0
        for index in 0 ..< 12 {
            let started = Date()
            guard let (data, response) = try? await session.data(for: request(url, headers: headers,
                                                                               range: "\(offset)-\(offset + 15)")),
                  let http = response as? HTTPURLResponse else { break }
            if index == 0 {
                file.httpStatus = http.statusCode
                file.firstByteMilliseconds = Date().timeIntervalSince(started) * 1000
                file.contentType = http.value(forHTTPHeaderField: "Content-Type")
                file.acceptsRanges = http.statusCode == 206
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                    file.totalBytes = total
                }
            }
            guard http.statusCode == 206, data.count >= 8 else { break }
            let bytes = [UInt8](data)
            var size = Int64(bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            guard type.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }) else { break }
            if size == 1, bytes.count >= 16 {
                size = Int64(bitPattern: bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            } else if size == 0, let total = file.totalBytes {
                size = total - offset
            }
            file.boxes.append(Box(type: type, offset: offset, size: size))
            guard size >= 8 else { break }
            offset += size
            if let total = file.totalBytes, offset >= total { break }
        }
        let types = file.boxes.map(\.type)
        if let moov = types.firstIndex(of: "moov"), let mdat = types.firstIndex(of: "mdat") {
            file.indexAfterMedia = moov > mdat
        }
        return file
    }

    /// Downloads from `offset` for `seconds`, counting bytes as they arrive.
    private static func timedDownload(_ url: URL, headers: [String: String], from offset: Int64,
                                      seconds: Double) async -> Download {
        let counter = ByteCounter(limit: seconds)
        let session = URLSession(configuration: .ephemeral, delegate: counter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let outcome = await counter.run(session.dataTask(with: request(url, headers: headers, range: "\(offset)-")))
        return Download(fromOffset: offset, bytes: outcome.bytes, seconds: outcome.seconds,
                        mbps: outcome.seconds > 0 ? Double(outcome.bytes) * 8 / outcome.seconds / 1e6 : 0,
                        firstByteMilliseconds: outcome.firstByte.map { $0 * 1000 }, httpStatus: outcome.status,
                        error: outcome.error)
    }
}

/// Counts a data task's bytes until a time limit, then cancels it.
private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        var bytes: Int64 = 0
        var seconds: Double = 0
        var firstByte: Double?
        var status: Int?
        var error: String?
    }

    private let limit: Double
    private let lock = NSLock()
    private var outcome = Outcome()
    private var started = Date()
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(limit: Double) { self.limit = limit }

    func run(_ task: URLSessionDataTask) async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation; started = Date() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            outcome.status = (response as? HTTPURLResponse)?.statusCode
            outcome.firstByte = Date().timeIntervalSince(started)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let done = lock.withLock { () -> Bool in
            outcome.bytes += Int64(data.count)
            return Date().timeIntervalSince(started) >= limit
        }
        if done { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finished = lock.withLock { () -> (CheckedContinuation<Outcome, Never>?, Outcome) in
            outcome.seconds = Date().timeIntervalSince(started)
            if let error, (error as NSError).code != NSURLErrorCancelled { outcome.error = error.logCode }
            defer { continuation = nil }
            return (continuation, outcome)
        }
        finished.0?.resume(returning: finished.1)
    }
}

// MARK: - The file's index

/*
 `videoStreamIndex`: the remote MP4's moov, read with ranged reads and
 summarised (tracks, timing runs, sizes, sync samples, chunk offsets against
 the media box, samples around the playhead). Structure only.
 */
@MainActor
enum VideoStreamIndex {
    struct Reply: Encodable {
        var available: Bool
        var note: String?
        var fileBytes: Int64?
        var topLevel: [String] = []
        var mdatRange: [Int64]?
        var movieTimescale: UInt32?
        var movieDuration: Double?
        var playhead: Double?
        var tracks: [Track] = []
    }

    struct Track: Encodable {
        var id: UInt32?
        var handler: String?
        var format: String?
        var timescale: UInt32?
        var duration: Double?
        var edits: [[Double]] = []          // [segment seconds, media time seconds (-1 empty), rate]
        var sttsEntries: Int = 0
        var sttsRuns: [[Int64]] = []        // first 12 runs: [count, delta]
        var sttsLongRuns: [[Int64]] = []    // runs whose delta is over 4x the first one
        var samples: Int = 0
        var sampleSeconds: Double = 0
        var cttsEntries: Int = 0
        var syncSamples: Int?
        var firstSyncSamples: [UInt32] = []
        var sizeUniform: UInt32?
        var sizeMax: UInt32 = 0
        var sizeTotal: Int64 = 0
        var zeroSizeSamples: Int = 0
        var stscEntries: Int = 0
        var chunks: Int = 0
        var firstChunkOffset: Int64?
        var lastChunkOffset: Int64?
        var dataEnd: Int64?
        var chunksOutsideMdat: Int = 0
        var chunkOffsetsDecreasing: Int = 0
        /// Samples around the playhead: [index, decode seconds, size, sync 1/0, chunk offset or -1].
        var aroundPlayhead: [[Double]] = []
    }

    static func register() {
        DebugSurface.shared.register([
            .command("videoStreamIndex", "The first video window's remote MP4 index (moov): per track the "
                     + "handler, codec, timescale, edit list, sample timing runs, sizes, sync samples and chunk "
                     + "offsets against the media box, and the samples around the playhead. Structure only: no "
                     + "sample data, pixels, titles, URLs or credentials.") { _ in
                await probe()
            },
        ])
    }

    static func probe() async -> Reply {
        guard let model = VideoWindowModel.withNativePlayers.allObjects.first(where: { $0.audioPlayer?.currentItem != nil }),
              let player = model.audioPlayer, let item = player.currentItem,
              let url = (item.asset as? AVURLAsset)?.url, !url.isFileURL, url.host != "127.0.0.1" else {
            return Reply(available: false, note: "No video window plays a remote file")
        }
        var reply = Reply(available: true)
        let playhead = player.currentTime().seconds
        reply.playhead = playhead.isFinite ? playhead : nil
        let headers = MediaAuthorization.shared.headerFields(for: url)
        let target = MediaAuthorization.shared.authorizedURL(url)

        // Top-level boxes.
        var offset: Int64 = 0
        var moov: (Int64, Int64)?
        for _ in 0 ..< 16 {
            guard let (data, total) = await read(target, headers: headers, offset: offset, length: 16),
                  data.count >= 8 else { break }
            if let total { reply.fileBytes = total }
            let b = [UInt8](data)
            var size = Int64(be32(b, 0))
            let type = String(decoding: b[4..<8], as: UTF8.self)
            if size == 1, b.count >= 16 { size = Int64(bitPattern: be64(b, 8)) }
            if size == 0, let total = reply.fileBytes { size = total - offset }
            guard size >= 8 else { break }
            reply.topLevel.append("\(type)@\(offset)+\(size)")
            if type == "moov" { moov = (offset, size) }
            if type == "mdat" { reply.mdatRange = [offset, offset + size] }
            offset += size
            if let total = reply.fileBytes, offset >= total { break }
        }
        guard let moov, moov.1 < 64 << 20,
              let (data, _) = await read(target, headers: headers, offset: moov.0, length: moov.1) else {
            reply.note = "No moov box found, or it is too large to read"
            return reply
        }
        let bytes = [UInt8](data)
        parse(bytes, from: 8, to: bytes.count, into: &reply, track: nil, playhead: playhead)
        return reply
    }

    // MARK: Parsing

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf"]

    /// Raw tables of the track being parsed, finished into a summary at its end.
    private final class Tables {
        var track = Track()
        var stts: [(UInt32, UInt32)] = []
        var stss: [UInt32] = []
        var sizes: [UInt32] = []
        var stsc: [(UInt32, UInt32)] = []   // first chunk, samples per chunk
        var chunkOffsets: [Int64] = []
    }

    private static func parse(_ b: [UInt8], from start: Int, to end: Int, into reply: inout Reply,
                              track: Tables?, playhead: Double) {
        var at = start
        while at + 8 <= end {
            var size = Int(be32(b, at))
            let type = String(decoding: b[(at + 4)..<(at + 8)], as: UTF8.self)
            var header = 8
            if size == 1, at + 16 <= end { size = Int(be64(b, at + 8)); header = 16 }
            if size == 0 { size = end - at }
            guard size >= header, at + size <= end else { break }
            let body = at + header
            let boxEnd = at + size
            if type == "trak" {
                let tables = Tables()
                parse(b, from: body, to: boxEnd, into: &reply, track: tables, playhead: playhead)
                reply.tracks.append(finish(tables, mdat: reply.mdatRange, playhead: playhead))
            } else if containers.contains(type) {
                parse(b, from: body, to: boxEnd, into: &reply, track: track, playhead: playhead)
            } else if type == "stsd", let track, body + 16 <= boxEnd {
                track.track.format = String(decoding: b[(body + 12)..<(body + 16)], as: UTF8.self)
            } else {
                leaf(type, b, body, boxEnd, reply: &reply, tables: track)
            }
            at = boxEnd
        }
    }

    private static func leaf(_ type: String, _ b: [UInt8], _ body: Int, _ end: Int, reply: inout Reply, tables: Tables?) {
        guard body + 4 <= end else { return }
        let version = b[body]
        let p = body + 4
        switch type {
        case "mvhd":
            let ts = version == 1 ? be32(b, p + 16) : be32(b, p + 8)
            let dur = version == 1 ? Double(be64(b, p + 20)) : Double(be32(b, p + 12))
            reply.movieTimescale = ts
            reply.movieDuration = ts > 0 ? dur / Double(ts) : nil
        case "tkhd":
            tables?.track.id = version == 1 ? be32(b, p + 16) : be32(b, p + 8)
        case "mdhd":
            let ts = version == 1 ? be32(b, p + 16) : be32(b, p + 8)
            let dur = version == 1 ? Double(be64(b, p + 20)) : Double(be32(b, p + 12))
            tables?.track.timescale = ts
            tables?.track.duration = ts > 0 ? dur / Double(ts) : nil
        case "hdlr":
            if p + 8 <= end { tables?.track.handler = String(decoding: b[(p + 4)..<(p + 8)], as: UTF8.self) }
        case "elst":
            let count = Int(be32(b, p))
            var q = p + 4
            let movieScale = Double(reply.movieTimescale ?? 1)
            let mediaScale = Double(tables?.track.timescale ?? 1)
            for _ in 0 ..< min(count, 8) {
                let segment = version == 1 ? Double(be64(b, q)) : Double(be32(b, q))
                let media = version == 1 ? Int64(bitPattern: be64(b, q + 8)) : Int64(Int32(bitPattern: be32(b, q + 4)))
                let rateOffset = version == 1 ? q + 16 : q + 8
                let rate = Double(Int16(bitPattern: UInt16(b[rateOffset]) << 8 | UInt16(b[rateOffset + 1])))
                tables?.track.edits.append([segment / movieScale, media < 0 ? -1 : Double(media) / mediaScale, rate])
                q += version == 1 ? 20 : 12
            }
        case "stts":
            let count = Int(be32(b, p))
            tables?.stts = (0 ..< count).compactMap { i in
                let q = p + 4 + i * 8
                return q + 8 <= end ? (be32(b, q), be32(b, q + 4)) : nil
            }
        case "ctts":
            tables?.track.cttsEntries = Int(be32(b, p))
        case "stss":
            let count = Int(be32(b, p))
            tables?.stss = (0 ..< count).compactMap { i in p + 4 + i * 4 + 4 <= end ? be32(b, p + 4 + i * 4) : nil }
        case "stsz":
            let uniform = be32(b, p)
            let count = Int(be32(b, p + 4))
            if uniform != 0 {
                tables?.track.sizeUniform = uniform
                tables?.sizes = Array(repeating: uniform, count: count)
            } else {
                tables?.sizes = (0 ..< count).compactMap { i in p + 8 + i * 4 + 4 <= end ? be32(b, p + 8 + i * 4) : nil }
            }
        case "stsc":
            let count = Int(be32(b, p))
            tables?.stsc = (0 ..< count).compactMap { i in
                let q = p + 4 + i * 12
                return q + 12 <= end ? (be32(b, q), be32(b, q + 4)) : nil
            }
        case "stco":
            let count = Int(be32(b, p))
            tables?.chunkOffsets = (0 ..< count).compactMap { i in p + 4 + i * 4 + 4 <= end ? Int64(be32(b, p + 4 + i * 4)) : nil }
        case "co64":
            let count = Int(be32(b, p))
            tables?.chunkOffsets = (0 ..< count).compactMap { i in
                p + 4 + i * 8 + 8 <= end ? Int64(bitPattern: be64(b, p + 4 + i * 8)) : nil
            }
        default:
            break
        }
    }

    private static func finish(_ t: Tables, mdat: [Int64]?, playhead: Double) -> Track {
        var track = t.track
        let scale = Double(track.timescale ?? 1)
        track.sttsEntries = t.stts.count
        track.sttsRuns = t.stts.prefix(12).map { [Int64($0.0), Int64($0.1)] }
        if let first = t.stts.first?.1, first > 0 {
            track.sttsLongRuns = t.stts.filter { $0.1 > first * 4 }.prefix(12).map { [Int64($0.0), Int64($0.1)] }
        }
        track.samples = t.sizes.count
        track.sampleSeconds = t.stts.reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / scale
        track.syncSamples = t.stss.isEmpty ? nil : t.stss.count
        track.firstSyncSamples = Array(t.stss.prefix(12))
        track.sizeMax = t.sizes.max() ?? 0
        track.sizeTotal = t.sizes.reduce(0) { $0 + Int64($1) }
        track.zeroSizeSamples = t.sizes.filter { $0 == 0 }.count
        track.stscEntries = t.stsc.count
        track.chunks = t.chunkOffsets.count
        track.firstChunkOffset = t.chunkOffsets.first
        track.lastChunkOffset = t.chunkOffsets.last
        track.chunkOffsetsDecreasing = zip(t.chunkOffsets, t.chunkOffsets.dropFirst()).filter { $0.1 < $0.0 }.count

        // Each sample's chunk and offset, from stsc + stco + stsz.
        var sampleOffsets: [Int64] = Array(repeating: -1, count: t.sizes.count)
        var sample = 0
        for (chunkIndex, chunkOffset) in t.chunkOffsets.enumerated() {
            let chunkNumber = UInt32(chunkIndex + 1)
            let perChunk = t.stsc.last(where: { $0.0 <= chunkNumber })?.1 ?? 0
            var within = chunkOffset
            for _ in 0 ..< Int(perChunk) where sample < t.sizes.count {
                sampleOffsets[sample] = within
                within += Int64(t.sizes[sample])
                sample += 1
            }
            if let mdat, chunkOffset < mdat[0] || chunkOffset >= mdat[1] { track.chunksOutsideMdat += 1 }
        }
        if let lastIndex = sampleOffsets.lastIndex(where: { $0 >= 0 }) {
            track.dataEnd = sampleOffsets[lastIndex] + Int64(t.sizes[lastIndex])
        }

        // Decode times, and the samples around the playhead.
        var times: [Double] = []
        times.reserveCapacity(t.sizes.count)
        var clock: Int64 = 0
        for (count, delta) in t.stts {
            for _ in 0 ..< Int(count) { times.append(Double(clock) / scale); clock += Int64(delta) }
        }
        if playhead.isFinite, !times.isEmpty {
            let mediaPlayhead = playhead + max(0, track.edits.first(where: { $0[1] >= 0 })?[1] ?? 0)
            let index = times.lastIndex(where: { $0 <= mediaPlayhead }) ?? 0
            let sync = Set(t.stss)
            for i in max(0, index - 4) ... min(times.count - 1, index + 8) where i < t.sizes.count {
                track.aroundPlayhead.append([Double(i), times[i], Double(t.sizes[i]),
                                             t.stss.isEmpty || sync.contains(UInt32(i + 1)) ? 1 : 0,
                                             Double(sampleOffsets[i])])
            }
        }
        return track
    }

    // MARK: Reading

    private static func read(_ url: URL, headers: [String: String], offset: Int64, length: Int64) async -> (Data, Int64?)? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 206 else { return nil }
        let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
        return (data, total)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
    }
}

