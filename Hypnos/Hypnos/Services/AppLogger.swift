import Foundation
import RAVEConsole
import os

/// Centralized logging facility for Hypnos
/// Uses Apple's os.Logger API for structured, performant logging.
///
/// **Debug visibility note:** `os.Logger.debug(...)` entries are not
/// preserved by OSLogStore on visionOS — they live only in the in-memory
/// ring buffer, so they don't show up in the in-app debug console even
/// when the level filter is set to Debug. Call sites that want their
/// entries visible in the console should use `Logger.log(level:_:)` with
/// `effectiveDebugLevel` so the level is promoted to `.info` while a
/// console window is open and stays `.debug` otherwise.
///
/// Example:
/// ```
/// AppLogger.remoteViewer.log(level: AppLogger.effectiveDebugLevel,
///                            "post \(id, privacy: .public)")
/// ```
///
/// `OSLogMessage` is a compiler-special type that cannot be passed
/// through wrapper functions, which forces this call-site pattern rather
/// than a custom Logger subtype.
enum AppLogger {
    /// App bundle identifier used as the logging subsystem
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.hypnos"

    /// `.info` while at least one console viewer is registered, `.debug`
    /// otherwise. Cheap to read (single unfair-lock-protected Bool).
    /// Pass this to `Logger.log(level:_:)` for entries that should be
    /// visible in the in-app debug console.
    static var effectiveDebugLevel: OSLogType {
        RAVELogStore.isViewing ? .info : .debug
    }

    // MARK: - Logger Categories

    /// AppModel state and navigation logging
    static let appModel = Logger(subsystem: subsystem, category: "AppModel")

    /// Stash GraphQL API client logging
    static let stashAPI = Logger(subsystem: subsystem, category: "StashAPI")

    /// Disk image cache operations
    static let diskCache = Logger(subsystem: subsystem, category: "DiskCache")

    /// Disk video cache operations
    static let videoCache = Logger(subsystem: subsystem, category: "VideoCache")

    /// Image enhancement tracking (3D conversion, background removal)
    static let enhancementTracker = Logger(subsystem: subsystem, category: "EnhancementTracker")

    /// Photo-library index: build, incremental sync, filename backfill.
    static let photosIndex = Logger(subsystem: subsystem, category: "PhotosIndex")

    /// Photo window model (per-window image state)
    static let photoWindow = Logger(subsystem: subsystem, category: "PhotoWindow")

    /// Local media source scanning
    static let localMedia = Logger(subsystem: subsystem, category: "LocalMedia")

    /// GraphQL image source
    static let graphQLImage = Logger(subsystem: subsystem, category: "GraphQLImageSource")

    /// GraphQL video source
    static let graphQLVideo = Logger(subsystem: subsystem, category: "GraphQLVideoSource")

    /// Stereoscopic video player
    static let stereoscopicPlayer = Logger(subsystem: subsystem, category: "StereoscopicPlayer")

    /// Image loader and caching
    static let imageLoader = Logger(subsystem: subsystem, category: "ImageLoader")

    /// UI/View layer logging
    static let views = Logger(subsystem: subsystem, category: "Views")

    /// Settings operations
    static let settings = Logger(subsystem: subsystem, category: "Settings")

    /// Immersive video view
    static let immersiveVideo = Logger(subsystem: subsystem, category: "ImmersiveVideo")

    /// General app lifecycle
    static let app = Logger(subsystem: subsystem, category: "App")

    /// Shared media handling (share sheet, caching, saving)
    static let sharedMedia = Logger(subsystem: subsystem, category: "SharedMedia")

    /// Window state persistence and restoration
    static let windowState = Logger(subsystem: subsystem, category: "WindowState")

    /// Background removal processing
    static let backgroundRemover = Logger(subsystem: subsystem, category: "BackgroundRemover")

    /// GIF to HEVC conversion and caching
    static let gifConverter = Logger(subsystem: subsystem, category: "GIFConverter")

    /// Video window model (per-window video state)
    static let videoWindow = Logger(subsystem: subsystem, category: "VideoWindow")

    /// Window visibility heartbeat diagnostics
    static let visibilityProbe = Logger(subsystem: subsystem, category: "VisibilityProbe")

    /// Visual adjustments (brightness, contrast, saturation)
    static let visualAdjustments = Logger(subsystem: subsystem, category: "VisualAdjustments")

    /// Remote API viewer (slideshow, WebSocket, API)
    static let remoteViewer = Logger(subsystem: subsystem, category: "RemoteViewer")

    /// Streamable-URL handoff (custom scheme, URL classification)
    static let streamURL = Logger(subsystem: subsystem, category: "StreamURL")

    /// Atmos object-audio spike (Settings → Developer)
    static let filmPlayer = Logger(subsystem: subsystem, category: "FilmPlayer")

    /// Library feature: home/detail browsing, playback routing, progress sync
    static let library = Logger(subsystem: subsystem, category: "Library")

    // The fake-3D signposter moved to RAVEMedia (`RAVEMediaLog.signposter`)
    // with the pipeline it instruments. Its subsystem is still this app's
    // bundle id, so Instruments and the in-app console see it unchanged; only
    // the two depth log categories were renamed (VideoCache/VideoWindow →
    // DepthCache/Pseudo3D), since those names belonged to this app's window
    // and download layers rather than to depth.
}

extension URL {
    /// Same names as RAVEMedia's `redactedForLogging`.
    private static let redactedQueryNames: Set<String> = ["apikey", "api_key", "token", "access_token", "key", "password", "secret"]

    /// URL string safe to log at `privacy: .public`: sensitive query values
    /// (Stash's `apikey`, Jellyfin's `api_key`, web-yt-dlp's `token`) are
    /// replaced with a placeholder. Needed because
    /// `.private` interpolation renders as `<private>` in Console, which made
    /// media-load failures undiagnosable on device.
    var loggableDescription: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              var items = components.queryItems, !items.isEmpty else {
            return absoluteString
        }
        for index in items.indices where Self.redactedQueryNames.contains(items[index].name.lowercased()) {
            items[index].value = "REDACTED"
        }
        components.queryItems = items
        return components.url?.absoluteString ?? absoluteString
    }
}
