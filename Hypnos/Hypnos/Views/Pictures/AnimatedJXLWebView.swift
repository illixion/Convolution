/*
 Hypnos - Animated JXL Web View

 First-view renderer for an animated JPEG XL, used only until a cached video
 conversion exists. It decodes the JXL in WebAssembly (a decode-only build of
 libjxl) and muxes the frames into an APNG that a plain `<img>` animates.
 WebKit then owns the animation loop and pauses it when the window is offscreen
 — the same lifecycle behaviour the video-in-`<img>` path relies on, and the
 reason this goes through an image element rather than a canvas.

 The decoded APNG is also posted back to Swift and transcoded to HEVC
 (AnimatedHEVCConverter), cached in the same store as GIF conversions. On the
 next open PhotoWindowModel finds that clip and plays it through the shared
 video-in-`<img>` path, so this WebView (and the WASM decode) is skipped.

 ImageIO can't be used: it decodes JPEG XL but exposes only the first frame of
 an animation. The bundled `jxl_decoder.js` (SINGLE_FILE emscripten build) and
 `jxl-anim.js` (APNG muxer) do the work. They are loaded via `data:` URL
 `<script src>` rather than inline `<script>` blocks: the minified emscripten
 output contains `</script>` substrings that terminate an inline block early
 (the browser then renders the rest of the decoder as page text). base64 in a
 src attribute can't break out of the tag, so the page stays self-contained and
 needs no file-URL read access.
*/

// tvOS has no WebKit. macOS's WKWebView exists, but this view's transparent/
// no-scroll setup (`webView.scrollView.*`) is UIKit-`WKWebView`-only API with
// no macOS equivalent property, and nothing in the macOS UI (Views/Mac/)
// mounts this view, so it gets the same stub-and-fail-closed treatment as a
// visionOS-only view on iOS: see Hypnos/CLAUDE.md "macOS" for the seam list
// and the plan to give this a real NSViewRepresentable later.
#if canImport(WebKit) && !os(macOS)
import DebugTrace
import SwiftUI
import WebKit

struct AnimatedJXLWebView: UIViewRepresentable {
    /// Raw JPEG XL bytes to decode and animate.
    let imageData: Data?
    /// Source URL keying the HEVC conversion built from this decode.
    var sourceURL: URL? = nil

    /// JS→Swift channel the page posts the decoded APNG (base64) on so it can
    /// be converted to HEVC and cached for the next open.
    private static let cacheMessageName = "jxlCache"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Self.cacheMessageName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.sourceURL = sourceURL

        guard let data = imageData else { return }
        let digest = Self.digest(of: data)
        guard context.coordinator.loadedDigest != digest else { return }
        context.coordinator.loadedDigest = digest
        webView.loadHTMLString(Self.decodeHTML(for: data), baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: cacheMessageName)
    }

    private static func digest(of data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(64))
        return hasher.finalize()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loadedDigest: Int?
        var sourceURL: URL?
        /// Guards against converting the same decode twice (the page posts once,
        /// but be defensive against re-entrancy across view reuse).
        private var conversionStarted = false

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == AnimatedJXLWebView.cacheMessageName,
                  let base64 = message.body as? String,
                  let apng = Data(base64Encoded: base64),
                  let url = sourceURL,
                  !conversionStarted else { return }
            conversionStarted = true
            // Convert the decoded APNG to HEVC in the background so reopening
            // this JXL plays through the shared native path — same cache as GIF.
            Task {
                _ = try? await AnimatedHEVCConverter.shared.convert(animatedData: apng, sourceURL: url)
            }
        }
    }

    // Read the decoder + muxer once as base64 (for data: URL <script src>).
    // Caching avoids re-reading the 888 KB decoder from the bundle each slide.
    private static let decoderB64 = loadResourceBase64("jxl_decoder")
    private static let animB64 = loadResourceBase64("jxl-anim")

    private static func loadResourceBase64(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let data = try? Data(contentsOf: url) else {
            AppLogger.remoteViewer.error("AnimatedJXLWebView: missing bundled resource \(name, privacy: .public).js")
            return ""
        }
        return data.base64EncodedString()
    }

    // Shared page chrome: transparent full-bleed image, hidden until ready so
    // the alt-text placeholder never paints, plus a loading overlay.
    //
    // The overlay fills the viewport (`inset: 0`) and centers its contents with
    // flexbox — never `top/left: 50%` percentage math, which resolves against a
    // zero-size viewport before the WKWebView is laid out and makes the spinner
    // pop in at the top-left corner and then jump to center. Flex centering is
    // size-independent, so it is centered from the very first paint. The spinner
    // covers the (blocking, indeterminate) WASM decode; once frame count is
    // known the muxing progress fills a determinate bar beneath it.
    private static let headAndBody = """
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
    .wrap { position: relative; width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; background: transparent; }
    #media { display: block; width: 100%; height: 100%; object-fit: contain; background: transparent; opacity: 0; transition: opacity 0.25s ease; }
    #media.ready { opacity: 1; }
    #loader {
      position: absolute; inset: 0;
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      gap: 14px; pointer-events: none;
    }
    #loader.hidden { display: none; }
    .spinner {
      width: 44px; height: 44px;
      border: 4px solid rgba(255,255,255,0.25);
      border-top-color: rgba(255,255,255,0.9);
      border-radius: 50%;
      animation: spin 0.9s linear infinite;
    }
    .bar {
      width: 140px; height: 4px; border-radius: 2px;
      background: rgba(255,255,255,0.2); overflow: hidden;
      opacity: 0; transition: opacity 0.2s ease;
    }
    .bar.show { opacity: 1; }
    .bar > div { width: 0%; height: 100%; background: rgba(255,255,255,0.9); transition: width 0.15s ease; }
    @keyframes spin { to { transform: rotate(360deg); } }
    </style>
    """

    /// Page for a fresh decode: runs the WASM decoder + APNG muxer, displays the
    /// result, and posts the encoded APNG back to Swift so it can be transcoded
    /// to HEVC and cached — the next open then plays through the native path.
    private static func decodeHTML(for data: Data) -> String {
        let base64 = data.base64EncodedString()
        return """
        <!doctype html><html><head>\(headAndBody)</head>
        <body>
        <div class="wrap">
          <img id="media" alt="" draggable="false">
          <div id="loader"><div class="spinner"></div><div id="bar" class="bar"><div id="barfill"></div></div></div>
        </div>
        <script src="data:text/javascript;base64,\(decoderB64)"></script>
        <script src="data:text/javascript;base64,\(animB64)"></script>
        <script>
        (async function () {
          const media = document.getElementById('media');
          const loader = document.getElementById('loader');
          const bar = document.getElementById('bar');
          const barfill = document.getElementById('barfill');
          const reveal = () => { loader.classList.add('hidden'); media.classList.add('ready'); };
          // Progress events from the WASM decoder/muxer: show a determinate bar
          // for the per-frame APNG muxing once the frame count is known.
          const onProgress = (p) => {
            if (p.phase === 'encoding' && p.total > 1) {
              bar.classList.add('show');
              barfill.style.width = Math.round((p.frame / p.total) * 100) + '%';
            }
          };
          try {
            const b = "\(base64)";
            const bin = atob(b), n = bin.length, u = new Uint8Array(n);
            for (let i = 0; i < n; i++) u[i] = bin.charCodeAt(i);
            const blob = await window.RoboFrameJXL.decodeToBlob(u.buffer, onProgress);
            // Display via a blob: object URL, never a base64 data: URL. A large
            // animated JXL muxes to a multi-MB APNG; inlined as a data: URL it
            // exceeds what <img> will decode and fails with a broken-image
            // square (only large ones — small decodes stay under the limit). An
            // object URL has no such size ceiling.
            media.onload = reveal;
            media.onerror = reveal;
            media.src = URL.createObjectURL(blob);
            // Separately hand the APNG bytes to Swift for background HEVC
            // caching. This reads the same blob to base64 but never touches the
            // displayed <img>, so a huge payload can't break rendering.
            const reader = new FileReader();
            reader.onload = () => {
              const dataURL = reader.result;
              try {
                const comma = dataURL.indexOf(',');
                window.webkit.messageHandlers.jxlCache.postMessage(dataURL.slice(comma + 1));
              } catch (e) {}
            };
            reader.readAsDataURL(blob);
          } catch (e) {
            console.error('JXL render failed:', e);
            reveal();
          }
        })();
        </script>
        </body></html>
        """
    }
}
#elseif os(macOS)
import SwiftUI

/// macOS stub — see the gate comment above. No decode, no HEVC caching; the
/// caller (`PhotoDisplayView`'s animated-image tier) simply shows nothing
/// where a JXL animation would play until this gets a real implementation.
struct AnimatedJXLWebView: View {
    let imageData: Data?
    var sourceURL: URL? = nil

    var body: some View {
        Color.clear
    }
}
#endif
