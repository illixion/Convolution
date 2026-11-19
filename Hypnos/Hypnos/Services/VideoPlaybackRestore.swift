/*
 Hypnos - Video Playback Restore

 Where each video window was and whether it was playing, keyed by its
 window value's UUID, so a window visionOS reopens after the app restarts (an
 update, a crash) comes back at its playhead and in its play/pause state
 instead of playing from 0.

 A file, not `HypnosDefaults.store`: this changes every few seconds during
 playback, and any write to that store makes every `@AppStorage` view update
 (a main-thread stall on the Vision Pro). Updates land in memory at once and
 are written off the main actor, a couple of seconds after the last one.
 */

import Foundation

@MainActor
enum VideoPlaybackRestore {
    struct Entry: Codable, Sendable {
        var identity: String
        var seconds: Double
        var paused: Bool
        var saved: Date
    }

    private static let maxEntries = 64
    private static let flushDelay: Duration = .seconds(2)
    private nonisolated static let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VideoPlaybackRestore.json")
    /// Serial, so the newest snapshot is always the one left on disk.
    private nonisolated static let queue = DispatchQueue(label: "com.illixion.hypnos.playback-restore", qos: .utility)

    private static var entries: [String: Entry] = {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return saved
    }()
    private static var flushTask: Task<Void, Never>?

    static func entry(for windowID: UUID) -> Entry? { entries[windowID.uuidString] }

    static func record(windowID: UUID, identity: String, seconds: Double, paused: Bool) {
        guard seconds.isFinite else { return }
        entries[windowID.uuidString] = Entry(identity: identity, seconds: seconds, paused: paused, saved: Date())
        if entries.count > maxEntries {
            let oldest = entries.sorted { $0.value.saved < $1.value.saved }.prefix(entries.count - maxEntries)
            for (key, _) in oldest { entries.removeValue(forKey: key) }
        }
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(for: flushDelay)
            flushTask = nil
            let snapshot = entries
            queue.async { write(snapshot) }
        }
    }

    private nonisolated static func write(_ snapshot: [String: Entry]) {
        var url = fileURL
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
