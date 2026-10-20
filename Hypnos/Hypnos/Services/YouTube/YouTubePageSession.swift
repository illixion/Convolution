/*
 Hypnos - one hidden page of YouTube's mobile site

 The YouTube tab's feeds (Home, Subscriptions, …) are whatever this page
 shows, read by `YouTubePageScript`. The page must sit in a window to keep
 running, at a phone's size so the mobile layout and its "load more" marker
 behave; `YouTubePageHost` keeps it there, clipped out of sight.

 visionOS, iOS and macOS use a WKWebView on `YouTubeAccount.dataStore`. tvOS
 has no public WebKit, but its UIKit still ships the legacy `UIWebView`
 (what tvOS-Browser and web-yt-dlp's player used), reached by class name and
 dynamic dispatch so nothing links against it; if a future tvOS drops it,
 the feeds just stay empty. It has no user scripts or message handlers, so a
 poll injects the script and drains what it queued.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit)

@MainActor
final class YouTubePageSession: NSObject {
    let webView: WKWebView
    var onPayload: ((YouTubePageScript.Payload) -> Void)?
    /// A page finished loading, with where it ended up.
    var onPageFinished: ((URL?) -> Void)?
    /// WebKit's content process died (memory pressure, usually); the page
    /// is blank until loaded again.
    var onPageLost: (() -> Void)?
    /// From `load` until the new page commits, messages are still the old
    /// page's (a Home card arriving after Subscriptions was asked for).
    private var awaitingCommit = false

    override init() {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: YouTubePageScript.source(.messageHandler),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = YouTubeAccount.dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if !os(macOS)
        // Never a full-screen player, whatever starts.
        configuration.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: CGRect(origin: .zero, size: YouTubePageHost.pageSize), configuration: configuration)
        webView.customUserAgent = YouTubeAccount.userAgent
        super.init()
        controller.add(MessageRelay(session: self), contentWorld: .defaultClient, name: YouTubePageScript.handlerName)
        webView.navigationDelegate = self
    }

    func load(_ url: URL) {
        guard YouTubeConsent.isGranted else { return }
        awaitingCommit = true
        webView.load(URLRequest(url: url))
    }

    func loadMore() {
        evaluateWithoutUserGesture(YouTubePageScript.loadMore)
    }

    /// `evaluateJavaScript` counts as a tap, which lets the page autoplay;
    /// WebKit's SPI for running a script without one doesn't. Falls back to
    /// the public call (the script's guard still pauses what starts) if a
    /// future WebKit drops the SPI.
    private func evaluateWithoutUserGesture(_ script: String) {
        typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, @escaping @convention(block) (Any?, Error?) -> Void) -> Void
        let selector = NSSelectorFromString("_evaluateJavaScriptWithoutUserGesture:completionHandler:")
        guard webView.responds(to: selector) else {
            webView.evaluateJavaScript(script, completionHandler: nil)
            return
        }
        let evaluate = unsafeBitCast(webView.method(for: selector), to: Evaluate.self)
        evaluate(webView, selector, script as NSString) { _, _ in }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !awaitingCommit else { return }
        guard JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let payload = try? JSONDecoder().decode(YouTubePageScript.Payload.self, from: data) else {
            AppLogger.youtube.debug("YouTube page sent something unreadable")
            return
        }
        onPayload?(payload)
    }
}

extension YouTubePageSession: WKNavigationDelegate {
    func webView(_: WKWebView, didCommit _: WKNavigation!) {
        awaitingCommit = false
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        onPageFinished?(webView.url)
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        AppLogger.youtube.error("YouTube page failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        AppLogger.youtube.error("YouTube page didn't load: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        AppLogger.youtube.notice("YouTube page's web process ended")
        onPageLost?()
    }
}

/// Holds the session weakly: the content controller keeps its handlers alive.
@MainActor
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var session: YouTubePageSession?

    init(session: YouTubePageSession) {
        self.session = session
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receive(message)
    }
}

#elseif os(tvOS)

import JavaScriptCore

extension NSObject {
    /// WebKitLegacy asks its frame load delegate this as each page's window
    /// is created, before any of the page's scripts run, which makes it the
    /// one way to put something into a `UIWebView` page ahead of the page
    /// (measured in the tvOS 26 simulator: the call arrives on UIKit's
    /// forwarder for every frame, and what it sets is there for the page).
    /// It covers every `UIWebView` the app makes; only the YouTube tab makes
    /// any.
    @objc(webView:didCreateJavaScriptContext:forFrame:)
    func hypnosWebView(_: AnyObject, didCreateJavaScriptContext context: JSContext, forFrame _: AnyObject) {
        _ = context.evaluateScript(YouTubePageScript.legacyDocumentStart)
    }
}

/// The members of tvOS's private `UIWebView` used here, called by selector
/// on `AnyObject` (declaring them is what makes those calls compile).
@objc protocol YouTubeLegacyWebView {
    @objc optional func loadRequest(_ request: URLRequest)
    @objc(stringByEvaluatingJavaScriptFromString:)
    optional func stringByEvaluatingJavaScript(from script: String) -> String?
}

@MainActor
final class YouTubePageSession: NSObject {
    let webView: UIView
    var onPayload: ((YouTubePageScript.Payload) -> Void)?
    var onPageFinished: ((URL?) -> Void)?
    var onPageLost: (() -> Void)?

    private var pollTask: Task<Void, Never>?
    private var finishedHref: String?
    private static let script = YouTubePageScript.legacyDocumentStart + ";" + YouTubePageScript.source(.pollingQueue)

    override init() {
        webView = Self.makeLegacyWebView(frame: CGRect(origin: .zero, size: YouTubePageHost.pageSize))
        super.init()
        webView.isUserInteractionEnabled = false
    }

    /// A `UIWebView` set up like the WKWebViews elsewhere: a phone's Safari,
    /// nothing playing without a tap, never full screen. Its user agent is
    /// read from the registered defaults when the first one is made (no
    /// other web view exists on tvOS for it to affect).
    static func makeLegacyWebView(frame: CGRect) -> UIView {
        UserDefaults.standard.register(defaults: ["UserAgent": YouTubeAccount.userAgent])
        guard let webViewClass = NSClassFromString("UIWebView") as? UIView.Type else {
            AppLogger.youtube.error("UIWebView is missing on this tvOS")
            return UIView(frame: frame)
        }
        let view = webViewClass.init(frame: frame)
        if view.responds(to: NSSelectorFromString("setMediaPlaybackRequiresUserAction:")) {
            view.setValue(true, forKey: "mediaPlaybackRequiresUserAction")
        }
        if view.responds(to: NSSelectorFromString("setAllowsInlineMediaPlayback:")) {
            view.setValue(true, forKey: "allowsInlineMediaPlayback")
        }
        return view
    }

    func load(_ url: URL) {
        guard YouTubeConsent.isGranted else { return }
        finishedHref = nil
        // Until the new document replaces it, the old one is still polled;
        // marked, its queue is thrown away instead of read.
        evaluate("window.__hypnosRetired = true")
        (webView as AnyObject).loadRequest?(URLRequest(url: url))
        startPolling()
    }

    func loadMore() {
        evaluate(YouTubePageScript.loadMore)
    }

    /// Every call injects the reader first, in the same evaluation, and the
    /// document-start script again in case the page somehow missed it. A
    /// call counts as a tap here (there is no way not to), so the page must
    /// never get one before `play()` refuses.
    @discardableResult
    func evaluate(_ script: String) -> String? {
        (webView as AnyObject).stringByEvaluatingJavaScript?(from: Self.script + ";" + script) ?? nil
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(500))
                guard self != nil else { return }
            }
        }
    }

    private func tick() {
        guard evaluate("window.__hypnosRetired === true") != "true" else { return }
        if let href = evaluate("location.href"), !href.isEmpty, href != "about:blank",
           evaluate("document.readyState") == "complete", href != finishedHref {
            finishedHref = href
            onPageFinished?(URL(string: href))
        }
        guard let drained = evaluate(YouTubePageScript.drain), drained != "[]",
              let data = drained.data(using: .utf8),
              let payloads = try? JSONDecoder().decode([YouTubePageScript.Payload].self, from: data) else {
            return
        }
        for payload in payloads { onPayload?(payload) }
    }
}

#endif

#endif
