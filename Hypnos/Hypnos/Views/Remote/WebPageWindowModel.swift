/*
 Hypnos - Web Page Window Model

 Per-window model for a pinned web page (a `.webPage` RemoteViewerConfig).
 Owns the WKWebView for the window's whole lifetime — the point of the feature
 is a page that keeps its state (scroll position, logins, in-page JS) while the
 user looks away, so the WebView must outlive any SwiftUI view identity churn.

 Also owns navigation state for the ornament, the optional auto-refresh timer,
 and the interaction gate: visionOS renders gaze-hover highlights inside web
 content, which is distracting on a page being used as ambient decoration, so
 the WebView only accepts input while the ornaments are visible.
 */

// tvOS has no WebKit.
#if canImport(WebKit) && !os(macOS)
import DebugTrace
import Foundation
import SwiftUI
import WebKit

@MainActor
@Observable
final class WebPageWindowModel {
    let config: RemoteViewerConfig
    let windowId: UUID

    // MARK: - Observable page state (drives the ornament)

    var pageTitle: String = ""
    var currentURLText: String = ""
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    /// Set when a navigation fails, cleared on the next successful load.
    var loadError: String?

    /// The page. Observation-ignored: it's a reference the view reads once to
    /// build the representable, and publishing UIKit objects buys nothing.
    @ObservationIgnored private(set) var webView: WKWebView?

    /// Fired when the page reports a user gesture. The window view uses it to
    /// keep the ornaments alive (they gate interaction, so auto-hiding them
    /// mid-scroll would yank input away) and to restart the refresh countdown.
    @ObservationIgnored var onUserInteraction: (() -> Void)?

    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var lastLoadDate: Date?

    /// Message-handler name for the in-page interaction reporter.
    private static let interactionHandlerName = "pageInteraction"

    // MARK: - Lifecycle

    /// Side-effect-free, per the project's per-window-model pattern: SwiftUI may
    /// build several of these and discard all but one. Everything happens in
    /// `start()`.
    init(config: RemoteViewerConfig, windowId: UUID) {
        self.config = config
        self.windowId = windowId
        self.currentURLText = config.resolvedWebPageURL?.absoluteString ?? ""
    }

    func start() {
        guard webView == nil, let url = config.resolvedWebPageURL else { return }

        let delegate = Delegate()
        delegate.onNavigationStateChanged = { [weak self] in self?.refreshNavigationState() }
        delegate.onLoadStarted = { [weak self] in
            self?.isLoading = true
            self?.loadError = nil
        }
        delegate.onLoadFinished = { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.lastLoadDate = Date()
            self.refreshNavigationState()
            self.restartRefreshTimer()
        }
        delegate.onLoadFailed = { [weak self] message in
            guard let self else { return }
            self.isLoading = false
            self.loadError = message
            self.refreshNavigationState()
            // Keep the timer running: for a transient network blip the next
            // auto-refresh is exactly the recovery the user wants.
            self.restartRefreshTimer()
        }
        delegate.onUserInteraction = { [weak self] in self?.noteUserInteraction() }
        self.delegate = delegate

        let configuration = WKWebViewConfiguration()
        // Persistent by default, but be explicit: cookies and localStorage
        // surviving relaunch is what makes a pinned dashboard stay logged in.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.interactionReporterScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        if config.webTransparentBackground {
            configuration.userContentController.addUserScript(
                WKUserScript(source: Self.transparentBackgroundScript,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: true)
            )
        }
        configuration.userContentController.add(delegate, name: Self.interactionHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        // Interaction starts blocked; the window view opens with its ornaments
        // visible and immediately unblocks. Doing it in this order means a page
        // that paints before the first `updateUIView` can't flash a hover
        // highlight.
        webView.isUserInteractionEnabled = false

        if config.webTransparentBackground {
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            // Without this the WebView paints an opaque backdrop derived from
            // the page's background colour, defeating the CSS injection.
            webView.underPageBackgroundColor = .clear
        }

        self.webView = webView
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func cleanup() {
        refreshTask?.cancel()
        refreshTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.interactionHandlerName)
        webView = nil
        delegate = nil
    }

    // MARK: - Commands

    func reload() {
        loadError = nil
        // A failed first load leaves nothing to reload — re-request the URL.
        if webView?.url == nil, let url = config.resolvedWebPageURL {
            isLoading = true
            webView?.load(URLRequest(url: url))
        } else {
            webView?.reload()
        }
        restartRefreshTimer()
    }

    func stopLoading() {
        webView?.stopLoading()
        isLoading = false
    }

    func goBack() {
        webView?.goBack()
        restartRefreshTimer()
    }

    func goForward() {
        webView?.goForward()
        restartRefreshTimer()
    }

    /// Back to the profile's configured page, however far the user has browsed.
    func goHome() {
        guard let url = config.resolvedWebPageURL else { return }
        loadError = nil
        isLoading = true
        webView?.load(URLRequest(url: url))
        restartRefreshTimer()
    }

    /// Applies the interaction gate. Called from the representable so the flag
    /// and the WebView can't disagree.
    func setInteractionEnabled(_ enabled: Bool) {
        guard let webView, webView.isUserInteractionEnabled != enabled else { return }
        webView.isUserInteractionEnabled = enabled
    }

    /// Pause background work while the window isn't in the user's current room.
    /// Refreshing a page nobody can see is pure waste; on return, a page that's
    /// past its interval is refreshed immediately so the user never reads stale
    /// numbers off a dashboard.
    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        let interval = config.webAutoRefreshInterval
        if interval > 0, let last = lastLoadDate, Date().timeIntervalSince(last) >= interval {
            reload()
        } else {
            restartRefreshTimer()
        }
    }

    // MARK: - Internals

    private func noteUserInteraction() {
        onUserInteraction?()
        // Treat auto-refresh as "reload after N seconds of idleness" — a reload
        // mid-form-fill would throw away the user's work.
        restartRefreshTimer()
    }

    private func refreshNavigationState() {
        guard let webView else { return }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title ?? ""
        if let url = webView.url {
            currentURLText = url.absoluteString
        }
    }

    private func restartRefreshTimer() {
        refreshTask?.cancel()
        refreshTask = nil
        let interval = config.webAutoRefreshInterval
        guard interval > 0, !isPaused else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, !self.isPaused else { return }
                AppLogger.remoteViewer.debug(
                    "[Web \(self.windowId.uuidString, privacy: .public)] auto-refresh after \(Int(interval), privacy: .public)s"
                )
                self.isLoading = true
                self.webView?.reload()
            }
        }
    }

    // MARK: - Injected scripts

    /// Reports user gestures back to Swift, throttled to once a second. Without
    /// this the ornaments would auto-hide mid-interaction and, because they gate
    /// input, the page would go dead under the user's hands.
    private static let interactionReporterScript = """
    (function () {
      var last = 0;
      function post() {
        var now = Date.now();
        if (now - last < 1000) { return; }
        last = now;
        try { window.webkit.messageHandlers.pageInteraction.postMessage(1); } catch (e) {}
      }
      ['pointerdown', 'touchstart', 'wheel', 'keydown', 'scroll'].forEach(function (name) {
        window.addEventListener(name, post, { passive: true, capture: true });
      });
    })();
    """

    /// Makes the document paint transparent so the page's content floats in the
    /// user's space. Re-applied on DOMContentLoaded because a page that replaces
    /// `document.head` wholesale would otherwise drop the style element.
    private static let transparentBackgroundScript = """
    (function () {
      var css = 'html, body { background: transparent !important;'
        + ' background-color: transparent !important; }';
      function apply() {
        if (document.getElementById('__hypnos_transparent')) { return; }
        var style = document.createElement('style');
        style.id = '__hypnos_transparent';
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      }
      apply();
      document.addEventListener('DOMContentLoaded', apply);
    })();
    """

    // MARK: - Delegate

    /// Navigation / UI / script-message delegate. A separate non-isolated
    /// NSObject (rather than the model itself) keeps `@Observable` away from
    /// NSObject conformance; it forwards everything through main-actor closures.
    final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onNavigationStateChanged: (() -> Void)?
        var onLoadStarted: (() -> Void)?
        var onLoadFinished: (() -> Void)?
        var onLoadFailed: ((String) -> Void)?
        var onUserInteraction: (() -> Void)?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadStarted?()
            onNavigationStateChanged?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadFinished?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            reportFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            reportFailure(error)
        }

        /// `target="_blank"` links return no web view by default, which reads as
        /// a dead link. Load them in place instead — a pinned page is a single
        /// panel, not a browser with tabs.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let request = navigationAction.request.url {
                webView.load(URLRequest(url: request))
            }
            return nil
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "pageInteraction" else { return }
            onUserInteraction?()
        }

        private func reportFailure(_ error: any Error) {
            let nsError = error as NSError
            // Cancelled navigations are routine (a redirect, or our own reload
            // landing on a still-loading page) and aren't worth surfacing.
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
                return
            }
            onLoadFailed?(nsError.localizedDescription)
        }
    }
}
#endif
