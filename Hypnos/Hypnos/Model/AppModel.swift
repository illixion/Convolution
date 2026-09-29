/*
 Hypnos - App Model

 The main model containing observable data used across the views.
 Includes navigation state, gallery management, and spatial image handling.
 */

import NextcloudMedia
import Photos
import RAVEMedia
import os
import RAVEUI
import RealityKit
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

enum Spatial3DImageState {
    case notGenerated
    case generating
    case generated
}

enum BackgroundRemovalState {
    case original
    case removing
    case removed
}

@MainActor
@Observable
class AppModel {
    // MARK: - Server Configuration (with UserDefaults persistence)

    var stashServerURL: String {
        didSet {
            if stashServerURL != oldValue {
                UserDefaults.standard.set(stashServerURL, forKey: "stashServerURL")
                // The new URL's host (if any) is (re-)registered by
                // updateAPIClient() below; a *changed or cleared* old host
                // needs its own unregister first, since updateStashMediaCredential
                // only ever touches the current host and would otherwise leave
                // a stale credential registered under an abandoned server.
                if let oldHost = URL(string: oldValue)?.host {
                    MediaAuthorization.shared.unregister(host: oldHost)
                }
                updateAPIClient()
            }
        }
    }

    var stashAPIKey: String {
        didSet {
            // Sanitize pasted keys: stray whitespace/newlines are invisible and
            // pernicious — HTTP header values get trimmed by the URL loading
            // system (so GraphQL works), but a query param is percent-encoded
            // verbatim (`%0A`), and Stash 401s a present-but-invalid apikey
            // even when guest access is allowed. Result: every URL the app
            // appends the key to (scene previews, screenshots) fails with
            // NSURLError -1013 while everything else looks healthy.
            // Assigning inside didSet does not re-trigger the observer.
            let trimmed = stashAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != stashAPIKey { stashAPIKey = trimmed }
            if stashAPIKey != oldValue {
                // Keychain, not UserDefaults: the defaults plist is an ordinary
                // readable file in the container. See KeychainStore.
                KeychainStore.set(stashAPIKey, for: .stashAPIKey)
                updateAPIClient()
            }
        }
    }

    // MARK: - Nextcloud Configuration

    /// Base URL of the Nextcloud instance, e.g. `https://cloud.example.com`.
    ///
    /// The three settings below are stored plainly; only the app password is a
    /// secret, and it lives in the Keychain. They are deliberately separate
    /// properties rather than one Codable blob so each can carry its own
    /// observer, matching how the Stash pair already works.
    var nextcloudServerURL: String {
        didSet {
            guard nextcloudServerURL != oldValue else { return }
            UserDefaults.standard.set(nextcloudServerURL, forKey: "nextcloudServerURL")
            // Same reasoning as the Stash server's observer: only the *current*
            // host is re-registered below, so an abandoned one has to be
            // dropped here or its credential outlives the server.
            if let oldHost = URL(string: oldValue)?.host {
                MediaAuthorization.shared.unregister(host: oldHost)
            }
            updateNextcloudClient()
        }
    }

    var nextcloudUsername: String {
        didSet {
            guard nextcloudUsername != oldValue else { return }
            UserDefaults.standard.set(nextcloudUsername, forKey: "nextcloudUsername")
            updateNextcloudClient()
        }
    }

    var nextcloudAppPassword: String {
        didSet {
            guard nextcloudAppPassword != oldValue else { return }
            KeychainStore.set(nextcloudAppPassword, for: .nextcloudAppPassword)
            updateNextcloudClient()
        }
    }

    /// Library root relative to the account's files, e.g. `Photos`.
    ///
    /// Not cosmetic: an unscoped search returns every image the account can
    /// see, which on a server that also holds a music library means thousands
    /// of album-art JPEGs interleaved with the photos. Chosen from a dropdown
    /// of the server's actual folders — see `NextcloudClient.folders(in:)` —
    /// because typing a path means guessing, and a wrong guess reads as an
    /// empty library rather than an error.
    var nextcloudRoot: String {
        didSet {
            guard nextcloudRoot != oldValue else { return }
            UserDefaults.standard.set(nextcloudRoot, forKey: "nextcloudRoot")
            updateNextcloudClient()
        }
    }

    /// Rebuilt whenever any of the four settings above change. Nil until the
    /// server is fully configured, which is also what `hasNextcloudServer`
    /// reports and what keeps the library out of the picker until it works.
    private(set) var nextcloudClient: NextcloudClient?

    var galleryImages: [GalleryImage] = []
    var isLoadingGallery: Bool = false
    var currentPage: Int = 0
    var hasMorePages: Bool = true
    /// Incremented on each loadInitialGallery; stale loadNextPage results are discarded
    private var galleryLoadGeneration: Int = 0

    var pageSize: Int = 30

    /// Available page size options for the picker
    static let pageSizeOptions: [Int] = [10, 20, 30, 50, 100]

    // MARK: - Video Gallery State

    var galleryVideos: [GalleryVideo] = []
    var isLoadingVideos: Bool = false
    var currentVideoPage: Int = 0

    /// The video window whose Adjustments are shown in the separate, freely
    /// repositionable "video-adjustments" window. Set when that window opens,
    /// cleared when it (or the owning video window) closes. Strong ref, so it
    /// must be cleared to avoid keeping a closed window's model alive.
    var videoAdjustmentsTarget: VideoWindowModel?
    var hasMoreVideoPages: Bool = true
    /// Incremented on each loadInitialVideos; stale loadNextVideoPage results are discarded
    private var videoLoadGeneration: Int = 0

    // MARK: - Stereoscopic Video Immersive State

    /// Whether the stereoscopic video immersive space is currently shown
    var isStereoscopicImmersiveSpaceShown: Bool = false

    /// The video currently being played in immersive mode
    var immersiveVideo: GalleryVideo?

    /// URL of the converted MV-HEVC file for immersive playback
    var immersiveVideoURL: URL?

    /// The video window that opened the current immersive session, so the
    /// immersive player can read that window's stereoscopic override. Only one
    /// immersive space exists at a time on visionOS, so a single owner suffices.
    weak var immersiveVideoOwner: VideoWindowModel?

    // MARK: - Filter State

    var currentFilter: ImageFilterCriteria = ImageFilterCriteria()
    var currentVideoFilter: SceneFilterCriteria = SceneFilterCriteria()

    /// A one-shot request to open a freshly created main window on a specific
    /// content tab (Pictures/Videos) after seeding the corresponding filter.
    /// Consumed by the new window's `ContentView` on appear, then cleared.
    var pendingGalleryFilter: PendingGalleryFilter?

    var savedViews: [SavedView] = []
    var selectedSavedView: SavedView?
    var savedVideoViews: [SavedVideoView] = []
    var selectedSavedVideoView: SavedVideoView?

    // MARK: - Autocomplete State

    var availableGalleries: [AutocompleteItem] = []
    var availableTags: [AutocompleteItem] = []
    var availableStudios: [AutocompleteItem] = []
    var availablePerformers: [AutocompleteItem] = []
    /// Stash groups, for the Videos filter's Groups section.
    var availableGroups: [MediaContainer] = []
    /// Containers for the Albums browser, for the library and media kind last
    /// asked for.
    var mediaContainers: [MediaContainer] = []
    var isLoadingMediaContainers: Bool = false

    /// In-flight pull-to-refresh, so overlapping refreshes coalesce. See
    /// `refreshGallery`.
    private var galleryRefreshTask: Task<Void, Never>?
    private var videoRefreshTask: Task<Void, Never>?

    /// Albums offered by the Photos filter. Counted for the media type last
    /// asked for, so switching between the Pictures and Videos filters reloads.
    var availablePhotoAlbums: [PhotoAlbum] = []
    /// People the index knows about. Empty until a face source exists — see
    /// `PhotosIndexSchema`; the dimension is built, the data is not yet.
    var availablePhotoPeople: [IndexedPerson] = []
    var isLoadingPhotoAlbums: Bool = false
    var isLoadingGalleries: Bool = false
    var isLoadingTags: Bool = false
    var isLoadingStudios: Bool = false
    var isLoadingPerformers: Bool = false

    // MARK: - API Client

    private(set) var apiClient: StashAPIClient

    // MARK: - Image Source (stored, always Stash server)

    private(set) var imageSource: any ImageSource

    /// Transient override consumed by the next gallery-mode remote viewer launch.
    /// Set by the photo-viewer slideshow button so the slideshow runs over the
    /// originating window's source/filter (e.g. local-folder source) instead of
    /// the app-wide Stash source. Cleared once consumed.
    var pendingGallerySlideshowSource: GallerySlideshowSourceOverride?

    /// Transient override consumed by the next video-mode remote viewer launch.
    /// Set by the video-viewer slideshow button so the slideshow runs over the
    /// originating window's video source/filter. Cleared once consumed.
    var pendingVideoSlideshowSource: VideoSlideshowSourceOverride?

    /// The photo viewer's `contentEntity` while it is on loan to the
    /// Spatial 3D ImmersiveSpace. The IPC + generated `Spatial3DImage` are
    /// reparented across scenes rather than rebuilt — one copy of the GPU
    /// resources, no second `generate()` pass. Cleared after the immersive
    /// space hands the entity back on exit.
    var immersiveLoanEntity: Entity?

    /// The PhotoWindowModel that currently owns the immersive presentation.
    /// Tracked separately from the loaned entity so the immersive view can
    /// reach back into the model on Digital Crown dismissal (where the
    /// space disappears without PhotoDisplayView noticing) and so other
    /// photo windows can refuse a second Immersive 3D entry while one is
    /// already in flight.
    weak var immersiveLoanOwner: PhotoWindowModel?

    // MARK: - Video Source (stored, always Stash server)

    private(set) var videoSource: any VideoSource

    // MARK: - Entitlements (App Store commerce seam)

    /// `NoopEntitlementProvider` (everything unlocked) outside a
    /// `HYPNOS_APPSTORE` build — see `EntitlementProviderFactory`.
    private(set) var entitlementProvider: any EntitlementProviding

    // MARK: - Selected Items for Detail View

    var selectedImage: GalleryImage?
    var selectedVideo: GalleryVideo?

    // MARK: - Scroll Position Tracking

    var lastViewedImageId: UUID?
    var lastViewedVideoId: UUID?

    // MARK: - Media Open Tap Debounce

    /// Pictures, Videos and the Local browser each have their own tap gesture
    /// and open function (see GalleryThumbnailView/PicturesTabView,
    /// VideoThumbnailView/VideoGalleryView, LocalMediaThumbnailView/
    /// LocalFolderBrowserView) — there's no single shared "open media" call to
    /// gate, so this cooldown lives on AppModel and every one of those tap
    /// handlers calls it first. One check covers two failure modes at once:
    /// a double-tap on the same thumbnail spawning a second pushed window, and
    /// a second tap landing on a *different* thumbnail (e.g. gaze moved to
    /// another cell mid-gesture) before the first tap's window has actually
    /// opened. Both are just "a tap arrived while the previous one is still
    /// being handled."
    private var lastMediaOpenTapAt: Date = .distantPast
    private let mediaOpenTapCooldown: TimeInterval = 0.5

    /// Returns true if a tap-to-open should proceed. Call at the very top of
    /// the tap handler, before touching any state (lastViewedImageId, etc.),
    /// so a suppressed tap has no side effects at all.
    func beginMediaOpenTap() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastMediaOpenTapAt) >= mediaOpenTapCooldown else {
            return false
        }
        lastMediaOpenTapAt = now
        return true
    }

    // MARK: - Main Window State

    var mainWindowSize: CGSize = CGSize(width: 1200, height: 800)

    // MARK: - Photo Window Memory Management

    /// Number of currently open pop-out photo windows
    var openPhotoWindowCount: Int = 0

    /// Request to open a photo window (consumed by ContentView)
    struct PhotoWindowOpenRequest: Identifiable {
        let id = UUID()
        let image: GalleryImage
        let bypassDuplicatePrompt: Bool
        /// Geometry to open at, when the request comes from a saved window group
        /// (`nil` = size from the image aspect ratio / scene default).
        var restoredSize: CGSize?
    }

    /// Current open request being processed
    var activePhotoWindowOpenRequest: PhotoWindowOpenRequest?

    /// Queue for pending photo window open requests
    private var queuedPhotoWindowOpenRequests: [PhotoWindowOpenRequest] = []

    /// Allow opening duplicate windows for the current request
    private var allowDuplicateOpen: Bool = false

    func enqueuePhotoWindowOpen(
        _ image: GalleryImage,
        bypassDuplicatePrompt: Bool = false,
        restoredSize: CGSize? = nil
    ) {
        let request = PhotoWindowOpenRequest(
            image: image,
            bypassDuplicatePrompt: bypassDuplicatePrompt,
            restoredSize: restoredSize
        )
        queuedPhotoWindowOpenRequests.append(request)

        if activePhotoWindowOpenRequest == nil {
            activePhotoWindowOpenRequest = queuedPhotoWindowOpenRequests.removeFirst()
        }
    }

    /// Returns true when the duplicate-window dialog should be shown.
    /// Active (same room) windows show the dialog so the user can choose
    /// summon vs duplicate. Backgrounded (other room) windows are auto-summoned
    /// silently by handlePhotoWindowOpenIfNeeded.
    func shouldConfirmDuplicateOpen(for request: PhotoWindowOpenRequest) -> Bool {
        if request.bypassDuplicatePrompt || allowDuplicateOpen {
            return false
        }

        switch existingWindowState(for: request.image.fullSizeURL) {
        case .none:
            return false
        case .activeInCurrentRoom:
            return true
        case .backgroundedInOtherRoom:
            // Auto-summoned by handlePhotoWindowOpenIfNeeded — no dialog needed
            return false
        }
    }

    func confirmDuplicateOpen() {
        allowDuplicateOpen = true
    }

    func advancePhotoWindowOpenQueue() {
        if queuedPhotoWindowOpenRequests.isEmpty {
            activePhotoWindowOpenRequest = nil
            allowDuplicateOpen = false
        } else {
            activePhotoWindowOpenRequest = queuedPhotoWindowOpenRequests.removeFirst()
            allowDuplicateOpen = false
        }
    }

    func cancelPendingPhotoWindowOpens() {
        queuedPhotoWindowOpenRequests.removeAll()
        activePhotoWindowOpenRequest = nil
        allowDuplicateOpen = false
    }

    // MARK: - Pop-Out Window Tracking

    /// Tracks open pop-out photo windows by image fullSizeURL string.
    /// Maps image URL string → array of PhotoWindowValue instances.
    /// Used to detect duplicate windows for the same image.
    var openPopOutWindows: [String: [PhotoWindowValue]] = [:]

    /// Register a pop-out window as open
    func registerPopOutWindow(imageURL: URL, windowValue: PhotoWindowValue) {
        let key = imageURL.absoluteString
        var values = openPopOutWindows[key] ?? []
        values.append(windowValue)
        openPopOutWindows[key] = values
    }

    /// Unregister a pop-out window when closed
    func unregisterPopOutWindow(imageURL: URL, windowValueId: UUID) {
        let key = imageURL.absoluteString
        openPopOutWindows[key]?.removeAll { $0.id == windowValueId }
        if openPopOutWindows[key]?.isEmpty == true {
            openPopOutWindows.removeValue(forKey: key)
        }
    }

    /// Check if any pop-out window exists for the given image URL
    func hasOpenPopOutWindow(for imageURL: URL) -> Bool {
        let key = imageURL.absoluteString
        return !(openPopOutWindows[key]?.isEmpty ?? true)
    }

    /// Get all open pop-out window values for the given image URL
    func popOutWindowValues(for imageURL: URL) -> [PhotoWindowValue] {
        let key = imageURL.absoluteString
        return openPopOutWindows[key] ?? []
    }

    // MARK: - Video Window Tracking

    /// Tracks open standalone (non-pushed) video windows, keyed by video
    /// identity. Mirrors `openPopOutWindows` — needed so a saved window group
    /// can capture video windows alongside photos, and so the group UI can tell
    /// which ones are already on screen.
    var openVideoWindows: [String: [VideoWindowValue]] = [:]

    /// Stable identity for a video across windows and app launches. Stash
    /// scenes have an id; local files and streamed URLs fall back to the URL.
    static func videoIdentityKey(for video: GalleryVideo) -> String {
        video.identity.isEmpty ? video.streamURL.absoluteString : video.identity
    }

    func registerVideoWindow(video: GalleryVideo, windowValue: VideoWindowValue) {
        let key = Self.videoIdentityKey(for: video)
        var values = openVideoWindows[key] ?? []
        values.append(windowValue)
        openVideoWindows[key] = values
    }

    func unregisterVideoWindow(video: GalleryVideo, windowValueId: UUID) {
        let key = Self.videoIdentityKey(for: video)
        openVideoWindows[key]?.removeAll { $0.id == windowValueId }
        if openVideoWindows[key]?.isEmpty == true {
            openVideoWindows.removeValue(forKey: key)
        }
    }

    /// Re-key a tracked video window after the user navigated prev/next, so the
    /// registry reflects what the window is actually showing (parallels
    /// `updatePopOutWindowImage`).
    func updateVideoWindowVideo(windowValueId: UUID, oldVideo: GalleryVideo, newVideo: GalleryVideo) {
        let oldKey = Self.videoIdentityKey(for: oldVideo)
        let newKey = Self.videoIdentityKey(for: newVideo)
        guard oldKey != newKey, var values = openVideoWindows[oldKey] else { return }
        guard let index = values.firstIndex(where: { $0.id == windowValueId }) else { return }
        var windowValue = values.remove(at: index)
        windowValue.video = newVideo
        var newValues = openVideoWindows[newKey] ?? []
        newValues.append(windowValue)
        openVideoWindows[newKey] = newValues
        if values.isEmpty {
            openVideoWindows.removeValue(forKey: oldKey)
        } else {
            openVideoWindows[oldKey] = values
        }
    }

    func hasOpenVideoWindow(for video: GalleryVideo) -> Bool {
        !(openVideoWindows[Self.videoIdentityKey(for: video)]?.isEmpty ?? true)
    }

    func videoWindowValues(for video: GalleryVideo) -> [VideoWindowValue] {
        openVideoWindows[Self.videoIdentityKey(for: video)] ?? []
    }

    // MARK: - Video Window Open Queue

    /// Video windows carry no duplicate-summon dialog (unlike photos), so the
    /// queue exists purely to hand a fully-built window value to a view that
    /// owns an `openWindow` action, and to stagger a batch of group restores.
    struct VideoWindowOpenRequest: Identifiable {
        let id = UUID()
        let windowValue: VideoWindowValue
    }

    var activeVideoWindowOpenRequest: VideoWindowOpenRequest?
    private var queuedVideoWindowOpenRequests: [VideoWindowOpenRequest] = []

    func enqueueVideoWindowOpen(_ windowValue: VideoWindowValue) {
        queuedVideoWindowOpenRequests.append(VideoWindowOpenRequest(windowValue: windowValue))
        if activeVideoWindowOpenRequest == nil {
            activeVideoWindowOpenRequest = queuedVideoWindowOpenRequests.removeFirst()
        }
    }

    func advanceVideoWindowOpenQueue() {
        activeVideoWindowOpenRequest = queuedVideoWindowOpenRequests.isEmpty
            ? nil
            : queuedVideoWindowOpenRequests.removeFirst()
    }

    // MARK: - Window Summon (Same-Room Detection)

    enum ExistingWindowState {
        case none
        case activeInCurrentRoom(PhotoWindowValue)
        case backgroundedInOtherRoom(PhotoWindowValue)
    }

    func existingWindowState(for imageURL: URL) -> ExistingWindowState {
        let values = popOutWindowValues(for: imageURL)
        guard !values.isEmpty else { return .none }

        for model in activePhotoWindowModels.values {
            if model.imageURL == imageURL, model.isInActiveRoom,
               let windowValue = model.popOutWindowValue {
                return .activeInCurrentRoom(windowValue)
            }
        }

        // Window exists but is backgrounded — find its PhotoWindowValue
        // for auto-summon via openWindow value matching
        if let backgroundedModel = activePhotoWindowModels.values.first(where: {
            $0.imageURL == imageURL && !$0.isInActiveRoom
        }), let windowValue = backgroundedModel.popOutWindowValue {
            return .backgroundedInOtherRoom(windowValue)
        }

        // Fallback: use the first tracked pop-out value
        return .backgroundedInOtherRoom(values[0])
    }

    /// Whether pop-out windows should use lightweight SwiftUI Image display
    /// instead of RealityKit. Activated on memory warning to free GPU resources.
    var useLightweightDisplay: Bool = false

    /// Whether all secondary windows should hide their content and pause videos.
    /// Toggled from the Developer section in Settings.
    var allWindowsHidden: Bool = false

    // MARK: - Photo Window Model Registry (for LRU Memory Pressure)

    /// Registry of active PhotoWindowModel instances. Used by the memory pressure
    /// handler to sort windows by last interaction time and selectively downscale
    /// the least-recently-interacted windows first.
    private var activePhotoWindowModels: [ObjectIdentifier: PhotoWindowModel] = [:]

    /// Register a photo window model as active (called from PhotoWindowModel.start())
    func registerWindowModel(_ model: PhotoWindowModel) {
        activePhotoWindowModels[ObjectIdentifier(model)] = model
    }

    /// Unregister a photo window model (called from PhotoWindowModel.cleanup())
    func unregisterWindowModel(_ model: PhotoWindowModel) {
        activePhotoWindowModels.removeValue(forKey: ObjectIdentifier(model))
    }

    // MARK: - Remote Viewer Window Open Queue

    struct RemoteViewerOpenRequest: Identifiable {
        let id = UUID()
        let configId: UUID
        let bypassDuplicatePrompt: Bool
        /// Geometry to open at, when the request comes from a saved window group.
        var restoredSize: CGSize?
    }

    var activeRemoteViewerOpenRequest: RemoteViewerOpenRequest?
    private var queuedRemoteViewerOpenRequests: [RemoteViewerOpenRequest] = []
    private var allowDuplicateRemoteViewerOpen: Bool = false

    func enqueueRemoteViewerOpen(
        configId: UUID,
        bypassDuplicatePrompt: Bool = false,
        restoredSize: CGSize? = nil
    ) {
        // A profile that can't describe what to show has nothing to open. The
        // window would come up empty (or, before this was refused, quietly
        // showing whatever the Pictures tab happened to be on).
        if let config = remoteViewerConfig(id: configId), !config.isLaunchable {
            AppLogger.remoteViewer.error(
                "Refusing to open “\(config.name, privacy: .public)”: \(config.launchBlockedReason ?? "not launchable", privacy: .public)"
            )
            return
        }

        let request = RemoteViewerOpenRequest(
            configId: configId,
            bypassDuplicatePrompt: bypassDuplicatePrompt,
            restoredSize: restoredSize
        )
        queuedRemoteViewerOpenRequests.append(request)

        if activeRemoteViewerOpenRequest == nil {
            activeRemoteViewerOpenRequest = queuedRemoteViewerOpenRequests.removeFirst()
        }
    }

    func shouldConfirmDuplicateRemoteViewerOpen(for request: RemoteViewerOpenRequest) -> Bool {
        if request.bypassDuplicatePrompt || allowDuplicateRemoteViewerOpen {
            return false
        }

        switch existingRemoteViewerWindowState(for: request.configId) {
        case .none:
            return false
        case .activeInCurrentRoom:
            return true
        case .backgroundedInOtherRoom:
            return false
        }
    }

    func confirmDuplicateRemoteViewerOpen() {
        allowDuplicateRemoteViewerOpen = true
    }

    func advanceRemoteViewerOpenQueue() {
        if queuedRemoteViewerOpenRequests.isEmpty {
            activeRemoteViewerOpenRequest = nil
            allowDuplicateRemoteViewerOpen = false
        } else {
            activeRemoteViewerOpenRequest = queuedRemoteViewerOpenRequests.removeFirst()
            allowDuplicateRemoteViewerOpen = false
        }
    }

    func cancelPendingRemoteViewerOpens() {
        queuedRemoteViewerOpenRequests.removeAll()
        activeRemoteViewerOpenRequest = nil
        allowDuplicateRemoteViewerOpen = false
    }

    // MARK: - Remote Viewer Window Tracking

    /// Tracks open remote viewer windows by configId string.
    /// Maps configId string → array of RemoteViewerWindowValue instances.
    private var openRemoteViewerWindows: [String: [RemoteViewerWindowValue]] = [:]

    func registerRemoteViewerWindow(configId: UUID, windowValue: RemoteViewerWindowValue) {
        let key = configId.uuidString
        var values = openRemoteViewerWindows[key] ?? []
        values.append(windowValue)
        openRemoteViewerWindows[key] = values
    }

    func unregisterRemoteViewerWindow(configId: UUID, windowValueId: UUID) {
        let key = configId.uuidString
        openRemoteViewerWindows[key]?.removeAll { $0.id == windowValueId }
        if openRemoteViewerWindows[key]?.isEmpty == true {
            openRemoteViewerWindows.removeValue(forKey: key)
        }
    }

    func remoteViewerWindowValues(for configId: UUID) -> [RemoteViewerWindowValue] {
        let key = configId.uuidString
        return openRemoteViewerWindows[key] ?? []
    }

    // MARK: - Remote Viewer Model Registry

    private var activeRemoteViewerModels: [ObjectIdentifier: RemoteViewerModel] = [:]

    func registerRemoteViewerModel(_ model: RemoteViewerModel) {
        activeRemoteViewerModels[ObjectIdentifier(model)] = model
    }

    func unregisterRemoteViewerModel(_ model: RemoteViewerModel) {
        activeRemoteViewerModels.removeValue(forKey: ObjectIdentifier(model))
    }

    // MARK: - Remote History Stores
    //
    // One store per (endpoint, token) pair. All viewer windows pointed at
    // the same RoboFrame instance share the same store so the history
    // grid reflects what's actually been shown across the room, not just
    // what this window has seen.

    private var remoteHistoryStores: [String: RemoteHistoryStore] = [:]
    private let sharedRemoteAPIClient = RemoteAPIClient()

    private func historyStoreKey(endpoint: String, accessToken: String) -> String {
        "\(endpoint)\u{1}\(accessToken)"
    }

    func remoteHistoryStore(for endpoint: String, accessToken: String) -> RemoteHistoryStore? {
        guard !endpoint.isEmpty else { return nil }
        let key = historyStoreKey(endpoint: endpoint, accessToken: accessToken)
        if let existing = remoteHistoryStores[key] { return existing }
        let store = RemoteHistoryStore(endpoint: endpoint, accessToken: accessToken, apiClient: sharedRemoteAPIClient)
        remoteHistoryStores[key] = store
        return store
    }

    /// Eagerly prime history stores for every saved Remote config that has
    /// an API endpoint. Called once after init so the grid renders
    /// instantly the first time a viewer's history button is pressed.
    func refreshAllRemoteHistoryStores() {
        for config in savedRemoteConfigs where !config.apiEndpoint.isEmpty {
            guard let store = remoteHistoryStore(for: config.apiEndpoint, accessToken: config.accessToken) else { continue }
            Task { await store.refresh() }
        }
    }

    // MARK: - Remote Viewer Window Summon

    enum ExistingRemoteViewerWindowState {
        case none
        case activeInCurrentRoom(RemoteViewerWindowValue)
        case backgroundedInOtherRoom(RemoteViewerWindowValue)
    }

    func existingRemoteViewerWindowState(for configId: UUID) -> ExistingRemoteViewerWindowState {
        let values = remoteViewerWindowValues(for: configId)
        guard !values.isEmpty else { return .none }

        for model in activeRemoteViewerModels.values {
            if model.config.id == configId, model.isRoomActive,
               let windowValue = model.windowValue {
                return .activeInCurrentRoom(windowValue)
            }
        }

        if let backgroundedModel = activeRemoteViewerModels.values.first(where: {
            $0.config.id == configId && !$0.isRoomActive
        }), let windowValue = backgroundedModel.windowValue {
            return .backgroundedInOtherRoom(windowValue)
        }

        return .backgroundedInOtherRoom(values[0])
    }

    /// Duration before auto-hiding UI (in seconds), 0 means disabled
    var autoHideDelay: TimeInterval {
        didSet {
            if autoHideDelay != oldValue {
                UserDefaults.standard.set(autoHideDelay, forKey: "autoHideDelay")
            }
        }
    }

    /// Available auto-hide delay options (0 = disabled)
    static let autoHideDelayOptions: [(label: String, value: TimeInterval)] = [
        ("Disabled", 0),
        ("2 seconds", 2),
        ("3 seconds", 3),
        ("5 seconds", 5),
        ("10 seconds", 10)
    ]

    // MARK: - Image Display Settings

    /// Maximum image resolution in pixels. Images are downsampled to this cap
    /// (with window-based optimization within the cap). 0 = Off (full native resolution).
    var maxImageResolution: Int {
        didSet {
            if maxImageResolution != oldValue {
                UserDefaults.standard.set(maxImageResolution, forKey: "maxImageResolution")
            }
        }
    }

    /// Available max image resolution options (value 0 = Off / no limit)
    static let maxImageResolutionOptions: [(label: String, value: Int)] = [
        ("480px", 480),
        ("640px", 640),
        ("960px", 960),
        ("1280px", 1280),
        ("1600px", 1600),
        ("2048px", 2048),
        ("2560px", 2560),
        ("3200px", 3200),
        ("4096px", 4096),
        ("Off", 0),
    ]

    /// Maximum resolution passed to RealityKit's `Spatial3DImage`. Fully
    /// independent of `maxImageResolution` — the 2D cap governs the on-screen
    /// MTLTexture, this one governs the source fed into the depth/parallax
    /// mesh. 0 = no cap (use native resolution).
    var spatial3DMaxResolution: Int {
        didSet {
            if spatial3DMaxResolution != oldValue {
                UserDefaults.standard.set(spatial3DMaxResolution, forKey: "spatial3DMaxResolution")
            }
        }
    }

    /// Distance (in points along z) the diorama foreground is popped forward
    /// from the backdrop plane. Higher = more pronounced parallax.
    var dioramaDistance: Double {
        didSet {
            if dioramaDistance != oldValue {
                UserDefaults.standard.set(dioramaDistance, forKey: "dioramaDistance")
            }
        }
    }

    /// Available diorama distance options
    static let dioramaDistanceOptions: [(label: String, value: Double)] = [
        ("10", 10), ("15", 15), ("20", 20), ("25", 25),
        ("30", 30), ("35", 35), ("40", 40), ("45", 45), ("50", 50),
    ]

    static let defaultDioramaDistance: Double = 25

    /// User preference for reduced-motion behavior (disable thumbnail
    /// gaze animations, instant photo-viewer swipe transitions, instant
    /// slideshow image switches). The system Accessibility setting also
    /// forces this on — read `effectiveReduceMotion` at use sites.
    var reduceMotion: Bool {
        didSet {
            if reduceMotion != oldValue {
                UserDefaults.standard.set(reduceMotion, forKey: "reduceMotion")
            }
        }
    }

    /// Mirrors `UIAccessibility.isReduceMotionEnabled`, kept current via a
    /// notification observer registered in `init`. Stored separately so
    /// SwiftUI views observing `effectiveReduceMotion` rebuild when the
    /// system setting changes outside the app.
    private(set) var systemReduceMotion: Bool = {
        #if os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return UIAccessibility.isReduceMotionEnabled
        #endif
    }()

    /// True when either the user toggle or the system Accessibility setting
    /// requests reduced motion. This is the value views should react to.
    var effectiveReduceMotion: Bool {
        reduceMotion || systemReduceMotion
    }

    /// Gallery thumbnail rendering style. `.flat` is a regular 2D
    /// thumbnail; `.diorama` overlays a foreground-popped subject layer
    /// for Apple TV-style parallax; `.spatial3D` runs each thumbnail
    /// through RealityKit's 2D→3D converter at low resolution.
    /// Forced to `.flat` when `effectiveReduceMotion` is true — read
    /// `effectiveThumbnailStyle` at use sites.
    var thumbnailStyle: ThumbnailStyle {
        didSet {
            if thumbnailStyle != oldValue {
                UserDefaults.standard.set(thumbnailStyle.rawValue, forKey: "thumbnailStyle")
            }
        }
    }

    var effectiveThumbnailStyle: ThumbnailStyle {
        guard PlatformCapabilities.supportsDiorama else { return .flat }
        return effectiveReduceMotion ? .flat : thumbnailStyle
    }

    var effectiveThumbnailDiorama: Bool {
        effectiveThumbnailStyle == .diorama
    }

    /// When true, image viewer windows have rounded corners.
    var roundedCorners: Bool {
        didSet {
            if roundedCorners != oldValue {
                UserDefaults.standard.set(roundedCorners, forKey: "roundedCorners")
            }
        }
    }

    /// Corner radius the photo viewer clips its picture to.
    ///
    /// A visionOS window *is* the photo — it is sized to the image and drawn
    /// as a rounded glass slab, so square corners poke out of it. A phone's
    /// screen is the frame and the photo is content inside it; rounding there
    /// only shaves the corners off the picture, which is why the setting is
    /// visionOS-only rather than merely defaulted off.
    var photoCornerRadius: CGFloat {
        #if os(visionOS)
        roundedCorners ? 50 : 0
        #else
        0
        #endif
    }

    /// When true, media selections open in separate pop-out windows (openWindow).
    /// When false, media selections use pushWindow for in-place navigation.
    var openMediaInNewWindows: Bool {
        didSet {
            if openMediaInNewWindows != oldValue {
                UserDefaults.standard.set(openMediaInNewWindows, forKey: "openMediaInNewWindows")
            }
        }
    }

    /// When true, webm scenes prefer Stash's server-side transcode (HLS) so they
    /// play in the native/Metal renderer (and fake-3D works). When false, use the
    /// direct stream URL and let WebKit handle undecodable containers. Read live
    /// by GraphQLVideoSource at fetch time (key "enableStashTranscoding").
    var enableStashTranscoding: Bool {
        didSet {
            if enableStashTranscoding != oldValue {
                UserDefaults.standard.set(enableStashTranscoding, forKey: "enableStashTranscoding")
            }
        }
    }

    /// Preferred depth model for REAL-TIME fake-3D (base filename, e.g.
    /// "DepthAnythingV2SmallF16"), or "" for automatic (first installed).
    /// Read live by CoreMLDepthProvider.findModelURL(role: .realtime); a
    /// change applies to the video being watched immediately (the player
    /// observes this and rebuilds the pump). Real-time inference gates every
    /// frame, so this should stay a fast model.
    var realtimeDepthModelName: String {
        didSet {
            if realtimeDepthModelName != oldValue {
                UserDefaults.standard.set(realtimeDepthModelName, forKey: "realtimeDepthModelName")
            }
        }
    }

    /// Preferred depth model for PRE-PROCESS (offline) 3D conversion, or ""
    /// for automatic. Offline conversion tolerates slower models, so a larger
    /// variant (e.g. a custom Base conversion) can be selected here while
    /// real-time keeps a fast one. Applies to conversions started after the
    /// change; cache lookups prefer entries made by this model.
    var preprocessDepthModelName: String {
        didSet {
            if preprocessDepthModelName != oldValue {
                UserDefaults.standard.set(preprocessDepthModelName, forKey: "preprocessDepthModelName")
            }
        }
    }

    /// When true, eligible videos (native-Metal-decodable, not genuinely
    /// stereoscopic) open with fake-3D already engaged: this video's
    /// pre-processed cache when the selected pre-process model has one, else
    /// real-time inference. Requires an installed depth model — with none
    /// installed videos open flat 2D as usual (no setup sheet is forced).
    /// Applied by VideoWindowModel once the native renderer is confirmed.
    var defaultRealtimePseudo3D: Bool {
        didSet {
            if defaultRealtimePseudo3D != oldValue {
                UserDefaults.standard.set(defaultRealtimePseudo3D, forKey: "defaultRealtimePseudo3D")
            }
        }
    }

    /// When true (default), videos open with audio muted; autoplay always
    /// starts playback either way. Off = videos open with sound. Applies to
    /// the video player windows and the gallery long-press quick look.
    var videoAutoplayMuted: Bool {
        didSet {
            if videoAutoplayMuted != oldValue {
                UserDefaults.standard.set(videoAutoplayMuted, forKey: "videoAutoplayMuted")
            }
        }
    }

    /// When true, per-image viewing enhancements (spatial 3D, background removal)
    /// are remembered and auto-restored on reopen.
    var rememberImageEnhancements: Bool {
        didSet {
            if rememberImageEnhancements != oldValue {
                UserDefaults.standard.set(rememberImageEnhancements, forKey: "rememberImageEnhancements")
            }
        }
    }

    /// Default viewing mode applied when an image is opened and no per-image
    /// remembered mode applies. Choices mirror the photo viewer's 3D menu.
    var defaultImageViewingMode: DefaultImageViewingMode {
        didSet {
            if defaultImageViewingMode != oldValue {
                UserDefaults.standard.set(defaultImageViewingMode.rawValue, forKey: "defaultImageViewingMode")
            }
        }
    }

    /// When true, previously converted images auto-restore into spatial 3D mode.
    /// This only applies when rememberImageEnhancements is enabled.
    var autoRestoreSpatial3D: Bool {
        didSet {
            if autoRestoreSpatial3D != oldValue {
                UserDefaults.standard.set(autoRestoreSpatial3D, forKey: "autoRestoreSpatial3D")
            }
        }
    }

    /// When true, entering Immersive 3D opens a dedicated mixed
    /// `ImmersiveSpace` (and dismisses the windowed IPC presentation)
    /// instead of expanding the image within the window. Off by default —
    /// the original Photos-style windowed immersive behavior is preserved.
    var fullyImmersive3DMode: Bool {
        didSet {
            if fullyImmersive3DMode != oldValue {
                UserDefaults.standard.set(fullyImmersive3DMode, forKey: "fullyImmersive3DMode")
            }
        }
    }

    /// Clears all remembered image enhancement data.
    func clearImageEnhancementData() async {
        await ImageEnhancementTracker.shared.clearAll()
    }

    // MARK: - Visual Adjustments

    /// Global default visual adjustments applied when no per-image adjustments are set
    var globalVisualAdjustments: VisualAdjustments = VisualAdjustments() {
        didSet {
            if globalVisualAdjustments != oldValue {
                if let data = try? JSONEncoder().encode(globalVisualAdjustments) {
                    UserDefaults.standard.set(data, forKey: "globalVisualAdjustments")
                }
            }
        }
    }

    /// Global default fake-3D tuning, applied to pseudo-3D videos that haven't
    /// been individually adjusted (mirrors globalVisualAdjustments).
    var globalPseudo3DSettings: Pseudo3DSettings = .default {
        didSet {
            if globalPseudo3DSettings != oldValue {
                if let data = try? JSONEncoder().encode(globalPseudo3DSettings) {
                    UserDefaults.standard.set(data, forKey: "globalPseudo3DSettings")
                }
            }
        }
    }

    // MARK: - Remote Viewer

    /// Last tag list catalog the server pushed to any open viewer. The catalog
    /// is identical for every window, so it's mirrored here to seed a freshly
    /// opened viewer's ornament before the server re-pushes `tagLists` (which
    /// only happens on connect — a late joiner on an already-open shared WS
    /// connection would otherwise start with no list names). The current list
    /// itself is fully server-tracked (per-window TagListManager active index).
    var tagListCatalog: [[String]] = []
    let modTagManager = ModTagManager()

    /// Persistent config for the gallery slideshow launched from photo viewer ornament.
    /// Stored separately from savedRemoteConfigs so it doesn't clutter the Remote tab.
    var gallerySlideshowConfig: RemoteViewerConfig? {
        didSet { persistImplicitSlideshowConfig(gallerySlideshowConfig, key: Self.gallerySlideshowConfigKey) }
    }

    /// Persistent config for the video slideshow launched from the video viewer
    /// ornament. Stored separately from savedRemoteConfigs and the gallery
    /// (image) slideshow config so each keeps its own display settings.
    var videoSlideshowConfig: RemoteViewerConfig? {
        didSet { persistImplicitSlideshowConfig(videoSlideshowConfig, key: Self.videoSlideshowConfigKey) }
    }

    static let gallerySlideshowConfigKey = "gallerySlideshowConfig"
    static let videoSlideshowConfigKey = "videoSlideshowConfig"

    /// Start a slideshow of the content the user is looking at right now.
    ///
    /// The *profile* is a reused `.appGallery` one, so display tweaks made in
    /// the slideshow's ornament (clock, Ken Burns, 3D mode…) persist between
    /// launches. The *content* rides along as a transient override, because it
    /// is by definition not something a saved profile can describe — trying to
    /// make a profile mean "whatever I'm looking at" is what made the old
    /// blank-endpoint mode unpredictable.
    func startGallerySlideshow(imageSource: any ImageSource, filter: ImageFilterCriteria?) {
        let config = gallerySlideshowConfig ?? makeAppGallerySlideshowConfig(name: "Gallery Slideshow")
        gallerySlideshowConfig = config
        pendingGallerySlideshowSource = GallerySlideshowSourceOverride(
            imageSource: imageSource,
            filter: filter
        )
        enqueueRemoteViewerOpen(configId: config.id)
    }

    /// Video counterpart of `startGallerySlideshow`, with its own profile slot
    /// so image and video slideshows keep separate display settings.
    func startVideoSlideshow(videoSource: any VideoSource, filter: SceneFilterCriteria?) {
        let config: RemoteViewerConfig
        if let existing = videoSlideshowConfig {
            config = existing
        } else {
            var fresh = makeAppGallerySlideshowConfig(name: "Video Slideshow")
            // Spatial 3D is image-only — never engage it for a video slideshow.
            fresh.slideshow3DMode = .off
            config = fresh
        }
        videoSlideshowConfig = config
        pendingVideoSlideshowSource = VideoSlideshowSourceOverride(
            videoSource: videoSource,
            filter: filter
        )
        enqueueRemoteViewerOpen(configId: config.id)
    }

    private func makeAppGallerySlideshowConfig(name: String) -> RemoteViewerConfig {
        var config = RemoteViewerConfig(name: name)
        config.mode = .appGallery
        config.apiEndpoint = ""
        applySlideshowDefaults(to: &config)
        return config
    }

    private func persistImplicitSlideshowConfig(_ config: RemoteViewerConfig?, key: String) {
        guard let config, let data = try? JSONEncoder().encode(config) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// When true, the Remote tab appears in the tab bar ornament
    /// Which library the Pictures and Videos tabs browse.
    ///
    /// Only consulted when a Stash server is configured — with no server there
    /// is nothing to choose between, and the photo library is the only source.
    var librarySource: LibrarySource {
        didSet {
            guard librarySource != oldValue else { return }
            UserDefaults.standard.set(librarySource.rawValue, forKey: "librarySource")
            applyLibrarySource()
        }
    }

    var enableRemoteViewer: Bool {
        didSet {
            if enableRemoteViewer != oldValue {
                UserDefaults.standard.set(enableRemoteViewer, forKey: "enableRemoteViewer")
            }
        }
    }

    /// Whether the welcome flow has been seen. False shows it over the main
    /// window on launch.
    ///
    /// Its *default* carries the upgrade rule: an install that already has a
    /// server, or has already answered the photo-library prompt, has plainly
    /// been set up and must not be walked through setup again. That is derived
    /// rather than migrated, so there is no flag-writing pass to get wrong.
    var hasCompletedWelcome: Bool {
        didSet {
            if hasCompletedWelcome != oldValue {
                UserDefaults.standard.set(hasCompletedWelcome, forKey: "hasCompletedWelcome")
            }
        }
    }


    /// Last incoming URL + time, for de-duplication. Both SwiftUI's `.onOpenURL`
    /// and the `SceneDelegate` notification fire for a custom-scheme open (the
    /// notification path exists for file-share cold launches that `.onOpenURL`
    /// misses), so a `hypnos://` handoff arrives twice and would open two
    /// windows. `shouldProcessIncomingURL` collapses identical URLs seen within
    /// a short window.
    private var lastIncomingURL: (raw: String, at: Date)?

    /// Returns false if this exact URL was already handled moments ago (the
    /// double-delivery described above). Distinct URLs, or the same URL after
    /// the window, are always processed.
    func shouldProcessIncomingURL(_ url: URL) -> Bool {
        let now = Date()
        if let last = lastIncomingURL, last.raw == url.absoluteString,
           now.timeIntervalSince(last.at) < 2.0 {
            return false
        }
        lastIncomingURL = (url.absoluteString, now)
        return true
    }

    /// Saved remote viewer configurations
    var savedRemoteConfigs: [RemoteViewerConfig] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(savedRemoteConfigs) {
                UserDefaults.standard.set(data, forKey: "savedRemoteConfigs")
            }
        }
    }

    func saveRemoteConfig(_ config: RemoteViewerConfig) {
        if let index = savedRemoteConfigs.firstIndex(where: { $0.id == config.id }) {
            savedRemoteConfigs[index] = config
        } else {
            savedRemoteConfigs.append(config)
        }
    }

    /// Persist a profile back into whichever store owns it.
    ///
    /// The gallery and video slideshow profiles live in their own slots
    /// precisely so they stay out of the Remote tab's list, but a viewer window
    /// persisting an ornament tweak only knows an id. Routing through here
    /// keeps that write-back from appending a copy of them to the saved list —
    /// which it did on every launch, since those slots start empty and the
    /// launching ornament mints a fresh id when it finds no config.
    func persistRemoteViewerConfig(_ config: RemoteViewerConfig) {
        if gallerySlideshowConfig?.id == config.id,
           !savedRemoteConfigs.contains(where: { $0.id == config.id }) {
            gallerySlideshowConfig = config
        } else if videoSlideshowConfig?.id == config.id,
                  !savedRemoteConfigs.contains(where: { $0.id == config.id }) {
            videoSlideshowConfig = config
        } else {
            saveRemoteConfig(config)
        }
    }

    /// Resolve a viewer profile by id across the saved profiles and the two
    /// implicit slideshow profiles (gallery / video), which are stored outside
    /// `savedRemoteConfigs` so they don't clutter the Remote tab. The
    /// `remote-viewer` scene needs this before it can decide which window to
    /// build for a given window value.
    func remoteViewerConfig(id: UUID) -> RemoteViewerConfig? {
        if let saved = savedRemoteConfigs.first(where: { $0.id == id }) { return saved }
        if let gallery = gallerySlideshowConfig, gallery.id == id { return gallery }
        if let video = videoSlideshowConfig, video.id == id { return video }
        return nil
    }

    func deleteRemoteConfig(_ config: RemoteViewerConfig) {
        savedRemoteConfigs.removeAll { $0.id == config.id }
    }

    func renameRemoteConfig(_ config: RemoteViewerConfig, newName: String) {
        if let index = savedRemoteConfigs.firstIndex(where: { $0.id == config.id }) {
            savedRemoteConfigs[index].name = newName
        }
    }

    // MARK: - Debug Console

    /// When true, the Console tab appears in the tab bar ornament.
    /// Only controls visibility — log capture is driven by open console
    /// views via LogStore's viewer refcount.
    var showDebugConsole: Bool {
        didSet {
            if showDebugConsole != oldValue {
                UserDefaults.standard.set(showDebugConsole, forKey: "showDebugConsole")
                updateDeviceTelemetry()
            }
        }
    }

    /// Wire the process-wide device-telemetry ticker (SlideshowSyncHub) to the
    /// Console developer toggle — quasi-dev-mode. When on, periodic
    /// `reportMetrics` + event `reportLog` frames flow to the RoboFrame backend
    /// over the existing slideshow WS (see DeviceMetrics / protocol.md).
    func updateDeviceTelemetry() {
        let enabled = showDebugConsole
        SlideshowSyncHub.shared.setTelemetryEnabled(enabled, provider: enabled ? { [weak self] in
            self?.captureDeviceMetrics() ?? DeviceMetrics.capture(deviceId: "hypnos", app: "hypnos", photoWindows: 0, slideshowWindows: 0)
        } : nil)
    }

    /// Build a process-wide telemetry sample. deviceId is best-effort: the first
    /// active remote viewer's stable device identity, else a generic label.
    private func captureDeviceMetrics() -> DeviceMetrics {
        let deviceId = activeRemoteViewerModels.values
            .map(\.slideshowDeviceId)
            .first ?? "hypnos"
        return DeviceMetrics.capture(
            deviceId: deviceId,
            app: "hypnos",
            photoWindows: openPhotoWindowCount,
            slideshowWindows: activeRemoteViewerModels.count
        )
    }

    /// When true, the app responds to system memory pressure by downscaling
    /// images and clearing caches. When false, memory pressure events are
    /// logged but not acted upon.
    var respectMemoryAlerts: Bool {
        didSet {
            if respectMemoryAlerts != oldValue {
                UserDefaults.standard.set(respectMemoryAlerts, forKey: "respectMemoryAlerts")
            }
        }
    }

    /// When true, Metal textures are created with lossy compression to reduce
    /// GPU memory footprint. Slight quality reduction in exchange for ~2-4x
    /// memory savings per texture. Requires Apple Silicon (apple5+ GPU family).
    var useLossyTextureCompression: Bool {
        didSet {
            if useLossyTextureCompression != oldValue {
                UserDefaults.standard.set(useLossyTextureCompression, forKey: "useLossyTextureCompression")
            }
        }
    }

    // MARK: - Slideshow Settings

    /// Slideshow delay between images (in seconds)
    var slideshowDelay: TimeInterval {
        didSet {
            if slideshowDelay != oldValue {
                UserDefaults.standard.set(slideshowDelay, forKey: "slideshowDelay")
            }
        }
    }

    /// Available slideshow delay options (in seconds)
    static let slideshowDelayOptions: [TimeInterval] = [
        3, 5, 10, 15, 20, 30, 45, 60, 90, 120
    ]

    /// Default slideshow display settings, used as initial values for every
    /// slideshow source (gallery, local folder, video, remote API). Saved
    /// `RemoteViewerConfig` profiles override these per-profile but inherit
    /// them when first created.
    var slideshowShowClock: Bool { didSet { if slideshowShowClock != oldValue { UserDefaults.standard.set(slideshowShowClock, forKey: "slideshowShowClock") } } }
    var slideshowShowSensors: Bool { didSet { if slideshowShowSensors != oldValue { UserDefaults.standard.set(slideshowShowSensors, forKey: "slideshowShowSensors") } } }
    var slideshowUseAspectRatio: Bool { didSet { if slideshowUseAspectRatio != oldValue { UserDefaults.standard.set(slideshowUseAspectRatio, forKey: "slideshowUseAspectRatio") } } }
    var slideshowEnableKenBurns: Bool { didSet { if slideshowEnableKenBurns != oldValue { UserDefaults.standard.set(slideshowEnableKenBurns, forKey: "slideshowEnableKenBurns") } } }
    var slideshowEnableDynamicBrightness: Bool { didSet { if slideshowEnableDynamicBrightness != oldValue { UserDefaults.standard.set(slideshowEnableDynamicBrightness, forKey: "slideshowEnableDynamicBrightness") } } }
    var slideshowEnableDiorama: Bool { didSet { if slideshowEnableDiorama != oldValue { UserDefaults.standard.set(slideshowEnableDiorama, forKey: "slideshowEnableDiorama") } } }
    var slideshowTransparentBackground: Bool { didSet { if slideshowTransparentBackground != oldValue { UserDefaults.standard.set(slideshowTransparentBackground, forKey: "slideshowTransparentBackground") } } }
    var slideshowTextSize: Double { didSet { if slideshowTextSize != oldValue { UserDefaults.standard.set(slideshowTextSize, forKey: "slideshowTextSize") } } }

    /// Default 2D upper resolution cap for slideshow images (mirrors the
    /// regular viewer's `maxImageResolution` setting). 0 = Off (native).
    var slideshowMaxImageResolution2D: Int {
        didSet {
            if slideshowMaxImageResolution2D != oldValue {
                UserDefaults.standard.set(slideshowMaxImageResolution2D, forKey: "slideshowMaxImageResolution2D")
            }
        }
    }

    /// Default 3D upper resolution cap for slideshow images, used when a
    /// slideshow's `slideshow3DMode` is non-`.off`. Fed into RealityKit's
    /// `Spatial3DImage`. 0 = Off (native).
    var slideshowMaxImageResolution3D: Int {
        didSet {
            if slideshowMaxImageResolution3D != oldValue {
                UserDefaults.standard.set(slideshowMaxImageResolution3D, forKey: "slideshowMaxImageResolution3D")
            }
        }
    }

    /// Apply the current slideshow defaults to a `RemoteViewerConfig`. Used
    /// when creating a new gallery/local/video slideshow config and when
    /// initializing a fresh profile in the Remote tab editor.
    func applySlideshowDefaults(to config: inout RemoteViewerConfig) {
        config.delay = slideshowDelay
        config.showClock = slideshowShowClock
        config.showSensors = slideshowShowSensors
        config.useAspectRatio = slideshowUseAspectRatio
        config.enableKenBurns = slideshowEnableKenBurns
        config.enableDynamicBrightness = slideshowEnableDynamicBrightness
        config.enableDiorama = slideshowEnableDiorama
        config.transparentBackground = slideshowTransparentBackground
        config.textSize = slideshowTextSize
        // Resolution caps inherit from the app-level defaults unless the
        // profile has already overridden them.
        if config.maxImageResolution2D == nil {
            config.maxImageResolution2D = slideshowMaxImageResolution2D
        }
        if config.maxImageResolution3D == nil {
            config.maxImageResolution3D = slideshowMaxImageResolution3D
        }
    }

    // MARK: - Initialization

    init() {
        // RAVEMedia's depth cache has no notion of this app's cache budget, so
        // it never evicts until told how much disk it may hold. Wired before
        // anything can enqueue a conversion; without it the depth cache grows
        // without bound rather than taking its CacheBudget share.
        RAVEMediaPolicy.depthCacheCap = { currentSize in
            CacheBudget.cap(for: .depth, currentSize: currentSize)
        }

        Task.detached(priority: .utility) {
            DepthConversionManager.cleanupOrphanedDownloads()
        }

        // Load persisted settings or use defaults (use local vars to avoid self reference issues)
        let defaultServerURL = ""
        let defaultAPIKey = ""
        let defaultAutoHideDelay: TimeInterval = 3.0
        let defaultSlideshowDelay: TimeInterval = 5.0

        let loadedServerURL = UserDefaults.standard.string(forKey: "stashServerURL") ?? defaultServerURL
        // The API key lives in the Keychain. Installs that predate that wrote it
        // to UserDefaults, so pull it across first — the migration is a no-op
        // once the legacy key is gone, and it deletes the plaintext copy only
        // after the Keychain write succeeds.
        KeychainStore.migrateFromUserDefaults(legacyKey: "stashAPIKey", to: .stashAPIKey)
        // Trim persisted keys too — pre-fix installs (and restored backups) may
        // have stored a key with trailing whitespace; see stashAPIKey.didSet.
        let loadedAPIKey = (KeychainStore.string(for: .stashAPIKey) ?? defaultAPIKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let loadedNextcloudServerURL = UserDefaults.standard.string(forKey: "nextcloudServerURL") ?? ""
        let loadedNextcloudUsername = UserDefaults.standard.string(forKey: "nextcloudUsername") ?? ""
        // Never in UserDefaults, so there is nothing to migrate across: this
        // setting only ever existed after the Keychain store did.
        let loadedNextcloudAppPassword = KeychainStore.string(for: .nextcloudAppPassword) ?? ""
        // "Photos" rather than "" so a fresh setup doesn't start by searching
        // the whole account — see `nextcloudRoot` for why that matters.
        let loadedNextcloudRoot = UserDefaults.standard.string(forKey: "nextcloudRoot") ?? "Photos"

        // Load auto-hide delay (0 means disabled, use default if not set)
        let savedAutoHideDelay = UserDefaults.standard.double(forKey: "autoHideDelay")
        let loadedAutoHideDelay = UserDefaults.standard.object(forKey: "autoHideDelay") != nil ? savedAutoHideDelay : defaultAutoHideDelay

        // Load slideshow delay
        let savedSlideshowDelay = UserDefaults.standard.double(forKey: "slideshowDelay")
        let loadedSlideshowDelay = UserDefaults.standard.object(forKey: "slideshowDelay") != nil ? savedSlideshowDelay : defaultSlideshowDelay

        // Load slideshow display defaults (defaults match the previous
        // RemoteViewerConfig defaults so behavior is unchanged on first launch).
        func loadBool(_ key: String, default defaultValue: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.bool(forKey: key) : defaultValue
        }
        let loadedSlideshowShowClock = loadBool("slideshowShowClock", default: true)
        let loadedSlideshowShowSensors = loadBool("slideshowShowSensors", default: true)
        let loadedSlideshowUseAspectRatio = loadBool("slideshowUseAspectRatio", default: true)
        let loadedSlideshowEnableKenBurns = loadBool("slideshowEnableKenBurns", default: true)
        let loadedSlideshowEnableDynamicBrightness = loadBool("slideshowEnableDynamicBrightness", default: true)
        let loadedSlideshowEnableDiorama = loadBool("slideshowEnableDiorama", default: false)
        let loadedSlideshowTransparentBackground = loadBool("slideshowTransparentBackground", default: false)
        let loadedSlideshowTextSize: Double = UserDefaults.standard.object(forKey: "slideshowTextSize") != nil
            ? UserDefaults.standard.double(forKey: "slideshowTextSize")
            : 1.0

        // Slideshow per-mode resolution caps. Default to the same 4096 cap
        // used elsewhere so first-launch behavior matches the regular viewer.
        let loadedSlideshowMaxImageResolution2D: Int = UserDefaults.standard.object(forKey: "slideshowMaxImageResolution2D") != nil
            ? UserDefaults.standard.integer(forKey: "slideshowMaxImageResolution2D")
            : 4096
        let loadedSlideshowMaxImageResolution3D: Int = UserDefaults.standard.object(forKey: "slideshowMaxImageResolution3D") != nil
            ? UserDefaults.standard.integer(forKey: "slideshowMaxImageResolution3D")
            : 4096

        // Load max image resolution (default: 4096, migrate from old bool key if needed)
        let loadedMaxImageResolution: Int
        if UserDefaults.standard.object(forKey: "maxImageResolution") != nil {
            loadedMaxImageResolution = UserDefaults.standard.integer(forKey: "maxImageResolution")
        } else if UserDefaults.standard.object(forKey: "dynamicImageResolution") != nil {
            // Migrate from old boolean setting: true → 4096, false → 0 (Off)
            loadedMaxImageResolution = UserDefaults.standard.bool(forKey: "dynamicImageResolution") ? 4096 : 0
            UserDefaults.standard.set(loadedMaxImageResolution, forKey: "maxImageResolution")
            UserDefaults.standard.removeObject(forKey: "dynamicImageResolution")
        } else {
            loadedMaxImageResolution = 4096
        }

        // Load spatial 3D max resolution (default: 4096)
        let loadedSpatial3DMaxResolution: Int
        if UserDefaults.standard.object(forKey: "spatial3DMaxResolution") != nil {
            loadedSpatial3DMaxResolution = UserDefaults.standard.integer(forKey: "spatial3DMaxResolution")
        } else {
            loadedSpatial3DMaxResolution = 4096
        }

        // Load diorama distance (default: 25)
        let loadedDioramaDistance: Double
        if UserDefaults.standard.object(forKey: "dioramaDistance") != nil {
            loadedDioramaDistance = UserDefaults.standard.double(forKey: "dioramaDistance")
        } else {
            loadedDioramaDistance = AppModel.defaultDioramaDistance
        }

        // Load reduce-motion user preference (default: false; system
        // Accessibility setting overrides via effectiveReduceMotion)
        let loadedReduceMotion = UserDefaults.standard.bool(forKey: "reduceMotion")

        // Load thumbnail style. Migrates from legacy `thumbnailDiorama`
        // bool: true → .diorama, false → .flat. Default for fresh installs
        // is .diorama to preserve the prior look, but only where the
        // platform supports it (`effectiveThumbnailStyle` also enforces
        // this for values already persisted from before this guard existed).
        let loadedThumbnailStyle: ThumbnailStyle = {
            if let raw = UserDefaults.standard.string(forKey: "thumbnailStyle"),
               let style = ThumbnailStyle(rawValue: raw) {
                return style
            }
            if UserDefaults.standard.object(forKey: "thumbnailDiorama") != nil {
                return UserDefaults.standard.bool(forKey: "thumbnailDiorama") ? .diorama : .flat
            }
            return PlatformCapabilities.supportsDiorama ? .diorama : .flat
        }()

        // Load rounded corners (default: true)
        let loadedRoundedCorners = UserDefaults.standard.object(forKey: "roundedCorners") != nil
            ? UserDefaults.standard.bool(forKey: "roundedCorners")
            : true

        // Load media opening mode (default: false = pushWindow navigation)
        // Migrate from old key "openImagesInSeparateWindows" if new key doesn't exist
        let loadedOpenMediaInNewWindows: Bool
        if UserDefaults.standard.object(forKey: "openMediaInNewWindows") != nil {
            loadedOpenMediaInNewWindows = UserDefaults.standard.bool(forKey: "openMediaInNewWindows")
        } else if UserDefaults.standard.object(forKey: "openImagesInSeparateWindows") != nil {
            loadedOpenMediaInNewWindows = UserDefaults.standard.bool(forKey: "openImagesInSeparateWindows")
            // Migrate to new key
            UserDefaults.standard.set(loadedOpenMediaInNewWindows, forKey: "openMediaInNewWindows")
            UserDefaults.standard.removeObject(forKey: "openImagesInSeparateWindows")
        } else {
            loadedOpenMediaInNewWindows = false
        }

        // Load remember image enhancements (default: true)
        let loadedRememberImageEnhancements = UserDefaults.standard.object(forKey: "rememberImageEnhancements") != nil
            ? UserDefaults.standard.bool(forKey: "rememberImageEnhancements")
            : true

        let loadedEnableStashTranscoding = loadBool("enableStashTranscoding", default: true)
        // Depth model preferences, split by role. Migrate the legacy single
        // "preferredDepthModelName" into both roles on first launch after the
        // split (the legacy key is also still read as a fallback by
        // CoreMLDepthProvider for anything not yet migrated).
        let legacyDepthModelName = UserDefaults.standard.string(forKey: "preferredDepthModelName") ?? ""
        let loadedRealtimeDepthModelName = UserDefaults.standard.string(forKey: "realtimeDepthModelName") ?? legacyDepthModelName
        let loadedPreprocessDepthModelName = UserDefaults.standard.string(forKey: "preprocessDepthModelName") ?? legacyDepthModelName
        let loadedDefaultRealtimePseudo3D = loadBool("defaultRealtimePseudo3D", default: false)
        let loadedVideoAutoplayMuted = loadBool("videoAutoplayMuted", default: true)

        // Load default image viewing mode (default: 2D / mono)
        let loadedDefaultImageViewingMode: DefaultImageViewingMode
        if let raw = UserDefaults.standard.string(forKey: "defaultImageViewingMode"),
           let mode = DefaultImageViewingMode(rawValue: raw) {
            loadedDefaultImageViewingMode = mode
        } else {
            loadedDefaultImageViewingMode = .mono
        }

        // Load 3D auto-restore (default: true)
        // Migrate from the prior "constrainImmersive3DToWindow" key (portal
        // attempt that never shipped enabled — drop its value on read).
        if UserDefaults.standard.object(forKey: "constrainImmersive3DToWindow") != nil {
            UserDefaults.standard.removeObject(forKey: "constrainImmersive3DToWindow")
        }
        let loadedFullyImmersive3DMode = UserDefaults.standard.object(forKey: "fullyImmersive3DMode") != nil
            ? UserDefaults.standard.bool(forKey: "fullyImmersive3DMode")
            : false
        let loadedAutoRestoreSpatial3D = UserDefaults.standard.object(forKey: "autoRestoreSpatial3D") != nil
            ? UserDefaults.standard.bool(forKey: "autoRestoreSpatial3D")
            : true

        // Load remote viewer (default: false)
        // Defaults to .stash so an existing install with a server keeps showing
        // exactly what it showed before this setting existed. tvOS has no such
        // installed base to preserve (added 2026-09-24), so a fresh Apple TV
        // picks its default from what's actually configured instead — see
        // `AppModel.defaultTVLibrarySource`.
        let loadedLibrarySource = UserDefaults.standard.string(forKey: "librarySource")
            .flatMap(LibrarySource.init(rawValue:))
            ?? {
                #if os(tvOS)
                return AppModel.defaultTVLibrarySource(
                    hasStashServer: !loadedServerURL.isEmpty,
                    hasNextcloudServer: !loadedNextcloudServerURL.isEmpty
                        && !loadedNextcloudUsername.isEmpty
                        && !loadedNextcloudAppPassword.isEmpty
                )
                #else
                return .stash
                #endif
            }()
        let loadedEnableRemoteViewer = UserDefaults.standard.bool(forKey: "enableRemoteViewer")

        // Unset means "never decided", which for an install that already has a
        // server or a settled photo-library prompt means "already set up".
        let loadedHasCompletedWelcome = UserDefaults.standard.object(forKey: "hasCompletedWelcome") as? Bool
            ?? (!loadedServerURL.isEmpty || PhotosAuthorization.status != .notDetermined)

        // Load debug console visibility (default: false)
        let loadedShowDebugConsole = UserDefaults.standard.bool(forKey: "showDebugConsole")

        // Load respect memory alerts (default: true)
        let loadedRespectMemoryAlerts = UserDefaults.standard.object(forKey: "respectMemoryAlerts") != nil
            ? UserDefaults.standard.bool(forKey: "respectMemoryAlerts")
            : true

        // Load lossy texture compression (default: false — opt-in since it's a quality tradeoff)
        let loadedUseLossyTextureCompression = UserDefaults.standard.object(forKey: "useLossyTextureCompression") != nil
            ? UserDefaults.standard.bool(forKey: "useLossyTextureCompression")
            : false

        // Load global visual adjustments
        let loadedGlobalVisualAdjustments: VisualAdjustments
        if let data = UserDefaults.standard.data(forKey: "globalVisualAdjustments"),
           let decoded = try? JSONDecoder().decode(VisualAdjustments.self, from: data) {
            loadedGlobalVisualAdjustments = decoded
        } else {
            loadedGlobalVisualAdjustments = VisualAdjustments()
        }

        let loadedGlobalPseudo3DSettings: Pseudo3DSettings
        if let data = UserDefaults.standard.data(forKey: "globalPseudo3DSettings"),
           let decoded = try? JSONDecoder().decode(Pseudo3DSettings.self, from: data) {
            loadedGlobalPseudo3DSettings = decoded
        } else {
            loadedGlobalPseudo3DSettings = .default
        }

        // Initialize stored properties
        self.stashServerURL = loadedServerURL
        self.stashAPIKey = loadedAPIKey
        self.nextcloudServerURL = loadedNextcloudServerURL
        self.nextcloudUsername = loadedNextcloudUsername
        self.nextcloudAppPassword = loadedNextcloudAppPassword
        self.nextcloudRoot = loadedNextcloudRoot
        self.autoHideDelay = loadedAutoHideDelay
        self.slideshowDelay = loadedSlideshowDelay
        self.slideshowShowClock = loadedSlideshowShowClock
        self.slideshowShowSensors = loadedSlideshowShowSensors
        self.slideshowUseAspectRatio = loadedSlideshowUseAspectRatio
        self.slideshowEnableKenBurns = loadedSlideshowEnableKenBurns
        self.slideshowEnableDynamicBrightness = loadedSlideshowEnableDynamicBrightness
        self.slideshowEnableDiorama = loadedSlideshowEnableDiorama
        self.slideshowTransparentBackground = loadedSlideshowTransparentBackground
        self.slideshowTextSize = loadedSlideshowTextSize
        self.slideshowMaxImageResolution2D = loadedSlideshowMaxImageResolution2D
        self.slideshowMaxImageResolution3D = loadedSlideshowMaxImageResolution3D
        self.maxImageResolution = loadedMaxImageResolution
        self.spatial3DMaxResolution = loadedSpatial3DMaxResolution
        self.dioramaDistance = loadedDioramaDistance
        self.reduceMotion = loadedReduceMotion
        self.thumbnailStyle = loadedThumbnailStyle
        self.roundedCorners = loadedRoundedCorners
        self.openMediaInNewWindows = loadedOpenMediaInNewWindows
        self.enableStashTranscoding = loadedEnableStashTranscoding
        self.realtimeDepthModelName = loadedRealtimeDepthModelName
        self.preprocessDepthModelName = loadedPreprocessDepthModelName
        self.defaultRealtimePseudo3D = loadedDefaultRealtimePseudo3D
        self.videoAutoplayMuted = loadedVideoAutoplayMuted
        self.rememberImageEnhancements = loadedRememberImageEnhancements
        self.autoRestoreSpatial3D = loadedAutoRestoreSpatial3D
        self.fullyImmersive3DMode = loadedFullyImmersive3DMode
        self.defaultImageViewingMode = loadedDefaultImageViewingMode
        self.librarySource = loadedLibrarySource
        self.hasCompletedWelcome = loadedHasCompletedWelcome
        self.enableRemoteViewer = loadedEnableRemoteViewer
        self.showDebugConsole = loadedShowDebugConsole
        self.respectMemoryAlerts = loadedRespectMemoryAlerts
        self.useLossyTextureCompression = loadedUseLossyTextureCompression
        self.globalVisualAdjustments = loadedGlobalVisualAdjustments
        self.globalPseudo3DSettings = loadedGlobalPseudo3DSettings

        // Initialize API client and image sources
        let client: StashAPIClient
        if !loadedServerURL.isEmpty, let url = URL(string: loadedServerURL) {
            // Use Stash server if configured
            let config = StashServerConfig(
                serverURL: url,
                apiKey: loadedAPIKey.isEmpty ? nil : loadedAPIKey
            )
            client = StashAPIClient(config: config)
            self.apiClient = client
            AppLogger.appModel.info("Init - Stash Server: \(loadedServerURL, privacy: .private), browsing \(loadedLibrarySource.rawValue, privacy: .public)")
        } else {
            // Fallback to example images if no server configured
            let defaultConfig = StashServerConfig.default
            client = StashAPIClient(config: defaultConfig)
            self.apiClient = client
            AppLogger.appModel.info("Init - No Stash Server configured, using standalone sources")
        }

        let nextcloud: NextcloudClient?
        if !loadedNextcloudServerURL.isEmpty, !loadedNextcloudUsername.isEmpty,
           !loadedNextcloudAppPassword.isEmpty,
           let url = URL(string: loadedNextcloudServerURL) {
            nextcloud = NextcloudClient(server: NextcloudServer(
                baseURL: url,
                username: loadedNextcloudUsername,
                appPassword: loadedNextcloudAppPassword,
                root: loadedNextcloudRoot))
        } else {
            nextcloud = nil
        }
        self.nextcloudClient = nextcloud

        // `effectiveLibrarySource` cannot be read yet — self is not fully
        // initialized — so its "fall back to Photos unless the stored choice is
        // actually available" rule is restated here and nowhere else. The
        // mapping from a choice to a pair of sources is `makeSources`, shared
        // with `applyLibrarySource`.
        let initialAvailable: [LibrarySource] = [.photos, .local]
            + (loadedServerURL.isEmpty ? [] : [.stash])
            + (nextcloud == nil ? [] : [.nextcloud])
        let initialSource: LibrarySource = initialAvailable.contains(loadedLibrarySource)
            ? loadedLibrarySource
            : .photos
        let initialSources = AppModel.makeSources(for: initialSource,
                                                  apiClient: client,
                                                  nextcloudClient: nextcloud)
        self.imageSource = initialSources.image
        self.videoSource = initialSources.video
        let entitlementProvider = EntitlementProviderFactory.make()
        self.entitlementProvider = entitlementProvider
        Task { await entitlementProvider.refresh() }

        // Now all stored properties are initialized, we can use self
        AppLogger.appModel.info("Init - Has API Key: \(!self.stashAPIKey.isEmpty, privacy: .public)")
        AppLogger.appModel.info("Init - Page Size: 30")

        // Mixable audio session so videos never interrupt other apps' audio.
        AudioSessionConfig.configureMixedPlayback()

        // The galleries have no other way to learn that the first index scan
        // finished: they loaded against an empty table.
        PhotosLibraryIndexer.shared.onIndexUpdated = { [weak self] in
            guard let self, self.effectiveLibrarySource == .photos else { return }
            Task { await self.reloadAllGalleries() }
        }

        // Launch is the one path that does not go through applyLibrarySource —
        // init builds the sources directly — so the index has to be kicked here
        // too. Without it a cold launch queries an index nothing ever built.
        if initialSource == .photos {
            PhotosLibraryIndexer.shared.start()
        }

        // Drain any depth model dropped into Documents (devicectl push / Files)
        // into the managed store so it's switchable/deletable like a download.
        DepthModelManager.shared.importInboxIfNeeded()

        // Load saved views and window groups from UserDefaults
        loadSavedViews()
        loadSavedVideoViews()
        loadSavedWindowGroups()
        loadSavedRemoteConfigs()
        modTagManager.load()

        // Apply default views on startup
        applyDefaultViewsOnStartup()

        // Start device telemetry if Console (dev mode) was already enabled —
        // property didSet doesn't fire for in-init assignment.
        updateDeviceTelemetry()

        // Same reason: the server settings were assigned during phase-1 init,
        // so their observers never ran and nothing registered the credentials.
        // Without this a cold launch leaves MediaAuthorization empty until the
        // user happens to edit the server settings, and every URL the app
        // authenticates client-side goes out unsigned — for Nextcloud, whose
        // URLs carry no credential of their own at all, that is every request.
        updateStashMediaCredential()
        updateNextcloudMediaCredential()
        // Jellyfin often shares the Stash host behind one reverse proxy;
        // keep the Stash key off its URLs from the first request on.
        FilmSession.excludeStoredServerFromOtherCredentials()

        // Monitor memory pressure and downscale windows that have been
        // backgrounded (not in active room) for at least 2 minutes.
        // Windows in the current room are never touched — the OS can
        // evict/restore GPU-private texture pages more efficiently than
        // app-level downscale-restore cycles.
        // Track system Accessibility "Reduce Motion" so effectiveReduceMotion
        // updates live when the user changes it outside the app.
        #if os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        // No `UIApplication.didReceiveMemoryWarningNotification` equivalent
        // on macOS — there's no per-app low-memory warning system the way
        // iOS has one (the `DispatchSource` memory-pressure monitor
        // elsewhere in this initializer covers macOS's own signal instead).
        #else
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.systemReduceMotion = UIAccessibility.isReduceMotionEnabled
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if self.respectMemoryAlerts {
                    AppLogger.appModel.warning("Memory warning received — downscaling long-backgrounded windows")

                    await ImageLoader.shared.clearMemoryCache()
                    await self.downscaleLongBackgroundedWindows()
                    // Light-touch slideshow trim: drop look-ahead +
                    // diorama working sets. Slideshow engines don't
                    // participate in the photo-viewer LRU idle-downscale
                    // because their continuous cycling naturally bounds
                    // memory.
                    for model in self.activeRemoteViewerModels.values {
                        model.trimForMemoryPressure()
                    }
                    SlideshowSyncHub.shared.emitTelemetryLog(
                        level: "warning",
                        domain: "memory",
                        message: "Memory warning — trimmed \(self.activeRemoteViewerModels.count) slideshow window(s), \(self.openPhotoWindowCount) photo window(s)"
                    )
                } else {
                    AppLogger.appModel.warning("Memory warning received — ignored (Respect System Memory Alerts is off)")
                }
            }
        }
        #endif

        // DispatchSource for logging memory pressure events.
        // Only listens for .critical — .warning events are left for the OS
        // to handle via its own page eviction, which is more granular than
        // app-level cache clearing.
        setupMemoryPressureSource()
    }

    // MARK: - DispatchSource Memory Pressure

    /// Dispatch source for system memory pressure events.
    /// Monitors .critical events for logging and diagnostics.
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private func setupMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data

            if event.contains(.critical) {
                AppLogger.appModel.warning("DispatchSource: critical memory pressure (respectMemoryAlerts=\(self.respectMemoryAlerts, privacy: .public))")
                // Unclaimed spatial-3D handoffs are pure cache — the windows
                // still showing an instance own it themselves.
                Spatial3DImageHandoff.shared.evictAll()
            } else if event.contains(.warning) {
                AppLogger.appModel.info("DispatchSource: warning memory pressure — no action (OS handles page eviction)")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Memory Pressure Downscale (Backgrounded Windows Only)

    /// Minimum duration a window must be outside the active room before
    /// memory pressure can downscale it.
    private static let backgroundedDownscaleThreshold: TimeInterval = 2 * 60 // 2 minutes

    /// Downscale photo windows that have been backgrounded (not in the active
    /// room) for longer than the threshold. Windows in the current room are
    /// never touched — the OS manages GPU-private texture page eviction more
    /// efficiently at that granularity.
    ///
    /// **Phase 1 — Release memory (no allocations):**
    /// Releases all heavy resources (textures, raw data, display images,
    /// background removal caches) without allocating anything new.
    ///
    /// **Phase 2 — Generate thumbnails:**
    /// After all targeted windows have freed their memory, loads small 256px
    /// thumbnails so windows show a recognizable preview instead of blank.
    private func downscaleLongBackgroundedWindows() async {
        let models = Array(activePhotoWindowModels.values)
        guard !models.isEmpty else { return }

        let now = Date()
        let threshold = Self.backgroundedDownscaleThreshold

        // Only target windows that are: not in active room, backgrounded for
        // longer than the threshold, not already downscaled, and not restoring.
        let eligible = models.filter { model in
            guard !model.isInActiveRoom,
                  !model.isIdleDownscaled,
                  !model.isRestoringFromIdle,
                  let since = model.backgroundedSince else { return false }
            return now.timeIntervalSince(since) >= threshold
        }

        guard !eligible.isEmpty else {
            let activeCount = models.filter { $0.isInActiveRoom }.count
            let recentBackgroundCount = models.filter { model in
                !model.isInActiveRoom && !model.isIdleDownscaled
                && (model.backgroundedSince.map { now.timeIntervalSince($0) < threshold } ?? true)
            }.count
            AppLogger.appModel.info(
                "Memory pressure: no eligible windows to downscale (\(activeCount, privacy: .public) active-room, \(recentBackgroundCount, privacy: .public) recently backgrounded, \(models.filter { $0.isIdleDownscaled }.count, privacy: .public) already downscaled)"
            )
            return
        }

        AppLogger.appModel.info(
            "Downscaling \(eligible.count, privacy: .public) of \(models.count, privacy: .public) windows (backgrounded > \(Int(threshold), privacy: .public)s)"
        )

        // Phase 1: Release all heavy memory first (no allocations)
        for model in eligible {
            await model.releaseMemoryForIdleDownscale()
        }

        // Phase 2: Now that memory is freed, generate small thumbnails
        for model in eligible {
            await model.applyIdleDownscaleThumbnail()
        }
    }

    // MARK: - Saved Views Persistence

    private static let savedViewsKey = "savedViews"

    private func loadSavedViews() {
        if let data = UserDefaults.standard.data(forKey: Self.savedViewsKey),
           let views = try? JSONDecoder().decode([SavedView].self, from: data) {
            savedViews = views
            AppLogger.appModel.info("Loaded \(views.count, privacy: .public) saved views")
        }
    }

    func saveSavedViews() {
        if let data = try? JSONEncoder().encode(savedViews) {
            UserDefaults.standard.set(data, forKey: Self.savedViewsKey)
            let count = savedViews.count
            AppLogger.appModel.info("Saved \(count, privacy: .public) views")
        }
    }

    func createSavedView(name: String) {
        let view = SavedView(name: name, filter: currentFilter, library: effectiveLibrarySource)
        savedViews.append(view)
        saveSavedViews()
    }

    func updateSavedView(_ view: SavedView, with filter: ImageFilterCriteria) {
        if let index = savedViews.firstIndex(where: { $0.id == view.id }) {
            savedViews[index].updateFilter(filter)
            saveSavedViews()
        }
    }

    func deleteSavedView(_ view: SavedView) {
        savedViews.removeAll { $0.id == view.id }
        if selectedSavedView?.id == view.id {
            selectedSavedView = nil
        }
        saveSavedViews()
    }

    func applySavedView(_ view: SavedView) {
        currentFilter = view.filter
        normalizeEmptyMultiSelectModifiers(&currentFilter)
        selectedSavedView = view
        Task {
            await loadInitialGallery()
        }
    }

    func deselectView() {
        currentFilter = ImageFilterCriteria()
        selectedSavedView = nil
        Task {
            await loadInitialGallery()
        }
    }

    /// Saved views describing the library currently being browsed.
    ///
    /// A Stash view and a Photos view have nothing to say to each other — the
    /// criteria they carry describe different data models — so each library
    /// lists only its own, and each gets its own default.
    var visibleSavedViews: [SavedView] {
        let library = effectiveLibrarySource
        return savedViews.filter { $0.library == library }
    }

    var visibleSavedVideoViews: [SavedVideoView] {
        let library = effectiveLibrarySource
        return savedVideoViews.filter { $0.library == library }
    }

    func setDefaultView(_ view: SavedView) {
        // Scoped to this view's own library, so the other library keeps its
        // default rather than silently losing it.
        for index in savedViews.indices where savedViews[index].library == view.library {
            savedViews[index].isDefault = false
        }
        // Set the new default
        if let index = savedViews.firstIndex(where: { $0.id == view.id }) {
            savedViews[index].isDefault = true
        }
        saveSavedViews()
    }

    func clearDefaultView() {
        let library = effectiveLibrarySource
        for index in savedViews.indices where savedViews[index].library == library {
            savedViews[index].isDefault = false
        }
        saveSavedViews()
    }

    // MARK: - Saved Video Views Persistence

    private static let savedVideoViewsKey = "savedVideoViews"

    private func loadSavedVideoViews() {
        if let data = UserDefaults.standard.data(forKey: Self.savedVideoViewsKey),
           let views = try? JSONDecoder().decode([SavedVideoView].self, from: data) {
            savedVideoViews = views
            AppLogger.appModel.info("Loaded \(views.count, privacy: .public) saved video views")
        }
    }

    func saveSavedVideoViews() {
        if let data = try? JSONEncoder().encode(savedVideoViews) {
            UserDefaults.standard.set(data, forKey: Self.savedVideoViewsKey)
            let count = savedVideoViews.count
            AppLogger.appModel.info("Saved \(count, privacy: .public) video views")
        }
    }

    func createSavedVideoView(name: String) {
        let view = SavedVideoView(name: name, filter: currentVideoFilter, library: effectiveLibrarySource)
        savedVideoViews.append(view)
        saveSavedVideoViews()
    }

    func updateSavedVideoView(_ view: SavedVideoView, with filter: SceneFilterCriteria) {
        if let index = savedVideoViews.firstIndex(where: { $0.id == view.id }) {
            savedVideoViews[index].updateFilter(filter)
            saveSavedVideoViews()
        }
    }

    func deleteSavedVideoView(_ view: SavedVideoView) {
        savedVideoViews.removeAll { $0.id == view.id }
        if selectedSavedVideoView?.id == view.id {
            selectedSavedVideoView = nil
        }
        saveSavedVideoViews()
    }

    func applySavedVideoView(_ view: SavedVideoView) {
        currentVideoFilter = view.filter
        normalizeEmptyMultiSelectModifiers(&currentVideoFilter)
        selectedSavedVideoView = view
        Task {
            await loadInitialVideos()
        }
    }

    func deselectVideoView() {
        currentVideoFilter = SceneFilterCriteria()
        selectedSavedVideoView = nil
        Task {
            await loadInitialVideos()
        }
    }

    func setDefaultVideoView(_ view: SavedVideoView) {
        for index in savedVideoViews.indices where savedVideoViews[index].library == view.library {
            savedVideoViews[index].isDefault = false
        }
        // Set the new default
        if let index = savedVideoViews.firstIndex(where: { $0.id == view.id }) {
            savedVideoViews[index].isDefault = true
        }
        saveSavedVideoViews()
    }

    func clearDefaultVideoView() {
        let library = effectiveLibrarySource
        for index in savedVideoViews.indices where savedVideoViews[index].library == library {
            savedVideoViews[index].isDefault = false
        }
        saveSavedVideoViews()
    }

    // MARK: - Saved Window Groups Persistence

    var savedWindowGroups: [SavedWindowGroup] = []
    private static let savedWindowGroupsKey = "savedWindowGroups"

    private func loadSavedWindowGroups() {
        if let data = UserDefaults.standard.data(forKey: Self.savedWindowGroupsKey),
           var groups = try? JSONDecoder().decode([SavedWindowGroup].self, from: data) {
            for groupIndex in groups.indices {
                // Drop entries this build can't restore (a kind written by a
                // newer version) rather than showing dead tiles, and re-resolve
                // local file URLs — the app sandbox container UUID changes on
                // every launch, so persisted absolute file URLs go stale.
                groups[groupIndex].entries = groups[groupIndex].entries
                    .filter(\.isRestorable)
                    .map { $0.resolvingLocalFileURLs() }
            }
            savedWindowGroups = groups
            persistSavedWindowGroups()
            AppLogger.windowState.info("Loaded \(groups.count, privacy: .public) saved window groups")
        }
    }

    private func loadSavedRemoteConfigs() {
        if let data = UserDefaults.standard.data(forKey: "savedRemoteConfigs"),
           let configs = try? JSONDecoder().decode([RemoteViewerConfig].self, from: data) {
            savedRemoteConfigs = configs
            AppLogger.remoteViewer.info("Loaded \(configs.count, privacy: .public) saved remote configs")
            refreshAllRemoteHistoryStores()
        }

        loadImplicitSlideshowConfig(key: Self.gallerySlideshowConfigKey) { self.gallerySlideshowConfig = $0 }
        loadImplicitSlideshowConfig(key: Self.videoSlideshowConfigKey) { self.videoSlideshowConfig = $0 }
        adoptStrandedImplicitSlideshowConfigs()
    }

    private func loadImplicitSlideshowConfig(key: String, assign: (RemoteViewerConfig) -> Void) {
        guard let data = UserDefaults.standard.data(forKey: key),
              var config = try? JSONDecoder().decode(RemoteViewerConfig.self, from: data) else { return }
        // These slots are always the app-content slideshow, whatever mode they
        // were stored with — they predate `.appGallery`, and a `.slideshow`
        // profile with no endpoint is refused now.
        config.mode = .appGallery
        assign(config)
    }

    /// Reclaim the gallery/video slideshow profiles that older builds leaked
    /// into the saved list.
    ///
    /// Those two profiles were never persisted in their own right, so each
    /// launch minted a fresh one, and the first ornament tweak in the resulting
    /// window appended it to `savedRemoteConfigs` — one throwaway row per
    /// launch, in the list that's supposed to hold profiles the user made. The
    /// newest of each kind becomes the profile for its slot (so its display
    /// settings survive) and the rest are dropped. Matched narrowly: our own
    /// name, blank endpoint, slideshow mode.
    private func adoptStrandedImplicitSlideshowConfigs() {
        func reclaim(name: String, slot: RemoteViewerConfig?) -> RemoteViewerConfig? {
            let stranded = savedRemoteConfigs.filter {
                $0.name == name && $0.mode == .slideshow && $0.apiEndpoint.isEmpty
            }
            guard !stranded.isEmpty else { return nil }
            savedRemoteConfigs.removeAll { config in stranded.contains { $0.id == config.id } }
            AppLogger.remoteViewer.info(
                "Reclaimed \(stranded.count, privacy: .public) stranded “\(name, privacy: .public)” config(s) from the saved list"
            )
            // A slot restored from its own key wins — it's the one the
            // slideshow has actually been using since the leak was fixed.
            guard slot == nil, var adopted = stranded.max(by: { $0.savedDate < $1.savedDate }) else {
                return nil
            }
            adopted.mode = .appGallery
            return adopted
        }

        if let adopted = reclaim(name: "Gallery Slideshow", slot: gallerySlideshowConfig) {
            gallerySlideshowConfig = adopted
        }
        if let adopted = reclaim(name: "Video Slideshow", slot: videoSlideshowConfig) {
            videoSlideshowConfig = adopted
        }
    }

    func persistSavedWindowGroups() {
        if let data = try? JSONEncoder().encode(savedWindowGroups) {
            UserDefaults.standard.set(data, forKey: Self.savedWindowGroupsKey)
            let count = savedWindowGroups.count
            AppLogger.windowState.info("Persisted \(count, privacy: .public) saved window groups")
        }
    }

    // MARK: - Snapshotting Open Windows

    /// Every currently-open standalone window, as group entries, each carrying
    /// the geometry that window is at right now.
    ///
    /// Sizes come from `RestoredWindowTracker`, which every window type writes
    /// its settled size into: it's the one store that's already kept in lockstep
    /// with the live geometry for photo, video and Remote windows alike. A window
    /// that hasn't reported a size yet yields `nil`, and restores at its natural
    /// size rather than a guess.
    var openWindowEntries: [SavedWindowEntry] {
        var entries: [SavedWindowEntry] = []

        for value in openPopOutWindows.values.flatMap({ $0 }) {
            entries.append(.photo(value.image, size: RestoredWindowTracker.windowSize(for: value.id)))
        }

        for value in openVideoWindows.values.flatMap({ $0 }) {
            entries.append(.video(
                value.video,
                size: RestoredWindowTracker.windowSize(for: value.id),
                stereoscopicOverride: value.stereoscopicOverride,
                settings3D: value.video3DSettings,
                pseudo3DEnabled: value.pseudo3DEnabled,
                pseudo3DSettings: value.pseudo3DSettings
            ))
        }

        for value in openRemoteViewerWindows.values.flatMap({ $0 }) {
            guard let config = remoteViewerConfig(id: value.configId) else { continue }
            entries.append(.remote(
                configId: config.id,
                name: config.name,
                detail: Self.remoteIdentityDetail(for: config),
                isWebPage: config.mode == .webPage,
                size: RestoredWindowTracker.windowSize(for: value.id)
            ))
        }

        return entries
    }

    /// Short identity for a Remote profile — the RoboFrame device id for a
    /// slideshow, the page host for a pinned web page. Mirrors what each
    /// window's ornament shows so a saved entry and a live window read alike.
    static func remoteIdentityDetail(for config: RemoteViewerConfig) -> String? {
        if config.mode == .webPage {
            return config.resolvedWebPageURL?.host ?? config.webPageURL
        }
        let deviceId = config.wsDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !deviceId.isEmpty { return deviceId }
        if config.apiEndpoint.trimmingCharacters(in: .whitespaces).isEmpty { return "Gallery" }
        return URL(string: config.apiEndpoint)?.host
    }

    // MARK: - Saved Window Group Mutations

    func saveCurrentWindowGroup(name: String) {
        let entries = openWindowEntries
        guard !entries.isEmpty else { return }
        let group = SavedWindowGroup(name: name, entries: entries)
        savedWindowGroups.append(group)
        persistSavedWindowGroups()
        AppLogger.windowState.info("Saved window group '\(name, privacy: .public)' with \(entries.count, privacy: .public) windows (\(group.contentSummary, privacy: .public))")
    }

    func deleteSavedWindowGroup(_ group: SavedWindowGroup) {
        savedWindowGroups.removeAll { $0.id == group.id }
        persistSavedWindowGroups()
    }

    func renameSavedWindowGroup(_ group: SavedWindowGroup, newName: String) {
        if let index = savedWindowGroups.firstIndex(where: { $0.id == group.id }) {
            savedWindowGroups[index].name = newName
            persistSavedWindowGroups()
        }
    }

    func removeEntriesFromWindowGroup(_ group: SavedWindowGroup, entryIds: Set<UUID>) {
        guard !entryIds.isEmpty,
              let groupIndex = savedWindowGroups.firstIndex(where: { $0.id == group.id }) else { return }
        savedWindowGroups[groupIndex].entries.removeAll { entryIds.contains($0.id) }
        if savedWindowGroups[groupIndex].entries.isEmpty {
            savedWindowGroups.remove(at: groupIndex)
        }
        persistSavedWindowGroups()
        AppLogger.windowState.info("Removed \(entryIds.count, privacy: .public) windows from group '\(group.name, privacy: .public)'")
    }

    func addEntriesToWindowGroup(_ group: SavedWindowGroup, entries: [SavedWindowEntry]) {
        guard !entries.isEmpty,
              let groupIndex = savedWindowGroups.firstIndex(where: { $0.id == group.id }) else { return }
        savedWindowGroups[groupIndex].entries.append(contentsOf: entries)
        persistSavedWindowGroups()
        AppLogger.windowState.info("Added \(entries.count, privacy: .public) windows to group '\(group.name, privacy: .public)'")
    }

    /// Open windows not already represented in this group, offered by the
    /// "add from open windows" picker.
    func openWindowEntriesNotInGroup(_ group: SavedWindowGroup) -> [SavedWindowEntry] {
        let existing = Set(group.entries.map(\.dedupeKey))
        return openWindowEntries.filter { !existing.contains($0.dedupeKey) }
    }

    // MARK: - Restoring Window Groups

    /// Whether a window showing this entry's content is already on screen.
    func hasOpenWindow(for entry: SavedWindowEntry) -> Bool {
        switch entry.kind {
        case .photo:
            guard let image = entry.image else { return false }
            return hasOpenPopOutWindow(for: image.fullSizeURL)
        case .video:
            guard let video = entry.video else { return false }
            return hasOpenVideoWindow(for: video)
        case .remote:
            guard let configId = entry.remoteConfigId else { return false }
            return !remoteViewerWindowValues(for: configId).isEmpty
        case .unknown:
            return false
        }
    }

    /// Open one saved window at the geometry it was saved at.
    ///
    /// - Parameter bypassDuplicatePrompt: skip the "window already open" dialog
    ///   for the kinds that have one, e.g. after the user chose "Open New".
    func restoreWindowEntry(_ entry: SavedWindowEntry, bypassDuplicatePrompt: Bool = false) {
        let size = entry.size?.cgSize

        switch entry.kind {
        case .photo:
            guard let image = entry.image else { return }
            enqueuePhotoWindowOpen(
                image,
                bypassDuplicatePrompt: bypassDuplicatePrompt,
                restoredSize: size
            )

        case .video:
            guard let video = entry.video else { return }
            var value = VideoWindowValue(
                video: video,
                stereoscopicOverride: entry.videoStereoscopicOverride,
                video3DSettings: entry.video3DSettings,
                pseudo3DEnabled: entry.videoPseudo3DEnabled,
                pseudo3DSettings: entry.videoPseudo3DSettings
            )
            value.restoredSize = size.map(RAVECodableSize.init)
            enqueueVideoWindowOpen(value)

        case .remote:
            guard let configId = entry.remoteConfigId, remoteViewerConfig(id: configId) != nil else {
                AppLogger.windowState.warning("Skipping restore of Remote window: profile \(entry.remoteConfigId?.uuidString ?? "?", privacy: .public) no longer exists")
                return
            }
            enqueueRemoteViewerOpen(
                configId: configId,
                bypassDuplicatePrompt: bypassDuplicatePrompt,
                restoredSize: size
            )

        case .unknown:
            break
        }
    }

    /// Restore every window in the group, staggered so visionOS places them one
    /// at a time instead of stacking them all at the same spot.
    func restoreWindowGroup(_ group: SavedWindowGroup) {
        Task { @MainActor in
            for entry in group.entries where entry.isRestorable {
                restoreWindowEntry(entry, bypassDuplicatePrompt: true)
                try? await Task.sleep(for: .seconds(0.3))
            }
            AppLogger.windowState.info("Restored all \(group.entries.count, privacy: .public) windows from group '\(group.name, privacy: .public)'")
        }
    }

    /// Update the image tracked for a pop-out window (called when user navigates prev/next)
    func updatePopOutWindowImage(windowValueId: UUID, oldImageURL: URL, newImage: GalleryImage) {
        let oldKey = oldImageURL.absoluteString
        let newKey = newImage.fullSizeURL.absoluteString

        // Remove from old URL key
        if var values = openPopOutWindows[oldKey] {
            if let index = values.firstIndex(where: { $0.id == windowValueId }) {
                var windowValue = values.remove(at: index)
                windowValue.image = newImage

                // Add under new URL key
                var newValues = openPopOutWindows[newKey] ?? []
                newValues.append(windowValue)
                openPopOutWindows[newKey] = newValues
            }
            if values.isEmpty {
                openPopOutWindows.removeValue(forKey: oldKey)
            } else {
                openPopOutWindows[oldKey] = values
            }
        }
    }

    // MARK: - Default Views Application

    private func applyDefaultViewsOnStartup() {
        // Apply default image view if one exists
        if let defaultImageView = visibleSavedViews.first(where: { $0.isDefault }) {
            currentFilter = defaultImageView.filter
            normalizeEmptyMultiSelectModifiers(&currentFilter)
            selectedSavedView = defaultImageView
            AppLogger.appModel.info("Applied default image view: \(defaultImageView.name, privacy: .public)")
        }

        // Apply default video view if one exists
        if let defaultVideoView = visibleSavedVideoViews.first(where: { $0.isDefault }) {
            currentVideoFilter = defaultVideoView.filter
            normalizeEmptyMultiSelectModifiers(&currentVideoFilter)
            selectedSavedVideoView = defaultVideoView
            AppLogger.appModel.info("Applied default video view: \(defaultVideoView.name, privacy: .public)")
        }
    }

    private func normalizeEmptyMultiSelectModifiers(_ filter: inout ImageFilterCriteria) {
        if filter.selectedGalleries.isEmpty {
            filter.galleryModifier = .includesAll
        }
        if filter.selectedTags.isEmpty {
            filter.tagModifier = .includesAll
        }
        if filter.selectedStudios.isEmpty {
            filter.studioModifier = .includesAll
        }
        if filter.selectedPerformers.isEmpty {
            filter.performerModifier = .includesAll
        }
    }

    private func normalizeEmptyMultiSelectModifiers(_ filter: inout SceneFilterCriteria) {
        if filter.selectedGalleries.isEmpty {
            filter.galleryModifier = .includesAll
        }
        if filter.selectedTags.isEmpty {
            filter.tagModifier = .includesAll
        }
        if filter.selectedStudios.isEmpty {
            filter.studioModifier = .includesAll
        }
        if filter.selectedPerformers.isEmpty {
            filter.performerModifier = .includesAll
        }
    }

    // MARK: - Settings Backup

    func exportSettingsBackup() async -> SettingsBackup {
        let video3DData = await Video3DSettingsTracker.shared.exportData()
        let imageEnhancementData = await ImageEnhancementTracker.shared.exportData()

        var backup = SettingsBackup(
            version: SettingsBackup.currentVersion,
            exportDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            stashServerURL: stashServerURL,
            // Deliberately nil: a backup is a file the user mails and AirDrops
            // around, and it must not carry a server credential. See
            // SettingsBackup.stashAPIKey.
            stashAPIKey: nil,
            nextcloudServerURL: nextcloudServerURL,
            nextcloudUsername: nextcloudUsername,
            nextcloudRoot: nextcloudRoot,
            autoHideDelay: autoHideDelay,
            slideshowDelay: slideshowDelay,
            slideshowShowClock: slideshowShowClock,
            slideshowShowSensors: slideshowShowSensors,
            slideshowUseAspectRatio: slideshowUseAspectRatio,
            slideshowEnableKenBurns: slideshowEnableKenBurns,
            slideshowEnableDynamicBrightness: slideshowEnableDynamicBrightness,
            slideshowEnableDiorama: slideshowEnableDiorama,
            slideshowTransparentBackground: slideshowTransparentBackground,
            slideshowTextSize: slideshowTextSize,
            slideshowMaxImageResolution2D: slideshowMaxImageResolution2D,
            slideshowMaxImageResolution3D: slideshowMaxImageResolution3D,
            maxImageResolution: maxImageResolution,
            spatial3DMaxResolution: spatial3DMaxResolution,
            dioramaDistance: dioramaDistance,
            roundedCorners: roundedCorners,
            openMediaInNewWindows: openMediaInNewWindows,
            rememberImageEnhancements: rememberImageEnhancements,
            autoRestoreSpatial3D: autoRestoreSpatial3D,
            fullyImmersive3DMode: fullyImmersive3DMode,
            showDebugConsole: showDebugConsole,
            respectMemoryAlerts: respectMemoryAlerts,
            enableRemoteViewer: enableRemoteViewer,
            librarySource: librarySource.rawValue,
            savedViews: savedViews,
            savedVideoViews: savedVideoViews,
            savedWindowGroups: savedWindowGroups,
            savedRemoteConfigs: savedRemoteConfigs,
            // The tag list (catalog and current selection) is fully
            // server-tracked, so nothing about it is exported. These legacy
            // global fields are left nil for backward-compatible decoding of
            // older backups.
            tagLists: nil,
            tagListDefaultIndex: nil,
            tagListLastActiveIndex: nil,
            video3DSettings: video3DData,
            imageEnhancementConvertedURLs: imageEnhancementData.convertedURLs,
            imageEnhancementLastViewingModes: imageEnhancementData.lastViewingModes,
            imageEnhancementFlippedURLs: imageEnhancementData.flippedURLs,
            imageEnhancementResolutionOverrides: imageEnhancementData.resolutionOverrides,
            imageEnhancementSpatial3DResolutionOverrides: imageEnhancementData.spatial3DResolutionOverrides,
            imageEnhancementWindowSizes: imageEnhancementData.windowSizes,
            globalVisualAdjustments: try? JSONEncoder().encode(globalVisualAdjustments),
            imageEnhancementAdjustments: imageEnhancementData.adjustments,
            thumbnailStyle: thumbnailStyle.rawValue,
            reduceMotion: reduceMotion,
            defaultImageViewingMode: defaultImageViewingMode.rawValue,
            enableStashTranscoding: enableStashTranscoding,
            realtimeDepthModelName: realtimeDepthModelName,
            preprocessDepthModelName: preprocessDepthModelName,
            defaultRealtimePseudo3D: defaultRealtimePseudo3D,
            videoAutoplayMuted: videoAutoplayMuted,
            useLossyTextureCompression: useLossyTextureCompression,
            globalPseudo3DSettings: try? JSONEncoder().encode(globalPseudo3DSettings),
            cacheSizePreset: UserDefaults.standard.string(forKey: CacheBudget.presetKey)
        )
        return backup
    }

    func importSettingsBackup(_ backup: SettingsBackup) async {
        // Simple settings — only apply if present in backup
        if let v = backup.stashServerURL { stashServerURL = v }
        if let v = backup.stashAPIKey { stashAPIKey = v }
        if let v = backup.nextcloudServerURL { nextcloudServerURL = v }
        if let v = backup.nextcloudUsername { nextcloudUsername = v }
        if let v = backup.nextcloudRoot { nextcloudRoot = v }
        if let v = backup.autoHideDelay { autoHideDelay = v }
        if let v = backup.slideshowDelay { slideshowDelay = v }
        if let v = backup.slideshowShowClock { slideshowShowClock = v }
        if let v = backup.slideshowShowSensors { slideshowShowSensors = v }
        if let v = backup.slideshowUseAspectRatio { slideshowUseAspectRatio = v }
        if let v = backup.slideshowEnableKenBurns { slideshowEnableKenBurns = v }
        if let v = backup.slideshowEnableDynamicBrightness { slideshowEnableDynamicBrightness = v }
        if let v = backup.slideshowEnableDiorama { slideshowEnableDiorama = v }
        if let v = backup.slideshowTransparentBackground { slideshowTransparentBackground = v }
        if let v = backup.slideshowTextSize { slideshowTextSize = v }
        if let v = backup.slideshowMaxImageResolution2D { slideshowMaxImageResolution2D = v }
        if let v = backup.slideshowMaxImageResolution3D { slideshowMaxImageResolution3D = v }
        if let v = backup.maxImageResolution { maxImageResolution = v }
        if let v = backup.spatial3DMaxResolution { spatial3DMaxResolution = v }
        if let v = backup.dioramaDistance { dioramaDistance = v }
        if let v = backup.roundedCorners { roundedCorners = v }
        if let v = backup.openMediaInNewWindows ?? backup.openImagesInSeparateWindows { openMediaInNewWindows = v }
        if let v = backup.rememberImageEnhancements { rememberImageEnhancements = v }
        if let v = backup.autoRestoreSpatial3D { autoRestoreSpatial3D = v }
        if let v = backup.fullyImmersive3DMode { fullyImmersive3DMode = v }
        if let v = backup.showDebugConsole { showDebugConsole = v }
        if let v = backup.respectMemoryAlerts { respectMemoryAlerts = v }
        if let v = backup.enableRemoteViewer { enableRemoteViewer = v }
        if let v = backup.librarySource.flatMap(LibrarySource.init(rawValue:)) { librarySource = v }
        if let raw = backup.thumbnailStyle, let style = ThumbnailStyle(rawValue: raw) { thumbnailStyle = style }
        if let v = backup.reduceMotion { reduceMotion = v }
        if let raw = backup.defaultImageViewingMode, let mode = DefaultImageViewingMode(rawValue: raw) { defaultImageViewingMode = mode }
        if let v = backup.enableStashTranscoding { enableStashTranscoding = v }
        if let v = backup.realtimeDepthModelName { realtimeDepthModelName = v }
        if let v = backup.preprocessDepthModelName { preprocessDepthModelName = v }
        if let v = backup.defaultRealtimePseudo3D { defaultRealtimePseudo3D = v }
        if let v = backup.videoAutoplayMuted { videoAutoplayMuted = v }
        if let v = backup.useLossyTextureCompression { useLossyTextureCompression = v }
        if let data = backup.globalPseudo3DSettings,
           let loaded = try? JSONDecoder().decode(Pseudo3DSettings.self, from: data) {
            globalPseudo3DSettings = loaded
        }
        if let raw = backup.cacheSizePreset, CacheSizePreset(rawValue: raw) != nil {
            UserDefaults.standard.set(raw, forKey: CacheBudget.presetKey)
        }

        // Complex settings
        if let v = backup.savedViews {
            savedViews = v
            saveSavedViews()
        }
        if let v = backup.savedVideoViews {
            savedVideoViews = v
            saveSavedVideoViews()
        }
        if let v = backup.savedWindowGroups {
            savedWindowGroups = v
            persistSavedWindowGroups()
        }
        if let v = backup.savedRemoteConfigs {
            savedRemoteConfigs = v
        }
        // Tag list selection is per-profile now and travels inside
        // savedRemoteConfigs. The legacy global `tagListDefaultIndex` from
        // older backups is intentionally ignored (it can't sensibly map onto
        // a specific profile, and per-profile values already restored above).

        // Actor-based trackers
        if let settings = backup.video3DSettings {
            await Video3DSettingsTracker.shared.importData(settings)
        }
        if let urls = backup.imageEnhancementConvertedURLs,
           let modes = backup.imageEnhancementLastViewingModes {
            await ImageEnhancementTracker.shared.importData(
                convertedURLs: urls,
                lastViewingModes: modes,
                flippedURLs: backup.imageEnhancementFlippedURLs,
                resolutionOverrides: backup.imageEnhancementResolutionOverrides,
                spatial3DResolutionOverrides: backup.imageEnhancementSpatial3DResolutionOverrides,
                windowSizes: backup.imageEnhancementWindowSizes,
                adjustments: backup.imageEnhancementAdjustments
            )
        }

        // Global visual adjustments
        if let data = backup.globalVisualAdjustments,
           let loaded = try? JSONDecoder().decode(VisualAdjustments.self, from: data) {
            globalVisualAdjustments = loaded
        }

        // Reconnect API client with potentially updated server config
        updateAPIClient()
    }

    // MARK: - API Client Management

    /// Opens a new main gallery window.
    /// Each call creates a fresh instance (UUID-keyed WindowGroup).
    func showMainWindow(openWindow: WindowOpenAction) {
        openWindow(id: "main", value: UUID())
    }

    /// Seeds the shared filter with a single tag and opens a new main gallery
    /// window focused on the matching content tab. `isVideo` picks the Videos
    /// tab + scene filter; otherwise the Pictures tab + image filter. The new
    /// window's `ContentView` consumes `pendingGalleryFilter` on appear to
    /// switch tabs and run the query.
    func openGalleryFilteredByTag(id tagId: String, name tagName: String, isVideo: Bool, openWindow: WindowOpenAction) {
        let item = AutocompleteItem(id: tagId, name: tagName)
        if isVideo {
            currentVideoFilter.clearFilters()
            currentVideoFilter.selectedTags = [item]
        } else {
            currentFilter.clearFilters()
            currentFilter.selectedTags = [item]
        }
        pendingGalleryFilter = PendingGalleryFilter(isVideo: isVideo)
        openWindow(id: "main", value: UUID())
    }

    /// Confirms a server answers, returning how many images it reports.
    ///
    /// Takes the credentials as parameters and does **not** store them, because
    /// the two callers want opposite orderings: Settings edits a server already
    /// in use, while the welcome flow is choosing one and must not switch the
    /// app onto a URL that turns out to be wrong. Committing is
    /// `commitStashServer(url:apiKey:)`, called only once this has succeeded.
    ///
    /// Queries through a GraphQL source built here rather than `imageSource`:
    /// the live source is whatever the current library says, so on Photos a
    /// "test the server" button was testing the photo library.
    func verifyStashServer(url urlString: String, apiKey: String) async throws -> Int {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            throw ImageSourceError.invalidURL(urlString)
        }
        let config = StashServerConfig(
            serverURL: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await apiClient.updateConfig(config)
        let result = try await GraphQLImageSource(apiClient: apiClient).fetchImages(page: 0, pageSize: 1)
        let count = result.totalCount ?? result.images.count

        // A successful metadata query only proves the key's claims are
        // accepted by GraphQL. Stash's media endpoints (images, thumbnails,
        // streams) separately re-verify the key via a signed-URL check, which
        // a key issued against a since-rotated server signing secret can fail
        // even while every GraphQL query keeps succeeding — this silently
        // broke every image/video/thumbnail in the app on 2026-09-24 while
        // this same check kept reporting "Connected." `updateAPIClient()` is
        // always called just before this (see the "Apply & Test Connection"
        // button), so `MediaAuthorization` already carries the credential
        // being tested here. `bypassCache: true` is required — a thumbnail
        // fetched successfully before the key broke would otherwise still be
        // sitting in disk cache and mask the failure.
        if let firstImage = result.images.first {
            guard (try? await ImageLoader.shared.loadRawData(from: firstImage.thumbnailURL, bypassCache: true)) != nil else {
                throw ImageSourceError.mediaAuthenticationFailed
            }
        }

        return count
    }

    /// Stores verified server credentials and starts browsing them.
    ///
    /// `stashServerURL` is assigned last on purpose: its observer is the one
    /// that rebuilds the sources, so letting it run after the key and the
    /// library choice are in place means the rebuild sees the finished state.
    func commitStashServer(url: String, apiKey: String) {
        // Configuring a server is the moment the app first needs the LAN, and
        // the UI is unambiguously up by now, so this is the in-context prompt.
        LocalNetworkPermission.prewarm(reason: "Stash server configured")
        stashAPIKey = apiKey
        librarySource = .stash
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == stashServerURL {
            // Same URL as before: no observer will fire, so nothing would pick
            // up the new key or library choice without asking directly.
            applyLibrarySource()
        } else {
            stashServerURL = trimmed
        }
    }

    func updateAPIClient() {
        updateStashMediaCredential()
        if !stashServerURL.isEmpty, let url = URL(string: stashServerURL) {
            // Update with Stash server config
            let config = StashServerConfig(
                serverURL: url,
                apiKey: stashAPIKey.isEmpty ? nil : stashAPIKey
            )
            let hasKey = !stashAPIKey.isEmpty
            AppLogger.appModel.info("Updating API client with URL: \(url, privacy: .private), hasAPIKey: \(hasKey, privacy: .public)")
            Task {
                await apiClient.updateConfig(config)
                // Routed through applyLibrarySource so a server edit respects
                // the current library choice. The video source was also
                // previously left alone here, so clearing a server URL kept
                // serving videos from the old GraphQL source.
                self.applyLibrarySource()
            }
        } else {
            // No server URL — fall back to the device photo library.
            AppLogger.appModel.info("No Stash Server URL configured, using the photo library")
            applyLibrarySource()
        }
    }

    /// Keeps `MediaAuthorization` in sync with the configured Stash server,
    /// so `ImageLoader`, the video players and the animated-image view can
    /// authenticate requests without any of them holding a reference to
    /// `AppModel`. Called from both `stashServerURL` and `stashAPIKey`'s
    /// observers via `updateAPIClient()`.
    ///
    /// A key prefixed `Bearer ` is a manual escape hatch (paste
    /// `Bearer <token>` into the field) for the header-auth path instead of
    /// the ordinary `?apikey=` query param — previously honored only by the
    /// animated-image WebView, now uniform across every consumer since they
    /// all resolve through the same registry.
    /// Whether a Nextcloud server is configured well enough to browse.
    ///
    /// All three parts are required: the username is part of every DAV path,
    /// and the app password is the only credential (Nextcloud has no
    /// unauthenticated media endpoint the way a guest-readable Stash does).
    var hasNextcloudServer: Bool {
        !nextcloudServerURL.isEmpty && !nextcloudUsername.isEmpty && !nextcloudAppPassword.isEmpty
    }

    #if os(tvOS)
    /// The library a fresh Apple TV install should open to, when nothing has
    /// been persisted yet. Unlike the iOS/visionOS default (`.stash`, kept only
    /// to preserve an existing install's behavior — see the call site), tvOS
    /// has no installed base predating this setting, so it can pick the
    /// sensible order directly: a configured server first (Stash, then
    /// Nextcloud), else Photos when the library is actually usable, else Local
    /// — Apple TV commonly has no iCloud Photos library at all (see
    /// `Hypnos/CLAUDE.md` "tvOS" → Known gaps), so a denied/restricted Photos
    /// library should not be the tab a first launch lands on.
    static func defaultTVLibrarySource(hasStashServer: Bool, hasNextcloudServer: Bool) -> LibrarySource {
        if hasStashServer { return .stash }
        if hasNextcloudServer { return .nextcloud }
        return PhotosAuthorization.isReadable ? .photos : .local
    }
    #endif

    /// Rebuilds the Nextcloud client and registers its credential.
    ///
    /// The registration is what makes every URL these sources hand out work:
    /// a Nextcloud preview or download URL carries no credential of its own —
    /// unlike Stash, which bakes its key into the URLs it returns — so the
    /// image loader and the video players authenticate by host at request
    /// time. Without this the grid would be a wall of 401s.
    func updateNextcloudClient() {
        updateNextcloudMediaCredential()
        guard let server = currentNextcloudServer else {
            nextcloudClient = nil
            applyLibrarySource()
            return
        }

        // Reuse the existing actor when only the server details changed, so a
        // root switch mid-browse doesn't strand in-flight requests against a
        // client nothing holds any more.
        if let client = nextcloudClient {
            Task { await client.updateServer(server) }
        } else {
            nextcloudClient = NextcloudClient(server: server)
        }
        AppLogger.appModel.info("Nextcloud client updated (root: \(self.nextcloudRoot, privacy: .public))")
        applyLibrarySource()
    }

    /// The configured server, or nil when any required part is missing.
    private var currentNextcloudServer: NextcloudServer? {
        guard hasNextcloudServer, let baseURL = URL(string: nextcloudServerURL) else { return nil }
        return NextcloudServer(baseURL: baseURL,
                               username: nextcloudUsername,
                               appPassword: nextcloudAppPassword,
                               root: nextcloudRoot)
    }

    /// Registers the Basic credential for the Nextcloud host, mirroring
    /// `updateStashMediaCredential`. Split out of `updateNextcloudClient` so
    /// `init` can register without also triggering the source rebuild that
    /// init does directly.
    private func updateNextcloudMediaCredential() {
        // Clearing the username or password leaves the URL — and so the host —
        // in place, so an incomplete configuration has to drop the credential
        // here rather than only in the URL's observer.
        guard let server = currentNextcloudServer, let host = server.baseURL.host else {
            if let staleHost = URL(string: nextcloudServerURL)?.host {
                MediaAuthorization.shared.unregister(host: staleHost)
            }
            return
        }
        MediaAuthorization.shared.register(
            host: host,
            credential: .header(name: "Authorization", value: server.authorizationHeader))
    }

    private func updateStashMediaCredential() {
        guard !stashServerURL.isEmpty, let host = URL(string: stashServerURL)?.host else { return }
        let raw = stashAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            MediaAuthorization.shared.unregister(host: host)
            return
        }
        if raw.lowercased().hasPrefix("bearer ") {
            let token = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            MediaAuthorization.shared.register(host: host, credential: .header(name: "Authorization", value: "Bearer \(token)"))
        } else {
            MediaAuthorization.shared.register(host: host, credential: .queryParam(name: "apikey", value: raw))
        }
    }


    /// The image source to use when no Stash server is configured: the device
    /// photo library, which is the app's standalone identity and the only path
    /// that needs no setup at all.
    ///
    /// Returned regardless of authorization. A denied or undecided library still
    /// wants a PhotosImageSource behind it, because that is what tells the
    /// gallery to explain the permission state instead of rendering an
    /// unexplained empty grid.
    /// Whether a Stash server is configured, and so whether there is a choice
    /// of library to make at all.
    var hasStashServer: Bool {
        !stashServerURL.isEmpty
    }

    /// Whether anything the user has configured will talk to the local
    /// network. Gates the local-network permission prewarm so a Photos-only
    /// user is never prompted for access the app will not use.
    var usesLocalNetworkFeatures: Bool {
        if hasStashServer { return true }
        return savedRemoteConfigs.contains { !$0.apiEndpoint.isEmpty }
    }

    /// The library sources currently selectable. Photos and Local need no
    /// setup, so both are always offered; Stash joins once a server is
    /// configured.
    var availableLibrarySources: [LibrarySource] {
        var sources: [LibrarySource] = [.photos, .local]
        if hasStashServer { sources.append(.stash) }
        if hasNextcloudServer { sources.append(.nextcloud) }
        return sources
    }

    /// The library actually in force: the stored choice when it is currently
    /// available, and Photos otherwise — the one source that always is. This
    /// is what makes losing the Stash server fall back cleanly instead of
    /// leaving `librarySource` pointing at something no longer offered.
    var effectiveLibrarySource: LibrarySource {
        availableLibrarySources.contains(librarySource) ? librarySource : .photos
    }

    /// The sources a library choice implies. The single place that mapping
    /// lives, so init and a later switch cannot disagree about it.
    ///
    /// Photos sources are returned regardless of authorization: an undecided or
    /// denied library still wants one behind it, because that is what tells the
    /// gallery which permission state to explain rather than leaving an
    /// unexplained empty grid.
    static func makeSources(for source: LibrarySource,
                            apiClient: StashAPIClient,
                            nextcloudClient: NextcloudClient?) -> (image: any ImageSource, video: any VideoSource) {
        switch source {
        case .photos:
            return (PhotosImageSource(), PhotosVideoSource())
        case .stash:
            return (GraphQLImageSource(apiClient: apiClient), GraphQLVideoSource(apiClient: apiClient))
        case .local:
            // Independent trees, like Photos and Stash never mixing image and
            // video results either — see `LocalMediaSource.photosDirectory`.
            return (LocalImageSource(rootURL: LocalMediaSource.photosDirectory),
                    LocalVideoSource(rootURL: LocalMediaSource.videosDirectory))
        case .nextcloud:
            // Only reachable with a configured server — `.nextcloud` is not in
            // `availableLibrarySources` without one, so `effectiveLibrarySource`
            // can't resolve to it — but a nil client here still has to mean
            // something, and Photos is the same fallback that rule already uses.
            guard let nextcloudClient else {
                return (PhotosImageSource(), PhotosVideoSource())
            }
            return (NextcloudImageSource(client: nextcloudClient),
                    NextcloudVideoSource(client: nextcloudClient))
        }
    }

    /// Rebuild both sources for the current library choice and reload.
    func applyLibrarySource() {
        // A view selected under the other library is not describing what is on
        // screen any more, so the chip must stop claiming it is active. The
        // criteria are left alone: only the applicable half is ever read.
        if let selected = selectedSavedView, selected.library != effectiveLibrarySource {
            selectedSavedView = nil
        }
        if let selected = selectedSavedVideoView, selected.library != effectiveLibrarySource {
            selectedSavedVideoView = nil
        }

        if effectiveLibrarySource == .photos {
            // Idempotent, and cheap when the index is already current: one
            // token-driven sync that usually finds nothing.
            PhotosLibraryIndexer.shared.start()
        }
        let sources = AppModel.makeSources(for: effectiveLibrarySource,
                                           apiClient: apiClient,
                                           nextcloudClient: nextcloudClient)
        imageSource = sources.image
        videoSource = sources.video
        AppLogger.appModel.info("Library source → \(self.effectiveLibrarySource.rawValue, privacy: .public)")
        Task { await reloadAllGalleries() }
    }

    func reloadAllGalleries() async {
        // Reload images if on pictures tab
        // Neither list is emptied first: loadInitial* replaces its contents when
        // the new page arrives, so the grid never shows a placeholder for a
        // reload it is about to satisfy.
        galleryLoadGeneration += 1
        currentPage = 0
        hasMorePages = true
        await loadInitialGallery()
        videoLoadGeneration += 1
        currentVideoPage = 0
        hasMoreVideoPages = true
        await loadInitialVideos()
    }
    // MARK: - Image Gallery Methods

    /// Load the initial gallery page
    func loadInitialGallery() async {
        // Bump generation so any in-flight loadNextPage from a prior load discards its results
        galleryLoadGeneration += 1

        let sourceType = String(describing: type(of: imageSource))
        AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadInitialGallery called, source: \(sourceType, privacy: .public)")
        // Ensure random sort has a seed for consistent pagination
        if currentFilter.sortField == .random && currentFilter.randomSeed == nil {
            currentFilter.shuffleRandomSort()
        }
        currentPage = 0
        hasMorePages = true
        // Force-reset loading flags so the new load can proceed even if a prior load is in-flight
        isLoadingGallery = false
        await loadNextPage()
    }

    /// Pull-to-refresh, owned here rather than by the view that asks for it.
    ///
    /// `.refreshable`'s task belongs to the scroll view hosting it, and SwiftUI
    /// cancels that task when the refresh interaction ends or the scroll view is
    /// replaced. Awaiting the load directly inside it means the cancellation
    /// travels straight into `URLSession.data(for:)`, which fails the request
    /// with `URLError.cancelled` — a refresh that reliably kills its own fetch.
    ///
    /// An unstructured `Task` does not inherit cancellation from the task that
    /// created it, so the load runs to completion regardless of what happens to
    /// the gesture. Overlapping refreshes await the one in flight rather than
    /// starting a second.
    func refreshGallery() async {
        if let existing = galleryRefreshTask {
            await existing.value
            return
        }
        let task = Task { await self.loadInitialGallery() }
        galleryRefreshTask = task
        await task.value
        galleryRefreshTask = nil
    }

    /// See `refreshGallery`.
    func refreshVideos() async {
        if let existing = videoRefreshTask {
            await existing.value
            return
        }
        let task = Task { await self.loadInitialVideos() }
        videoRefreshTask = task
        await task.value
        videoRefreshTask = nil
    }

    /// Load the next page of gallery images
    func loadNextPage() async {
        guard !isLoadingGallery && hasMorePages else {
            let loading = isLoadingGallery
            let hasMore = hasMorePages
            AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextPage skipped - isLoading: \(loading, privacy: .public), hasMore: \(hasMore, privacy: .public)")
            return
        }

        let generation = galleryLoadGeneration
        let page = currentPage
        let sourceTypeName = String(describing: type(of: imageSource))
        AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextPage starting, page: \(page, privacy: .public), source: \(sourceTypeName, privacy: .public)")
        isLoadingGallery = true
        defer {
            if generation == galleryLoadGeneration {
                isLoadingGallery = false
            }
        }

        do {
            // Always use filter since we're on Stash server
            let result = try await imageSource.fetchImages(page: currentPage, pageSize: pageSize, filter: currentFilter)
            // Discard results if a new loadInitialGallery was called while fetching
            guard generation == galleryLoadGeneration else {
                AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextPage discarding stale results (generation \(generation, privacy: .public) != \(self.galleryLoadGeneration, privacy: .public))")
                return
            }
            AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextPage got \(result.images.count, privacy: .public) images, hasMore: \(result.hasMore, privacy: .public)")
            if page == 0 {
                // Replace, rather than having loadInitialGallery empty the array
                // up front. Clearing first meant every reload — a filter change,
                // an index update, leaving an album — painted the empty-or-
                // loading placeholder until the first page arrived. Brief, but a
                // bright placeholder mid-transition reads as a flash.
                galleryImages = result.images
            } else {
                // De-duplicated on append. Item ids are derived from identity
                // now, so a repeat is a genuine duplicate id in the ForEach
                // rather than two harmless instances of the same asset — and a
                // page can repeat one if the library shifts between fetches.
                let seen = Set(galleryImages.map(\.identity))
                galleryImages.append(contentsOf: result.images.filter { !seen.contains($0.identity) })
            }
            hasMorePages = result.hasMore
            currentPage += 1
        } catch {
            // A failed *first* page has to clear: whatever is on screen no longer
            // matches the filter that was just applied, and leaving it there
            // would claim otherwise. A *cancelled* one must not — nobody is
            // waiting for the answer, and emptying the grid because a refresh
            // gesture was torn down is how a pull-to-refresh ends up looking
            // like it deleted the library.
            if error.isCancellation {
                AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "Gallery page load cancelled")
            } else {
                AppLogger.appModel.error("Failed to load gallery page: \(error.localizedDescription, privacy: .public)")
                if page == 0 {
                    galleryImages = []
                }
            }
        }
    }

    /// Requests Photos access and, if it is granted, adopts the library as the
    /// image source. No-op when a Stash server is configured — that stays the
    /// user's chosen source until they clear it.
    func requestPhotosAccessAndReload() async {
        await PhotosAuthorization.request()

        // Revoked from the Settings app while we were away. Keeping a mirror of
        // a library we may no longer read is not defensible, so it goes.
        guard PhotosAuthorization.isReadable else {
            PhotosLibraryIndexer.shared.handleAccessRevoked()
            availablePhotoAlbums = []
            availablePhotoPeople = []
            await reloadAllGalleries()
            return
        }
        // Gated on the library actually in force, NOT on the absence of a
        // server. The earlier `stashServerURL.isEmpty` guard predated
        // LibrarySource and meant that granting access while a server was
        // configured returned here without rebuilding anything: the user
        // allowed access and still landed on "No Photos to Show".
        guard effectiveLibrarySource == .photos, PhotosAuthorization.isReadable else { return }
        applyLibrarySource()
    }

    /// Apply current filter and reload gallery
    func applyFilter() async {
        selectedSavedView = nil  // Clear saved view selection when manually filtering
        await loadInitialGallery()
    }

    /// Clear all filters and reload
    func clearFilters() async {
        currentFilter.clearFilters()
        selectedSavedView = nil
        await loadInitialGallery()
    }

    // MARK: - Autocomplete Methods

    /// Search galleries for autocomplete
    func searchGalleries(query: String) async {

        isLoadingGalleries = true
        defer { isLoadingGalleries = false }

        do {
            let result = try await apiClient.findGalleries(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availableGalleries = result.galleries.map {
                AutocompleteItem(id: $0.id, name: $0.displayName)
            }.sorted {
                let name1 = $0.name.lowercased()
                let name2 = $1.name.lowercased()

                let name1IsExactMatch = (name1 == lowercasedQuery)
                let name2IsExactMatch = (name2 == lowercasedQuery)

                if name1IsExactMatch, !name2IsExactMatch { return true }
                if !name1IsExactMatch, name2IsExactMatch { return false }

                let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                if name1HasPrefix, !name2HasPrefix {
                    return true
                } else if !name1HasPrefix, name2HasPrefix {
                    return false
                } else if name1HasPrefix, name2HasPrefix {
                    // Both have prefix match: prioritize shorter names and those without separators
                    let name1HasSeparator = name1.contains("_") || name1.contains("-")
                    let name2HasSeparator = name2.contains("_") || name2.contains("-")
                    if name1HasSeparator != name2HasSeparator {
                        return !name1HasSeparator
                    }
                    // Both have same separator status: sort by length then alphabetically
                    if name1.count != name2.count {
                        return name1.count < name2.count
                    }
                    return name1 < name2
                } else {
                    return name1 < name2
                }
            }
            let galleriesCount = availableGalleries.count
            AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "Loaded \(galleriesCount, privacy: .public) galleries for autocomplete")
        } catch {
            AppLogger.appModel.error("Failed to search galleries: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Search tags for autocomplete
    func searchTags(query: String) async {

        isLoadingTags = true
        defer { isLoadingTags = false }

        do {
            let result = try await apiClient.findTags(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availableTags = result.tags.map { AutocompleteItem(id: $0.id, name: $0.name) }
                .sorted {
                    let name1 = $0.name.lowercased()
                    let name2 = $1.name.lowercased()

                    let name1IsExactMatch = (name1 == lowercasedQuery)
                    let name2IsExactMatch = (name2 == lowercasedQuery)

                    if name1IsExactMatch, !name2IsExactMatch { return true }
                    if !name1IsExactMatch, name2IsExactMatch { return false }

                    let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                    let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                    if name1HasPrefix, !name2HasPrefix {
                        return true
                    } else if !name1HasPrefix, name2HasPrefix {
                        return false
                    } else if name1HasPrefix, name2HasPrefix {
                        // Both have prefix match: prioritize shorter names and those without separators
                        let name1HasSeparator = name1.contains("_") || name1.contains("-")
                        let name2HasSeparator = name2.contains("_") || name2.contains("-")
                        if name1HasSeparator != name2HasSeparator {
                            return !name1HasSeparator
                        }
                        // Both have same separator status: sort by length then alphabetically
                        if name1.count != name2.count {
                            return name1.count < name2.count
                        }
                        return name1 < name2
                    } else {
                        return name1 < name2
                    }
                }
        } catch {
            AppLogger.appModel.error("Failed to search tags: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Search studios for autocomplete
    func searchStudios(query: String) async {

        isLoadingStudios = true
        defer { isLoadingStudios = false }

        do {
            let result = try await apiClient.findStudios(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availableStudios = result.studios.map { AutocompleteItem(id: $0.id, name: $0.name) }
                .sorted {
                    let name1 = $0.name.lowercased()
                    let name2 = $1.name.lowercased()

                    let name1IsExactMatch = (name1 == lowercasedQuery)
                    let name2IsExactMatch = (name2 == lowercasedQuery)

                    if name1IsExactMatch, !name2IsExactMatch { return true }
                    if !name1IsExactMatch, name2IsExactMatch { return false }

                    let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                    let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                    if name1HasPrefix, !name2HasPrefix {
                        return true
                    } else if !name1HasPrefix, name2HasPrefix {
                        return false
                    } else if name1HasPrefix, name2HasPrefix {
                        let name1HasSeparator = name1.contains("_") || name1.contains("-")
                        let name2HasSeparator = name2.contains("_") || name2.contains("-")
                        if name1HasSeparator != name2HasSeparator {
                            return !name1HasSeparator
                        }
                        if name1.count != name2.count {
                            return name1.count < name2.count
                        }
                        return name1 < name2
                    } else {
                        return name1 < name2
                    }
                }
        } catch {
            AppLogger.appModel.error("Failed to search studios: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Search performers for autocomplete
    func searchPerformers(query: String) async {

        isLoadingPerformers = true
        defer { isLoadingPerformers = false }

        do {
            let result = try await apiClient.findPerformers(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availablePerformers = result.performers.map { AutocompleteItem(id: $0.id, name: $0.name) }
                .sorted {
                    let name1 = $0.name.lowercased()
                    let name2 = $1.name.lowercased()

                    let name1IsExactMatch = (name1 == lowercasedQuery)
                    let name2IsExactMatch = (name2 == lowercasedQuery)

                    if name1IsExactMatch, !name2IsExactMatch { return true }
                    if !name1IsExactMatch, name2IsExactMatch { return false }

                    let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                    let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                    if name1HasPrefix, !name2HasPrefix {
                        return true
                    } else if !name1HasPrefix, name2HasPrefix {
                        return false
                    } else if name1HasPrefix, name2HasPrefix {
                        let name1HasSeparator = name1.contains("_") || name1.contains("-")
                        let name2HasSeparator = name2.contains("_") || name2.contains("-")
                        if name1HasSeparator != name2HasSeparator {
                            return !name1HasSeparator
                        }
                        if name1.count != name2.count {
                            return name1.count < name2.count
                        }
                        return name1 < name2
                    } else {
                        return name1 < name2
                    }
                }
        } catch {
            AppLogger.appModel.error("Failed to search performers: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Groups for the Videos filter. Only images have galleries and only scenes
    /// have groups, so this is loaded only when filtering videos.
    func loadGroups() async {
        do {
            let result = try await apiClient.findGroups(perPage: Self.containerFetchLimit)
            availableGroups = result.groups.map(MediaContainer.init(group:))
        } catch {
            AppLogger.appModel.error("Failed to load groups: \(error.localizedDescription, privacy: .public)")
            availableGroups = []
        }
    }

    // MARK: - Media Containers

    /// Load the browsable containers for the library in force.
    ///
    /// Routed by library for the same reason `loadAutocompleteData` is: a Photos
    /// album and a Stash gallery are reached completely differently, and only
    /// the resulting shape is shared.
    func loadMediaContainers(isVideo: Bool) async {
        isLoadingMediaContainers = true
        defer { isLoadingMediaContainers = false }

        switch effectiveLibrarySource {
        case .photos:
            guard PhotosAuthorization.isReadable else {
                mediaContainers = []
                return
            }
            let mediaType: PHAssetMediaType = isVideo ? .video : .image
            let albums = (try? await PhotosIndexStore.shared.albums(mediaType: mediaType)) ?? []
            mediaContainers = albums.map(MediaContainer.init(album:))

        case .stash where isVideo:
            // Groups are Stash's containers for scenes, the counterpart to
            // galleries for images.
            do {
                let result = try await apiClient.findGroups(perPage: Self.containerFetchLimit)
                mediaContainers = result.groups.map(MediaContainer.init(group:))
            } catch {
                AppLogger.appModel.error("Failed to load groups: \(error.localizedDescription, privacy: .public)")
                mediaContainers = []
            }

        case .stash:
            do {
                // Bounded rather than Stash's "all" sentinel: a predictable cap
                // beats relying on a magic per-page value, and a library with
                // more galleries than this wants search, not a longer grid.
                let result = try await apiClient.findGalleries(page: 1, perPage: Self.containerFetchLimit)
                mediaContainers = result.galleries
                    .map(MediaContainer.init(gallery:))
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch {
                AppLogger.appModel.error("Failed to load galleries: \(error.localizedDescription, privacy: .public)")
                mediaContainers = []
            }

        case .local, .nextcloud:
            // Never actually called. Local renders its own
            // LocalFolderBrowserView instead of the container grid, and
            // Nextcloud hides the Albums tab altogether
            // (`LibrarySource.offersAlbums`). Kept exhaustive, not reachable.
            mediaContainers = []
        }
        AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel,
                               "Loaded \(self.mediaContainers.count, privacy: .public) containers")
    }

    /// Most containers any one browse will show.
    private static let containerFetchLimit = 500

    /// Whether `container` is the one currently filtering the given media kind.
    func isContainerApplied(_ container: MediaContainer, isVideo: Bool) -> Bool {
        switch container.kind {
        case .album, .smartAlbum:
            let criteria = isVideo ? currentVideoFilter.photosCriteria : currentFilter.photosCriteria
            return criteria.albumIds == [container.id]
        case .gallery:
            return currentFilter.galleryIds == [container.id]
        case .group:
            return currentVideoFilter.groupIds == [container.id]
        }
    }

    /// Applies a container as the filter for one media kind and reloads.
    ///
    /// Replaces any container selection rather than adding to it — opening an
    /// album from a browser reads as "show me this one" — but leaves every other
    /// filter dimension alone.
    func applyContainer(_ container: MediaContainer, isVideo: Bool) {
        switch container.kind {
        case .album, .smartAlbum:
            if isVideo {
                currentVideoFilter.photosCriteria.selectedAlbums = [container.filterItem]
                currentVideoFilter.photosCriteria.albumModifier = .includes
            } else {
                currentFilter.photosCriteria.selectedAlbums = [container.filterItem]
                currentFilter.photosCriteria.albumModifier = .includes
            }
        case .gallery:
            currentFilter.selectedGalleries = [container.filterItem]
            currentFilter.galleryModifier = .includesAll
        case .group:
            currentVideoFilter.selectedGroups = [container.filterItem]
            currentVideoFilter.groupModifier = .includesAll
        }

        Task {
            if isVideo {
                await loadInitialVideos()
            } else {
                await loadInitialGallery()
            }
        }
    }

    /// Clears whatever container is filtering the given media kind.
    func clearAppliedContainer(isVideo: Bool) {
        if isVideo {
            currentVideoFilter.photosCriteria.selectedAlbums = []
            currentVideoFilter.selectedGroups = []
        } else {
            currentFilter.photosCriteria.selectedAlbums = []
            currentFilter.selectedGalleries = []
        }
        Task {
            if isVideo {
                await loadInitialVideos()
            } else {
                await loadInitialGallery()
            }
        }
    }

    /// Load whatever the Filters tab needs to populate its pickers.
    ///
    /// Routed by library, because the two have nothing in common: Stash needs
    /// tags, performers, studios and galleries fetched over GraphQL, and Photos
    /// needs its album list read from PhotoKit. Calling the Stash searches while
    /// browsing Photos was the original bug here — with no server configured
    /// they each failed and logged, and the tab offered filter dimensions that
    /// could not apply to what was on screen.
    func loadAutocompleteData(isVideo: Bool) async {
        switch effectiveLibrarySource {
        case .photos:
            await loadPhotoAlbums(isVideo: isVideo)
        case .stash:
            await searchGalleries(query: "")
            await searchTags(query: "")
            await searchStudios(query: "")
            await searchPerformers(query: "")
            if isVideo {
                await loadGroups()
            }
        case .local, .nextcloud:
            // The Filters tab hides itself for these sources (nothing here
            // has tags, albums or galleries to filter by) and redirects away
            // if it was already open — see ContentView and
            // `LibrarySource.offersFilters`. Not reachable.
            break
        }
    }

    /// Read the album and people lists for one media type.
    ///
    /// Both are grouped queries against the index now. They used to be a
    /// `PHAsset` fetch per album per media type, run every time the Filters tab
    /// appeared, purely to get counts.
    func loadPhotoAlbums(isVideo: Bool) async {
        guard PhotosAuthorization.isReadable else {
            availablePhotoAlbums = []
            availablePhotoPeople = []
            return
        }
        isLoadingPhotoAlbums = true
        let mediaType: PHAssetMediaType = isVideo ? .video : .image
        availablePhotoAlbums = (try? await PhotosIndexStore.shared.albums(mediaType: mediaType)) ?? []
        availablePhotoPeople = (try? await PhotosIndexStore.shared.people(mediaType: mediaType)) ?? []
        isLoadingPhotoAlbums = false
        AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel,
                               "Loaded \(self.availablePhotoAlbums.count, privacy: .public) albums, \(self.availablePhotoPeople.count, privacy: .public) people")
    }

    // MARK: - Video Gallery Methods

    /// Load the initial video gallery page
    func loadInitialVideos() async {
        // Bump generation so any in-flight loadNextVideoPage discards its results
        videoLoadGeneration += 1

        AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadInitialVideos called")
        // Ensure random sort has a seed for consistent pagination
        if currentVideoFilter.sortField == .random && currentVideoFilter.randomSeed == nil {
            currentVideoFilter.shuffleRandomSort()
        }
        currentVideoPage = 0
        hasMoreVideoPages = true
        // Force-reset loading flags so the new load can proceed even if a prior load is in-flight
        isLoadingVideos = false
        await loadNextVideoPage()
    }

    /// Load the next page of videos
    func loadNextVideoPage() async {
        guard !isLoadingVideos && hasMoreVideoPages else {
            let loadingVideos = isLoadingVideos
            let hasMoreVideo = hasMoreVideoPages
            AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextVideoPage skipped - isLoading: \(loadingVideos, privacy: .public), hasMore: \(hasMoreVideo, privacy: .public)")
            return
        }

        let generation = videoLoadGeneration
        let videoPage = currentVideoPage
        AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextVideoPage starting, page: \(videoPage, privacy: .public)")
        isLoadingVideos = true
        defer {
            if generation == videoLoadGeneration {
                isLoadingVideos = false
            }
        }

        do {
            // Always use filter since we're on Stash server
            let result = try await videoSource.fetchVideos(page: currentVideoPage, pageSize: pageSize, filter: currentVideoFilter)
            // Discard results if a new loadInitialVideos was called while fetching
            guard generation == videoLoadGeneration else {
                AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextVideoPage discarding stale results")
                return
            }
            AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "loadNextVideoPage got \(result.videos.count, privacy: .public) videos, hasMore: \(result.hasMore, privacy: .public)")
            // See loadNextPage for both halves of this: page 0 replaces so a
            // reload never paints an empty grid, and later pages de-duplicate
            // because derived ids make a repeated asset a duplicate id.
            if videoPage == 0 {
                galleryVideos = result.videos
            } else {
                let seen = Set(galleryVideos.map(\.identity))
                galleryVideos.append(contentsOf: result.videos.filter { !seen.contains($0.identity) })
            }
            hasMoreVideoPages = result.hasMore
            currentVideoPage += 1
        } catch {
            // See loadNextPage: cancellation leaves the list alone.
            if error.isCancellation {
                AppLogger.appModel.log(level: AppLogger.effectiveDebugLevel, "Video page load cancelled")
            } else {
                AppLogger.appModel.error("Failed to load video page: \(error.localizedDescription, privacy: .public)")
                if videoPage == 0 {
                    galleryVideos = []
                }
            }
        }
    }

    /// Apply current video filter and reload videos
    func applyVideoFilter() async {
        selectedSavedVideoView = nil  // Clear saved video view selection when manually filtering
        await loadInitialVideos()
    }

    /// Clear all video filters and reload
    func clearVideoFilters() async {
        currentVideoFilter.clearFilters()
        selectedSavedVideoView = nil
        await loadInitialVideos()
    }

    // MARK: - Multi-Select State

    /// Whether the image gallery is in multi-select mode
    var isSelectingImages = false

    /// Whether the video gallery is in multi-select mode
    var isSelectingVideos = false

    /// Selected image stash IDs during multi-select
    var selectedImageIds: Set<String> = []

    /// Selected video stash IDs during multi-select
    var selectedVideoIds: Set<String> = []

    func exitImageSelection() {
        isSelectingImages = false
        selectedImageIds.removeAll()
    }

    func exitVideoSelection() {
        isSelectingVideos = false
        selectedVideoIds.removeAll()
    }

    func removeDeletedImages(stashIds: Set<String>) {
        galleryImages.removeAll { image in
            guard let sid = image.stashId else { return false }
            return stashIds.contains(sid)
        }
        selectedImageIds.subtract(stashIds)
    }

    func removeDeletedVideos(stashIds: Set<String>) {
        galleryVideos.removeAll { video in
            guard let sid = video.stashId else { return false }
            return stashIds.contains(sid)
        }
        selectedVideoIds.subtract(stashIds)
    }

    // MARK: - Rating & O Counter Mutations

    func updateImageRating(stashId: String, rating100: Int?) async throws {
        try await apiClient.updateImageRating(imageId: stashId, rating100: rating100)
        // Update local state
        if var image = selectedImage, image.stashId == stashId {
            image.rating100 = rating100
            selectedImage = image
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].rating100 = rating100
        }
    }

    func incrementImageOCounter(stashId: String) async throws {
        let newValue = try await apiClient.incrementImageOCounter(imageId: stashId)
        if var image = selectedImage, image.stashId == stashId {
            image.oCounter = newValue
            selectedImage = image
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = newValue
        }
    }

    func decrementImageOCounter(stashId: String) async throws {
        let newValue = try await apiClient.decrementImageOCounter(imageId: stashId)
        if var image = selectedImage, image.stashId == stashId {
            image.oCounter = newValue
            selectedImage = image
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = newValue
        }
    }

}
