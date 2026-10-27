/*
 Hypnos - Photo Ornament View

 Unified ornament for all picture viewer windows.
 Controls are configured via PhotoViewerContext to show/hide
 navigation, slideshow, rating, and context-specific buttons.

 Layout: [Gallery] | [< N/M >] | [Slideshow] | [3D v] | [Info] | [Share] | [Adjustments] | [extras] | [Resolution]

 "Adjustments" opens the image-enhancements popover (brightness/contrast/saturation,
 auto-enhance, background removal, and flip — all unified there). "extras" are
 context-specific icon buttons (Pop Out when pushed, Save when shared).
 */

import RealityKit
import RAVEUI
import SwiftUI

/// Footprint a spinner is pinned to when it stands in for a glyph or a label
/// in the ornament bar. A `ProgressView`'s intrinsic height is taller than a
/// `.title3` icon or a `.callout` line, and `scaleEffect` scales rendering
/// without changing layout — so an unconstrained spinner grows the bar's
/// height for as long as it is on screen. File-scope rather than a static on
/// the view: `PhotoOrnamentView` is generic, and generic types can't hold
/// static stored properties.
private let ornamentGlyphSize: CGFloat = 22

/// Determines which controls are visible in the photo ornament
enum PhotoViewerContext {
    /// Pushed from gallery grid — back button (dismissWindow), nav, slideshow, 3D, rating, extra buttons
    case pushedFromGallery
    /// Standalone pop-out window — gallery button (openWindow), nav, slideshow, 3D, rating
    case standalone
    /// Shared media viewer — gallery button (openWindow), 3D only
    case shared
}

struct PhotoOrnamentView<ExtraMenuItems: View>: View {
    @Bindable var windowModel: PhotoWindowModel
    let context: PhotoViewerContext
    var onGalleryButtonTap: () -> Void
    @ViewBuilder var extraMenuItems: () -> ExtraMenuItems
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow
    #if !os(visionOS)
    /// Set while the ornament's horizontal scroller is being dragged; see
    /// `EnvironmentValues.ornamentIsScrolling`.
    @Environment(\.ornamentIsScrolling) private var ornamentIsScrolling
    #endif

    var body: some View {
        HStack(spacing: RAVEChromeMetrics.spacing) {
            // Gallery / Back button
            Button(action: onGalleryButtonTap) {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .raveChromeButtonStyle()
            .help(context == .pushedFromGallery ? "Pictures" : "Show Gallery")

            Divider()
                .frame(height: 24)

            if context != .shared {
                navigationControls

                Divider()
                    .frame(height: 24)

                slideshowButton

                Divider()
                    .frame(height: 24)
            }

            if PlatformCapabilities.supportsSpatial3D {
                threeDMenu
            }

            // Info button (rating / metadata — when stashId exists and not shared context)
            if context != .shared, windowModel.image.stashId != nil {
                Divider()
                    .frame(height: 24)

                infoButton
            }

            Divider()
                .frame(height: 24)

            shareButton

            Divider()
                .frame(height: 24)

            adjustmentsButton

            // Context-specific extras (Pop Out / Save). Rendered inline as
            // icon-only buttons — there's at most one in any context, so a
            // dedicated "More" menu would be a single-item drop-down.
            extraMenuItems()
                .labelStyle(.iconOnly)
                .raveChromeButtonStyle()
                .font(.title3)

            // Resolution indicator: in 3D mode controls the spatial 3D source
            // resolution; otherwise controls the 2D display resolution.
            if windowModel.is3DMode {
                if !windowModel.isAnimatedImage, windowModel.currentSpatial3DSourceDimension > 0 {
                    resolutionMenu
                }
            } else if !windowModel.isRealityKitDisplay, !windowModel.isAnimatedImage,
                      windowModel.displayTexture != nil || windowModel.displayImage != nil {
                resolutionMenu
            }
        }
        .padding(.horizontal, RAVEChromeMetrics.horizontalPadding)
        .padding(.vertical, RAVEChromeMetrics.verticalPadding)
        .glassBackgroundEffect()
        #if !os(visionOS)
        // The bar scrolls when it is wider than the screen, and a scroll is
        // not a button press — without this the chrome auto-hides out from
        // under the finger mid-drag. The signal comes from the scroller
        // (`\.ornamentIsScrolling`) rather than from a drag gesture here: a
        // zero-distance DragGesture on the scroller's content takes the touch
        // at touch-down and the pan never starts, which is what made the
        // controls past the right edge unreachable.
        .onChange(of: ornamentIsScrolling) { _, isScrolling in
            if isScrolling { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        #endif
        .onChange(of: windowModel.showMediaInfoPopover) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: windowModel.showAdjustmentsPopover) { _, isOpen in
            if isOpen {
                windowModel.cancelAutoHideTimer()
                // Pre-load the preview thumbnail while the user is
                // reaching for the slider so the first slider tick can
                // flip into the 2D preview synchronously. Loading on
                // first slider tick was lossy: continuous drag kept the
                // MainActor busy and the async thumbnail Task's
                // continuation didn't get a chance to run until the
                // drag paused, making the live preview feel like it
                // appeared a beat too late.
                Task { await windowModel.prewarmAdjustmentPreview() }
            } else {
                windowModel.startAutoHideTimer()
                windowModel.clearAdjustmentPreviewIfUnused()
            }
        }
    }

    // MARK: - Navigation Controls

    @ViewBuilder
    private var navigationControls: some View {
        Button {
            Task {
                await windowModel.previousGalleryImage()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.title3)
        }
        .raveChromeButtonStyle()
        .disabled(!windowModel.hasPreviousGalleryImage || windowModel.controlsLocked)

        if windowModel.controlsLocked {
            // Same footprint as the position counter it replaces. A bare
            // ProgressView is taller than a .callout line, and scaleEffect
            // only scales rendering, not layout — so without an explicit
            // height the whole ornament bar grows while an image loads and
            // shrinks again when it lands.
            ProgressView()
                .controlSize(.small)
                .frame(height: ornamentGlyphSize)
                .frame(minWidth: 60)
        } else if windowModel.loadFailure != nil {
            // A failed load replaces the position counter rather than the
            // spinner that used to sit here forever.
            Image(systemName: "exclamationmark.triangle")
                .font(.callout)
                .foregroundColor(.orange)
                .frame(minWidth: 60)
                .help(windowModel.loadFailure ?? "")
        } else {
            Text("\(windowModel.currentGalleryPosition) / \(windowModel.galleryImageCount)")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(minWidth: 60)
        }

        Button {
            Task {
                await windowModel.nextGalleryImage()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.title3)
        }
        .raveChromeButtonStyle()
        .disabled(!windowModel.hasNextGalleryImage || windowModel.controlsLocked)
    }

    // MARK: - Slideshow Button

    private var slideshowButton: some View {
        Button {
            launchGallerySlideshow()
        } label: {
            Image(systemName: "play.fill")
                .font(.title3)
        }
        .raveChromeButtonStyle()
        .disabled(windowModel.controlsLocked)
        .help("Slideshow")
    }

    private func launchGallerySlideshow() {
        windowModel.appModel.startGallerySlideshow(
            imageSource: windowModel.imageSource,
            filter: windowModel.snapshotFilter
        )
    }

    // MARK: - 3D Menu

    private var threeDMenu: some View {
        Menu {
            // .onAppear/.onDisappear pause the host's auto-hide while the menu
            // is open (same pattern as VideoOrnamentsView).
            Group {
                // Menus spell the pipeline out; "RK" is only the short form
                // (the button's tooltip). AI 3D stays last.
                nativeMenuButton(
                    title: "RealityKit 3D",
                    icon: "spatial.capture.fill",
                    isChecked: windowModel.desiredViewingMode == .spatial3D,
                    isDisabled: windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode != .spatial3DImmersive
                ) {
                    Task {
                        if windowModel.desiredViewingMode == .spatial3D {
                            await windowModel.switchToViewingMode(.mono)
                        } else {
                            await windowModel.switchToViewingMode(.spatial3D)
                        }
                    }
                }

                nativeMenuButton(
                    title: "RealityKit 3D (Immersive)",
                    icon: "inset.filled.pano",
                    isChecked: windowModel.desiredViewingMode == .spatial3DImmersive,
                    isDisabled: windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode != .spatial3D
                ) {
                    Task {
                        if windowModel.desiredViewingMode == .spatial3DImmersive {
                            await windowModel.switchToViewingMode(.mono)
                        } else {
                            await windowModel.switchToViewingMode(.spatial3DImmersive)
                        }
                    }
                }

                nativeMenuButton(
                    title: "Diorama",
                    icon: "spatial.capture.on.hexagon",
                    isChecked: windowModel.isDioramaMode,
                    isDisabled: windowModel.isAnimatedImage || windowModel.isRealityKitDisplay || windowModel.isProcessingDiorama
                ) {
                    Task {
                        await windowModel.toggleDiorama()
                    }
                }

                // Depth from the real-time model on one mesh: engages in
                // about a second, where RealityKit 3D takes several.
                nativeMenuButton(
                    title: windowModel.isAIDepthAvailable ? "AI 3D" : "AI 3D (needs a depth model)",
                    icon: "wand.and.sparkles",
                    isChecked: windowModel.isAIDepthMode,
                    isDisabled: !windowModel.isAIDepthAvailable || windowModel.isAnimatedImage
                        || windowModel.isRealityKitDisplay || windowModel.isProcessingAIDepth
                ) {
                    Task {
                        await windowModel.toggleAIDepth()
                    }
                }

                if isAnyAlternateModeActive {
                    Divider()

                    nativeMenuButton(
                        title: "2D",
                        icon: "rectangle",
                        isChecked: false
                    ) {
                        Task {
                            if windowModel.isDioramaMode {
                                await windowModel.setDioramaMode(false)
                            }
                            if windowModel.isAIDepthMode {
                                await windowModel.setAIDepthMode(false)
                            }
                            if windowModel.desiredViewingMode != .mono {
                                await windowModel.switchToViewingMode(.mono)
                            }
                        }
                    }
                }
            }
            .onAppear { updateOrnamentMenuCount(opened: true) }
            .onDisappear { updateOrnamentMenuCount(opened: false) }
        } label: {
            Group {
                if windowModel.spatial3DImageState == .generating || windowModel.isProcessingAIDepth {
                    // Constrain the spinner to the icon's footprint. scaleEffect
                    // only scales rendering, not layout, so without a fixed frame
                    // the default ProgressView is taller than the .title3 icon and
                    // grows the ornament's height while converting.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: ornamentGlyphSize, height: ornamentGlyphSize)
                } else {
                    Image(systemName: threeDMenuIcon)
                }
            }
            .font(.title3)
            .padding(6)
            .background(isAnyAlternateModeActive ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .menuStyle(.button)
        .raveChromeButtonStyle()
        // Enabled for animated images too: 3D / Immersive 3D convert the first
        // frame (the same explicit path the auto-restore pill uses), and 2D
        // returns to the animation. Diorama stays disabled for animated via its
        // own item flag — it's a separate pipeline, not part of this.
        .help(threeDMenuHelp)
    }

    /// The short form of the mode in force: there's no room for
    /// "RealityKit" in a tooltip.
    private var threeDMenuHelp: String {
        if windowModel.isAIDepthMode { return "3D: AI 3D" }
        if windowModel.isDioramaMode { return "3D: Diorama" }
        switch windowModel.desiredViewingMode {
        case .spatial3D: return "3D: RK 3D"
        case .spatial3DImmersive: return "3D: RK 3D (Immersive)"
        default: return "3D"
        }
    }

    private var is3DModeActive: Bool {
        windowModel.desiredViewingMode == .spatial3D || windowModel.desiredViewingMode == .spatial3DImmersive
    }

    private var isAnyAlternateModeActive: Bool {
        is3DModeActive || windowModel.isDioramaMode || windowModel.isAIDepthMode
    }

    private var threeDMenuIcon: String {
        if windowModel.isAIDepthMode { return "wand.and.sparkles" }
        if windowModel.isDioramaMode { return "spatial.capture.on.hexagon" }
        switch windowModel.desiredViewingMode {
        case .spatial3D: return "spatial.capture.fill"
        case .spatial3DImmersive: return "inset.filled.pano"
        default: return "view.3d"
        }
    }

    // MARK: - Resolution Menu

    private var resolutionMenu: some View {
        let is3D = windowModel.is3DMode
        let activeOverride = is3D ? windowModel.spatial3DResolutionOverride : windowModel.resolutionOverride
        let displayResolution = is3D ? windowModel.currentSpatial3DSourceDimension : windowModel.currentDisplayResolution
        let helpPrefix = is3D ? "3D Source Resolution" : "Image Resolution"

        return Menu {
            Group {
                nativeMenuButton(
                    title: "Auto",
                    isChecked: activeOverride == nil
                ) {
                    Task {
                        if is3D {
                            await windowModel.applySpatial3DResolutionOverride(nil)
                        } else {
                            await windowModel.applyResolutionOverride(nil)
                        }
                    }
                }

                Divider()

                ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                    nativeMenuButton(
                        title: option.label,
                        isChecked: activeOverride == option.value
                    ) {
                        Task {
                            if is3D {
                                await windowModel.applySpatial3DResolutionOverride(option.value)
                            } else {
                                await windowModel.applyResolutionOverride(option.value)
                            }
                        }
                    }
                }
            }
            .onAppear { updateOrnamentMenuCount(opened: true) }
            .onDisappear { updateOrnamentMenuCount(opened: false) }
        } label: {
            Text("\(displayResolution)px")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(activeOverride != nil ? .accentColor : .secondary)
        }
        .menuStyle(.button)
        .raveChromeButtonStyle()
        .disabled(windowModel.controlsLocked)
        .help(activeOverride != nil ? "\(helpPrefix) Override: \(resolutionOverrideLabel)" : helpPrefix)
    }

    /// Label for the current resolution override setting
    private var resolutionOverrideLabel: String {
        let override = windowModel.is3DMode ? windowModel.spatial3DResolutionOverride : windowModel.resolutionOverride
        guard let override else { return "Auto" }
        return AppModel.maxImageResolutionOptions.first { $0.value == override }?.label ?? "\(override)px"
    }

    // MARK: - Info Button (Rating & Metadata)

    private var infoButton: some View {
        Button {
            windowModel.showMediaInfoPopover.toggle()
        } label: {
            Image(systemName: windowModel.image.rating100 != nil ? "info.circle.fill" : "info.circle")
                .font(.title3)
                .foregroundColor(windowModel.image.rating100 != nil ? .yellow : nil)
        }
        .raveChromeButtonStyle()
        .disabled(windowModel.controlsLocked)
        .help("Info")
        .sheet(isPresented: Bindable(windowModel).showMediaInfoPopover) {
            if let stashId = windowModel.image.stashId {
                MediaDetailSheet(
                    mediaType: .image(stashId: stashId),
                    onDelete: {
                        // Remove from gallery and close this photo window (the
                        // sheet only dismisses itself; the window would otherwise
                        // linger showing the now-deleted image).
                        let appModel = windowModel.appModel
                        if let idx = appModel.galleryImages.firstIndex(where: { $0.stashId == stashId }) {
                            appModel.galleryImages.remove(at: idx)
                        }
                        dismissWindow()
                    },
                    onSaved: { newRating in
                        windowModel.image.rating100 = newRating
                        if let idx = windowModel.galleryImages.firstIndex(where: { $0.stashId == stashId }) {
                            windowModel.galleryImages[idx].rating100 = newRating
                        }
                    }
                )
            }
        }
    }

    // MARK: - Adjustments Button (image enhancements: sliders, auto-enhance, background removal, flip)

    private var adjustmentsButton: some View {
        Button {
            windowModel.showAdjustmentsPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .padding(6)
                .background(adjustmentsHighlighted ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .raveChromeButtonStyle()
        .help("Adjustments")
        .popover(isPresented: Bindable(windowModel).showAdjustmentsPopover) {
            VisualAdjustmentsPopover(
                currentAdjustments: Binding(
                    get: { windowModel.currentAdjustments },
                    set: { windowModel.currentAdjustments = $0 }
                ),
                globalAdjustments: Binding(
                    get: { windowModel.appModel.globalVisualAdjustments },
                    set: {
                        windowModel.appModel.globalVisualAdjustments = $0
                        if !windowModel.currentAdjustments.isModified {
                            windowModel.reloadImagePresentationWithAdjustments()
                        }
                    }
                ),
                showAutoEnhance: !windowModel.isAnimatedImage,
                // RealityKit's IPC doesn't honor compositing-time
                // sharpen, so hide the per-image slider while a 3D
                // image is on screen (animated images don't use the
                // sharpen shader path either).
                showSharpen: !windowModel.is3DMode && !windowModel.isAnimatedImage,
                // "Distance" for spatial-3D photos, persisted separately for the
                // two context-menu modes: regular 3D (.spatial3D) vs portal
                // Immersive 3D (.spatial3DImmersive). Bind to whichever is active.
                scale3D: windowModel.is3DMode ? Binding(
                    get: {
                        windowModel.desiredViewingMode == .spatial3DImmersive
                            ? windowModel.currentAdjustments.immersiveScale
                            : windowModel.currentAdjustments.scale
                    },
                    set: { newValue in
                        if windowModel.desiredViewingMode == .spatial3DImmersive {
                            windowModel.currentAdjustments.immersiveScale = newValue
                        } else {
                            windowModel.currentAdjustments.scale = newValue
                        }
                    }
                ) : nil,
                isProcessingAutoEnhance: windowModel.isProcessingAutoEnhance,
                onToggleAutoEnhance: {
                    Task {
                        await windowModel.toggleAutoEnhance()
                    }
                },
                onCurrentAdjustmentsChanged: { adjustments in
                    Task {
                        await windowModel.trackAdjustments()
                    }
                    windowModel.reloadImagePresentationWithAdjustments()
                },
                showBackgroundRemoval: !windowModel.isRealityKitDisplay,
                backgroundRemovalState: windowModel.backgroundRemovalState,
                onToggleBackgroundRemoval: {
                    Task {
                        await windowModel.toggleBackgroundRemoval()
                    }
                },
                showAIHDR: Self.offersAIHDR && !windowModel.isAnimatedImage && !windowModel.isRealityKitDisplay
                    && windowModel.backgroundRemovalState == .original && !windowModel.currentAdjustments.isAutoEnhanced,
                isAIHDREnabled: windowModel.aiHDREnabled,
                isProcessingAIHDR: windowModel.isProcessingAIHDR,
                onToggleAIHDR: {
                    Task {
                        await windowModel.toggleAIHDR()
                    }
                },
                showFlip: !windowModel.isRealityKitDisplay && !windowModel.is3DMode,
                isImageFlipped: windowModel.isImageFlipped,
                onToggleFlip: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        windowModel.toggleFlip()
                    }
                }
            )
        }
    }

    /// AI HDR needs an EDR layer, which tvOS doesn't have.
    private static var offersAIHDR: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// Increment / decrement the open-menu counter on `windowModel`. Clamped
    /// at zero so a missed event can't drive the count negative.
    private func updateOrnamentMenuCount(opened: Bool) {
        if opened {
            windowModel.openOrnamentMenuCount += 1
            windowModel.cancelAutoHideTimer()
        } else {
            windowModel.openOrnamentMenuCount = max(0, windowModel.openOrnamentMenuCount - 1)
            if windowModel.openOrnamentMenuCount == 0 {
                windowModel.startAutoHideTimer()
            }
        }
    }

    /// Whether the Adjustments button should show a highlight (adjustments modified or image flipped)
    private var adjustmentsHighlighted: Bool {
        windowModel.effectiveAdjustments.isModified || windowModel.isImageFlipped
    }

    // MARK: - Share

    private var shareButton: some View {
        Button {
            Task {
                await windowModel.shareImage()
            }
        } label: {
            Group {
                if windowModel.isPreparingShare {
                    // Constrained to the icon's footprint for the same reason
                    // as the loading spinner in `navigationControls`.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: ornamentGlyphSize, height: ornamentGlyphSize)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .font(.title3)
        }
        .raveChromeButtonStyle()
        .disabled(windowModel.isPreparingShare || windowModel.controlsLocked)
        .help("Share")
        .shareSheet(url: $windowModel.shareFileURL) {
            windowModel.startAutoHideTimer()
        }
    }

    // MARK: - Native Menu Item Helper

    /// Radio-style item for a native visionOS `Menu`: leading icon (optional),
    /// title, and a trailing checkmark on the selected entry. Matches the item
    /// style used by VideoOrnamentsView's ViewMode menu.
    private func nativeMenuButton(
        title: String,
        icon: String? = nil,
        isChecked: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if let icon {
                    Label(title, systemImage: icon)
                } else {
                    Text(title)
                }
                if isChecked {
                    Image(systemName: "checkmark")
                }
            }
        }
        .disabled(isDisabled)
    }
}
