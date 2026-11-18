/*
 Hypnos - what each video's picture was found to be

 `VideoFormatAnalyzer` (Vergence) works out from a few decoded frames
 whether a video is 2D, packed 3D or VR, how its eyes are packed and in
 which order (`VideoFormatSampler` takes the frames). The answer is kept
 here so a video is looked at once, not every time it opens. Keyed by
 `GalleryVideo.identity` and the analyzer's version, so a better analyzer
 looks again. A JSON file in Application Support, written off the main
 actor (a `HypnosDefaults` write stalls a playing video, see CLAUDE.md).
 */

import DebugTrace
import Foundation
import Synchronization
import VergenceApple

final class VideoFormatAnalysisStore: Sendable {
    static let shared = VideoFormatAnalysisStore()

    /// Bump when the analyzer changes what it finds: older answers are
    /// looked at again.
    static let version = 1

    /// How sure an analysis must be to be used without asking.
    static let confidenceToApply = 0.7

    private let entries: Mutex<[String: VideoFormatAnalysis]>
    private let file: URL?
    private let writes = DispatchQueue(label: "com.illixion.hypnos.video-format-analysis", qos: .utility)

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        file = directory?.appendingPathComponent("VideoFormatAnalysis.json")
        let stored = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: VideoFormatAnalysis].self, from: $0) } ?? [:]
        entries = Mutex(stored)
    }

    private static func key(_ identity: String) -> String { "\(version)|\(identity)" }

    func analysis(for identity: String) -> VideoFormatAnalysis? {
        entries.withLock { $0[Self.key(identity)] }
    }

    func set(_ analysis: VideoFormatAnalysis, for identity: String) {
        let snapshot: [String: VideoFormatAnalysis]? = entries.withLock { entries in
            let key = Self.key(identity)
            guard entries[key] != analysis else { return nil }
            entries[key] = analysis
            return entries
        }
        guard let snapshot, let file else { return }
        writes.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            } catch {
                AppLogger.videoWindow.warning("Video format analysis not saved: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }
}
