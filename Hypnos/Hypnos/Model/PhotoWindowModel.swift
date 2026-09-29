/*
 Hypnos - Photo Window Model

 Per-window model for individual photo display windows.
 Each photo window gets its own instance with independent state.

 Memory strategy: Windows open in lightweight 2D mode using a downsampled
 UIImage via SwiftUI Image. RealityKit (full resolution) is only loaded when
 the user explicitly activates 3D. On window resize, the 2D display image
 is re-downsampled in memory (no temp files on disk).
 */

import DebugTrace
import ImageIO
import Metal
import RealityKit
import SwiftUI

@MainActor
@Observable
class PhotoWindowModel {
    // MARK: - Window-specific Image State

    var image: GalleryImage
    var imageURL: URL
    var imageAspectRatio: CGFloat = 1.0
    var contentEntity: Entity = Entity()
    var spatial3DImageState: Spatial3DImageState = .notGenerated
    var spatial3DImage: ImagePresentationComponent.Spatial3DImage? = nil
    /// Handoff registry key this window holds a claimed reference for, so
    /// `cleanup()` can drop it. Only the *claiming* window takes a reference;
    /// a depositing window keeps its instance through `spatial3DImage`.
    var spatial3DHandoffKey: Spatial3DImageHandoff.Key? = nil
    /// Whether to show the 3D restore prompt pill at the bottom of the viewer
    var showAutoRestorePrompt: Bool = false
    /// Whether the auto-restore target is immersive 3D (vs regular 3D)
    var autoRestoreImmersive: Bool = false
    /// Whether the 3D prompt pill is offering 3D for *animated* content (vs the
    /// normal auto-restore of a previously-converted still). When true, "Yes"
    /// enables 3D of the first frame; auto-3D never fires for animated content.
    var autoRestoreForAnimated: Bool = false
    /// Whether the window is currently snapped to a surface (mirrored from
    /// `surfaceSnappingInfo`). Used to suppress the 3D restore prompt, which
    /// is irrelevant on a snapped wall view and can pop up unexpectedly on
    /// device reboot since restored windows start in a snapped state.
    var isWindowSnapped: Bool = false

    /// Whether the window is waiting on image bytes / a decode.
    ///
    /// Backed by a stored property rather than declared directly so every one
    /// of the ~20 assignment sites across the extensions funnels through one
    /// place that arms and disarms the stall watchdog below. A stalled or
    /// failing backend used to leave this `true` forever, and since the whole
    /// ornament is gated on it the window became uninteractable — the bug this
    /// machinery exists to make impossible.
    @ObservationIgnored private var _isLoadingDetailImage: Bool = false
    var isLoadingDetailImage: Bool {
        get {
            access(keyPath: \.isLoadingDetailImage)
            return _isLoadingDetailImage
        }
        set {
            let wasLoading = _isLoadingDetailImage
            withMutation(keyPath: \.isLoadingDetailImage) {
                _isLoadingDetailImage = newValue
            }
            guard wasLoading != newValue else { return }
            if newValue {
                armLoadStallWatchdog()
            } else {
                cancelLoadStallWatchdog()
            }
        }
    }

    /// Human-readable reason the current image could not be loaded, or nil when
    /// there is no failure. Set by `loadImageDataForDetail`; cleared when a load
    /// starts or succeeds. Drives the in-window error card and re-enables the
    /// ornament so a dead image never traps the window.
    var loadFailure: String? = nil

    /// Set by the watchdog when a load has been outstanding for longer than
    /// `loadStallTimeout`. Doesn't abort anything — it just stops the loading
    /// state from holding the ornament hostage, and surfaces the fact that the
    /// backend is not answering.
    var isLoadStalled: Bool = false

    /// Seconds a load may run before the window stops treating it as a normal
    /// wait. Comfortably longer than a slow-but-healthy fetch, and well under
    /// `ImageLoader`'s own request timeout so the UI degrades first.
    static let loadStallTimeout: TimeInterval = 8

    @ObservationIgnored private var loadStallWatchdogTask: Task<Void, Never>?

    /// The single gate the ornament's controls use. Loading only locks the
    /// controls while the load is both in progress *and* behaving: once it
    /// fails or stalls, everything comes back so the user can retry, navigate
    /// away, or close the window.
    var controlsLocked: Bool {
        isLoadingDetailImage && loadFailure == nil && !isLoadStalled
    }

    private func armLoadStallWatchdog() {
        loadStallWatchdogTask?.cancel()
        isLoadStalled = false
        loadStallWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PhotoWindowModel.loadStallTimeout))
            guard let self, !Task.isCancelled, self.isLoadingDetailImage else { return }
            self.isLoadStalled = true
            AppLogger.photoWindow.warning(
                "Image load still outstanding after \(PhotoWindowModel.loadStallTimeout, privacy: .public)s — releasing viewer controls"
            )
        }
    }

    private func cancelLoadStallWatchdog() {
        loadStallWatchdogTask?.cancel()
        loadStallWatchdogTask = nil
        isLoadStalled = false
    }

    var inputPlaneEntity: Entity = Entity()

    /// True while this window owns the Spatial3D ImmersiveSpace presentation.
    /// Set by the view-mode switch when `AppModel.fullyImmersive3DMode` is on
    /// and the user picks Immersive 3D; PhotoDisplayView observes this and
    /// drives `openImmersiveSpace` / `dismissImmersiveSpace`. The windowed
    /// IPC stays in `.spatial3D` (or mono) while immersive is hosted
    /// elsewhere — only one presentation runs at a time.
    var hostFullyImmersiveSpace: Bool = false

    // MARK: - 2D Display Image State

    /// GPU-private texture for lightweight 2D display (nil when in 3D mode).
    /// Preferred over displayImage — lives in GPU memory, not counted as dirty CPU pages.
    var displayTexture: MTLTexture? = nil

    /// Downsampled UIImage for lightweight 2D display.
    /// Only used as a fallback for idle-downscale thumbnails and 3D adjustment previews.
    var displayImage: UIImage? = nil

    /// Whether the window is showing the RealityKit 3D view
    var is3DMode: Bool = false

    /// Set when user taps "Generate 3D" from 2D mode — the RealityView
    /// init closure will consume this flag and start generation.
    var pendingGenerate3D: Bool = false

    /// Viewing mode queued while the image was still loading. Applied once loading finishes.
    var pendingViewingMode: ImagePresentationComponent.ViewingMode?

    /// Native image dimensions (read from file metadata without decoding)
    var nativeImageDimensions: CGSize?

    /// The max dimension used for the current displayImage
    var currentDisplayMaxDimension: CGFloat = 0

    /// Per-window resolution override. When non-nil, this overrides the global
    /// maxImageResolution from AppModel and forces dynamic resolution behavior
    /// even when the global setting is Off. nil = use global setting.
    var resolutionOverride: Int? = nil

    /// Per-window spatial 3D source resolution override. When non-nil, this
    /// overrides the global spatial3DMaxResolution from AppModel for the source
    /// image fed into RealityKit's Spatial3DImage. nil = use global setting.
    var spatial3DResolutionOverride: Int? = nil

    /// Last source-image max dimension actually used when generating the
    /// current spatial 3D image. 0 when no 3D image has been generated yet.
    /// Used by the ornament resolution menu to display the effective value.
    var currentSpatial3DSourceDimension: Int = 0

    /// Last known window size for resize-triggered reloads
    var lastWindowSize: CGSize?

    /// Saved window size from a previous session, restored from the enhancement tracker.
    /// Used by PhotoDisplayView for initial window sizing instead of mainWindowSize.
    var savedWindowSize: CGSize?

    /// Debounce task for window resize
    var resizeDebounceTask: Task<Void, Never>?

    /// Whether a display image load is currently in progress (prevents concurrent loads)
    var isLoadingDisplayImage: Bool = false

    /// True during the initial sequential load from start(). Prevents resize-triggered
    /// reloads from interfering with enhancement restoration.
    var isInitialLoadInProgress: Bool = false

    /// Task for 3D generation (tracked so cleanup can avoid removing the component mid-generation)
    var generateTask: Task<Void, Never>?

    /// Trigger for immersive window resize (incremented when entering/exiting immersive)
    var immersiveResizeTrigger: Int = 0

    /// Trigger for a tiny window-size nudge to force IPC to re-anchor its
    /// off-axis blur calibration. Driven by Spatial3DRefreshHub when the user
    /// drifts past a head-pose threshold while viewing windowed spatial3D.
    var calibrationNudgeTrigger: Int = 0

    /// Window size before entering immersive mode (for restoration)
    var preImmersiveWindowSize: CGSize? = nil

    /// The desired viewing mode (set immediately, before RealityKit animation completes)
    var desiredViewingMode: ImagePresentationComponent.ViewingMode = .mono

    /// Scale factor for converting window points to texture pixels
    /// (visionOS rendering density + headroom)
    static let displayScaleFactor: CGFloat = 2.5

    // MARK: - Background Removal State

    /// Current state of background removal processing
    var backgroundRemovalState: BackgroundRemovalState = .original

    /// The original display texture before background removal (stored for toggle-back)
    var originalDisplayTexture: MTLTexture? = nil

    /// The background-removed version as a GPU texture (cached for re-toggle)
    var backgroundRemovedTexture: MTLTexture? = nil

    /// The auto-enhanced background-removed version as a GPU texture (cached for re-toggle)
    var autoEnhancedBackgroundRemovedTexture: MTLTexture? = nil

    /// Task for background removal (tracked so cleanup can cancel it)
    var backgroundRemovalTask: Task<Void, Never>?

    // MARK: - Diorama State

    /// Uncropped foreground (full source frame, transparent background) used
    /// for the diorama overlay. Stored as a GPU-private MTLTexture so its
    /// pixels live in GPU memory (not dirty CPU pages) — escapes jetsam
    /// accounting and benefits from Apple Silicon lossless compression.
    /// Deep-color sources (>8-bit) ride an rgba16Float texture all the way
    /// through, matching the base image's color fidelity.
    var dioramaForegroundTexture: MTLTexture? = nil

    /// Subject-blurred backdrop. The original image with the subject region
    /// gaussian-blurred so the floating foreground doesn't reveal a doubled
    /// silhouette behind it when viewed off-axis. Same dimensions as source.
    var dioramaBackdropTexture: MTLTexture? = nil

    /// Whether diorama foreground generation is currently running.
    var isProcessingDiorama: Bool = false

    /// Whether the photo viewer is currently in diorama viewing mode. Treated
    /// as a sibling viewing mode to spatial 3D / immersive 3D — mutually
    /// exclusive with both. Persisted via `ViewingModePreference.diorama`.
    var isDioramaMode: Bool = false

    /// Task for diorama foreground generation (cancellable on cleanup / image switch).
    var dioramaTask: Task<Void, Never>?

    // MARK: - Visual Adjustments State

    /// Per-image visual adjustments (Current tab values)
    var currentAdjustments: VisualAdjustments = VisualAdjustments()

    /// In-memory display-resolution auto-enhanced texture (for fast toggle-back)
    var autoEnhancedDisplayTexture: MTLTexture? = nil

    /// The original display texture before auto-enhance was applied (for toggle-back)
    var preAutoEnhanceDisplayTexture: MTLTexture? = nil

    /// Whether auto-enhance is currently being processed
    var isProcessingAutoEnhance: Bool = false

    /// The effective adjustments to apply, combining per-image overrides
    /// with global defaults so a per-image slider movement doesn't wipe
    /// out a separately-configured global setting on another axis. Same
    /// composition semantics as the slideshow's effective* properties:
    /// brightness/sharpen add, contrast/saturation/opacity multiply,
    /// isAutoEnhanced ORs. Neutral per-image values compose to identity
    /// against global, so dragging opacity on an image with a global
    /// saturation boost preserves that boost on the bake-relevant axes.
    var effectiveAdjustments: VisualAdjustments {
        let global = appModel.globalVisualAdjustments
        var combined = VisualAdjustments()
        combined.brightness = currentAdjustments.brightness + global.brightness
        combined.contrast = currentAdjustments.contrast * global.contrast
        combined.saturation = currentAdjustments.saturation * global.saturation
        combined.opacity = currentAdjustments.opacity * global.opacity
        combined.sharpen = currentAdjustments.sharpen + global.sharpen
        combined.isAutoEnhanced = currentAdjustments.isAutoEnhanced || global.isAutoEnhanced
        return combined
    }

    /// Whether to show the adjustments popover (driven from ornament button)
    var showAdjustmentsPopover: Bool = false

    /// Whether to show the media info/rating popover (driven from ornament button)
    var showMediaInfoPopover: Bool = false

    /// Whether the view is temporarily showing a 2D preview while 3D adjustments are
    /// being tuned. When true, is3DMode is false and displayImage holds a thumbnail.
    /// The RealityKit component is removed; it gets rebuilt once sliders settle.
    var isShowingAdjustmentPreview: Bool = false

    /// Saved spatial3D generation state before entering adjustment preview mode,
    /// so we know whether to re-generate 3D after the reload.
    var prePreviewSpatial3DState: Spatial3DImageState = .notGenerated

    /// Debounce task for reloading ImagePresentationComponent with adjustments
    var adjustments3DReloadTask: Task<Void, Never>?

    /// Deferred teardown of the 3D component when entering the 2D adjustment
    /// preview. Removal must wait for any in-flight generate() to settle —
    /// RealityKit crashes if the component is destroyed while its internal
    /// progress callback is still firing. The debounced regen task awaits
    /// this before installing a replacement component so ordering between
    /// old-component removal and new-component creation stays deterministic.
    var adjustmentPreviewTeardownTask: Task<Void, Never>?

    /// Snapshot of the adjustments that were last baked into the current
    /// `spatial3DImage`. `reloadImagePresentationWithAdjustments` consults
    /// this to skip the regen dance when only render-time fields (opacity,
    /// sharpen) changed — those don't need to be re-baked. Reset to
    /// `VisualAdjustments()` on each fresh IPC creation (raw bytes go in,
    /// so the implicit baseline is "neutral") and to nil on 3D exit.
    var lastBakedAdjustments: VisualAdjustments?

    /// Whether any popover is currently open (used to suppress auto-hide timer)
    var hasOpenPopover: Bool {
        showAdjustmentsPopover || showMediaInfoPopover || openOrnamentMenuCount > 0
    }

    /// Counter for ornament-anchored Menu drop-downs (More, 3D, Resolution).
    /// SwiftUI's `Menu` doesn't expose an open binding, so we increment when
    /// the menu's content view appears and decrement when it disappears.
    /// Used to suppress the diorama foreground while a menu is shown so the
    /// menu panel isn't visually occluded by the popped-forward foreground.
    var openOrnamentMenuCount: Int = 0

    var isAnyOrnamentMenuOpen: Bool {
        openOrnamentMenuCount > 0
    }

    // MARK: - Image Flip State

    /// Whether the image is horizontally flipped (showing its "back side")
    var isImageFlipped: Bool = false

    /// Persist the current flip state to the enhancement tracker.
    func trackFlipState() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setFlipped(url: imageURL, isFlipped: isImageFlipped)
    }

    /// Persist the current resolution override to the enhancement tracker.
    func trackResolutionOverride() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setResolutionOverride(url: imageURL, resolution: resolutionOverride)
    }

    /// Persist the current spatial 3D resolution override to the enhancement tracker.
    func trackSpatial3DResolutionOverride() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setSpatial3DResolutionOverride(url: imageURL, resolution: spatial3DResolutionOverride)
    }

    /// Persist the current window size to the enhancement tracker.
    func trackWindowSize(_ size: CGSize) async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setWindowSize(url: imageURL, size: size)
    }

    /// Persist the current visual adjustments to the enhancement tracker.
    func trackAdjustments() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setAdjustments(
            url: imageURL, adjustments: currentAdjustments.isModified ? currentAdjustments : nil
        )
    }

    /// Apply the user's default viewing mode (Settings → Display) when an
    /// image opens without a remembered per-image mode and no auto-restore
    /// is in flight. No-op for animated images, in-progress 3D modes, or when
    /// any enhancement / remembered mode is already active.
    func applyDefaultViewingModeIfNeeded() async {
        // Pop-outs restored after a visionOS reboot must not honor the global
        // default viewing mode — if the user switched the default to 3D and
        // has many windows snapped, applying it on every restored window
        // would generate spatial 3D for all of them at once. The user can
        // still opt in per window via the ornament.
        guard !isRestoredPopOut else { return }
        // Nothing decoded, so every mode below would fail its own way and
        // replace the failure card with an empty RealityView. Leave the window
        // in the failed state where the user has a Retry.
        guard loadFailure == nil else { return }
        guard !isAnimatedImage else { return }
        guard backgroundRemovalState == .original else { return }
        guard !is3DMode, desiredViewingMode == .mono else { return }
        guard !currentAdjustments.isAutoEnhanced else { return }

        // Diorama default takes precedence over any per-image remembered mode
        // and is not blocked by the 3D auto-restore prompt — the user has
        // expressed a strong preference at the global level. The prompt stays
        // visible (rendered above the diorama foreground) so the user can
        // still opt in to 3D for this image.
        //
        // The diorama foreground/backdrop generation is fire-and-forget here
        // so a gallery prev/next swipe doesn't pause its slide-in waiting on
        // Vision. The diorama layers fade in once ready.
        if appModel.defaultImageViewingMode == .diorama {
            guard !isDioramaMode else { return }
            isApplyingDefaultViewingMode = true
            Task { @MainActor [weak self] in
                await self?.setDioramaMode(true)
                self?.isApplyingDefaultViewingMode = false
            }
            return
        }

        guard !showAutoRestorePrompt else { return }
        guard !isDioramaMode else { return }

        // If the user has a remembered non-2D, non-3D mode for this image,
        // respect it instead of overriding with the default. A remembered
        // `.mono` or a remembered 3D mode is treated the same as no
        // remembered mode — `.mono` because the default should win after
        // a 3D→2D toggle, and the 3D modes because the default-3D fallthrough
        // generates the same result without relying on autoRestoreSpatial3D
        // being enabled.
        if appModel.rememberImageEnhancements,
           let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL),
           lastMode != .mono,
           lastMode != .spatial3D,
           lastMode != .spatial3DImmersive {
            if lastMode == .diorama {
                await setDioramaMode(true)
                return
            }
            // Other modes (.backgroundRemoved, .autoEnhanced, etc.) are
            // restored by autoRestorePreviousEnhancement; don't override them.
            return
        }

        isApplyingDefaultViewingMode = true
        defer { isApplyingDefaultViewingMode = false }

        switch appModel.defaultImageViewingMode {
        case .mono, .diorama:
            return
        case .spatial3D:
            await switchToViewingMode(.spatial3D)
            await waitForSpatial3DGeneration()
        case .spatial3DImmersive:
            await switchToViewingMode(.spatial3DImmersive)
            await waitForSpatial3DGeneration()
        }
    }

    /// Polls `spatial3DImageState` until generation finishes (or a safety
    /// deadline elapses). Used by `applyDefaultViewingModeIfNeeded` so a
    /// gallery prev/next swipe doesn't slide the new image in before the
    /// RealityKit scene has actually been built — avoiding a 2D→3D pop.
    /// `switchToViewingMode(.spatial3D)` only kicks off `activate3DMode`;
    /// the real generation runs from the RealityView's init closure.
    func waitForSpatial3DGeneration() async {
        let deadline = Date().addingTimeInterval(15)
        while !Task.isCancelled, Date() < deadline {
            if spatial3DImageState == .generated { return }
            // If 3D was abandoned (e.g. failed init / animated image), stop waiting.
            if !is3DMode && pendingViewingMode == nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Restore saved visual adjustments (slider values) for the current image.
    /// Auto-enhance restoration is handled separately by autoRestorePreviousEnhancement().
    func restoreAdjustments() async {
        guard appModel.rememberImageEnhancements else { return }
        guard let savedAdjustments = await ImageEnhancementTracker.shared.adjustments(url: imageURL) else { return }
        currentAdjustments = savedAdjustments
    }

    // MARK: - Idle Downscale State

    /// Timestamp of the last user interaction with this window.
    /// Used by AppModel's LRU memory pressure system to determine which
    /// windows to downscale first (least-recently-interacted = first evicted).
    var lastInteractionTime: Date = Date()

    /// Whether this window has been downscaled due to memory pressure.
    /// When true, the display image is at thumbnail resolution and raw data
    /// has been released. Restored on next user interaction.
    var isIdleDownscaled: Bool = false

    /// True while `restoreFromIdleDownscale` is running async work.
    /// Prevents memory-pressure from immediately re-downscaling this window.
    var isRestoringFromIdle: Bool = false

    /// State captured before idle downscale so restore can skip the full
    /// auto-restore pipeline and directly reload from cache.
    var hadBackgroundRemoval: Bool = false
    var had3DMode: Bool = false
    var hadAutoEnhance: Bool = false

    /// Max dimension used for idle-downscaled thumbnail display
    static let idleDownscaleDimension: CGFloat = 256

    /// Current key into SharedTextureCache for the base display texture.
    /// Tracked so we can release our reference on cleanup, resize, or image switch.
    var displayTextureCacheKey: SharedTextureCache.TextureKey?

    // MARK: - Scene Phase Idle Downscale

    /// Task that fires after the inactivity timeout to downscale the window
    var scenePhaseIdleTask: Task<Void, Never>?

    /// How long a window must remain inactive/background before being downscaled
    static let scenePhaseIdleTimeout: TimeInterval = 5 * 60 // 5 minutes

    /// Whether this window is in the user's current room (scene phase is active).
    /// Used by AppModel's memory pressure system to prioritize downscaling
    /// windows in inactive rooms before touching windows the user can see.
    var isInActiveRoom: Bool = true

    /// Timestamp when this window last left the active room (scene phase
    /// transitioned away from .active). Used by the memory pressure handler
    /// to only downscale windows that have been backgrounded long enough.
    var backgroundedSince: Date?

    /// Display name for this window used in log messages
    var displayName: String {
        image.title ?? image.fullSizeURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Share State

    var isPreparingShare: Bool = false
    var shareFileURL: URL?

    // MARK: - GIF Support

    var isAnimatedGIF: Bool = false
    var isAnimatedWebP: Bool = false
    var isAnimatedWebVisual: Bool = false
    /// Animated JPEG XL. ImageIO only yields the first frame, so it's decoded
    /// via the bundled WASM libjxl path (AnimatedJXLWebView) on first view; that
    /// decode is converted to HEVC and cached so reopens play natively.
    var isAnimatedJXL: Bool = false
    var isAnimatedImage: Bool { isAnimatedGIF || isAnimatedWebP || isAnimatedWebVisual || isAnimatedJXL }
    var currentImageData: Data? = nil
    var animatedImageSourceURL: URL? = nil
    /// Cached HEVC conversion of an animated GIF *or* animated JXL, once
    /// available — drives the unified native `<img src=mp4>` playback path in
    /// PhotoDisplayView (WebKit owns the animation lifecycle), with a `<video>`
    /// fallback if the `<img>` tier can't decode HEVC.
    var animatedHEVCURL: URL? = nil

    /// Set when the cached clip fails to decode in the native video-in-`<img>`
    /// tier (e.g. WebKit can't play HEVC in an `<img>`), flipping playback to
    /// the `<video>` player (WebVideoPlayerView), which decodes HEVC reliably.
    var animatedImgPlaybackFailed: Bool = false

    /// Background task converting an animated GIF to the cached HEVC the
    /// native playback path uses. Runs off the load path so the raw GIF
    /// displays immediately; on completion it sets `animatedHEVCURL` and
    /// playback switches to the lighter cached video. Cancelled on navigate /
    /// cleanup so a conversion never outlives the image that started it.
    var animatedConversionTask: Task<Void, Never>?

    // MARK: - UI Visibility State

    var isUIHidden: Bool = false
    var isWindowControlsHidden: Bool = false

    /// When true, the window was restored by visionOS (wall-snapped pop-out
    /// reappearing after a reboot) rather than freshly opened by the user.
    /// Suppresses global viewing-mode defaults that could otherwise switch
    /// many restored windows into 3D at once and blow the memory budget.
    var isRestoredPopOut: Bool = false
    var autoHideTask: Task<Void, Never>?
    var windowControlsHideTask: Task<Void, Never>?
    /// Auto-dismiss timer for the 3D restore prompt pill
    var autoRestorePromptDismissTask: Task<Void, Never>?
    static let autoRestorePromptTimeout: TimeInterval = 10

    // MARK: - Gallery Navigation State

    /// Snapshot of gallery images when this window was opened
    var galleryImages: [GalleryImage] = []

    /// Current index in the gallery
    var currentGalleryIndex: Int = 0

    // MARK: - Lazy Loading State

    /// Image source for loading more pages
    let imageSource: any ImageSource

    /// Snapshotted filter from when the window was opened
    let snapshotFilter: ImageFilterCriteria?

    /// Current page for this window's pagination
    var currentPage: Int

    /// Whether there are more pages to load
    var hasMorePages: Bool

    /// Page size for pagination
    let pageSize: Int

    /// Whether a page load is in progress
    var isLoadingMoreImages: Bool = false

    /// How close to the end of the loaded set before triggering a load
    let prefetchThreshold: Int = 5

    // MARK: - Shared References

    var appModel: AppModel

    /// Pop-out window value for tracking (nil for pushed/shared windows)
    let popOutWindowValue: PhotoWindowValue?

    /// When true, always use RealityKit's ImagePresentationComponent in mono mode
    /// instead of the lightweight 2D SwiftUI Image. Used by the main window picture
    /// viewer so the 2D-to-3D transition uses RealityKit's built-in animation.
    let useRealityKitDisplay: Bool

    /// Whether this model always uses RealityKit for display (even in 2D/mono mode)
    var isRealityKitDisplay: Bool { useRealityKitDisplay }

    /// The effective max resolution for this window, considering per-window override.
    /// When resolutionOverride is set, it takes priority over the global setting.
    /// A value of 0 means "Off" (full native resolution).
    var effectiveMaxResolution: Int {
        resolutionOverride ?? appModel.maxImageResolution
    }

    /// The effective spatial 3D source resolution, considering per-window override.
    /// 0 means "no cap" (use native resolution).
    var effectiveSpatial3DMaxResolution: Int {
        spatial3DResolutionOverride ?? appModel.spatial3DMaxResolution
    }

    /// The current display resolution in pixels (longest edge of the displayed image).
    /// Returns 0 when no display image is loaded (e.g., in 3D mode or loading).
    var currentDisplayResolution: Int {
        if let texture = displayTexture {
            return max(texture.width, texture.height)
        }
        guard let image = displayImage else { return 0 }
        return Int(max(image.size.width, image.size.height))
    }

    // MARK: - Initialization

    /// Whether start() has been called (guards against duplicate onAppear calls)
    private var didStart = false

    init(image: GalleryImage, appModel: AppModel, popOutWindowValue: PhotoWindowValue? = nil, useRealityKitDisplay: Bool = false) {
        self.image = image
        self.imageURL = image.fullSizeURL
        self.appModel = appModel
        self.popOutWindowValue = popOutWindowValue
        self.useRealityKitDisplay = useRealityKitDisplay
        // Stored form on purpose: the property's setter arms the stall
        // watchdog, and `init` must stay side-effect-free (SwiftUI re-creates
        // the view struct and discards duplicate models). `start()` arms it.
        self._isLoadingDetailImage = true

        // Capture pagination state for lazy loading. Local images navigate
        // over LocalImageSource's flat scan of the Documents folder, not the
        // Stash gallery the app happens to have loaded.
        if image.source == .local {
            // Scope navigation/slideshow to the folder this image lives in
            // (recursively), rather than the whole Documents directory.
            let folderRoot = image.fullSizeURL.isFileURL ? image.fullSizeURL.deletingLastPathComponent() : nil
            self.imageSource = LocalImageSource(rootURL: folderRoot)
            self.snapshotFilter = nil
            self.currentPage = 0
            self.hasMorePages = true
            self.pageSize = appModel.pageSize
            self.galleryImages = [image]
            self.currentGalleryIndex = 0
        } else {
            self.imageSource = appModel.imageSource
            self.snapshotFilter = appModel.currentFilter
            self.currentPage = appModel.currentPage
            self.hasMorePages = appModel.hasMorePages
            self.pageSize = appModel.pageSize
            self.galleryImages = appModel.galleryImages
            self.currentGalleryIndex = galleryImages.firstIndex(of: image) ?? 0
        }

        // NOTE: Side effects (openPhotoWindowCount, image loading Task) are
        // deferred to start() which is called from onAppear.  Putting them here
        // would cause them to fire every time SwiftUI re-creates the view struct,
        // even though @State discards the duplicate model.
    }

    /// Call once from onAppear to register the window and begin loading.
    func start() {
        guard !didStart else { return }
        didStart = true
        isInitialLoadInProgress = true
        // init set the loading flag through its stored backing, so arm the
        // watchdog now that the window is really starting to load.
        if isLoadingDetailImage { armLoadStallWatchdog() }

        appModel.openPhotoWindowCount += 1
        appModel.registerWindowModel(self)
        lastInteractionTime = Date()

        // Register pop-out window for duplicate detection
        if let windowValue = popOutWindowValue {
            appModel.registerPopOutWindow(imageURL: imageURL, windowValue: windowValue)
        }

        // Local images don't have a preloaded gallery on AppModel — fetch the
        // first page of LocalImageSource and relocate the current image's
        // index so prev/next navigate within local files instead of falling
        // back to position 0 of the Stash gallery.
        if image.source == .local {
            Task { await self.loadInitialLocalGallery() }
        }

        // Sequential load: resolution restore → window size restore → data → enhancement check → 2D fallback → flip restore
        Task {
            // Restore per-image settings before any image loading
            if self.appModel.rememberImageEnhancements {
                let savedOverride = await ImageEnhancementTracker.shared.resolutionOverride(url: self.imageURL)
                if savedOverride != nil {
                    self.resolutionOverride = savedOverride
                }
                let savedS3DOverride = await ImageEnhancementTracker.shared.spatial3DResolutionOverride(url: self.imageURL)
                if savedS3DOverride != nil {
                    self.spatial3DResolutionOverride = savedS3DOverride
                }
                let savedSize = await ImageEnhancementTracker.shared.windowSize(url: self.imageURL)
                if let savedSize {
                    self.savedWindowSize = savedSize
                    self.lastWindowSize = savedSize
                }
            }
            // A generated Spatial3DImage was handed over for this image (a
            // pop-out of a window already in 3D), so open straight into 3D and
            // let createImagePresentationComponent claim it — nothing to
            // generate. Deposits only exist for the moment around a pop-out, so
            // this cannot override the general "images open in 2D" policy.
            if Spatial3DImageHandoff.shared.has(key: self.spatial3DHandoffLookupKey) {
                AppLogger.photoWindow.info(
                    "[Handoff] window opening with a waiting instance — activating 3D directly"
                )
                self.activate3DMode(explicit: true)
            }
            await self.loadImageDataForDetail(url: self.imageURL)
            // Restore slider values (brightness/contrast/saturation).
            // Auto-enhance restoration is handled by autoRestorePreviousEnhancement()
            // inside loadImageDataForDetail, so the display image is already set if active.
            await self.restoreAdjustments()
            // If no enhancement was applied and it's not a GIF, load 2D display image
            if !self.isAnimatedImage && !self.is3DMode && self.backgroundRemovalState == .original && !self.currentAdjustments.isAutoEnhanced {
                let windowSize = self.lastWindowSize ?? self.appModel.mainWindowSize
                await self.loadDisplayImage(for: windowSize)
            }
            // Restore flip state (independent of other enhancements, but not for 3D/RealityKit)
            if self.appModel.rememberImageEnhancements, !self.is3DMode {
                let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: self.imageURL)
                if wasFlipped {
                    self.isImageFlipped = true
                }
            }
            self.isInitialLoadInProgress = false
            await self.applyPendingViewingMode()

            // Apply default viewing mode if nothing else has been restored.
            await self.applyDefaultViewingModeIfNeeded()
        }
    }

    // MARK: - Image Loading

    /// Load image data for the detail view and detect if it's an animated image.
    /// Pass autoRestore: false when calling from loadDisplayImage — that path only
    /// needs the raw data and must not trigger a second concurrent auto-restoration.
    func loadImageDataForDetail(url: URL, autoRestore: Bool = true) async {
        loadFailure = nil
        let data: Data
        do {
            guard let loaded = try await ImageLoader.shared.loadRawData(from: url) else {
                // The loader has nothing for this URL and no error to report
                // (an unresolvable Photos asset, a non-HTTP response). Nothing
                // downstream would clear the loading flag, so finish here.
                recordLoadFailure("This image could not be loaded.", url: url)
                return
            }
            data = loaded
        } catch {
            recordLoadFailure(loadFailureMessage(for: error), url: url, error: error)
            return
        }

        currentImageData = data
        animatedImageSourceURL = await resolveSourceFileURL() ?? url
        isAnimatedGIF = data.isAnimatedGIF
        let fileNameExtension = (image.fileName as NSString?)?.pathExtension.lowercased() ?? ""
        let visualFileType = image.visualFileType ?? ""
        let lowerURL = url.absoluteString.lowercased()
        let isWebPByURL = url.pathExtension.lowercased() == "webp" || lowerURL.contains("webp")
        let isWebPByFileName = fileNameExtension == "webp"
        let isWebPByBytes = data.isWebP
        let isAnimatedWebPByBytes = data.isAnimatedWebP
        isAnimatedWebVisual = visualFileType == "VideoFile"
        // Stash image endpoints often hide the real file extension in the URL.
        // Use the original filename from GraphQL as the format hint, then hand
        // the asset to the browser-based renderer which can display both static
        // and animated WebP correctly.
        isAnimatedWebP = isWebPByFileName || isAnimatedWebPByBytes || isWebPByBytes || isWebPByURL
        isAnimatedJXL = data.isAnimatedJXL

        if isAnimatedGIF {
            // For GIFs, calculate aspect ratio from the image data
            if let image = UIImage(data: data) {
                imageAspectRatio = image.size.width / image.size.height
            }

            // Show the raw GIF immediately — WebKit animates it in an
            // <img>. Prefer a cached HEVC clip if one already exists;
            // otherwise convert in the background (non-blocking) so this
            // session stays responsive and the next open plays the
            // lighter cached video.
            isLoadingDetailImage = false
            animatedHEVCURL = await DiskAnimatedHEVCCache.shared.cachedFileURL(for: url)
            if animatedHEVCURL == nil {
                startAnimatedConversion(data: data, url: url)
            }
        } else if isAnimatedWebP || isAnimatedWebVisual || isAnimatedJXL {
            if let image = UIImage(data: data) {
                imageAspectRatio = image.size.width / image.size.height
            }
            // Animated JXL shares the GIF HEVC path: if a prior WASM
            // decode was already converted, play that natively and skip
            // the WebView decode entirely. Otherwise AnimatedJXLWebView
            // decodes it on-device this session and kicks off the HEVC
            // conversion for next time.
            if isAnimatedJXL {
                animatedHEVCURL = await DiskAnimatedHEVCCache.shared.cachedFileURL(for: url)
            }
            isLoadingDetailImage = false
        } else if autoRestore {
            // Check if the image was previously enhanced and auto-restore
            await autoRestorePreviousEnhancement()
        }

        // Animated content never auto-generates 3D/diorama (the guards
        // in the auto paths key off isAnimatedImage). If the user's
        // settings would have auto-3D'd a still, offer 3D via the pill
        // instead so they can choose 3D (of the first frame) or just
        // watch the animation.
        if isAnimatedImage {
            await maybeOfferAnimated3DIfNeeded()
        }
    }

    /// Put the window into a recoverable failed-load state: stop loading (so the
    /// ornament unlocks), remember why, and let `PhotoDisplayView` offer a retry.
    /// Every exit from a failed load goes through here — leaving
    /// `isLoadingDetailImage` set is what used to jam the window.
    func recordLoadFailure(_ message: String, url: URL, error: Error? = nil) {
        if let error {
            AppLogger.photoWindow.error(
                "Error loading image data: \(error.localizedDescription) (\(error.logCode, privacy: .public))"
            )
        } else {
            AppLogger.photoWindow.error(
                "Image load produced no data for \(url.loggableDescription)"
            )
        }
        isInitialLoadInProgress = false
        isLoadingDetailImage = false
        loadFailure = message
    }

    func loadFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "The server took too long to respond."
            case .notConnectedToInternet:
                return "No internet connection."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach the server."
            case .networkConnectionLost:
                return "The connection was lost."
            default:
                break
            }
        }
        if let loaderError = error as? ImageLoaderError {
            return loaderError.errorDescription ?? "This image could not be loaded."
        }
        return error.localizedDescription
    }

    /// Re-run the load for the image this window is showing. Used by the failed
    /// / stalled state's Retry button.
    func retryImageLoad() async {
        recordInteraction()
        loadFailure = nil
        isLoadStalled = false
        currentImageData = nil
        currentDisplayMaxDimension = 0
        isLoadingDetailImage = true
        // The flag may already have been true (retrying a stall rather than a
        // failure), in which case the setter short-circuits — re-arm explicitly
        // so a retry that also stalls surfaces the Retry button again.
        armLoadStallWatchdog()
        await loadImageDataForDetail(url: imageURL)
        guard loadFailure == nil else { return }
        if !isAnimatedImage, !is3DMode, backgroundRemovalState == .original,
           !currentAdjustments.isAutoEnhanced {
            let windowSize = lastWindowSize ?? appModel.mainWindowSize
            await loadDisplayImage(for: windowSize)
        }
        isLoadingDetailImage = false
    }

    /// Kick off the background animated-GIF → HEVC conversion and adopt the
    /// result when it finishes. Held in `animatedConversionTask` so navigating
    /// to another image (or window cleanup) cancels it, and the completed URL
    /// is only adopted if this window is still showing the same GIF.
    func startAnimatedConversion(data: Data, url: URL) {
        animatedConversionTask?.cancel()
        animatedConversionTask = Task { [weak self] in
            let converted = try? await AnimatedHEVCConverter.shared.convert(animatedData: data, sourceURL: url)
            guard let self, !Task.isCancelled, let converted,
                  self.imageURL == url, self.isAnimatedGIF else { return }
            self.animatedHEVCURL = converted
        }
    }

    /// Record an enhancement in the tracker, but only if the setting is enabled.
    /// When true, viewing-mode changes triggered by `applyDefaultViewingModeIfNeeded`
    /// are suppressed from being persisted as a per-image user choice.
    var isApplyingDefaultViewingMode: Bool = false

    func trackViewingMode(_ mode: ViewingModePreference) async {
        guard appModel.rememberImageEnhancements else { return }
        guard !isApplyingDefaultViewingMode else { return }
        await ImageEnhancementTracker.shared.setLastViewingMode(url: imageURL, mode: mode)
    }

    func trackImageConverted() async {
        guard appModel.rememberImageEnhancements else { return }
        // The identity goes in alongside the URL: this is the one place that
        // knows both, and the converted-to-3D filter needs the identity because
        // a Stash image's URL is a server path, not an id.
        await ImageEnhancementTracker.shared.markAsConverted(url: imageURL, identity: image.identity)
    }

    /// Auto-restore the last enhancement (3D or background removal) if applicable.
    /// When useRealityKitDisplay is set, always activates RealityKit in mono mode.
    func autoRestorePreviousEnhancement() async {
        guard !isAnimatedImage, !is3DMode else { return }
        guard backgroundRemovalState == .original else { return }

        if useRealityKitDisplay {
            // Always use RealityKit — check if we should also auto-generate 3D
            if appModel.rememberImageEnhancements {
                let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
                let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)
                let defaultIs3D = appModel.defaultImageViewingMode == .spatial3D || appModel.defaultImageViewingMode == .spatial3DImmersive
                let shouldOfferRestore = appModel.autoRestoreSpatial3D && wasConverted && (lastMode == .spatial3D || lastMode == .spatial3DImmersive)
                if shouldOfferRestore && !defaultIs3D {
                    presentAutoRestorePrompt(immersive: lastMode == .spatial3DImmersive)
                }
                activate3DMode(generateImmediately: false)
            } else {
                activate3DMode(generateImmediately: false)
            }
            return
        }

        guard appModel.rememberImageEnhancements else { return }

        let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
        let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)

        if appModel.autoRestoreSpatial3D && wasConverted && (lastMode == .spatial3D || lastMode == .spatial3DImmersive) {
            // Skip the prompt when the user's default mode is already 3D /
            // immersive 3D — applyDefaultViewingModeIfNeeded will switch into
            // that mode anyway, so the offer would be redundant.
            let defaultIs3D = appModel.defaultImageViewingMode == .spatial3D || appModel.defaultImageViewingMode == .spatial3DImmersive
            if !defaultIs3D {
                presentAutoRestorePrompt(immersive: lastMode == .spatial3DImmersive)
            }
        } else if lastMode == .autoEnhanced {
            if let cachedData = await AutoEnhanceCache.shared.loadData(for: imageURL),
               let cachedImage = UIImage(data: cachedData) {
                await applyDownscaledAutoEnhance(cachedImage)
            } else {
                await performFullResolutionAutoEnhance()
            }
        } else if lastMode == .backgroundRemovedAutoEnhanced {
            // Combined state: restore bg removal with auto-enhance active
            currentAdjustments.isAutoEnhanced = true
            if let cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL) {
                await applyCachedBackgroundRemovalFromURL(cachedURL)
            } else {
                await performFullResolutionBackgroundRemoval(isAutoDuringLoad: true)
            }
        } else if lastMode == .backgroundRemoved {
            if let cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL) {
                await applyCachedBackgroundRemovalFromURL(cachedURL)
            } else {
                await performFullResolutionBackgroundRemoval(isAutoDuringLoad: true)
            }
        }
    }

    // MARK: - 2D Display Image Loading

    /// Load a downsampled display image sized appropriately for the given window size.
    /// Uses CGImageSource for memory-efficient downsampling without loading
    /// the full image into memory. No temp files are written to disk.
    func loadDisplayImage(for windowSize: CGSize) async {
        guard !isAnimatedImage else { return }
        guard !is3DMode else { return }
        guard !isLoadingDisplayImage else { return }
        guard backgroundRemovalState == .original else { return }
        guard !currentAdjustments.isAutoEnhanced else { return }

        lastWindowSize = windowSize

        isLoadingDisplayImage = true
        defer { isLoadingDisplayImage = false }

        // Ensure raw data is downloaded to disk cache.
        // autoRestore: false — auto-restoration runs exclusively from start(), not here.
        if currentImageData == nil {
            await loadImageDataForDetail(url: imageURL, autoRestore: false)
            // A second failed round trip against a dead backend buys nothing and
            // doubles the wait; the failure card already offers an explicit retry.
            guard loadFailure == nil else { return }
        }
        guard !isAnimatedImage else { return }
        // autoRestorePreviousEnhancement may have run inside loadImageDataForDetail —
        // abort the 2D load if an enhancement is now active
        guard backgroundRemovalState == .original, !is3DMode else { return }

        // Resolve source file URL (prefer disk cache, fall back to original URL)
        guard let sourceURL = await resolveSourceFileURL() else {
            AppLogger.photoWindow.error("No source file available for display image")
            isLoadingDetailImage = false
            return
        }

        // Read native dimensions from file metadata (no decode)
        if nativeImageDimensions == nil {
            nativeImageDimensions = ThumbnailGenerator.shared.getImageDimensions(for: sourceURL)
        }

        let nativeMaxDim = max(nativeImageDimensions?.width ?? 8192, nativeImageDimensions?.height ?? 8192)

        // Calculate target dimension: full native when effective resolution is off (0),
        // otherwise window size × scale factor capped at both max resolution and native.
        // During initial load, use max resolution directly — window size is unreliable
        // during visionOS scene restoration and the resize handler will adjust later.
        let effectiveRes = effectiveMaxResolution
        let targetDimension: CGFloat
        if effectiveRes > 0 {
            let maxRes = CGFloat(effectiveRes)
            if isInitialLoadInProgress {
                targetDimension = min(maxRes, nativeMaxDim)
            } else {
                targetDimension = min(
                    max(windowSize.width, windowSize.height) * Self.displayScaleFactor,
                    maxRes,
                    nativeMaxDim
                )
            }
        } else {
            targetDimension = nativeMaxDim
        }

        // Skip if already loaded at a similar resolution (within 20%)
        if displayTexture != nil, currentDisplayMaxDimension > 0 {
            let ratio = targetDimension / currentDisplayMaxDimension
            if ratio > 0.8 && ratio < 1.2 {
                // Already at a good-enough resolution — but this is still an
                // exit from the load, so release the loading state rather than
                // leaving the ornament locked.
                isLoadingDetailImage = false
                return
            }
        }

        let newCacheKey = SharedTextureCache.TextureKey(
            imageURL: imageURL.absoluteString,
            maxDimension: Int(targetDimension)
        )

        // Restored windows get a fresh GPU allocation. The exact-resolution
        // reproduction strongly correlates with acquiring the same shared
        // texture as an already-broken restored window; do not let a restored
        // scene consume or seed the cross-window cache while diagnosing that.
        let allowsSharedTexture = !isRestoredPopOut

        // Release previous cache entry if switching to a different resolution
        if let oldKey = displayTextureCacheKey, oldKey != newCacheKey {
            SharedTextureCache.shared.release(key: oldKey)
            displayTextureCacheKey = nil
        }

        // Try shared texture cache first — another window may already have this texture
        if allowsSharedTexture, let cached = SharedTextureCache.shared.acquire(key: newCacheKey) {
            AppLogger.windowState.info(
                "[Photo \(self.displayName, privacy: .private(mask: .hash))] shared texture hit dimension=\(newCacheKey.maxDimension, privacy: .public)"
            )
            displayTexture = cached.texture
            imageAspectRatio = cached.aspectRatio
            currentDisplayMaxDimension = targetDimension
            displayTextureCacheKey = newCacheKey
            isLoadingDetailImage = false
            return
        }

        // Downsample and upload to GPU texture off main thread.
        // When effective resolution is off (0), force full-quality decode to bypass
        // CGImageSource thumbnail API which can introduce interpolation artifacts.
        let useLossy = appModel.useLossyTextureCompression
        let fullDecode = effectiveRes == 0
        let sendable = await Task.detached { [sourceURL, targetDimension, useLossy, fullDecode] () -> SendableTexture? in
            guard let tex = MetalImageRenderer.shared?.createTexture(from: sourceURL, maxDimension: targetDimension, useLossyCompression: useLossy, forceFullDecode: fullDecode) else { return nil }
            return SendableTexture(texture: tex)
        }.value

        guard let texture = sendable?.texture else {
            let error = ImageLoaderError.decodeFailed
            recordLoadFailure(loadFailureMessage(for: error), url: sourceURL, error: error)
            return
        }

        // Re-check after off-thread downsampling: an enhancement may have been applied
        // concurrently (e.g., from the start() task running in parallel with this load)
        guard backgroundRemovalState == .original, !is3DMode, !currentAdjustments.isAutoEnhanced else {
            isLoadingDetailImage = false
            return
        }

        displayTexture = texture
        imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
        currentDisplayMaxDimension = targetDimension

        if allowsSharedTexture {
            SharedTextureCache.shared.store(key: newCacheKey, texture: texture, aspectRatio: imageAspectRatio)
            displayTextureCacheKey = newCacheKey
        } else {
            AppLogger.windowState.info(
                "[Photo \(self.displayName, privacy: .private(mask: .hash))] restored window using private texture dimension=\(Int(targetDimension), privacy: .public)"
            )
        }
        isLoadingDetailImage = false
    }

    /// Auto-restore background removal by applying to the current display image.
    /// Unlike the user-initiated toggle, this processes the already-downsampled display image
    /// to avoid jarring resizes. Only updates in-memory cache (not persistent cache).
    /// Handle window resize with 1-second debounce. Re-downsamples the display
    /// image in memory when the window size changes significantly.
    /// No-op when dynamic image resolution is disabled (already at full res).
    func handleWindowResize(_ newSize: CGSize) {
        // Update LRU timestamp but don't trigger idle-downscale restore.
        // SwiftUI fires geometry changes when content is cleared (e.g. during
        // memory-pressure downscale), which would cause an immediate re-restore.
        lastInteractionTime = Date()
        lastWindowSize = newSize

        // Persist window size (debounced alongside the image reload)
        // Skip persistence when in 3D immersive mode — the window is
        // temporarily expanded to fill the field of vision and should
        // not overwrite the user's actual window size.
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }

            // Persist the window size for this image (skip during immersive 3D)
            if !self.isViewingSpatial3DImmersive {
                await self.trackWindowSize(newSize)
            }

            // Re-downsample display image if dynamic resolution is active
            guard self.effectiveMaxResolution > 0 else { return }
            guard !self.is3DMode, !self.isAnimatedImage else { return }
            guard !self.isLoadingDetailImage, !self.isLoadingDisplayImage else { return }
            guard !self.isInitialLoadInProgress else { return }
            guard self.displayTexture != nil || self.displayImage != nil else { return }

            if self.backgroundRemovalState == .removed {
                await self.reloadBackgroundRemovedAtCurrentResolution()
            } else if self.currentAdjustments.isAutoEnhanced {
                await self.reloadAutoEnhancedAtCurrentResolution()
            } else if self.backgroundRemovalState == .original {
                await self.loadDisplayImage(for: newSize)
            }
        }
    }

    /// Resolve the file URL for the current image (disk cache or original file URL)
    func resolveSourceFileURL() async -> URL? {
        await Self.localFileURL(for: imageURL)
    }

    /// The local file backing `url`, whatever kind of URL it is.
    ///
    /// The single answer to "give me something CGImageSource, AVFoundation or
    /// ImagePresentationComponent can open". Three call sites previously each
    /// had their own version handling only file URLs and the disk cache, which
    /// is exactly why a `photos-asset:///` URL reached CGImageSource and failed
    /// with "The file 001 couldn't be opened" — the schemes those copies did not
    /// know about fell through to being used verbatim.
    ///
    /// Returns nil when no local file can be produced; callers decide whether
    /// that is fatal or worth a download attempt.
    static func localFileURL(for url: URL) async -> URL? {
        if url.isFileURL { return url }
        // A Photos asset has no URL of its own — it is addressed by a synthetic
        // one and materialized on first use.
        if PhotosAssetURL.isPhotosAsset(url) {
            return await PhotosAssetStore.shared.fileURL(for: url)
        }
        return await DiskImageCache.shared.cachedFileURL(for: url)
    }

    // MARK: - Interaction Tracking

    /// Record a user interaction with this window. Updates the LRU timestamp
    /// and restores from idle downscale if the window was previously evicted.
    func recordInteraction() {
        lastInteractionTime = Date()

        if isIdleDownscaled {
            Task {
                await restoreFromIdleDownscale()
            }
        }
    }

    // MARK: - Shared Utilities

    /// Calculate the target dimension for background-removed image downsampling.
    /// Mirrors the logic from loadDisplayImage / downscaleForDisplay.
    func backgroundRemovalTargetDimension() -> CGFloat {
        let effectiveRes = effectiveMaxResolution
        guard effectiveRes > 0 else { return 8192 } // No limit

        let maxRes = CGFloat(effectiveRes)
        if isInitialLoadInProgress {
            return maxRes
        }
        let windowSize = lastWindowSize ?? appModel.mainWindowSize
        return min(
            max(windowSize.width, windowSize.height) * Self.displayScaleFactor,
            maxRes
        )
    }

    /// Downscale an image for display using the same strategy as loadDisplayImage.
    /// Mirrors the target-dimension logic: min(windowSize × scale, maxRes, nativeMax).
    func downscaleForDisplay(_ image: UIImage) async -> UIImage {
        let effectiveRes = effectiveMaxResolution
        // If dynamic resolution is disabled, use the image as-is
        guard effectiveRes > 0 else {
            return image
        }

        let maxRes = CGFloat(effectiveRes)
        let imageWidth = image.size.width
        let imageHeight = image.size.height
        let nativeMaxDim = max(imageWidth, imageHeight)

        // Match loadDisplayImage: window size × scale, capped at max resolution and native
        let windowSize = lastWindowSize ?? appModel.mainWindowSize
        let targetDimension = min(
            max(windowSize.width, windowSize.height) * Self.displayScaleFactor,
            maxRes,
            nativeMaxDim
        )

        guard nativeMaxDim > targetDimension else {
            return image // Already smaller than target, no downsampling needed
        }

        // Bit-depth-preserving downscale via CGImageDeepColor: UIGraphicsImageRenderer
        // would flatten 16-bit sources (e.g. JXL upscaler output) to 8-bit.
        guard let cgImage = image.cgImage else { return image }
        let scaleFactor = targetDimension / nativeMaxDim
        let newWidth = Int((CGFloat(cgImage.width) * scaleFactor).rounded())
        let newHeight = Int((CGFloat(cgImage.height) * scaleFactor).rounded())

        guard let resized = CGImageDeepColor.redraw(cgImage, size: (newWidth, newHeight)) else {
            return image
        }
        return UIImage(cgImage: resized, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Downscale a UIImage for display and upload directly to a GPU-private texture.
    /// The intermediate UIImage is freed after upload, keeping only the GPU texture alive.
    /// Pass `autoCropTransparentEdges: false` for background-removed images —
    /// their output is a full-source-frame canvas with the subject inside a
    /// transparent border (see `BackgroundRemover`, commit "Preserve source
    /// frame size in background removal output"). Cropping the margins here
    /// re-collapses the frame to the subject's bounding box, which for flat
    /// images with a small foreground mask shifts the aspect ratio and shrinks
    /// the viewer window — the bug f748109 was meant to fix, reintroduced at
    /// the texture-upload step.
    func downscaleAndUploadTexture(_ image: UIImage, autoCropTransparentEdges: Bool = true) async -> MTLTexture? {
        let downscaled = await downscaleForDisplay(image)
        let useLossy = appModel.useLossyTextureCompression
        let sendable = await Task.detached { [useLossy] in
            guard let tex = MetalImageRenderer.shared?.createTexture(from: downscaled, useLossyCompression: useLossy, autoCropTransparentEdges: autoCropTransparentEdges) else { return nil as SendableTexture? }
            return SendableTexture(texture: tex)
        }.value
        return sendable?.texture
    }

    // MARK: - Resource Cleanup

    /// Explicitly release large resources when the window is being dismissed.
    /// Ensures GPU textures and image data are freed promptly rather than
    /// waiting for ARC/deinit which may be delayed by SwiftUI state retention.
    func cleanup() {
        // Cancel all tasks
        scenePhaseIdleTask?.cancel()
        scenePhaseIdleTask = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        adjustments3DReloadTask?.cancel()
        adjustments3DReloadTask = nil
        adjustmentPreviewTeardownTask?.cancel()
        adjustmentPreviewTeardownTask = nil
        // Clearing the flag disarms the stall watchdog through the setter.
        isLoadingDetailImage = false
        loadFailure = nil

        // If 3D generation is in progress, we CANNOT remove the
        // ImagePresentationComponent — RealityKit's generate() ignores Swift
        // cooperative cancellation and will crash if the component is gone when
        // its progress callback fires. Instead, cancel the task and let the
        // entity + component be deallocated naturally when the model is released.
        let generationActive = generateTask != nil
        generateTask?.cancel()
        generateTask = nil

        pendingViewingMode = nil

        // Release Spatial3DImage GPU texture. A handoff reference (deposited
        // for, or claimed from, another window) is refcounted separately — the
        // registry keeps the instance alive for whoever else holds it.
        if let handoffKey = spatial3DHandoffKey {
            Spatial3DImageHandoff.shared.release(key: handoffKey)
            spatial3DHandoffKey = nil
        }
        spatial3DImage = nil
        spatial3DImageState = .notGenerated

        // Release shared texture cache reference
        if let cacheKey = displayTextureCacheKey {
            SharedTextureCache.shared.release(key: cacheKey)
            displayTextureCacheKey = nil
        }

        // Release image data
        animatedConversionTask?.cancel()
        animatedConversionTask = nil
        animatedImgPlaybackFailed = false
        currentImageData = nil
        animatedImageSourceURL = nil
        animatedHEVCURL = nil
        displayTexture = nil
        displayImage = nil
        isShowingAdjustmentPreview = false
        clearAutoEnhanceState()
        clearBackgroundRemovalState()
        clearDioramaState()

        // Only remove the component if generation is NOT active.
        // If active, the entity retains the component until ARC releases both.
        if !generationActive {
            contentEntity.components.remove(ImagePresentationComponent.self)
        }

        // Clear collection references
        galleryImages = []

        // Unregister pop-out window
        if let windowValue = popOutWindowValue {
            appModel.unregisterPopOutWindow(imageURL: imageURL, windowValueId: windowValue.id)
        }

        if didStart {
            appModel.unregisterWindowModel(self)
            appModel.openPhotoWindowCount -= 1
        }
    }
}
