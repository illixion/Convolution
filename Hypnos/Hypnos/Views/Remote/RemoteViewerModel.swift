/*
 Hypnos - Remote Viewer Model

 The slideshow window's model: a SlideshowEngine plus the window's profile
 (`RemoteViewerConfig`), the clock overlay, and the display toggles the
 ornament and adjustments panel write back to that profile.
 */

import DebugTrace
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation

@MainActor
@Observable
class RemoteViewerModel: SlideshowEngine {
    // MARK: - Configuration

    var config: RemoteViewerConfig
    var windowValue: RemoteViewerWindowValue?

    var showClock: Bool = true

    /// Whether the current video should loop: true unless its clip length
    /// exceeds the interval, in which case it plays once and freezes on its
    /// last frame so it doesn't restart its opening frame before the advance.
    private(set) var currentVideoLoops: Bool = true

    /// Callback to persist config changes back to AppModel
    var onConfigChanged: ((RemoteViewerConfig) -> Void)?

    // MARK: - Init

    init(config: RemoteViewerConfig) {
        self.config = config
        self.showClock = config.showClock

        super.init(
            delay: config.delay,
            enableKenBurns: config.enableKenBurns,
            useAspectRatio: config.useAspectRatio,
            enableDynamicBrightness: config.enableDynamicBrightness,
            enableDiorama: config.enableDiorama
        )
    }

    // MARK: - Actions

    func advanceToNext() {
        goToNextImage()
    }

    func toggleClock() {
        showClock.toggle()
    }

    // MARK: - Bindable Display Toggles
    //
    // Bridging properties for the Viewer tab of VisualAdjustmentsPopover.
    // Several display flags live on both the engine (runtime source of truth)
    // and `config` (persistence). Writing through these setters keeps the
    // two in sync and triggers `onConfigChanged` so the change is saved.

    var displayShowClock: Bool {
        get { showClock }
        set {
            showClock = newValue
            if config.showClock != newValue {
                config.showClock = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableKenBurns: Bool {
        get { enableKenBurns }
        set {
            enableKenBurns = newValue
            if config.enableKenBurns != newValue {
                config.enableKenBurns = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableDynamicBrightness: Bool {
        get { enableDynamicBrightness }
        set {
            enableDynamicBrightness = newValue
            if config.enableDynamicBrightness != newValue {
                config.enableDynamicBrightness = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableDiorama: Bool {
        get { enableDiorama }
        set {
            enableDiorama = newValue
            if config.enableDiorama != newValue {
                config.enableDiorama = newValue
                onConfigChanged?(config)
            }
            // When toggled on while a post is already displayed, kick off
            // foreground generation so the overlay appears without waiting
            // for the next slide to advance.
            if newValue, let post = currentPost, let image = currentImage, currentForegroundTexture == nil {
                generateDioramaForeground(post: post, image: image, isCurrent: true)
            }
        }
    }

    var displayTransparentBackground: Bool {
        get { config.transparentBackground }
        set {
            if config.transparentBackground != newValue {
                config.transparentBackground = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayUseAspectRatio: Bool {
        get { useAspectRatio }
        set {
            useAspectRatio = newValue
            if config.useAspectRatio != newValue {
                config.useAspectRatio = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayDelay: TimeInterval {
        get { delay }
        set {
            delay = newValue
            if config.delay != newValue {
                config.delay = newValue
                onConfigChanged?(config)
            }
        }
    }

    // MARK: - Video

    /// Called by the video player once the current clip's length is known
    /// (loadedmetadata). Decides whether the clip should loop.
    func onVideoDurationKnown(_ seconds: Double, for post: RemotePost) {
        guard seconds.isFinite, seconds > 0 else {
            AppLogger.remoteViewer.warning("Video duration unusable for post \(post._id, privacy: .private(mask: .hash)): \(seconds, privacy: .public)")
            return
        }
        // A late callback from a torn-down player for a post we've moved past
        // is irrelevant — only the post on screen (or crossfading in as
        // `nextPost`, since loadedmetadata typically beats the commit) matters.
        guard currentPost?._id == post._id || nextPost?._id == post._id else { return }
        // Loop only if the clip fits inside the interval; a longer clip plays
        // through once.
        currentVideoLoops = seconds <= delay
    }
}
