/*
 Hypnos - picture comparison window (debug, visionOS)

 An A/B of how visionOS presents the same HDR / Dolby Vision film through
 different renderers, opened beside the film player by the `filmCompare`
 debug command. It plays Jellyfin's own HLS remux of the loaded film (Dolby
 Vision kept, `hevc-rangetype`), muted, following the film player's clock
 loosely (a seek when they drift apart by more than a quarter second; this is
 for looking at, not for lip sync):

 - `playerLayer`: an `AVPlayerLayer` with the film player's display criteria
   on its window (what the flat video window does).
 - `playerViewController`: AVKit's `AVPlayerViewController` with its controls
   hidden, which states its own criteria (what Infuse uses for Dolby Vision).

 `filmLayerRange` sets the film player's own layer's `preferredDynamicRange`,
 the one setting it has that a stock layer doesn't.
 */

#if os(visionOS)
import AVFoundation
import AVKit
import MetalKit
import RAVEFilm
import RealityKit
import SwiftUI

@MainActor @Observable
final class PictureCompare {
    static let shared = PictureCompare()
    static let windowID = "picture-compare"

    enum Renderer: String, CaseIterable {
        case playerLayer, playerViewController, videoPlayerComponent, filmRenderer, filmComponent
    }

    private(set) var renderer: Renderer?
    /// Bumped by each request, which the film player turns into openWindow.
    private(set) var openRequest = 0
    private(set) var status = "Closed"
    private(set) var player: AVPlayer?
    private var followTask: Task<Void, Never>?
    private var loadedItemID: String?
    /// The AVKit controller showing, for `layerTree`.
    weak var controller: AVPlayerViewController?
    /// The comparison window's plain layer host, for `layerTree`.
    weak var layerHost: UIView?

    /// The comparison's view and layer tree, with each layer's dynamic-range
    /// settings, to find what AVKit sets that a plain layer doesn't.
    func layerTree() -> [String] {
        var lines: [String] = []
        let root: UIView? = controller?.viewIfLoaded ?? layerHost
        guard let root else { return ["nothing showing"] }
        if let window = root.window {
            lines.append("window \(type(of: window)) scene \(window.windowScene.map { String(describing: type(of: $0)) } ?? "-")")
            lines.append("  criteria \(window.avDisplayManager.preferredDisplayCriteria.map { "\($0)" } ?? "nil") matching \(window.avDisplayManager.isDisplayCriteriaMatchingEnabled)")
            var ancestor: UIView? = root.superview
            while let view = ancestor { lines.append("  up: \(type(of: view)) \(Self.describe(view.layer))"); ancestor = view.superview }
        }
        func walk(_ view: UIView, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            lines.append("\(pad)view \(type(of: view)) hidden=\(view.isHidden) \(Self.describe(view.layer))")
            for sub in view.layer.sublayers ?? [] where sub.delegate !== nil ? !(view.subviews.contains { $0.layer === sub }) : true {
                walkLayer(sub, depth + 1)
            }
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        func walkLayer(_ layer: CALayer, _ depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + "layer " + Self.describe(layer))
            for sub in layer.sublayers ?? [] { walkLayer(sub, depth + 1) }
        }
        walk(root, 0)
        return lines
    }

    static func describeFilmLayer() -> String {
        describe(FilmSession.shared.player.video.displayLayer)
    }

    private static func describe(_ layer: CALayer) -> String {
        var parts = ["\(type(of: layer))"]
        let keys = ["preferredDynamicRange", "wantsExtendedDynamicRangeContent", "toneMapMode", "contentsHeadroom",
                    "wantsExtendedDynamicRangeContent", "contentsFormat", "allowsDisplayCompositing", "videoGravity",
                    "isReadyForDisplay", "pixelBufferAttributes", "preventsDisplaySleepDuringVideoPlayback"]
        for key in Set(keys).sorted() where layer.responds(to: Selector(key)) {
            if let value = layer.value(forKey: key) { parts.append("\(key)=\(value)") }
        }
        if let filters = layer.filters, !filters.isEmpty { parts.append("filters=\(filters)") }
        if let filters = layer.compositingFilter { parts.append("compositing=\(filters)") }
        return parts.joined(separator: " ")
    }

    func open(_ renderer: Renderer) async -> String {
        guard let item = FilmSession.shared.loadedItem else { return "No film is loaded" }
        if renderer == .filmComponent {
            followTask?.cancel()
            player?.pause()
            player = nil
            loadedItemID = nil
            startFilmComponent()
            self.renderer = renderer
            openRequest += 1
            status = "Showing filmComponent"
            return status
        }
        stopFilmComponent()
        if renderer == .filmRenderer {
            // The film player's own renderer: nothing to stream or follow.
            followTask?.cancel()
            player?.pause()
            player = nil
            loadedItemID = nil
            self.renderer = renderer
            openRequest += 1
            status = "Showing filmRenderer"
            return status
        }
        if player == nil || loadedItemID != item.id {
            guard let library = LibraryService.current() else { return "No Jellyfin server" }
            do {
                let plan = try await library.streamPlan(itemId: item.id, quality: .original)
                let player = AVPlayer(url: plan.streamURL)
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                self.player = player
                loadedItemID = item.id
            } catch {
                return "No stream: \(error.localizedDescription)"
            }
        }
        self.renderer = renderer
        openRequest += 1
        status = "Showing \(renderer.rawValue)"
        follow()
        return status
    }

    func close() {
        stopFilmComponent()
        followTask?.cancel()
        followTask = nil
        player?.pause()
        player = nil
        loadedItemID = nil
        renderer = nil
        status = "Closed"
    }

    /// Keeps the comparison near the film player: same play state, re-seeked
    /// when more than a quarter second apart.
    private func follow() {
        followTask?.cancel()
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                let film = FilmSession.shared.player
                let target = film.currentTime
                let drift = player.currentTime().seconds - target
                if !drift.isFinite || abs(drift) > 0.25 {
                    // Aimed a little ahead: the seek itself takes time.
                    let lead = film.isPlaying ? 0.3 : 0
                    await player.seek(to: CMTime(seconds: target + lead, preferredTimescale: 600),
                                      toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if film.isPlaying, player.rate == 0 { player.play() }
                if !film.isPlaying, player.rate != 0 { player.pause() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: The film's own samples through RealityKit

    /// A renderer of its own, fed every sample the film player enqueues (its
    /// stereo tap) and clocked by a synchronizer that mirrors the film's
    /// timebase: both run on the host clock, so the mirror only has to follow
    /// rate changes, seeks and re-anchors.
    let componentRenderer = AVSampleBufferVideoRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var mirrorTask: Task<Void, Never>?
    private var synchronizerAttached = false

    private func startFilmComponent() {
        let video = FilmSession.shared.player.video
        if !synchronizerAttached {
            synchronizer.addRenderer(componentRenderer)
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
            synchronizerAttached = true
        }
        _ = video
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.mirrorClock()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// Called once RealityKit's component holds the renderer: a renderer
    /// with no video target throws on its first enqueue.
    func componentDidAttach() {
        guard renderer == .filmComponent, mirrorTask != nil else { return }
        let video = FilmSession.shared.player.video
        nonisolated(unsafe) let renderer = componentRenderer
        video.onSampleBuffer = { buffer in renderer.enqueue(buffer) }
        video.onFlush = { renderer.flush() }
        // Samples from the playhead on: a seek in place refills both.
        video.seek(to: video.currentTime)
    }

    private func stopFilmComponent() {
        guard mirrorTask != nil else { return }
        mirrorTask?.cancel()
        mirrorTask = nil
        let video = FilmSession.shared.player.video
        video.onSampleBuffer = nil
        video.onFlush = nil
        componentRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        synchronizer.setRate(0, time: .zero)
    }

    private(set) var mirrorCorrections = 0

    private func mirrorClock() {
        let film = FilmSession.shared.player.video.timebase
        let host = CMClockGetHostTimeClock()
        let now = CMClockGetTime(host)
        let filmTime = CMSyncConvertTime(now, from: host, to: film)
        let rate = CMTimebaseGetRate(film)
        let ours = CMSyncConvertTime(now, from: host, to: synchronizer.timebase)
        if rate != Float64(synchronizer.rate) || abs((filmTime - ours).seconds) > 0.001 {
            synchronizer.setRate(Float(rate), time: filmTime, atHostTime: now)
            mirrorCorrections += 1
        }
    }

    var componentStatus: String {
        let status = switch componentRenderer.status {
        case .rendering: "rendering"
        case .failed: "failed \(componentRenderer.error.map { "\(($0 as NSError).code)" } ?? "?")"
        default: "unknown"
        }
        return "\(status), corrections \(mirrorCorrections), skew \(String(format: "%.1f", (CMTimebaseGetTime(synchronizer.timebase) - CMTimebaseGetTime(FilmSession.shared.player.video.timebase)).seconds * 1000)) ms"
    }

    var drift: Double? {
        guard let player else { return nil }
        let value = player.currentTime().seconds - FilmSession.shared.player.currentTime
        return value.isFinite ? value : nil
    }
}

struct PictureCompareView: View {
    private var compare = PictureCompare.shared

    var body: some View {
        Group {
            if compare.renderer == .filmComponent {
                CompareRealityView(source: .renderer(compare.componentRenderer))
            } else if compare.renderer == .filmRenderer {
                CompareRealityView(source: .renderer(FilmSession.shared.player.video.displayLayer.sampleBufferRenderer))
            } else if let player = compare.player, let renderer = compare.renderer {
                switch renderer {
                case .playerLayer:
                    CompareLayerView(player: player, criteria: FilmSession.shared.player.video.displayCriteria)
                case .playerViewController:
                    CompareControllerView(player: player)
                case .videoPlayerComponent:
                    CompareRealityView(source: .player(player))
                case .filmRenderer, .filmComponent:
                    EmptyView()
                }
            } else {
                Text(compare.status).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(3840.0 / 1740.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if let renderer = compare.renderer {
                Text(renderer.rawValue)
                    .font(.caption).padding(6)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
                    .padding(12)
            }
        }
        .onDisappear { compare.close() }
    }
}

private struct CompareLayerView: UIViewRepresentable {
    let player: AVPlayer
    let criteria: AVDisplayCriteria?

    func makeUIView(context: Context) -> NativeVideoHostView {
        let host = NativeVideoHostView(metalView: MTKViewPlaceholder.make())
        host.metalView.isHidden = true
        host.systemView.isHidden = false
        host.systemView.playerLayer.player = player
        host.backgroundColor = .black
        PictureCompare.shared.layerHost = host
        return host
    }

    func updateUIView(_ host: NativeVideoHostView, context: Context) {
        host.systemView.playerLayer.player = player
        host.displayCriteria = criteria
    }

    static func dismantleUIView(_ host: NativeVideoHostView, coordinator: ()) {
        host.systemView.playerLayer.player = nil
        host.displayCriteria = nil
    }
}

private struct CompareControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.player = player
        PictureCompare.shared.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}

/// RealityKit's video component on an AVPlayer, the way AVKit's own visionOS
/// player appears to draw (its view tree has no AVPlayerLayer).
private struct CompareRealityView: View {
    enum Source {
        case player(AVPlayer)
        case renderer(AVSampleBufferVideoRenderer)
    }
    let source: Source

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                let entity = Entity()
                entity.name = "compare"
                var component = switch source {
                case .player(let player): VideoPlayerComponent(avPlayer: player)
                case .renderer(let renderer): VideoPlayerComponent(videoRenderer: renderer)
                }
                component.desiredViewingMode = .mono
                entity.components.set(component)
                content.add(entity)
                if case .renderer = source {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        PictureCompare.shared.componentDidAttach()
                    }
                }
            } update: { content in
                guard let entity = content.entities.first(where: { $0.name == "compare" }) else { return }
                // The component's screen is 1 m tall at the video's aspect;
                // fit it to the window's height.
                let frame = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                let height = frame.extents.y
                entity.scale = SIMD3(repeating: height)
                entity.position = frame.center
            }
        }
        .frame(depth: 0)
    }
}

/// The host view wants a Metal view; the comparison never draws into it.
private enum MTKViewPlaceholder {
    static func make() -> MTKView { MTKView(frame: .zero, device: nil) }
}

/// Opens the comparison window when `PictureCompare` asks.
struct PictureCompareOpener: ViewModifier {
    @OpenWindowProxy private var openWindow
    private var compare = PictureCompare.shared

    func body(content: Content) -> some View {
        content.onChange(of: compare.openRequest) {
            openWindow(id: PictureCompare.windowID)
        }
    }
}
#endif
