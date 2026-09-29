import DebugTrace
import Foundation

/// Centralized logging facility for Hypnos.
///
/// Every category is a DebugTrace `DebugLogger`: the same API as `os.Logger`,
/// but each line also lands in DebugTrace's in-memory ring, which the in-app
/// console tails and debug traces export. `.debug` lines are captured there
/// directly, so there is no need to promote them while a console is open.
///
/// **Privacy.** These lines are read by cloud models through the debug server
/// and end up in support traces. The default is os_log's: numbers and bools
/// are public, everything else is private (shown on this device's own console
/// in development builds, `<private>` in every export). Mark `.public` only
/// for values the app itself defines — states, counts, sizes, error codes, ids
/// it generated. Use `.private(mask: .hash)` for server or library ids that are
/// useful to match across lines, and `.sensitive` for credentials.
///
/// ```
/// AppLogger.remoteViewer.debug("post \(post._id, privacy: .private(mask: .hash)) state=\(state, privacy: .public)")
/// ```
enum AppLogger {
    /// App bundle identifier used as the logging subsystem
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.hypnos"

    // MARK: - Logger Categories

    /// AppModel state and navigation logging
    static let appModel = DebugLogger(subsystem: subsystem, category: "AppModel")

    /// Stash GraphQL API client logging
    static let stashAPI = DebugLogger(subsystem: subsystem, category: "StashAPI")

    /// Disk image cache operations
    static let diskCache = DebugLogger(subsystem: subsystem, category: "DiskCache")

    /// Disk video cache operations
    static let videoCache = DebugLogger(subsystem: subsystem, category: "VideoCache")

    /// Image enhancement tracking (3D conversion, background removal)
    static let enhancementTracker = DebugLogger(subsystem: subsystem, category: "EnhancementTracker")

    /// Photo-library index: build, incremental sync, filename backfill.
    static let photosIndex = DebugLogger(subsystem: subsystem, category: "PhotosIndex")

    /// Photo window model (per-window image state)
    static let photoWindow = DebugLogger(subsystem: subsystem, category: "PhotoWindow")

    /// Local media source scanning
    static let localMedia = DebugLogger(subsystem: subsystem, category: "LocalMedia")

    /// GraphQL image source
    static let graphQLImage = DebugLogger(subsystem: subsystem, category: "GraphQLImageSource")

    /// GraphQL video source
    static let graphQLVideo = DebugLogger(subsystem: subsystem, category: "GraphQLVideoSource")

    /// Stereoscopic video player
    static let stereoscopicPlayer = DebugLogger(subsystem: subsystem, category: "StereoscopicPlayer")

    /// Image loader and caching
    static let imageLoader = DebugLogger(subsystem: subsystem, category: "ImageLoader")

    /// UI/View layer logging
    static let views = DebugLogger(subsystem: subsystem, category: "Views")

    /// Settings operations
    static let settings = DebugLogger(subsystem: subsystem, category: "Settings")

    /// Immersive video view
    static let immersiveVideo = DebugLogger(subsystem: subsystem, category: "ImmersiveVideo")

    /// General app lifecycle
    static let app = DebugLogger(subsystem: subsystem, category: "App")

    /// Shared media handling (share sheet, caching, saving)
    static let sharedMedia = DebugLogger(subsystem: subsystem, category: "SharedMedia")

    /// Window state persistence and restoration
    static let windowState = DebugLogger(subsystem: subsystem, category: "WindowState")

    /// Background removal processing
    static let backgroundRemover = DebugLogger(subsystem: subsystem, category: "BackgroundRemover")

    /// GIF to HEVC conversion and caching
    static let gifConverter = DebugLogger(subsystem: subsystem, category: "GIFConverter")

    /// Video window model (per-window video state)
    static let videoWindow = DebugLogger(subsystem: subsystem, category: "VideoWindow")

    /// Window visibility heartbeat diagnostics
    static let visibilityProbe = DebugLogger(subsystem: subsystem, category: "VisibilityProbe")

    /// Visual adjustments (brightness, contrast, saturation)
    static let visualAdjustments = DebugLogger(subsystem: subsystem, category: "VisualAdjustments")

    /// Remote API viewer (slideshow, WebSocket, API)
    static let remoteViewer = DebugLogger(subsystem: subsystem, category: "RemoteViewer")

    /// Streamable-URL handoff (custom scheme, URL classification)
    static let streamURL = DebugLogger(subsystem: subsystem, category: "StreamURL")

    /// Atmos object-audio spike (Settings → Developer)
    static let filmPlayer = DebugLogger(subsystem: subsystem, category: "FilmPlayer")

    /// Library feature: home/detail browsing, playback routing, progress sync
    static let library = DebugLogger(subsystem: subsystem, category: "Library")

    /// Per-video 3D conversion settings persistence
    static let video3DSettings = DebugLogger(subsystem: subsystem, category: "Video3DSettings")

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

    /// URL string with sensitive query values (Stash's `apikey`, Jellyfin's
    /// `api_key`, web-yt-dlp's `token`) replaced with a placeholder. Still log
    /// it at the default (private) level: the host and path are the user's.
    /// This keeps the credential off the in-app console too, where private
    /// values are shown in development builds.
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

extension Error {
    /// The bridged `NSError` domain and code, e.g. `NSURLErrorDomain -1001`.
    /// Code-defined, so safe to log `.public` next to a `localizedDescription`
    /// that stays private (it often embeds URLs and file paths).
    var logCode: String {
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}
