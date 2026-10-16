/*
 Hypnos - the YouTube tab's web views (sideload builds only: `HYPNOS_YOUTUBE`)

 `YouTubePageHost` keeps the feed's hidden page in the window. A web view
 outside any window stops running, and a tiny or transparent one lays the
 page out wrong, so it is full phone size inside a zero-size container that
 clips it. WebKit only checks that the view is in a visible window, not
 whether any of it shows (measured on macOS: the page reports itself
 visible and runs animation frames as normal).

 `YouTubeBrowserView` is the same site where the person can touch it: to
 sign in, or to answer what the hidden page is waiting on (the EU cookie
 consent, a Google check). It shares the hidden page's cookies. On tvOS it
 is a `UIWebView` driven by a cursor on the remote's touch surface
 (`TVWebCursor`).
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

// MARK: - Hidden page

struct YouTubePageHost: View {
    /// An iPhone's, so the mobile layout and its "load more" marker behave.
    static let pageSize = CGSize(width: 430, height: 932)

    let session: YouTubePageSession

    var body: some View {
        ClippingContainer(page: session.webView)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if os(macOS)
private struct ClippingContainer: NSViewRepresentable {
    let page: NSView

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.clipsToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        guard page.superview !== container else { return }
        page.removeFromSuperview()
        page.frame = CGRect(origin: .zero, size: YouTubePageHost.pageSize)
        container.addSubview(page)
    }
}
#else
private struct ClippingContainer: UIViewRepresentable {
    let page: UIView

    func makeUIView(context _: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        return container
    }

    func updateUIView(_ container: UIView, context _: Context) {
        guard page.superview !== container else { return }
        page.removeFromSuperview()
        page.frame = CGRect(origin: .zero, size: YouTubePageHost.pageSize)
        container.addSubview(page)
    }
}
#endif

// MARK: - Browser

enum YouTubeBrowserPurpose: Identifiable, Hashable {
    case signIn
    /// Open the page the hidden one is stuck on, so the person can answer.
    case answer(URL)

    var id: Self { self }

    var url: URL {
        switch self {
        case .signIn: YouTubeAccount.signInURL
        case .answer(let url): url
        }
    }

    var title: String {
        switch self {
        case .signIn: "Sign In to YouTube"
        case .answer: "YouTube"
        }
    }
}

extension View {
    /// Shows `YouTubeBrowserView` for the purpose set, as a sheet (full
    /// screen on tvOS), and calls `onDismiss` when it closes.
    func youTubeBrowser(_ purpose: Binding<YouTubeBrowserPurpose?>, onDismiss: @escaping () -> Void = {}) -> some View {
        #if os(tvOS)
        fullScreenCover(item: purpose, onDismiss: onDismiss) { purpose in
            YouTubeBrowserView(purpose: purpose)
        }
        #else
        sheet(item: purpose, onDismiss: onDismiss) { purpose in
            YouTubeBrowserView(purpose: purpose)
        }
        #endif
    }
}

struct YouTubeBrowserView: View {
    let purpose: YouTubeBrowserPurpose
    @Environment(\.dismiss) private var dismiss
    @State private var page = YouTubeBrowserPage()

    var body: some View {
        #if os(tvOS)
        ZStack(alignment: .bottom) {
            TVWebCursorView(webView: page.webView, evaluate: page.evaluate)
                .ignoresSafeArea()
            Text(hint)
                .font(.caption)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 40)
                .allowsHitTesting(false)
        }
        .onExitCommand { dismiss() }
        .task { await run() }
        #else
        NavigationStack {
            BrowserWebView(webView: page.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(purpose.title)
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if purpose == .signIn {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 640, idealHeight: 760)
        #endif
        .task { await run() }
        #endif
    }

    private var hint: String {
        #if os(tvOS)
        purpose == .signIn
            ? "Swipe to move the pointer and click to press. Double-click to scroll instead. Passkeys can't be used here: choose \"Try another way\" and use your password. Press Menu when you're done."
            : "Swipe to move the pointer and click to press. Double-click to scroll instead. Press Menu when you're done."
        #else
        "Passkeys can't be used in an app's web view: on Google's page, choose \"Try another way\" and use your password."
        #endif
    }

    /// Loads the page; for sign-in, closes by itself once YouTube's own page
    /// says it is signed in (cookies alone can belong to a session that
    /// ended).
    private func run() async {
        page.load(purpose.url)
        guard purpose == .signIn else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard YouTubeAccount.isYouTubePage(page.currentURL), await page.saysSignedIn() else { continue }
            await YouTubeAccount.shared.refresh()
            AppLogger.youtube.info("YouTube sign-in finished")
            dismiss()
            return
        }
    }
}

/// The browser's own web view, on the same cookies as the hidden pages.
@MainActor
final class YouTubeBrowserPage {
    #if canImport(WebKit)
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = YouTubeAccount.dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if !os(macOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = YouTubeAccount.userAgent
    }

    var currentURL: URL? { webView.url }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func saysSignedIn() async -> Bool {
        (try? await webView.evaluateJavaScript(Self.signedInCheck)) as? Bool ?? false
    }
    #else
    let webView: UIView

    init() {
        webView = YouTubePageSession.makeLegacyWebView(frame: .zero)
    }

    var currentURL: URL? { evaluate("location.href").flatMap(URL.init(string:)) }

    func load(_ url: URL) {
        (webView as AnyObject).loadRequest?(URLRequest(url: url))
    }

    func saysSignedIn() async -> Bool {
        evaluate("String(\(Self.signedInCheck))") == "true"
    }

    @discardableResult
    func evaluate(_ script: String) -> String? {
        (webView as AnyObject).stringByEvaluatingJavaScript?(from: script) ?? nil
    }
    #endif

    /// The page's own config, as the feed reader reads it.
    private static let signedInCheck = "(() => { try { return window.ytcfg.get('LOGGED_IN') === true; } catch (e) { return false; } })()"
}

#if canImport(WebKit)
#if os(macOS)
private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context _: Context) -> WKWebView { webView }
    func updateNSView(_: WKWebView, context _: Context) {}
}
#else
private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context _: Context) -> WKWebView { webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}
#endif
#endif

#endif
