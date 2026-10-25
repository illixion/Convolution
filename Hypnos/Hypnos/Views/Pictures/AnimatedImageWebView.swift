/*
 Hypnos - Animated Image Web View

 WKWebView-based animated image renderer for formats like animated WebP.
 Loads the image from its direct URL to preserve browser-native animation.
 */

// tvOS has no WebKit.
#if canImport(WebKit)
import SwiftUI
import WebKit

#if os(macOS)
extension AnimatedImageWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, coordinator: context.coordinator) }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
}
#else
extension AnimatedImageWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, coordinator: context.coordinator) }
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
}
#endif

@MainActor
struct AnimatedImageWebView {
    enum ElementType: String {
        case image
        case video
    }

    let imageURL: URL
    var elementType: ElementType = .image
    /// Optional pre-downloaded bytes. When supplied, the WebView decodes
    /// them inline via a `data:` URL instead of re-fetching `imageURL` —
    /// avoids a multi-second re-download for animated WebP/GIF where the
    /// slideshow already holds the bytes from the prefetch step.
    var imageData: Data?
    /// MIME type for `imageData`. Defaults to `image/webp` (the only
    /// caller today); video elements should pass an appropriate type.
    var imageDataMimeType: String = "image/webp"
    /// Called when the media element fails to load/decode (e.g. a video-in-
    /// `<img>` source Safari can't decode). Drives the slideshow's fall-through
    /// from the native `<img>` tier to the `<video>`/HLS tiers.
    var onError: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError)
    }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "mediaError")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.makeTransparentAndFixed()
        return webView
    }

    func update(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.onError = onError
        let digest = imageURL.absoluteString.hashValue
            ^ elementType.rawValue.hashValue
            ^ credentialDigest
            ^ (imageData?.count ?? 0)
        guard coordinator.loadedDigest != digest else { return }
        coordinator.loadedDigest = digest

        loadMedia(webView: webView)
    }

    private func loadMedia(webView: WKWebView) {
        // Inline-bytes fast path: skip the network entirely by embedding
        // a `data:` URL. WebKit decodes from memory and the animation
        // starts as soon as the document parses.
        if let data = imageData {
            let base64 = data.base64EncodedString()
            let source = "data:\(imageDataMimeType);base64,\(base64)"
            let html = sharedHTML(body: mediaElementMarkup(source: source, isObjectURL: false))
            webView.loadHTMLString(html, baseURL: nil)
            return
        }

        if imageURL.isFileURL {
            let htmlFile = imageURL.deletingLastPathComponent().appendingPathComponent(".hypnos_animated_asset.html")
            try? htmlForLocalFile(relativePath: imageURL.lastPathComponent).write(to: htmlFile, atomically: true, encoding: .utf8)
            webView.loadFileURL(htmlFile, allowingReadAccessTo: imageURL.deletingLastPathComponent())
            return
        }

        let html: String
        if case .header(let name, let value) = MediaAuthorization.shared.credential(for: imageURL) {
            // A `<img>`/`<video> src` carries neither a header nor an
            // out-of-band credential, so a header-authenticated host (a
            // Basic-auth Nextcloud server, or Stash's manual `Bearer …`
            // escape hatch) is fetched in JS and handed to the element as a
            // blob URL instead.
            html = htmlForRemoteFetch(url: imageURL, headerName: name, headerValue: value)
        } else {
            html = htmlForRemoteSource(url: MediaAuthorization.shared.authorizedURL(imageURL))
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantle(_ webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mediaError")
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var loadedDigest: Int?
        var onError: (() -> Void)?

        init(onError: (() -> Void)?) {
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "mediaError" { onError?() }
        }
    }

    /// A coarse hash of this URL's credential, so a credential change (e.g.
    /// the Stash server being reconfigured) invalidates the loaded digest
    /// even though `imageURL` itself didn't change.
    private var credentialDigest: Int {
        switch MediaAuthorization.shared.credential(for: imageURL) {
        case .none: return 0
        case .queryParam(let name, let value): return name.hashValue ^ value.hashValue
        case .header(let name, let value): return name.hashValue ^ value.hashValue ^ 1
        }
    }

    private func mediaElementMarkup(source: String, isObjectURL: Bool) -> String {
        switch elementType {
        case .image:
            let srcAttribute = isObjectURL ? "" : "src=\"\(source)\""
            return "<img id=\"media\" \(srcAttribute) alt=\"animated media\" draggable=\"false\" />"
        case .video:
            let srcAttribute = isObjectURL ? "" : "src=\"\(source)\""
            return "<video id=\"media\" \(srcAttribute) autoplay loop muted playsinline></video>"
        }
    }

    private func sharedHTML(body: String, script: String = "") -> String {
        """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    background: transparent;
                }
                .wrap {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    background: transparent;
                }
                #media {
                    display: block;
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: transparent;
                }
            </style>
        </head>
        <body>
            <div class="wrap">
                \(body)
            </div>
            <script>
                (function () {
                    var m = document.getElementById('media');
                    if (m) m.addEventListener('error', function () {
                        try { window.webkit.messageHandlers.mediaError.postMessage('error'); } catch (e) {}
                    });
                })();
                \(script)
            </script>
        </body>
        </html>
        """
    }

    private func htmlForLocalFile(relativePath: String) -> String {
        sharedHTML(body: mediaElementMarkup(source: relativePath, isObjectURL: false))
    }

    private func htmlForRemoteSource(url: URL) -> String {
        sharedHTML(body: mediaElementMarkup(source: url.absoluteString.jsEscapedForSingleQuotedString, isObjectURL: false))
    }

    private func htmlForRemoteFetch(url: URL, headerName: String, headerValue: String) -> String {
        let escapedURL = url.absoluteString.jsEscapedForSingleQuotedString
        let escapedHeaderName = headerName.jsEscapedForSingleQuotedString
        let escapedHeaderValue = headerValue.jsEscapedForSingleQuotedString
        let body = mediaElementMarkup(source: "", isObjectURL: true)
        let script = """
        (async function() {
            const response = await fetch('\(escapedURL)', {
                headers: { '\(escapedHeaderName)': '\(escapedHeaderValue)' }
            });
            const blob = await response.blob();
            const objectURL = URL.createObjectURL(blob);
            const media = document.getElementById('media');
            media.src = objectURL;
            if (media.tagName === 'VIDEO') {
                media.play().catch(function() {});
            }
        })();
        """
        return sharedHTML(body: body, script: script)
    }
}

private extension String {
    var jsEscapedForSingleQuotedString: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
#endif
