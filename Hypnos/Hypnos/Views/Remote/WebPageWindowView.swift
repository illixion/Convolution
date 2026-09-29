/*
 Hypnos - Web Page Window View

 Pins an arbitrary web page as an interactive panel in the user's space — the
 `.webPage` half of the Remote tab (the other half is the RoboFrame slideshow).

 Three behaviours make it a *pinned* page rather than a browser window:
 - Page state is retained: the WebView is owned by WebPageWindowModel for the
   window's lifetime, so looking away and coming back doesn't reload it.
 - Window size is retained across cold relaunches, via the same
   WindowSizePersistence the slideshow window uses.
 - Interaction is gated on ornament visibility: with the ornaments hidden the
   page takes no input, so visionOS's gaze-hover highlights stay quiet and a
   tap anywhere reveals the controls instead of hitting a link.
 */

// tvOS has no WebKit.
#if canImport(WebKit) && !os(macOS)

import DebugTrace
import RAVEUI
import SwiftUI

struct WebPageWindowView: View {
    let windowValue: RemoteViewerWindowValue
    /// Writes the resolved window size back into the Codable window value so
    /// visionOS persists it for the next cold relaunch (scene restoration).
    var onSizeSettled: ((CGSize) -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.scenePhase) private var scenePhase

    @State private var pageModel: WebPageWindowModel?
    @State private var sizePersistence: WindowSizePersistence?
    @State private var controlsVisible = true
    @State private var autoHideTimer: Task<Void, Never>?
    /// Set when the profile has no usable URL, so the window explains itself
    /// instead of coming up as an empty pane of glass.
    @State private var configurationError: String?

    /// Corner rounding for the opaque presentation. The page paints its own
    /// background edge-to-edge, so without this the panel has hard square
    /// corners over the rounded glass backing.
    private let cornerRadius: CGFloat = 24

    private var isTransparent: Bool {
        pageModel?.config.webTransparentBackground ?? false
    }

    var body: some View {
        ZStack {
            if let model = pageModel, model.webView != nil {
                PinnedWebPageView(model: model, interactionEnabled: controlsVisible)
                    .allowsHitTesting(controlsVisible)
                    .clipShape(.rect(cornerRadius: isTransparent ? 0 : cornerRadius))
            } else {
                unavailableView
            }

            // Reveal target, in FRONT of the page. A gesture on the container
            // *behind* the WebView is never delivered on device: with the page
            // non-interactive, gaze targeting finds nothing in that region and
            // the whole window goes dead — no way back to the ornaments. It also
            // can't be `Color.clear`; only a drawn layer is gaze-targetable, so
            // this is a real (invisible) fill.
            if !controlsVisible {
                Color.white.opacity(0.001)
                    .contentShape(.rect)
                    .onTapGesture { showControls() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A transparent page is meant to float with no window backing at all;
        // an opaque one gets the standard visionOS glass so it reads as a panel
        // (and has something to show while the first paint lands).
        .background {
            if !isTransparent {
                Color.clear.glassBackgroundEffect()
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            sizePersistence?.currentSize = newSize
            sizePersistence?.scheduleWriteback(newSize)
        }
        .ornament(
            visibility: controlsVisible ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomFront),
            contentAlignment: .top,
            ornament: {
                if let model = pageModel {
                    WebPageOrnamentView(model: model, onHideControls: hideControls)
                }
            }
        )
        .contentShape(.rect)
        // Backstop for the in-front catcher above (and the reveal path when the
        // page failed to load, so there's no WebView in the way at all).
        .onTapGesture {
            showControls()
        }
        // Hidden with the ornaments, so a pinned page reads as content in the
        // room rather than a window. Safe to hide only because the invisible
        // in-front catcher above is a confirmed-working way back — it is the
        // sole reveal path, so don't remove it without replacing it.
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .hidesStatusBar(!controlsVisible)
        .onAppear {
            setup()
        }
        .onDisappear {
            teardown()
        }
        .onChange(of: scenePhase) { _, newPhase in
            pageModel?.setPaused(newPhase != .active)
        }
    }

    @ViewBuilder
    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(configurationError ?? "Loading…")
                .font(.title3)
                .multilineTextAlignment(.center)
            if configurationError != nil {
                Text("Set a page URL in the Remote tab, then launch the profile again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
    }

    // MARK: - Lifecycle

    private func setup() {
        AppLogger.windowState.info(
            "[WebPage \(windowValue.id.uuidString, privacy: .public)] view appeared config=\(windowValue.configId.uuidString, privacy: .public) savedSize=\(String(describing: windowValue.restoredSize?.cgSize), privacy: .public)"
        )
        RestoredWindowTracker.markSeen(windowValue.id)
        appModel.registerRemoteViewerWindow(configId: windowValue.configId, windowValue: windowValue)
        setupSizePersistence()

        guard pageModel == nil else { return }
        guard let config = appModel.remoteViewerConfig(id: windowValue.configId) else {
            configurationError = "This viewer profile no longer exists."
            AppLogger.remoteViewer.error("No config found for id \(windowValue.configId.uuidString, privacy: .public)")
            return
        }
        guard config.resolvedWebPageURL != nil else {
            configurationError = "\"\(config.name)\" has no valid page URL."
            return
        }

        let model = WebPageWindowModel(config: config, windowId: windowValue.id)
        model.onUserInteraction = {
            // Keep the ornaments (and thus input) alive while the page is in
            // use; the page can't reveal them itself once they're gone.
            resetAutoHideTimer()
        }
        model.start()
        pageModel = model
        controlsVisible = true
        resetAutoHideTimer()
    }

    private func teardown() {
        appModel.unregisterRemoteViewerWindow(configId: windowValue.configId, windowValueId: windowValue.id)
        autoHideTimer?.cancel()
        sizePersistence?.cancel()
        pageModel?.cleanup()
    }

    /// Mirrors RemoteViewerWindowView: the mechanics live in
    /// `WindowSizePersistence` so both wall-pinnable windows share one
    /// implementation.
    private func setupSizePersistence() {
        let persistence = WindowSizePersistence(
            windowId: windowValue.id,
            log: AppLogger.remoteViewer
        )
        persistence.onSizeSettled = onSizeSettled
        persistence.windowScene = { [weak sceneDelegate] in sceneDelegate?.windowScene }
        sizePersistence = persistence
        persistence.applyRestoredSizeIfNeeded(archived: windowValue.restoredSize?.cgSize)
    }

    // MARK: - Controls visibility (and with it, the interaction gate)

    private func showControls() {
        guard !controlsVisible else { return }
        withAnimation { controlsVisible = true }
        resetAutoHideTimer()
    }

    private func hideControls() {
        autoHideTimer?.cancel()
        withAnimation { controlsVisible = false }
    }

    private func resetAutoHideTimer() {
        autoHideTimer?.cancel()
        guard appModel.autoHideDelay > 0 else { return }
        autoHideTimer = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }
}
#endif
