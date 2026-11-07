import DebugTrace
import Foundation
import RAVEMedia

/// Analysis tracks for Smooth Motion on a 3D title: the fields `vergence
/// analyze` computed ahead, which let the 3D picture get in-between frames
/// for both eyes from one motion field (Vergence's `SharedFieldInterpolator`;
/// `docs/plans/blu-ray-3d-smooth-motion.md`).
///
/// Three places, in order:
/// - A file in Documents/Smooth Motion (the Files app shows it under the
///   app), named after the film as the Library shows it, or after its
///   Jellyfin item id: `Bumblebee.vgat`. Indexed whole, from a mapped file.
/// - The Jellyfin server, whose Convolution plugin analyses every 3D title
///   once (`SmoothMotionService`, a nightly task on a Mac server) and serves
///   the track in chunks, read around the playhead as the film plays
///   (Vergence's `StreamingAnalysisTrack`), once it is whole.
/// - An analysis coordinator (`AnalysisCoordinator`, `vergenced`), when one
///   is set: told where the film is playing, it has workers make the pieces
///   around the playhead first and serves chunks while they fill.
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
        if let library = await MainActor.run(body: { LibraryService.current() }),
           let server = await serverFields(library: library, id: id, startSeconds: startSeconds) {
            return server
        }
        guard let coordinator = AnalysisCoordinator.current() else { return nil }
        return await coordinatorFields(coordinator, id: id, startSeconds: startSeconds)
    }

    /// The fields for a 2D Library title (flat, or played as AI 3D): only an
    /// analysis coordinator makes them (`smooth-motion-2d`, the whole
    /// picture's flow), while it plays. Nil without a coordinator, or for a
    /// title it won't take (a 3D one). Pairs the track doesn't cover yet get
    /// the device's own interpolator.
    static func monoFields(id: String, startSeconds: Double = 0) async -> AnalysisTrackFieldProvider? {
        guard let coordinator = AnalysisCoordinator.current() else { return nil }
        return await coordinatorFields(coordinator, id: id, startSeconds: startSeconds,
                                       workload: AnalysisCoordinator.smoothMotion2D)
    }

    /// AI 3D's depth for a 2D Library title from an analysis coordinator
    /// (`ai-3d-depth`: the offline pipeline with a larger model), read as it
    /// fills; the player warps it and runs its own model only for frames it
    /// doesn't hold yet. Nil without a coordinator, or for a 3D title.
    static func depthTrack(id: String, startSeconds: Double = 0) async -> AnalysisDepthTrack? {
        guard let coordinator = AnalysisCoordinator.current(),
              let (track, status) = await coordinatorTrack(coordinator, id: id, startSeconds: startSeconds,
                                                           workload: AnalysisCoordinator.aiDepth) else { return nil }
        return AnalysisDepthTrack(lookup: track, frameRate: status.frameRate)
    }

    private static func coordinatorFields(_ coordinator: AnalysisCoordinator, id: String, startSeconds: Double,
                                          workload: String = AnalysisCoordinator.smoothMotion3D) async -> AnalysisTrackFieldProvider? {
        guard let (track, status) = await coordinatorTrack(coordinator, id: id, startSeconds: startSeconds,
                                                           workload: workload) else { return nil }
        return AnalysisTrackFieldProvider(lookup: track, frameRate: status.frameRate,
                                          needsDisparity: workload == AnalysisCoordinator.smoothMotion3D,
                                          inflate: AnalysisDeflate.inflate)
    }

    /// A title's track for `workload`, read from the coordinator in chunks
    /// around the playhead, which it is told as the track is read.
    private static func coordinatorTrack(_ coordinator: AnalysisCoordinator, id: String, startSeconds: Double,
                                         workload: String) async -> (StreamingAnalysisTrack, AnalysisCoordinator.Status)? {
        let status: AnalysisCoordinator.Status
        do {
            status = try await coordinator.playing(itemId: id, seconds: startSeconds, workload: workload)
        } catch {
            // Not a title it works on (2D for 3D work and the reverse, a disc), or the server is away.
            AppLogger.filmPlayer.info("Analysis server: no \(workload, privacy: .public) track (\(error.logCode, privacy: .public))")
            return nil
        }
        guard status.chunks > 0, status.chunkSeconds > 0 else { return nil }
        let reporter = AnalysisPlayheadReporter(coordinator: coordinator, itemId: id, workload: workload,
                                                startSeconds: startSeconds)
        let track = StreamingAnalysisTrack(chunkSeconds: status.chunkSeconds, chunkCount: status.chunks,
                                           retrySeconds: 1.5, partialRefetchSeconds: 1.5,
                                           onDemand: { reporter.note($0) }) { index in
            try await coordinator.chunk(itemId: id, index: index, workload: workload)
        }
        track.prefetch(at: startSeconds)
        AppLogger.filmPlayer.info(
            "Analysis server track (\(workload, privacy: .public)) \(status.state, privacy: .public), \(status.piecesDone, privacy: .public) of \(status.pieces, privacy: .public) pieces, \(status.chunks, privacy: .public) chunks")
        return (track, status)
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
