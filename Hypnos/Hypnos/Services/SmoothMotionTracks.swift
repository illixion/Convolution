import DebugTrace
import Foundation
import RAVEMedia

/// Analysis tracks for Smooth Motion on a 3D title: the fields `vergence
/// analyze` computed ahead, which let the 3D picture get in-between frames
/// for both eyes from one motion field (Vergence's `SharedFieldInterpolator`;
/// `docs/plans/blu-ray-3d-smooth-motion.md`).
///
/// Two places, in order:
/// - A file in Documents/Smooth Motion (the Files app shows it under the
///   app), named after the film as the Library shows it, or after its
///   Jellyfin item id: `Bumblebee.vgat`. Indexed whole, from a mapped file.
/// - The Jellyfin server, whose Convolution plugin analyses every 3D title
///   once (`SmoothMotionService`, a nightly task on a Mac server) and serves
///   the track in chunks, read around the playhead as the film plays
///   (Vergence's `StreamingAnalysisTrack`).
enum SmoothMotionTracks {
    static var folder: URL {
        URL.documentsDirectory.appending(path: "Smooth Motion", directoryHint: .isDirectory)
    }

    /// The fields for the film called `name` with Jellyfin item id `id`, or
    /// nil when there is no track for it (or it can't be read).
    /// - Parameter startSeconds: where playback starts, so the server's
    ///   first chunks are fetched before the player asks.
    static func fields(name: String, id: String, startSeconds: Double = 0) async -> AnalysisTrackFieldProvider? {
        if let local = await localFields(name: name, id: id) { return local }
        guard let library = await MainActor.run(body: { LibraryService.current() }) else { return nil }
        return await serverFields(library: library, id: id, startSeconds: startSeconds)
    }

    private static func localFields(name: String, id: String) async -> AnalysisTrackFieldProvider? {
        await Task.detached(priority: .utility) {
            for base in [id, name] {
                let file = folder.appending(path: fileName(base) + ".vgat")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let started = Date()
                do {
                    let index = try AnalysisTrackIndex(Data(contentsOf: file, options: .alwaysMapped))
                    AppLogger.filmPlayer.info(
                        "Smooth Motion track \(file.lastPathComponent, privacy: .private(mask: .hash)): \(index.entries.count, privacy: .public) records, indexed in \(Date().timeIntervalSince(started) * 1000, format: .fixed(precision: 0), privacy: .public) ms")
                    return AnalysisTrackFieldProvider(index: index, inflate: AnalysisDeflate.inflate)
                } catch {
                    AppLogger.filmPlayer.error(
                        "Smooth Motion track \(file.lastPathComponent, privacy: .private(mask: .hash)) unreadable: \(error.logCode, privacy: .public)")
                }
            }
            return nil
        }.value
    }

    private static func serverFields(library: JellyfinLibrary, id: String, startSeconds: Double) async -> AnalysisTrackFieldProvider? {
        let status: JellyfinLibrary.SmoothMotionServerTrack
        do {
            status = try await library.smoothMotionTrack(itemId: id)
        } catch {
            // An older plugin has no such route (404), or the server is away.
            AppLogger.filmPlayer.info("Smooth Motion: no server track (\(error.logCode, privacy: .public))")
            return nil
        }
        guard status.state == "ready", let chunkSeconds = status.chunkSeconds, chunkSeconds > 0,
              let chunks = status.chunks, chunks > 0 else {
            let progress = status.progress.map { String(format: " %.0f%%", $0 * 100) } ?? ""
            AppLogger.filmPlayer.info(
                "Smooth Motion: server track \(status.state, privacy: .public)\(progress, privacy: .public)\(status.reason.map { ": " + $0 } ?? "", privacy: .public)")
            return nil
        }
        let track = StreamingAnalysisTrack(chunkSeconds: chunkSeconds, chunkCount: chunks) { index in
            try await library.smoothMotionChunk(itemId: id, index: index)
        }
        track.prefetch(at: startSeconds)
        AppLogger.filmPlayer.info(
            "Smooth Motion: server track, \(chunks, privacy: .public) chunks of \(chunkSeconds, format: .fixed(precision: 0), privacy: .public) s at \(status.frameRate ?? 0, format: .fixed(precision: 3), privacy: .public) fps")
        return AnalysisTrackFieldProvider(lookup: track, frameRate: status.frameRate, inflate: AnalysisDeflate.inflate)
    }

    /// A film name as a file name: no path separators.
    static func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
