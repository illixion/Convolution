/*
 Hypnos - Settings Backup

 Codable backup container for all app settings plus a lightweight FileDocument
 wrapper for SwiftUI fileExporter / fileImporter.
 */

import RAVEMedia
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backup Data Model

struct SettingsBackup: Codable {
    /// Schema version — increment when fields change semantics or type.
    let version: Int
    let exportDate: Date
    let appVersion: String

    // Simple display settings (all optional for forward/backward compatibility)
    var stashServerURL: String?

    /// **Never written by an export.** Kept decodable so a backup taken before
    /// version 2 still restores the key it contains.
    ///
    /// A backup is a plain JSON file the user saves, AirDrops and mails to
    /// themselves; a server credential riding along inside it turns every one
    /// of those into a credential leak, and the file gives no hint that it
    /// holds one. Server *addresses* still travel — they are configuration, not
    /// secrets — so a restore rebuilds everything except the password, which
    /// the user re-enters once. See `KeychainStore`.
    var stashAPIKey: String?

    /// Nextcloud's configuration, on the same terms as Stash's: the address,
    /// the account name and the chosen root travel, and the app password —
    /// the only secret of the four — does not. A restore therefore rebuilds
    /// the whole setup except the sign-in, which is one pass through Login
    /// Flow v2 (and re-signing in is the right shape anyway: an app password
    /// is issued per device).
    var nextcloudServerURL: String?
    var nextcloudUsername: String?
    var nextcloudRoot: String?

    var autoHideDelay: TimeInterval?
    var slideshowDelay: TimeInterval?
    var slideshowShowClock: Bool?
    var slideshowShowSensors: Bool?
    var slideshowUseAspectRatio: Bool?
    var slideshowEnableKenBurns: Bool?
    var slideshowEnableDynamicBrightness: Bool?
    var slideshowEnableDiorama: Bool?
    var slideshowTransparentBackground: Bool?
    var slideshowTextSize: Double?
    var slideshowMaxImageResolution2D: Int?
    var slideshowMaxImageResolution3D: Int?
    var maxImageResolution: Int?
    var spatial3DMaxResolution: Int?
    var dioramaDistance: Double?
    var roundedCorners: Bool?
    var openMediaInNewWindows: Bool?
    /// Legacy key for backward compatibility when importing old backups
    var openImagesInSeparateWindows: Bool?
    var rememberImageEnhancements: Bool?
    var autoRestoreSpatial3D: Bool?
    var fullyImmersive3DMode: Bool?
    var showDebugConsole: Bool?
    var respectMemoryAlerts: Bool?
    var enableRemoteViewer: Bool?
    var librarySource: String?

    // Complex Codable settings
    var savedViews: [SavedView]?
    var savedVideoViews: [SavedVideoView]?
    var savedWindowGroups: [SavedWindowGroup]?
    var savedRemoteConfigs: [RemoteViewerConfig]?

    // Tag lists (shared across all viewer windows)
    var tagLists: [[String]]?
    var tagListDefaultIndex: Int?
    var tagListLastActiveIndex: Int?

    // Actor-based tracker data
    var video3DSettings: [String: Video3DSettings]?
    var imageEnhancementConvertedURLs: [String]?
    var imageEnhancementLastViewingModes: [String: String]?
    var imageEnhancementFlippedURLs: [String]?
    var imageEnhancementResolutionOverrides: [String: Int]?
    var imageEnhancementSpatial3DResolutionOverrides: [String: Int]?
    var imageEnhancementWindowSizes: [String: [Double]]?

    // Visual adjustments
    var globalVisualAdjustments: Data?
    var imageEnhancementAdjustments: [String: Data]?

    // Display / playback settings added after the initial schema. All
    // optional so older backups (missing the keys) still decode, and a
    // restore leaves them untouched rather than resetting to defaults.
    var thumbnailStyle: String?
    var galleryGridStyle: String?
    var reduceMotion: Bool?
    var defaultImageViewingMode: String?
    var enableStashTranscoding: Bool?
    var realtimeDepthModelName: String?
    var preprocessDepthModelName: String?
    var defaultRealtimePseudo3D: Bool?
    var videoAutoplayMuted: Bool?
    var useLossyTextureCompression: Bool?
    var globalPseudo3DSettings: Data?
    var cacheSizePreset: String?

    /// 2: credentials are no longer exported (see `stashAPIKey`). Version 1
    /// files may contain one and are still imported as before.
    static let currentVersion = 2
}

// MARK: - FileDocument Wrapper

// `FileDocument` (and `fileExporter`/`fileImporter`, its SwiftUI presenters)
// don't exist on tvOS — there is no Files app / document picker to hand a
// backup file to. Settings → Backup is hidden from the tvOS Settings tab for
// the same reason (see Hypnos/CLAUDE.md "tvOS").
#if !os(tvOS)
struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
