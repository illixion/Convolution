/*
 Hypnos - Library downloads: an object-audio film kept on the device

 The film player streams from the Atmos Objects plugin (`FilmServerClient`):
 a video index, an init segment and keyframe-interval video segments, plus
 the audio scene, per-segment events and FLAC channel groups. A download
 keeps the same responses, and `FilmPackage` answers the player's requests
 from them (`FilmOfflineStore`), so offline playback runs the same code as
 streamed: same picture path, Dolby Vision included, same object audio.

 The video is not kept as loose segments. Init + segments in order is a
 fragmented MP4, so they are appended to the download's media file in
 Documents (a real .mp4 in the Files app, video only), and `video-ranges.json`
 records where each one starts. The audio scene lives beside the ranges,
 under Application Support:

   film/video-index.json     GET Video
   film/video-ranges.json    [[offset, length]], init first, then segment n at n + 1
   film/tracks.json          GET Tracks (absent: the plugin predates track choice)
   film/scene.json           GET Scene, once the whole film is decoded
   film/audio/<n>-events.json, film/audio/<n>-<g>.flac
 */

import Foundation
import RAVEFilm

struct FilmPackage: FilmOfflineStore {
    let directory: URL
    /// The joined video, or nil for a disc (its picture is read from the image).
    let video: URL?

    init(itemId: String, video: URL?) {
        directory = Self.directory(itemId: itemId)
        self.video = video
    }

    static func directory(itemId: String) -> URL {
        LibraryOfflineStore.itemDirectory(itemId).appendingPathComponent("film", isDirectory: true)
    }

    var videoIndexURL: URL { directory.appendingPathComponent("video-index.json") }
    var videoRangesURL: URL { directory.appendingPathComponent("video-ranges.json") }
    var tracksURL: URL { directory.appendingPathComponent("tracks.json") }
    var sceneURL: URL { directory.appendingPathComponent("scene.json") }
    var audioDirectory: URL { directory.appendingPathComponent("audio", isDirectory: true) }

    func eventsURL(segment: Int) -> URL { audioDirectory.appendingPathComponent("\(segment)-events.json") }
    func groupURL(segment: Int, group: Int) -> URL { audioDirectory.appendingPathComponent("\(segment)-\(group).flac") }

    func data(path: String, query: [URLQueryItem]) async throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.first {
        case "Video":
            guard let video else { throw FilmServerError.http(path: path, status: 404) }
            if parts.count == 1 { return try read(videoIndexURL, path: path) }
            let index: Int? = if parts.count == 2, parts[1] == "Init" { 0 }
                else if parts.count == 3, parts[1] == "Segments", let n = Int(parts[2]) { n + 1 }
                else { nil }
            guard let index else { throw FilmServerError.http(path: path, status: 404) }
            return try readRange(index, of: video, path: path)
        case "Tracks":
            return try read(tracksURL, path: path)
        case "Scene":
            // The one track downloaded, whatever `audioStream` asks for.
            guard FileManager.default.fileExists(atPath: sceneURL.path) else { throw FilmServerError.http(path: path, status: 422) }
            return try read(sceneURL, path: path)
        case "Segments" where parts.count == 3:
            guard let n = Int(parts[1]) else { break }
            if parts[2] == "Events" { return try read(eventsURL(segment: n), path: path) }
            if let group = Int(parts[2]) { return try read(groupURL(segment: n, group: group), path: path) }
        default:
            break
        }
        throw FilmServerError.http(path: path, status: 404)
    }

    private func read(_ url: URL, path: String) throws -> Data {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw FilmServerError.http(path: path, status: 404)
        }
        return data
    }

    private func readRange(_ index: Int, of file: URL, path: String) throws -> Data {
        let ranges = try JSONDecoder().decode([[Int64]].self, from: read(videoRangesURL, path: path))
        guard ranges.indices.contains(index), ranges[index].count == 2 else { throw FilmServerError.http(path: path, status: 404) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(ranges[index][0]))
        guard let data = try handle.read(upToCount: Int(ranges[index][1])), data.count == Int(ranges[index][1]) else {
            throw FilmServerError.http(path: path, status: 404)
        }
        return data
    }
}
