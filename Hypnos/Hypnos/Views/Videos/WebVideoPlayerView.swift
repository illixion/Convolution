/*
 Hypnos - Web Video Player View

 WKWebView-based video player that supports WebM and other formats
 not natively supported by AVPlayer.
 */

// tvOS has no WebKit. macOS's WKWebView exists, but this player's transparent/
// custom-controls setup and JS bridge (`webView.scrollView.*`, the message
// handlers wired in `makeUIView`) need real macOS adaptation this pass didn't
// reach — nothing in the macOS UI (Views/Mac/) mounts it; macOS's own video
// window uses a plain AVKit `AVPlayerView` instead (`Views/Mac/`). See
// Hypnos/CLAUDE.md "macOS" for the seam list and gaps.
#if canImport(WebKit) && !os(macOS)
import DebugTrace
import Foundation
import SwiftUI
import WebKit

struct WebVideoPlayerView: UIViewRepresentable {
    let videoURL: URL
    /// Optional second URL the *page* switches to on error, without involving
    /// Swift (the remote slideshow's raw → HLS escalation). The main video
    /// window leaves this nil and uses `onSourceUnplayable` instead, so the
    /// re-route also updates the renderer and unlocks the AVFoundation features.
    var fallbackVideoURL: URL? = nil
    var showControls: Bool = true
    /// Whether the window is in the user's current room. When false, auto-resume
    /// is suppressed and the video is paused to save resources.
    var isRoomActive: Bool = true
    /// Called once when the video's native dimensions become known (from the HTML video element's loadedmetadata event).
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    /// Called once when the clip length (seconds) becomes known, from the same
    /// loadedmetadata event. The remote viewer reports it to the server as
    /// `imageReady { durationMs }` so a clip longer than the slideshow interval
    /// delays the advance until it has played through.
    var onDurationKnown: ((Double) -> Void)? = nil
    /// Whether the video element loops. A clip that fits the interval loops
    /// (default); a clip longer than the interval plays once and freezes on its
    /// last frame until the server advances, so it doesn't restart its opening
    /// frame just before the crossfade.
    var loop: Bool = true
    /// Optional visual adjustments to apply as CSS filters on the video element
    var visualAdjustments: VisualAdjustments? = nil
    /// Optional A-B loop controller. When provided, the player exposes JS hooks
    /// for querying current time and setting loop bounds; the controller drives them.
    var loopController: VideoLoopController? = nil
    /// Optional per-window playback model. When provided, the player binds
    /// play/pause/seek/mute command closures and reports playback state back to
    /// it (driving the custom SwiftUI control bar). nil for callers that don't
    /// need custom controls (animated GIFs, remote slideshow, stereoscopic fallback).
    var playbackModel: VideoWindowModel? = nil
    /// Initial mute state for the <video> element (autoplay always starts
    /// playback; this only controls whether it opens with audio). Callers
    /// without a mute UI (GIFs, remote slideshow) keep the muted default.
    var startMuted: Bool = true

    /// Called when the source can't be played: a decode/unsupported-source error
    /// (immediately), or a network error whose in-page retries were exhausted.
    /// The video window uses it to fall forward onto Stash's server transcode.
    var onSourceUnplayable: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.onVideoSizeKnown = onVideoSizeKnown
        coordinator.onDurationKnown = onDurationKnown
        coordinator.onSourceUnplayable = onSourceUnplayable

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(coordinator, name: "videoDimensions")
        configuration.userContentController.add(coordinator, name: "videoPlayback")
        configuration.userContentController.add(coordinator, name: "videoSourceFailed")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Kicking play() from the delegate's didFinish is what actually starts
        // autoplay reliably: a Swift-initiated play on a fully loaded page is
        // honoured where the page's own initial attempt gets dropped. (This used
        // to happen by accident via the room-activity JS on the open-time
        // scene-phase flap, which is why a prev/next switch — no phase change —
        // stayed blank.)
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onVideoSizeKnown = onVideoSizeKnown
        coordinator.onDurationKnown = onDurationKnown
        coordinator.onSourceUnplayable = onSourceUnplayable

        // Wire up A-B loop controller (re-bound each update; closures hold a weak webView)
        if let loopController {
            loopController.queryCurrentTime = { [weak webView] in
                guard let webView else { return nil }
                do {
                    let result = try await webView.evaluateJavaScript("document.getElementById('player') ? document.getElementById('player').currentTime : null")
                    if let n = result as? NSNumber { return n.doubleValue }
                } catch {}
                return nil
            }
            loopController.setLoopBounds = { [weak webView] a, b in
                guard let webView else { return }
                let js: String
                if let a, let b {
                    js = "if (window.__startABLoop) window.__startABLoop(\(a), \(b));"
                } else {
                    js = "if (window.__stopABLoop) window.__stopABLoop();"
                }
                webView.evaluateJavaScript(js)
            }
        }

        // Wire up the playback model (custom controls). Commands evaluate JS on
        // the <video> element; state flows back via the videoPlayback handler.
        if let playbackModel {
            coordinator.onPlaybackUpdate = { [weak playbackModel] body in
                guard let playbackModel else { return }
                playbackModel.applyPlaybackState(
                    currentTime: (body["currentTime"] as? Double) ?? 0,
                    duration: (body["duration"] as? Double) ?? 0,
                    paused: (body["paused"] as? Bool) ?? true,
                    muted: (body["muted"] as? Bool) ?? false,
                    buffered: (body["buffered"] as? Double) ?? 0
                )
            }
            playbackModel.playCommand = { [weak webView] in
                webView?.evaluateJavaScript("var p = document.getElementById('player'); if (p) p.play().catch(function(){});")
            }
            playbackModel.pauseCommand = { [weak webView] in
                // Also stand down the autoplay kick: an explicit pause outranks
                // a still-retrying autoplay attempt.
                webView?.evaluateJavaScript("window.__autoplayKickCancelled = true; var p = document.getElementById('player'); if (p) p.pause();")
            }
            playbackModel.seekCommand = { [weak webView] t in
                webView?.evaluateJavaScript("{ const p = document.getElementById('player'); if (p) p.currentTime = \(t); }")
            }
            playbackModel.setMutedCommand = { [weak webView] m in
                webView?.evaluateJavaScript("{ const p = document.getElementById('player'); if (p) p.muted = \(m ? "true" : "false"); }")
            }
        }

        // Only reload the page when the video URL changes
        if coordinator.loadedURL != videoURL {
            coordinator.loadedURL = videoURL
            coordinator.resetForNewVideo()
            // Seed the coordinator's controls state so the post-load JS toggle
            // doesn't fire redundantly (and, more importantly, so the initial
            // DOM already matches — see the conditional `controls` attribute in
            // generateVideoHTML). Without this, the page loads with native
            // controls visible and they flash until updateUIView's JS runs.
            coordinator.lastShowControls = showControls
            coordinator.lastLoop = loop
            // Seed room activity too: the fresh page starts with the current
            // state baked in (`window._roomActive`), so the room block below
            // doesn't fire a play/pause JS call against a page that hasn't
            // finished loading — which is exactly what used to leave a video
            // switched via prev/next sitting on a blank first frame. Autoplay is
            // now driven from inside the page (kickAutoplay).
            coordinator.lastIsRoomActive = isRoomActive
            if videoURL.isFileURL {
                loadLocalVideo(webView: webView, coordinator: coordinator, fileURL: videoURL)
            } else {
                let html = generateVideoHTML(for: videoURL)
                webView.loadHTMLString(html, baseURL: videoURL)
            }
        }

        // Toggle controls via JS without reloading
        if coordinator.lastShowControls != showControls {
            coordinator.lastShowControls = showControls
            let js = "document.getElementById('player').controls = \(showControls);"
            webView.evaluateJavaScript(js)
        }

        // Toggle looping via JS without reloading. A long clip flips this to
        // false once its duration is known so it plays through once.
        if coordinator.lastLoop != loop {
            coordinator.lastLoop = loop
            let js = "{ const p = document.getElementById('player'); if (p) p.loop = \(loop); }"
            webView.evaluateJavaScript(js)
        }

        // Apply visual adjustments when they change. Tonal/opacity-only changes
        // stay as cheap CSS filters; sharpen switches the WebView to a WebGL
        // presentation canvas because WebKit does not visibly apply SVG
        // convolution filters to hardware-backed <video> layers on visionOS.
        if let adjustments = visualAdjustments, adjustments != coordinator.lastAdjustments {
            coordinator.lastAdjustments = adjustments
            let css = Self.javascriptStringLiteral(adjustments.cssFilterString())
            let js = """
            if (window.__setHypnosVideoAdjustments) {
                window.__setHypnosVideoAdjustments({
                    brightness: \(adjustments.brightness),
                    contrast: \(adjustments.contrast),
                    saturation: \(adjustments.saturation),
                    opacity: \(adjustments.opacity),
                    sharpen: \(adjustments.clampedSharpenAmount),
                    cssFilter: \(css)
                });
            }
            """
            webView.evaluateJavaScript(js)
        } else if visualAdjustments == nil && coordinator.lastAdjustments != nil {
            coordinator.lastAdjustments = nil
            let identity = VisualAdjustments()
            let css = Self.javascriptStringLiteral(identity.cssFilterString())
            let js = """
            if (window.__setHypnosVideoAdjustments) {
                window.__setHypnosVideoAdjustments({
                    brightness: \(identity.brightness),
                    contrast: \(identity.contrast),
                    saturation: \(identity.saturation),
                    opacity: \(identity.opacity),
                    sharpen: \(identity.clampedSharpenAmount),
                    cssFilter: \(css)
                });
            }
            """
            webView.evaluateJavaScript(js)
        }

        // Pause/resume and toggle auto-resume based on room activity
        if coordinator.lastIsRoomActive != isRoomActive {
            coordinator.lastIsRoomActive = isRoomActive
            if isRoomActive {
                // Cancel any pending src unload
                coordinator.cancelSrcUnload()

                if coordinator.isSourceUnloaded {
                    // Restore src after unload; only resume playback if it was
                    // playing at room exit (a manual pause sticks).
                    let js = """
                    (function() {
                        window._roomActive = true;
                        var p = document.getElementById('player');
                        if (!p) { return; }
                        p.src = originalSrc; p.load();
                        if (window._resumeOnRoomActive !== false) {
                            window._autoResumeUntil = Date.now() + 3000;
                            p.play().catch(function() {});
                            if (window.__kickAutoplayNow) window.__kickAutoplayNow();
                        }
                    })();
                    """
                    webView.evaluateJavaScript(js)
                    coordinator.isSourceUnloaded = false
                } else {
                    // Room re-entered: restore the state from room exit. Only a
                    // video that was playing then auto-resumes (brief auto-resume
                    // window; outside it user pauses / audio interruptions are
                    // respected). A manually paused video stays paused — focus
                    // flaps from other media must not unpause it.
                    let js = """
                    (function() {
                        window._roomActive = true;
                        if (window._resumeOnRoomActive !== false) {
                            window._autoResumeUntil = Date.now() + 3000;
                            document.getElementById('player').play().catch(function() {});
                            // A video whose autoplay never got going before the
                            // window left the room resumes the poll here.
                            if (window.__kickAutoplayNow) window.__kickAutoplayNow();
                        }
                    })();
                    """
                    webView.evaluateJavaScript(js)
                }
            } else {
                // Left room: remember whether it was playing, disable
                // auto-resume, pause, and schedule src unload. A video whose
                // autoplay hasn't produced frames yet still reports paused —
                // count "never started" as playing so the open-time scene-phase
                // flap doesn't permanently defeat autoplay (mirrors the
                // .waitingToPlayAtSpecifiedRate handling in the AVPlayer paths).
                let js = """
                (function() {
                    window._roomActive = false;
                    var p = document.getElementById('player');
                    if (p) {
                        window._resumeOnRoomActive = !p.paused || !window.__playbackEverStarted;
                        p.pause();
                    }
                })();
                """
                webView.evaluateJavaScript(js)
                coordinator.scheduleSrcUnload(webView: webView)
            }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "videoDimensions")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "videoPlayback")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "videoSourceFailed")
        coordinator.onVideoSizeKnown = nil
        coordinator.onDurationKnown = nil
        coordinator.onSourceUnplayable = nil
        coordinator.onPlaybackUpdate = nil
        webView.navigationDelegate = nil
        coordinator.cancelSrcUnload()
        coordinator.cleanupHTMLFile()
    }

    /// Load a local video by writing a temporary HTML file into the video's directory
    /// and using loadFileURL to grant WKWebView read access to that directory.
    private func loadLocalVideo(webView: WKWebView, coordinator: Coordinator, fileURL: URL) {
        // Use relative filename so WKWebView resolves it against the HTML file's directory
        let relativeSrc = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? fileURL.lastPathComponent
        let html = generateVideoHTML(videoSrc: relativeSrc)
        let videoDir = fileURL.deletingLastPathComponent()
        let videoBaseName = fileURL.deletingPathExtension().lastPathComponent
        let htmlFile = videoDir.appendingPathComponent(".hypnos_player_\(videoBaseName).html")
        // Clean up previous HTML file if switching videos
        coordinator.cleanupHTMLFile()
        try? html.write(to: htmlFile, atomically: true, encoding: .utf8)
        coordinator.htmlFileURL = htmlFile
        webView.loadFileURL(htmlFile, allowingReadAccessTo: videoDir)
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var htmlFileURL: URL?
        var loadedURL: URL?
        var lastShowControls: Bool?
        var lastLoop: Bool?
        var lastIsRoomActive: Bool?
        var lastAdjustments: VisualAdjustments?
        var onVideoSizeKnown: ((CGSize) -> Void)?
        var onDurationKnown: ((Double) -> Void)?
        /// Fired once per page load when the source turns out to be a dead end.
        var onSourceUnplayable: (() -> Void)?
        private var didReportSourceFailure = false
        /// Forwards periodic playback state ({currentTime, duration, paused, muted, buffered})
        /// to the bound VideoWindowModel for the custom control bar.
        var onPlaybackUpdate: (([String: Any]) -> Void)?
        /// Prevents firing the callback more than once per video load
        private var didReportSize: Bool = false
        /// Prevents firing the duration callback more than once per video load
        private var didReportDuration: Bool = false

        /// Task that fires after 30s of inactivity to unload the video src
        var srcUnloadTask: Task<Void, Never>?
        /// Whether the video src has been unloaded to free memory
        var isSourceUnloaded: Bool = false

        /// How long the video must remain inactive before unloading its src
        static let srcUnloadDelay: TimeInterval = 30

        func cleanupHTMLFile() {
            guard let url = htmlFileURL else { return }
            try? FileManager.default.removeItem(at: url)
            htmlFileURL = nil
        }

        func resetForNewVideo() {
            didReportSize = false
            didReportDuration = false
            didReportSourceFailure = false
            cancelSrcUnload()
            isSourceUnloaded = false
        }

        func scheduleSrcUnload(webView: WKWebView) {
            srcUnloadTask?.cancel()
            srcUnloadTask = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .seconds(Self.srcUnloadDelay))
                guard !Task.isCancelled, let self, let webView else { return }
                let js = """
                (function() {
                    var p = document.getElementById('player');
                    if (p) { p.removeAttribute('src'); p.load(); }
                })();
                """
                _ = try? await webView.evaluateJavaScript(js)
                self.isSourceUnloaded = true
            }
        }

        func cancelSrcUnload() {
            srcUnloadTask?.cancel()
            srcUnloadTask = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The page is live now — start playback from the app side. The
            // in-page poll is the backup for the frames before this fires.
            webView.evaluateJavaScript("if (window.__kickAutoplayNow) window.__kickAutoplayNow();")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "videoSourceFailed" {
                guard !didReportSourceFailure else { return }
                didReportSourceFailure = true
                let reason = (message.body as? [String: Any])?["reason"] as? String ?? "unknown"
                AppLogger.videoWindow.warning("WebKit player reported source unplayable (\(reason, privacy: .public))")
                onSourceUnplayable?()
                return
            }
            if message.name == "videoPlayback" {
                if let body = message.body as? [String: Any] {
                    onPlaybackUpdate?(body)
                }
                return
            }
            guard message.name == "videoDimensions",
                  let body = message.body as? [String: Any] else { return }
            // Duration and dimensions arrive together on loadedmetadata but
            // are guarded independently — a stream with unknown dimensions can
            // still report a usable clip length, and vice versa.
            if !didReportDuration, let duration = body["duration"] as? Double,
               duration > 0, duration.isFinite {
                didReportDuration = true
                onDurationKnown?(duration)
            }
            guard let width = body["width"] as? Double,
                  let height = body["height"] as? Double,
                  width > 0, height > 0,
                  !didReportSize else { return }
            didReportSize = true
            onVideoSizeKnown?(CGSize(width: width, height: height))
        }
    }

    private func generateVideoHTML(for url: URL) -> String {
        // A `<video src>` can carry neither a header nor an out-of-band
        // credential, so only a query-param auth (Stash) is reachable here —
        // a header-credentialed host (or a future Nextcloud source, which
        // never routes through this player; see NativeMetalVideoPlayerView)
        // is returned unauthenticated by authorizedURL and the request 401s.
        let videoURLString = MediaAuthorization.shared.authorizedURL(url).absoluteString
        let fallbackURLString = fallbackVideoURL.map {
            MediaAuthorization.shared.authorizedURL($0).absoluteString
        }
        return generateVideoHTML(videoSrc: videoURLString, fallbackVideoSrc: fallbackURLString)
    }

    private func generateVideoHTML(videoSrc: String, fallbackVideoSrc: String? = nil) -> String {
        // Match the initial `controls` attribute to showControls so native
        // controls never flash on load before the JS toggle can hide them.
        let controlsAttr = showControls ? "controls " : ""
        let loopAttr = loop ? "loop " : ""
        // Unmuted autoplay is allowed here: the WKWebView is configured with
        // mediaTypesRequiringUserActionForPlayback = [].
        let mutedAttr = startMuted ? "muted " : ""
        let initialAdjustments = visualAdjustments ?? VisualAdjustments()
        let initialFilter = initialAdjustments.cssFilterString()
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                html, body {
                    width: 100%;
                    height: 100%;
                    background: transparent;
                    overflow: hidden;
                }
                .video-container {
                    width: 100%;
                    height: 100%;
                    position: relative;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    background: transparent;
                }
                video,
                #sharpen-canvas {
                    position: absolute;
                    inset: 0;
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: transparent;
                }
                video {
                    filter: \(initialFilter);
                }
                #sharpen-canvas {
                    display: none;
                    pointer-events: none;
                }
                .error {
                    color: #ff6b6b;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    text-align: center;
                    padding: 20px;
                }
            </style>
        </head>
        <body>
            <div class="video-container">
                <video id="player" \(controlsAttr)autoplay playsinline \(loopAttr)\(mutedAttr)src="\(videoSrc)">
                    Your browser does not support video playback.
                </video>
                <canvas id="sharpen-canvas"></canvas>
            </div>
            <script>
                const video = document.getElementById('player');
                const sharpenCanvas = document.getElementById('sharpen-canvas');
                const originalSrc = video.src;
                const fallbackSrc = \(Self.javascriptStringLiteral(fallbackVideoSrc ?? ""));
                let didSwitchToFallbackSrc = false;
                const reportsSourceFailure = \(onSourceUnplayable != nil ? "true" : "false");
                let didReportSourceFailure = false;
                let retryCount = 0;
                const maxRetries = 5;
                const baseDelay = 3000; // 3 seconds initial delay
                let visualAdjustments = {
                    brightness: \(initialAdjustments.brightness),
                    contrast: \(initialAdjustments.contrast),
                    saturation: \(initialAdjustments.saturation),
                    opacity: \(initialAdjustments.opacity),
                    sharpen: \(initialAdjustments.clampedSharpenAmount),
                    cssFilter: '\(initialFilter)'
                };

                // Room activity flag — baked in at load, updated by Swift via
                // evaluateJavaScript. When false, autoplay, auto-resume and
                // error recovery are all suppressed.
                window._roomActive = \(isRoomActive ? "true" : "false");

                // Auto-resume on pause is only allowed within a brief window after
                // a scene-phase transition (window restoration), to recover from
                // spurious system pauses. Outside this window, user-initiated
                // pauses and audio-session interruptions are respected.
                window._autoResumeUntil = Date.now() + 3000;

                // ----- WebGL sharpen presentation -----
                // CSS/SVG convolution filters are ignored by WebKit's video
                // compositor on visionOS. When Sharpen is active we keep the
                // <video> as the decoder/playback source, upload each frame to a
                // WebGL texture, and present a sharpened quad on the canvas.
                let sharpenGL = null;
                let sharpenProgram = null;
                let sharpenTexture = null;
                let sharpenUniforms = null;
                let sharpenRenderToken = 0;
                let sharpenRendererActive = false;
                let sharpenFallbackToCSS = false;

                window.__setHypnosVideoAdjustments = function(next) {
                    visualAdjustments = next;
                    applyVisualAdjustmentsMode();
                };

                function applyVisualAdjustmentsMode() {
                    if (visualAdjustments.sharpen > 0.001 && !sharpenFallbackToCSS) {
                        video.style.filter = 'none';
                        video.style.opacity = '0';
                        sharpenCanvas.style.display = 'block';
                        startSharpenRenderer();
                    } else {
                        stopSharpenRenderer();
                        sharpenCanvas.style.display = 'none';
                        video.style.opacity = '';
                        video.style.filter = visualAdjustments.cssFilter || 'none';
                    }
                }

                function startSharpenRenderer() {
                    if (sharpenRendererActive) return;
                    sharpenRendererActive = true;
                    const token = ++sharpenRenderToken;
                    const render = function() {
                        if (!sharpenRendererActive || token !== sharpenRenderToken || visualAdjustments.sharpen <= 0.001) return;
                        drawSharpenedFrame();
                        if (video.requestVideoFrameCallback) {
                            video.requestVideoFrameCallback(render);
                        } else {
                            requestAnimationFrame(render);
                        }
                    };
                    render();
                }

                function stopSharpenRenderer() {
                    sharpenRendererActive = false;
                    sharpenRenderToken++;
                }

                function initSharpenGL() {
                    if (sharpenGL) return true;
                    const gl = sharpenCanvas.getContext('webgl', {
                        alpha: true,
                        premultipliedAlpha: false,
                        preserveDrawingBuffer: false
                    });
                    if (!gl) return false;

                    const vertexSource = `
                        attribute vec2 aPosition;
                        varying vec2 vTexCoord;
                        void main() {
                            vTexCoord = (aPosition + 1.0) * 0.5;
                            gl_Position = vec4(aPosition, 0.0, 1.0);
                        }
                    `;
                    const fragmentSource = `
                        precision mediump float;
                        varying vec2 vTexCoord;
                        uniform sampler2D uVideo;
                        uniform vec2 uTexel;
                        uniform float uBrightness;
                        uniform float uContrast;
                        uniform float uSaturation;
                        uniform float uOpacity;
                        uniform float uSharpen;

                        void main() {
                            vec2 uv = vec2(vTexCoord.x, 1.0 - vTexCoord.y);
                            vec4 color = texture2D(uVideo, uv);
                            vec3 b = texture2D(uVideo, uv + vec2(0.0, -uTexel.y)).rgb;
                            vec3 d = texture2D(uVideo, uv + vec2(-uTexel.x, 0.0)).rgb;
                            vec3 f = texture2D(uVideo, uv + vec2(uTexel.x, 0.0)).rgb;
                            vec3 h = texture2D(uVideo, uv + vec2(0.0, uTexel.y)).rgb;
                            float lobe = 0.55 * clamp(uSharpen, 0.0, 1.0);
                            color.rgb = clamp(color.rgb * (1.0 + 4.0 * lobe) - lobe * (b + d + f + h), 0.0, 1.0);

                            color.rgb += uBrightness;
                            color.rgb = (color.rgb - 0.5) * uContrast + 0.5;
                            float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
                            color.rgb = mix(vec3(luminance), color.rgb, uSaturation);
                            color.rgb = clamp(color.rgb, 0.0, 1.0);
                            gl_FragColor = vec4(color.rgb, color.a * uOpacity);
                        }
                    `;

                    function compile(type, source) {
                        const shader = gl.createShader(type);
                        gl.shaderSource(shader, source);
                        gl.compileShader(shader);
                        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return null;
                        return shader;
                    }

                    const vertexShader = compile(gl.VERTEX_SHADER, vertexSource);
                    const fragmentShader = compile(gl.FRAGMENT_SHADER, fragmentSource);
                    if (!vertexShader || !fragmentShader) return false;

                    const program = gl.createProgram();
                    gl.attachShader(program, vertexShader);
                    gl.attachShader(program, fragmentShader);
                    gl.linkProgram(program);
                    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return false;

                    const buffer = gl.createBuffer();
                    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
                    gl.bufferData(
                        gl.ARRAY_BUFFER,
                        new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
                        gl.STATIC_DRAW
                    );

                    gl.useProgram(program);
                    const position = gl.getAttribLocation(program, 'aPosition');
                    gl.enableVertexAttribArray(position);
                    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);

                    const texture = gl.createTexture();
                    gl.bindTexture(gl.TEXTURE_2D, texture);
                    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
                    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
                    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
                    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

                    sharpenGL = gl;
                    sharpenProgram = program;
                    sharpenTexture = texture;
                    sharpenUniforms = {
                        video: gl.getUniformLocation(program, 'uVideo'),
                        texel: gl.getUniformLocation(program, 'uTexel'),
                        brightness: gl.getUniformLocation(program, 'uBrightness'),
                        contrast: gl.getUniformLocation(program, 'uContrast'),
                        saturation: gl.getUniformLocation(program, 'uSaturation'),
                        opacity: gl.getUniformLocation(program, 'uOpacity'),
                        sharpen: gl.getUniformLocation(program, 'uSharpen')
                    };
                    return true;
                }

                function resizeSharpenCanvas(gl) {
                    const maxRenderScale = 2.0;
                    const maxRenderPixels = 2560 * 1440;
                    const deviceScale = Math.min(window.devicePixelRatio || 1, maxRenderScale);
                    let width = Math.max(1, Math.floor(sharpenCanvas.clientWidth * deviceScale));
                    let height = Math.max(1, Math.floor(sharpenCanvas.clientHeight * deviceScale));
                    const renderPixels = width * height;
                    if (renderPixels > maxRenderPixels) {
                        const pixelScale = Math.sqrt(maxRenderPixels / renderPixels);
                        width = Math.max(1, Math.floor(width * pixelScale));
                        height = Math.max(1, Math.floor(height * pixelScale));
                    }
                    if (sharpenCanvas.width !== width || sharpenCanvas.height !== height) {
                        sharpenCanvas.width = width;
                        sharpenCanvas.height = height;
                    }

                    const videoAspect = video.videoWidth > 0 && video.videoHeight > 0
                        ? video.videoWidth / video.videoHeight
                        : width / height;
                    const canvasAspect = width / height;
                    let viewportWidth = width;
                    let viewportHeight = height;
                    if (canvasAspect > videoAspect) {
                        viewportWidth = Math.round(height * videoAspect);
                    } else {
                        viewportHeight = Math.round(width / videoAspect);
                    }
                    const viewportX = Math.floor((width - viewportWidth) * 0.5);
                    const viewportY = Math.floor((height - viewportHeight) * 0.5);
                    gl.viewport(viewportX, viewportY, viewportWidth, viewportHeight);
                }

                function drawSharpenedFrame() {
                    if (video.readyState < 2) return;
                    if (!initSharpenGL()) {
                        sharpenFallbackToCSS = true;
                        applyVisualAdjustmentsMode();
                        return;
                    }

                    const gl = sharpenGL;
                    const uniforms = sharpenUniforms;
                    if (!uniforms) return;
                    resizeSharpenCanvas(gl);
                    gl.clearColor(0, 0, 0, 0);
                    gl.clear(gl.COLOR_BUFFER_BIT);
                    gl.useProgram(sharpenProgram);
                    gl.bindTexture(gl.TEXTURE_2D, sharpenTexture);
                    try {
                        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
                    } catch (e) {
                        sharpenFallbackToCSS = true;
                        applyVisualAdjustmentsMode();
                        return;
                    }

                    gl.uniform1i(uniforms.video, 0);
                    gl.uniform2f(
                        uniforms.texel,
                        1.0 / Math.max(1, video.videoWidth),
                        1.0 / Math.max(1, video.videoHeight)
                    );
                    gl.uniform1f(uniforms.brightness, visualAdjustments.brightness);
                    gl.uniform1f(uniforms.contrast, visualAdjustments.contrast);
                    gl.uniform1f(uniforms.saturation, visualAdjustments.saturation);
                    gl.uniform1f(uniforms.opacity, visualAdjustments.opacity);
                    gl.uniform1f(uniforms.sharpen, visualAdjustments.sharpen);
                    gl.drawArrays(gl.TRIANGLES, 0, 6);
                };
                applyVisualAdjustmentsMode();

                // Reload the video source after an error with exponential backoff
                function reloadVideo() {
                    if (!window._roomActive) return;
                    if (retryCount >= maxRetries) return;
                    retryCount++;
                    const delay = baseDelay * Math.pow(2, retryCount - 1);
                    setTimeout(function() {
                        if (!window._roomActive) return;
                        video.src = originalSrc;
                        video.load();
                        video.play().catch(function() {});
                    }, delay);
                }

                // Tell Swift the source is a dead end so it can re-route (Stash
                // server transcode). Reported once per page load.
                function reportSourceFailure(reason) {
                    if (!reportsSourceFailure || didReportSourceFailure) return false;
                    if (!(window.webkit && window.webkit.messageHandlers.videoSourceFailed)) return false;
                    didReportSourceFailure = true;
                    window.webkit.messageHandlers.videoSourceFailed.postMessage({ reason: reason });
                    return true;
                }

                // Page-level escalation to a second URL (remote slideshow).
                function switchToFallbackVideo() {
                    if (!fallbackSrc || didSwitchToFallbackSrc) return false;
                    didSwitchToFallbackSrc = true;
                    retryCount = 0;
                    window.__playbackEverStarted = false;
                    video.src = fallbackSrc;
                    video.load();
                    video.play().catch(function() {});
                    return true;
                }

                // On error: a decode / unsupported-source error is terminal for
                // this URL (the codec isn't supported), so escalate immediately —
                // to the in-page fallback if there is one, else to Swift. A
                // network error is worth retrying in place, and only becomes an
                // escalation once the retries are spent.
                video.addEventListener('error', function() {
                    const code = (video.error && video.error.code) || 0;
                    const terminal = code === 3 /* MEDIA_ERR_DECODE */
                        || code === 4 /* MEDIA_ERR_SRC_NOT_SUPPORTED */;
                    if (terminal) {
                        if (switchToFallbackVideo()) return;
                        if (reportSourceFailure('decode-error-' + code)) return;
                    }
                    if (retryCount >= maxRetries) {
                        if (switchToFallbackVideo()) return;
                        if (reportSourceFailure('retries-exhausted')) return;
                    }
                    reloadVideo();
                });

                // ----- Autoplay -----
                // The bare `autoplay` attribute is not enough: when this page is
                // loaded into a WKWebView that isn't in the window hierarchy yet
                // (which is what happens on a prev/next switch, where the whole
                // player view is rebuilt), the initial attempt is dropped and the
                // video sits on a blank frame until the user taps play.
                //
                // A dropped `play()` does NOT reject — its promise just stays
                // pending — so retrying in `.catch` never fires. Poll instead:
                // re-issue play() while the element is still paused, and stop as
                // soon as it reports playing (or the user pauses, or the window
                // leaves the room, or we run out of patience).
                let autoplayTicks = 0;
                let autoplayTimer = null;
                const maxAutoplayTicks = 24;      // ~10s at 400ms
                function stopAutoplayKick() {
                    if (autoplayTimer !== null) {
                        clearInterval(autoplayTimer);
                        autoplayTimer = null;
                    }
                }
                function autoplayKickDone() {
                    return window.__playbackEverStarted
                        || window.__autoplayKickCancelled
                        || !window._roomActive;
                }
                function kickAutoplayOnce() {
                    if (autoplayKickDone()) { stopAutoplayKick(); return; }
                    if (!video.paused) return;
                    video.play().catch(function() {});
                }
                // Exposed so Swift can kick from the navigation delegate, once
                // the page has genuinely finished loading into a live WKWebView.
                window.__kickAutoplayNow = function() {
                    if (autoplayKickDone()) return;
                    kickAutoplayOnce();
                    startAutoplayKick();
                };
                function startAutoplayKick() {
                    if (autoplayTimer !== null || autoplayKickDone()) return;
                    autoplayTimer = setInterval(function() {
                        autoplayTicks++;
                        if (autoplayTicks > maxAutoplayTicks) { stopAutoplayKick(); return; }
                        kickAutoplayOnce();
                    }, 400);
                }
                video.addEventListener('loadeddata', function() { kickAutoplayOnce(); startAutoplayKick(); });
                video.addEventListener('canplay', function() { kickAutoplayOnce(); startAutoplayKick(); });
                video.addEventListener('playing', stopAutoplayKick);
                startAutoplayKick();

                // Also catch source-level errors (nested <source> or src attribute)
                video.addEventListener('stalled', function() {
                    // Only act if the video isn't playing
                    if (video.paused && video.readyState < 3) {
                        reloadVideo();
                    }
                });

                // Report native video dimensions and clip length to Swift once
                // metadata is loaded. Duration drives the server's dwell so a
                // clip longer than the interval plays through before advancing.
                function reportMetadata() {
                    if (window.webkit && window.webkit.messageHandlers.videoDimensions) {
                        window.webkit.messageHandlers.videoDimensions.postMessage({
                            width: video.videoWidth,
                            height: video.videoHeight,
                            duration: isFinite(video.duration) ? video.duration : 0
                        });
                    }
                }
                video.addEventListener('loadedmetadata', reportMetadata);
                // Some containers report NaN duration at loadedmetadata and the
                // real value only on a later durationchange. Swift dedupes, so
                // re-reporting is harmless.
                video.addEventListener('durationchange', reportMetadata);

                // Reset retry count on successful playback
                video.addEventListener('playing', function() {
                    retryCount = 0;
                    // Autoplay has genuinely begun. Until this flips, the
                    // room-exit capture treats the video as "was playing":
                    // <video>.paused stays true while autoplay is still
                    // buffering, so a scene-phase flap right at window open
                    // would otherwise record "user paused" and kill autoplay.
                    window.__playbackEverStarted = true;
                });

                // ----- Custom controls bridge -----
                // Report playback state to Swift so the SwiftUI control bar can
                // render play/pause, the scrubber, buffered range, and mute.
                function postPlayback() {
                    if (!(window.webkit && window.webkit.messageHandlers.videoPlayback)) return;
                    var b = 0;
                    try { if (video.buffered.length) b = video.buffered.end(video.buffered.length - 1); } catch (e) {}
                    window.webkit.messageHandlers.videoPlayback.postMessage({
                        currentTime: video.currentTime || 0,
                        duration: isFinite(video.duration) ? video.duration : 0,
                        paused: video.paused,
                        muted: video.muted,
                        buffered: b
                    });
                }
                video.addEventListener('timeupdate', postPlayback);
                video.addEventListener('play', postPlayback);
                video.addEventListener('pause', postPlayback);
                video.addEventListener('seeked', postPlayback);
                video.addEventListener('volumechange', postPlayback);
                video.addEventListener('loadedmetadata', postPlayback);
                video.addEventListener('durationchange', postPlayback);

                // ----- A-B Loop -----
                // Frame-accurate seek-back at point B using requestVideoFrameCallback
                // (falls back to requestAnimationFrame). Native `loop` is disabled while
                // an A-B loop is active so it doesn't compete with our seeks.
                window.__abLoop = { a: null, b: null, active: false, monitorTok: 0 };

                window.__startABLoop = function(a, b) {
                    var L = window.__abLoop;
                    L.a = a;
                    L.b = b;
                    L.active = true;
                    L.monitorTok++;
                    var tok = L.monitorTok;
                    video.removeAttribute('loop');
                    var epsilon = 1 / 60; // one frame at 60fps
                    var step = function() {
                        if (!L.active || tok !== L.monitorTok) return;
                        if (L.a !== null && L.b !== null) {
                            if (video.currentTime >= L.b - epsilon) {
                                // Use fastSeek when available for smoother loops
                                if (typeof video.fastSeek === 'function') {
                                    video.fastSeek(L.a);
                                } else {
                                    video.currentTime = L.a;
                                }
                            }
                        }
                        if (typeof video.requestVideoFrameCallback === 'function') {
                            video.requestVideoFrameCallback(step);
                        } else {
                            requestAnimationFrame(step);
                        }
                    };
                    step();
                };

                window.__stopABLoop = function() {
                    var L = window.__abLoop;
                    L.active = false;
                    L.a = null;
                    L.b = null;
                    L.monitorTok++;
                    video.loop = true;
                };

                // Resume playback if the video randomly pauses (e.g. after space restoration).
                // Scoped to a brief window after a scene-phase transition so that user-initiated
                // pauses and audio-session interruptions outside that window are respected.
                video.addEventListener('pause', function() {
                    if (!window._roomActive) return;
                    if (Date.now() > (window._autoResumeUntil || 0)) return;
                    if (!video.ended && video.readyState >= 2) {
                        setTimeout(function() {
                            if (!window._roomActive) return;
                            if (Date.now() > (window._autoResumeUntil || 0)) return;
                            if (video.paused && !video.ended) {
                                video.play().catch(function() {});
                            }
                        }, 500);
                    }
                });
            </script>
        </body>
        </html>
        """
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
#elseif os(macOS)
import SwiftUI

/// macOS stub — see the gate comment above. Reports its source unplayable
/// immediately so a caller chained onto `onSourceUnplayable`
/// (`VideoWindowModel.handleSourceUnplayable`) falls forward onto Stash's
/// server transcode instead of showing a permanently blank frame; a caller
/// with no transcode to fall back to just stays blank, same as it would if
/// the transcode attempt itself failed.
struct WebVideoPlayerView: View {
    let videoURL: URL
    var fallbackVideoURL: URL? = nil
    var showControls: Bool = true
    var isRoomActive: Bool = true
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var onDurationKnown: ((Double) -> Void)? = nil
    var loop: Bool = true
    var visualAdjustments: VisualAdjustments? = nil
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    var startMuted: Bool = true
    var onSourceUnplayable: (() -> Void)? = nil

    var body: some View {
        Color.clear.onAppear { onSourceUnplayable?() }
    }
}
#endif
