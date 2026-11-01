import DebugTrace
import Foundation
import RAVEMedia

/// Analysis tracks for Smooth Motion on a 3D disc: the fields a Mac computed
/// ahead with `vergence analyze`, which let the 3D picture get in-between
/// frames for both eyes from one motion field (Vergence's
/// `SharedFieldInterpolator`; `docs/plans/blu-ray-3d-smooth-motion.md`).
///
/// For now a track is a file the user puts in Documents/Smooth Motion (the
/// Files app shows it under the app), named after the film as the Library
/// shows it, or after its Jellyfin item id: `Bumblebee.vgat`. A paired Mac
/// sending the same records live comes later.
enum SmoothMotionTracks {
    static var folder: URL {
        URL.documentsDirectory.appending(path: "Smooth Motion", directoryHint: .isDirectory)
    }

    /// The fields for the film called `name` with item id `id`, or nil when
    /// there is no track for it (or it can't be read). Indexing a whole
    /// film's track reads only its record headers, from a mapped file.
    static func fields(name: String, id: String) async -> AnalysisTrackFieldProvider? {
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

    /// A film name as a file name: no path separators.
    static func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
