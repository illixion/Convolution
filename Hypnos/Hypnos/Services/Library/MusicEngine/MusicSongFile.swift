/*
 Hypnos - one song's bytes for the music engine.

 The engine plays from a file on the device, not from AVPlayer's stream: a song is fetched once, from
 the start, into `Caches/MusicPlayback/`, and the decoders read that file while it grows. That is what
 lets the next song be decoded before the playing one ends (the gapless join and the crossfade need
 its first frames in hand), lets a seek re-read what has already arrived without the network, and gives
 the seam detector (`MusicSeams`) the song's first and last moments to listen to.

 What is fetched (`MusicSongFile.Source`): the original file when it is a container AudioToolbox's
 stream parser reads (FLAC, MP3, MPEG-4 AAC/ALAC, WAV, AIFF, CAF, ADTS), otherwise a FLAC the server
 transcodes, which is lossless and parses with exact frame counts (Ogg, Opus, WMA, APE...). A dropped
 connection resumes the original with an HTTP range; a transcode starts over.

 The files are a playback buffer, not a cache: `MusicSongFiles.keep(_:)` drops every file the session
 no longer needs, and the folder is emptied at launch.
 */

import AudioToolbox
import Foundation
import os

nonisolated final class MusicSongFile: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Source: Equatable {
        /// The file as the server holds it.
        case original
        /// A FLAC the server makes from it.
        case flacTranscode
    }

    struct Progress: Sendable {
        var received: Int64 = 0
        var expected: Int64?
        var complete = false
        var failure: String?
    }

    let itemID: String
    let source: Source
    let fileURL: URL
    /// The parser's hint for this file's container.
    let typeHint: AudioFileTypeID
    private let remoteURL: URL
    private let state = OSAllocatedUnfairLock(initialState: Progress())
    private var writer: FileHandle?
    private var session: URLSession?
    private var attempts = 0
    private var cancelled = false
    /// A retried HTTP status cancelled its own task; that task's completion must not count as a second failure.
    private var retryingStatus = false

    init(itemID: String, source: Source, remoteURL: URL, typeHint: AudioFileTypeID, directory: URL) {
        self.itemID = itemID
        self.source = source
        self.remoteURL = remoteURL
        self.typeHint = typeHint
        let name = (itemID + (source == .original ? "" : "-flac")).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        fileURL = directory.appendingPathComponent(name)
        super.init()
    }

    var progress: Progress { state.withLock { $0 } }

    func start() {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        writer = try? FileHandle(forWritingTo: fileURL)
        guard writer != nil else { fail("The song couldn't be stored on the device."); return }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        request(from: 0)
    }

    private func request(from offset: Int64) {
        var request = URLRequest(url: remoteURL)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        session?.dataTask(with: request).resume()
    }

    /// Stops the transfer and deletes the file.
    func cancel() {
        state.withLock { $0.failure = $0.complete ? nil : "cancelled" }
        session?.delegateQueue.addOperation { [self] in
            cancelled = true
            try? writer?.close()
            writer = nil
        }
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Up to `count` bytes from `offset`, of what has arrived. Empty when nothing new is there yet.
    func read(at offset: Int64, count: Int, using handle: inout FileHandle?) -> Data {
        let received = state.withLock { $0.received }
        guard offset < received else { return Data() }
        if handle == nil { handle = try? FileHandle(forReadingFrom: fileURL) }
        guard let handle else { return Data() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: min(count, Int(received - offset))) ?? Data()
        } catch { return Data() }
    }

    private func fail(_ message: String) {
        state.withLock { if !$0.complete { $0.failure = message } }
    }

    // MARK: - URLSessionDataDelegate (on the session's serial queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // A file URL (the engine's checks) has no status to read.
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        let received = state.withLock { $0.received }
        switch http.statusCode {
        case 200:
            // A fresh body: the server ignored the range (or this is the first request).
            if received > 0 {
                try? writer?.truncate(atOffset: 0)
                state.withLock { $0.received = 0 }
            }
            if http.expectedContentLength > 0 { state.withLock { $0.expected = http.expectedContentLength } }
            completionHandler(.allow)
        case 206:
            if state.withLock({ $0.expected == nil }), http.expectedContentLength > 0 {
                state.withLock { $0.expected = received + http.expectedContentLength }
            }
            completionHandler(.allow)
        case _ where attempts < 3 && (http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode)):
            // The server tripped over itself (Jellyfin's transcode-folder lock race answers a stream request
            // with a 500 when songs are skipped quickly) and the next try goes through: try again, don't give up.
            attempts += 1
            retryingStatus = true
            completionHandler(.cancel)
            scheduleRetry(from: source == .original ? received : 0, after: 0.4 * Double(attempts), on: session.delegateQueue)
        default:
            fail(http.statusCode == 401 || http.statusCode == 403 ? "The server refused this song." : "The server couldn't send this song (HTTP \(http.statusCode)).")
            completionHandler(.cancel)
        }
    }

    private func scheduleRetry(from resumeAt: Int64, after delay: Double, on queue: OperationQueue) {
        if resumeAt == 0 { try? writer?.truncate(atOffset: 0); state.withLock { $0.received = 0 } }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            queue.addOperation { [self] in
                guard !cancelled else { return }
                request(from: resumeAt)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled, let writer else { return }
        do {
            try writer.seekToEnd()
            try writer.write(contentsOf: data)
            state.withLock { $0.received += Int64(data.count) }
        } catch {
            fail("The song couldn't be stored on the device.")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled else { return }
        if retryingStatus { retryingStatus = false; return }
        if state.withLock({ $0.failure != nil }) { return }
        if let error {
            // A dropped connection: carry on from what arrived (the original), or start the transcode over.
            attempts += 1
            guard attempts <= 3, (error as? URLError)?.code != .cancelled else {
                fail("The song stopped downloading: \((error as? URLError)?.code.rawValue ?? -1).")
                return
            }
            let resumeAt = source == .original ? state.withLock { $0.received } : 0
            if resumeAt == 0 { try? writer?.truncate(atOffset: 0); state.withLock { $0.received = 0 } }
            scheduleRetry(from: resumeAt, after: Double(attempts), on: session.delegateQueue)
            return
        }
        try? writer?.synchronize()
        state.withLock { $0.complete = true; $0.expected = $0.received }
    }
}

/// The songs the music session has asked for, by item. Main actor: the session is the only caller.
@MainActor
final class MusicSongFiles {
    static let shared = MusicSongFiles()
    let directory: URL
    private var files: [String: MusicSongFile] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MusicPlayback", isDirectory: true)
        // Last launch's buffers are of no use: start empty.
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The file for `item`, fetching it if this is the first ask. `fallback` asks for the transcode after
    /// the original turned out unreadable.
    func file(for item: JellyfinMusicItem, base: URL, token: String, fallback: Bool = false) -> MusicSongFile {
        let source: MusicSongFile.Source = fallback || !MusicContainer.streams(item.Container) ? .flacTranscode : .original
        let key = item.Id + (source == .original ? "" : "-flac")
        if let file = files[key], file.progress.failure == nil { return file }
        let url = Self.url(for: item.Id, source: source, base: base, token: token)
        let file = MusicSongFile(itemID: item.Id, source: source, remoteURL: url,
                                 typeHint: source == .original ? MusicContainer.typeHint(item.Container) : kAudioFileFLACType,
                                 directory: directory)
        files[key]?.cancel()
        files[key] = file
        file.start()
        return file
    }

    /// Why `itemID`'s file stopped downloading, if it did (as opposed to arriving and not being readable).
    func downloadFailure(of itemID: String) -> String? {
        files.values.first { $0.itemID == itemID && $0.source == .original }?.progress.failure
    }

    /// Drops every file but those of `itemIDs`.
    func keep(_ itemIDs: Set<String>) {
        for (key, file) in files where !itemIDs.contains(file.itemID) {
            file.cancel()
            files[key] = nil
        }
    }

    nonisolated static func url(for itemID: String, source: MusicSongFile.Source, base: URL, token: String) -> URL {
        let path = source == .original ? "Audio/\(itemID)/stream" : "Audio/\(itemID)/stream.flac"
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = source == .original
            ? [URLQueryItem(name: "Static", value: "true"), URLQueryItem(name: "ApiKey", value: token)]
            : [URLQueryItem(name: "AudioCodec", value: "flac"), URLQueryItem(name: "Static", value: "false"),
               URLQueryItem(name: "ApiKey", value: token)]
        return c.url!
    }
}

/// Which of Jellyfin's containers AudioToolbox's stream parser reads, and its hint for each.
nonisolated enum MusicContainer {
    /// Jellyfin's `Container` is a comma list for MPEG-4 ("mov,mp4,m4a,3gp,3g2,mj2").
    static func names(_ container: String?) -> [String] {
        (container ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func streams(_ container: String?) -> Bool { typeHintIfKnown(container) != nil }

    static func typeHint(_ container: String?) -> AudioFileTypeID { typeHintIfKnown(container) ?? 0 }

    private static func typeHintIfKnown(_ container: String?) -> AudioFileTypeID? {
        let names = names(container)
        if names.contains("flac") { return kAudioFileFLACType }
        if names.contains("mp3") { return kAudioFileMP3Type }
        if names.contains("m4a") || names.contains("mp4") || names.contains("m4b") || names.contains("alac") { return kAudioFileM4AType }
        if names.contains("wav") { return kAudioFileWAVEType }
        if names.contains("aiff") || names.contains("aif") { return kAudioFileAIFFType }
        if names.contains("caf") { return kAudioFileCAFType }
        if names.contains("aac") { return kAudioFileAAC_ADTSType }
        return nil
    }
}
