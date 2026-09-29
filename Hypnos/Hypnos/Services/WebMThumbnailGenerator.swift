/*
 Hypnos - WebM Thumbnail Generator

 AVFoundation (AVAssetImageGenerator) can't read WebM, so the normal local
 video thumbnail path returns nil and the grid shows a placeholder. WebKit
 *can* decode WebM (it's how the app plays it), so we render the file in an
 offscreen WKWebView, seek past the common black intro frame, and capture a
 frame to a <canvas>, reusing the same temp-HTML + loadFileURL(allowingRead
 AccessTo:) pattern WebVideoPlayerView uses for local playback.
 */

// tvOS has no WebKit. macOS is excluded too: this generator renders into a
// real offscreen UIWindow/UIWindowScene to force a WKWebView layout pass, a
// technique with no macOS equivalent (NSWindow/WKWebView don't need it — a
// hosted WKWebView lays out once added to a view hierarchy regardless of
// window visibility), and nothing mounts this path on macOS. See
// Hypnos/CLAUDE.md "macOS".
#if canImport(WebKit) && !os(macOS)
import DebugTrace
import UIKit
import WebKit

@MainActor
final class WebMThumbnailGenerator {
    static let shared = WebMThumbnailGenerator()

    /// At most this many offscreen captures run at once — each spins up a
    /// WKWebView that decodes video, which is heavy.
    private let maxConcurrent = 4
    private var activePermits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Coalesce concurrent requests for the same file.
    private var inProgress: [URL: Task<UIImage?, Never>] = [:]

    private init() {}

    func generateThumbnail(for url: URL, maxSize: CGFloat) async -> UIImage? {
        if let existing = inProgress[url] {
            return await existing.value
        }

        let task = Task { [weak self] () -> UIImage? in
            guard let self else { return nil }
            await self.acquire()
            defer { self.release() }
            return await WebMFrameCapture(maxSize: maxSize).capture(url: url)
        }

        inProgress[url] = task
        let result = await task.value
        inProgress[url] = nil
        return result
    }

    // MARK: - Concurrency gate (counting semaphore on the main actor)

    private func acquire() async {
        if activePermits < maxConcurrent {
            activePermits += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by release(), which hands its permit straight to us.
    }

    private func release() {
        if waiters.isEmpty {
            activePermits -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// One-shot offscreen capture. Owns its WKWebView for the duration of a single
/// frame grab and tears everything down in `finish`.
@MainActor
private final class WebMFrameCapture: NSObject, WKScriptMessageHandler {
    private let maxSize: CGFloat
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var htmlFileURL: URL?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(maxSize: CGFloat) {
        self.maxSize = maxSize
        super.init()
    }

    func capture(url: URL) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            self.continuation = cont
            self.begin(url: url)
        }
    }

    private func begin(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "frame")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
        webView.isOpaque = false
        webView.alpha = 0.01 // Not 0/hidden — WebKit suspends media rendering when fully hidden.
        webView.isUserInteractionEnabled = false
        self.webView = webView

        // Must live in a window for WebKit to actually decode video frames.
        guard let window = Self.foregroundWindow() else {
            finish(nil)
            return
        }
        window.addSubview(webView)

        // Temp HTML next to the video, referencing it by relative name, with read
        // access granted to the directory (mirrors WebVideoPlayerView).
        let videoDir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let htmlFile = videoDir.appendingPathComponent(".hypnos_thumb_\(baseName).html")
        let relativeSrc = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? url.lastPathComponent

        do {
            try Self.html(relativeSrc: relativeSrc, maxSize: maxSize).write(to: htmlFile, atomically: true, encoding: .utf8)
            htmlFileURL = htmlFile
            webView.loadFileURL(htmlFile, allowingReadAccessTo: videoDir)
        } catch {
            AppLogger.imageLoader.warning("WebM thumbnail: failed to stage HTML for \(url.lastPathComponent, privacy: .private)")
            finish(nil)
            return
        }

        // Safety net: decode/seek can stall on some files.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            self.finish(nil)
        }
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == "frame" else { return }
            if let body = message.body as? [String: Any],
               let dataURL = body["data"] as? String,
               let image = Self.image(fromDataURL: dataURL) {
                finish(image)
            } else {
                let reason = (message.body as? [String: Any])?["error"] as? String ?? "unknown"
                AppLogger.imageLoader.debug("WebM thumbnail capture failed: \(reason, privacy: .public)")
                finish(nil)
            }
        }
    }

    private func finish(_ image: UIImage?) {
        guard !finished else { return }
        finished = true

        timeoutTask?.cancel()
        timeoutTask = nil

        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "frame")
        webView?.removeFromSuperview()
        webView = nil

        if let htmlFileURL {
            try? FileManager.default.removeItem(at: htmlFileURL)
            self.htmlFileURL = nil
        }

        continuation?.resume(returning: image)
        continuation = nil
    }

    // MARK: - Helpers

    private static func foregroundWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return active?.windows.first { $0.isKeyWindow } ?? active?.windows.first
    }

    private static func image(fromDataURL dataURL: String) -> UIImage? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }

    private static func html(relativeSrc: String, maxSize: CGFloat) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:0;background:#000;overflow:hidden}#v{width:64px;height:64px;object-fit:cover}</style>
        </head>
        <body>
        <video id="v" muted playsinline preload="auto" src="\(relativeSrc)"></video>
        <canvas id="c" style="display:none"></canvas>
        <script>
        (function(){
          var v=document.getElementById('v'), c=document.getElementById('c'), MAX=\(Int(maxSize)), done=false;
          function post(o){try{window.webkit.messageHandlers.frame.postMessage(o);}catch(e){}}
          function fail(r){if(done)return;done=true;post({error:String(r||'fail')});}
          function grab(){
            if(done)return;
            var w=v.videoWidth, h=v.videoHeight;
            if(!w||!h){fail('nodims');return;}
            var s=Math.min(1, MAX/Math.max(w,h));
            c.width=Math.max(1,Math.round(w*s)); c.height=Math.max(1,Math.round(h*s));
            try{
              c.getContext('2d').drawImage(v,0,0,c.width,c.height);
              done=true; post({data:c.toDataURL('image/jpeg',0.82)});
            }catch(e){fail('draw:'+e);}
          }
          v.addEventListener('loadedmetadata',function(){
            // Seek 10% in — videos frequently open on a black frame.
            var t=(isFinite(v.duration)&&v.duration>0)?v.duration*0.1:0;
            if(t<=0)t=0.01;
            try{v.currentTime=t;}catch(e){fail('seek');}
          });
          v.addEventListener('seeked',grab);
          v.addEventListener('error',function(){fail('videoerror');});
          // Fallback if 'seeked' never fires but a frame is decodable.
          setTimeout(function(){ if(!done && v.readyState>=2) grab(); }, 8000);
          v.load();
        })();
        </script>
        </body>
        </html>
        """
    }
}
#endif
