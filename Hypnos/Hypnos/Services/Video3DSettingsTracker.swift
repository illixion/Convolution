/*
 Hypnos - Video 3D Settings Tracker

 Persists user-selected 3D conversion settings per video ID.
 Settings are stored in UserDefaults and automatically restored when the same video is opened.
 */

import DebugTrace
import Foundation

actor Video3DSettingsTracker {
    static let shared = Video3DSettingsTracker()

    private let userDefaultsKey = "video3DSettings"
    private var settingsByVideoId: [String: Video3DSettings]

    private init() {
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: Video3DSettings].self, from: data) {
            settingsByVideoId = decoded
            let count = settingsByVideoId.count
            AppLogger.video3DSettings.info("Loaded 3D settings for \(count, privacy: .public) videos")
        } else {
            settingsByVideoId = [:]
        }
    }

    /// Save 3D settings for a video
    func saveSettings(videoId: String, settings: Video3DSettings) {
        settingsByVideoId[videoId] = settings
        save()
        AppLogger.video3DSettings.info("Saved 3D settings for video: \(videoId, privacy: .private)")
    }

    /// Load 3D settings for a video
    func loadSettings(videoId: String) -> Video3DSettings? {
        return settingsByVideoId[videoId]
    }

    /// Check if settings exist for a video
    func hasSettings(videoId: String) -> Bool {
        return settingsByVideoId[videoId] != nil
    }

    /// Remove settings for a video
    func removeSettings(videoId: String) {
        settingsByVideoId.removeValue(forKey: videoId)
        save()
    }

    /// Clear all saved settings
    func clearAll() {
        settingsByVideoId.removeAll()
        save()
    }

    /// Get the count of videos with saved settings
    var savedCount: Int {
        settingsByVideoId.count
    }

    // MARK: - Backup Export / Import

    /// Export all settings for backup
    func exportData() -> [String: Video3DSettings] {
        return settingsByVideoId
    }

    /// Import settings from backup, replacing current data
    func importData(_ settings: [String: Video3DSettings]) {
        settingsByVideoId = settings
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settingsByVideoId) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
}
