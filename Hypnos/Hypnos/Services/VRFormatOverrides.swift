/*
 Hypnos - VR formats chosen by hand

 What the 3D sheet's VR section set for a video, over what its tags and
 name said (`VRFormatDetector`). Kept in a JSON file in Application Support,
 written off the main actor: a `HypnosDefaults` write makes every
 `@AppStorage` view update, a stall the playing video would show (see
 CLAUDE.md). Keyed by `GalleryVideo.identity`, like the depth cache and the
 3D settings tracker.
 */

import DebugTrace
import Foundation
import Synchronization
import VergenceApple

final class VRFormatOverrides: Sendable {
    static let shared = VRFormatOverrides()

    private let formats: Mutex<[String: VRFormat]>
    private let file: URL?
    private let writes = DispatchQueue(label: "com.illixion.hypnos.vr-overrides", qos: .utility)

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        file = directory?.appendingPathComponent("VRFormatOverrides.json")
        let stored = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: VRFormat].self, from: $0) } ?? [:]
        formats = Mutex(stored)
    }

    func format(for identity: String) -> VRFormat? {
        formats.withLock { $0[identity] }
    }

    func set(_ format: VRFormat?, for identity: String) {
        let snapshot: [String: VRFormat]? = formats.withLock { formats in
            guard formats[identity] != format else { return nil }
            formats[identity] = format
            return formats
        }
        guard let snapshot, let file else { return }
        writes.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            } catch {
                AppLogger.videoWindow.warning("VR format overrides not saved: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }
}
