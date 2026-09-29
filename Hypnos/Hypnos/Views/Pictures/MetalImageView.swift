/*
 Hypnos - Metal Image View

 UIViewRepresentable wrapping MTKView for displaying GPU-private
 MTLTexture objects in SwiftUI. Draws on demand (not 60fps) and
 applies brightness/contrast/saturation via Metal fragment shader.
 Supports both 8-bit (bgra8Unorm) and 16-bit (rgba16Unorm / rgba16Float)
 source textures.
 */

import DebugTrace
import MetalKit
import SwiftUI

// This is a real `UIViewRepresentable`, not something visionOS-only, so it
// already compiles and runs on iOS/tvOS unchanged. macOS needs an
// `NSViewRepresentable` instead — a different protocol with different
// required method names (`makeNSView`/`updateNSView`), even though `MTKView`
// and every line of Metal setup below are already fully cross-platform.
// Nothing in the macOS UI (Views/Mac/) mounts this view yet, so this pass
// stubs it rather than writing that (small, mechanical, `Coordinator`-sharing)
// second wrapper — see Hypnos/CLAUDE.md "macOS" for the seam list and gaps.
#if !os(macOS)

/// An on-demand MTKView can receive its first draw request before a restored
/// visionOS scene has a drawable. Re-arm rendering when the view is attached or
/// laid out instead of relying on that one early request.
private final class ResilientMTKView: MTKView {
    var requestRedraw: (() -> Void)?
    private var lastLayoutSize: CGSize = .zero

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            requestRedraw?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        if bounds.width > 0, bounds.height > 0 {
            requestRedraw?()
        }
    }
}

/// Matches `ImageUniforms` in Shaders.metal — pass-1 (RCAS) input.
private struct ImageUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var sharpen: Float
}

/// Matches `AAUniforms` in Shaders.metal — pass-2 (resolve + tonal) input.
private struct AAUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var applyResolve: Float
}

struct MetalImageView: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase

    let texture: MTLTexture?
    let brightness: Float
    let contrast: Float
    let saturation: Float
    let sharpen: Float
    var diagnosticLabel: String? = nil
    var onFramePresented: (() -> Void)? = nil
    var onRenderStalled: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(diagnosticLabel: diagnosticLabel)
    }

    func makeUIView(context: Context) -> MTKView {
        guard let renderer = MetalImageRenderer.shared else {
            return MTKView()
        }

        let mtkView = ResilientMTKView(frame: .zero, device: renderer.device)
        mtkView.delegate = context.coordinator
        mtkView.requestRedraw = { [weak mtkView, weak coordinator = context.coordinator] in
            guard let mtkView, let coordinator else { return }
            coordinator.requestRedraw(in: mtkView)
        }

        // Draw on demand, not continuously
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        // Transparent background so SwiftUI background shows through
        mtkView.isOpaque = false
        mtkView.layer.isOpaque = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        // Pick framebuffer format based on texture depth
        let is16Bit = texture.map { Self.isDeepColor($0) } ?? false
        mtkView.colorPixelFormat = is16Bit ? .rgba16Float : .bgra8Unorm

        // Store current state in coordinator
        context.coordinator.renderer = renderer
        context.coordinator.texture = texture
        context.coordinator.brightness = brightness
        context.coordinator.contrast = contrast
        context.coordinator.saturation = saturation
        context.coordinator.sharpen = sharpen
        context.coordinator.scenePhase = scenePhase
        context.coordinator.onFramePresented = onFramePresented
        context.coordinator.onRenderStalled = onRenderStalled

        context.coordinator.logViewCreated(mtkView)

        context.coordinator.requestRedraw(in: mtkView)
        return mtkView
    }

    func updateUIView(_ mtkView: MTKView, context: Context) {
        let coordinator = context.coordinator
        var needsRedraw = false

        if coordinator.scenePhase != scenePhase {
            coordinator.logScenePhaseChange(from: coordinator.scenePhase, to: scenePhase, view: mtkView)
            coordinator.scenePhase = scenePhase
            needsRedraw = true
        }
        coordinator.onFramePresented = onFramePresented
        coordinator.onRenderStalled = onRenderStalled
        if coordinator.texture !== texture {
            // Switch framebuffer format if bit depth changed
            let is16Bit = texture.map { Self.isDeepColor($0) } ?? false
            let requiredFormat: MTLPixelFormat = is16Bit ? .rgba16Float : .bgra8Unorm
            if mtkView.colorPixelFormat != requiredFormat {
                mtkView.colorPixelFormat = requiredFormat
            }
            coordinator.texture = texture
            needsRedraw = true
        }
        if coordinator.brightness != brightness {
            coordinator.brightness = brightness
            needsRedraw = true
        }
        if coordinator.contrast != contrast {
            coordinator.contrast = contrast
            needsRedraw = true
        }
        if coordinator.saturation != saturation {
            coordinator.saturation = saturation
            needsRedraw = true
        }
        if coordinator.sharpen != sharpen {
            coordinator.sharpen = sharpen
            needsRedraw = true
        }

        if needsRedraw {
            coordinator.requestRedraw(in: mtkView)
        } else if !coordinator.hasPresentedFrame {
            coordinator.ensureRedraw(in: mtkView)
        }
    }

    /// Check if a texture uses a deep color (>8-bit) pixel format.
    private static func isDeepColor(_ texture: MTLTexture) -> Bool {
        switch texture.pixelFormat {
        case .rgba16Unorm, .rgba16Float, .rgba16Snorm,
             .rgba32Float, .rg16Float, .r16Float:
            return true
        default:
            return false
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: MetalImageRenderer?
        var texture: MTLTexture?
        var brightness: Float = 0
        var contrast: Float = 1
        var saturation: Float = 1
        var sharpen: Float = 0
        var scenePhase: ScenePhase = .inactive

        private(set) var hasPresentedFrame = false
        private var redrawGeneration = 0
        private var retryActive = false
        private var drawAttemptCount = 0
        private var hasEverPresentedFrame = false
        private let diagnosticLabel: String
        private let diagnosticID = String(UUID().uuidString.prefix(8))
        var onFramePresented: (() -> Void)?
        var onRenderStalled: (() -> Void)?

        /// Offscreen RCAS target. Allocated lazily and reused across draws.
        /// Reallocated when drawable size or pixel format changes.
        private var intermediate: MTLTexture?

        init(diagnosticLabel: String?) {
            self.diagnosticLabel = diagnosticLabel ?? "image"
        }

        func logViewCreated(_ view: MTKView) {
            let textureSize = texture.map { "\($0.width)x\($0.height)" } ?? "nil"
            AppLogger.windowState.info(
                "[Metal \(self.diagnosticID, privacy: .public)] create label=\(self.diagnosticLabel, privacy: .public) texture=\(textureSize, privacy: .public) bounds=\(Int(view.bounds.width), privacy: .public)x\(Int(view.bounds.height), privacy: .public) attached=\(view.window != nil, privacy: .public) phase=\(String(describing: self.scenePhase), privacy: .public)"
            )
        }

        func logScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase, view: MTKView) {
            AppLogger.windowState.info(
                "[Metal \(self.diagnosticID, privacy: .public)] phase label=\(self.diagnosticLabel, privacy: .public) \(String(describing: oldPhase), privacy: .public)->\(String(describing: newPhase), privacy: .public) attached=\(view.window != nil, privacy: .public)"
            )
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Drawable resize — drop the cached intermediate so it gets
            // reallocated at the new size on the next draw.
            intermediate = nil
            requestRedraw(in: view)
        }

        /// Keep requesting the first frame until the restored scene supplies a
        /// drawable. A cache hit can mount this view immediately, while a cache
        /// miss naturally delays mounting until after texture creation; that is
        /// why the bug appeared tied to selecting the exact same resolution.
        func requestRedraw(in view: MTKView) {
            hasPresentedFrame = false
            retryActive = true
            drawAttemptCount = 0
            redrawGeneration &+= 1
            let generation = redrawGeneration
            triggerDraw(in: view)
            scheduleRetry(in: view, generation: generation, attempt: 0)
        }

        func ensureRedraw(in view: MTKView) {
            if retryActive {
                triggerDraw(in: view)
            } else {
                requestRedraw(in: view)
            }
        }

        private func scheduleRetry(in view: MTKView, generation: Int, attempt: Int) {
            guard attempt < 80 else {
                if redrawGeneration == generation {
                    retryActive = false
                    AppLogger.windowState.error(
                        "[Metal \(self.diagnosticID, privacy: .public)] exhausted redraw retries label=\(self.diagnosticLabel, privacy: .public) drawCallbacks=\(self.drawAttemptCount, privacy: .public) attached=\(view.window != nil, privacy: .public) bounds=\(Int(view.bounds.width), privacy: .public)x\(Int(view.bounds.height), privacy: .public) drawable=\(Int(view.drawableSize.width), privacy: .public)x\(Int(view.drawableSize.height), privacy: .public)"
                    )
                    onRenderStalled?()
                }
                return
            }
            let delay = attempt < 10 ? 0.05 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                guard let self, let view,
                      self.redrawGeneration == generation,
                      !self.hasPresentedFrame else { return }
                // Only draw while attached (a detached layer can't vend a
                // drawable), but keep the retry chain alive either way: on
                // visionOS 27 a scene can report active while its views are
                // never re-attached to a compositor placement, and aborting
                // here silently made that state unobservable — running to
                // exhaustion is what surfaces it through onRenderStalled.
                // A genuinely torn-down view still ends the chain via the
                // weak references above.
                if view.window != nil {
                    self.triggerDraw(in: view)
                }
                self.scheduleRetry(in: view, generation: generation, attempt: attempt + 1)
            }
        }

        private func triggerDraw(in view: MTKView) {
            // `setNeedsDisplay()` can be silently ignored after visionOS loses
            // a restored window's compositor surface. `draw()` is the explicit
            // MTKView API for paused/on-demand rendering and invokes the
            // delegate immediately when the layer can still produce a frame.
            view.draw()
            if !hasPresentedFrame {
                view.setNeedsDisplay()
            }
        }

        private func markFramePresented() {
            hasPresentedFrame = true
            retryActive = false
            redrawGeneration &+= 1
            if !hasEverPresentedFrame {
                hasEverPresentedFrame = true
                AppLogger.windowState.info(
                    "[Metal \(self.diagnosticID, privacy: .public)] first frame submitted label=\(self.diagnosticLabel, privacy: .public) attempts=\(self.drawAttemptCount, privacy: .public)"
                )
            }
            // `MTKView.draw()` invokes the delegate synchronously. Defer the
            // SwiftUI state callback so it cannot trigger view reconciliation
            // reentrantly from inside MetalKit's draw stack.
            DispatchQueue.main.async { [weak self] in
                self?.onFramePresented?()
            }
        }

        func draw(in view: MTKView) {
            drawAttemptCount += 1
            guard let renderer else { return logDrawWait("renderer unavailable", view: view) }
            guard let texture else { return logDrawWait("texture unavailable", view: view) }
            guard let drawable = view.currentDrawable else { return logDrawWait("currentDrawable nil", view: view) }
            guard let finalPassDesc = view.currentRenderPassDescriptor else {
                return logDrawWait("renderPassDescriptor nil", view: view)
            }
            guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                return logDrawWait("commandBuffer unavailable", view: view)
            }

            let is16 = view.colorPixelFormat == .rgba16Float
            let useRCAS = sharpen > 0.001
            let drawableW = drawable.texture.width
            let drawableH = drawable.texture.height

            // Pass-2 input texture: either the offscreen RCAS result, or the source.
            var pass2InputTexture: MTLTexture = texture

            if useRCAS {
                // Render RCAS at source resolution for SSAA — capped at 2×
                // drawable per axis so a huge source doesn't blow up VRAM.
                // Floor at drawable size so we never upsample-then-downsample
                // a small source for no benefit.
                let interW = min(max(texture.width, drawableW), drawableW * 2)
                let interH = min(max(texture.height, drawableH), drawableH * 2)

                let intermediateTex = ensureIntermediate(
                    device: renderer.device,
                    width: interW,
                    height: interH,
                    pixelFormat: view.colorPixelFormat
                )

                if let intermediateTex {
                    let pass1Desc = MTLRenderPassDescriptor()
                    pass1Desc.colorAttachments[0].texture = intermediateTex
                    pass1Desc.colorAttachments[0].loadAction = .clear
                    pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    pass1Desc.colorAttachments[0].storeAction = .store

                    if let pass1Encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) {
                        let rcasPipeline = is16 ? renderer.rcasPipelineState16 : renderer.rcasPipelineState
                        pass1Encoder.setRenderPipelineState(rcasPipeline)
                        pass1Encoder.setFragmentTexture(texture, index: 0)
                        var rcasU = ImageUniforms(brightness: 0, contrast: 1, saturation: 1, sharpen: sharpen)
                        pass1Encoder.setFragmentBytes(&rcasU, length: MemoryLayout<ImageUniforms>.size, index: 0)
                        pass1Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                        pass1Encoder.endEncoding()
                        pass2InputTexture = intermediateTex
                    }
                }
            }

            // Engage rotated-grid resolve whenever pass-2's input is larger
            // than the drawable — independent of RCAS. A raw source bigger
            // than the drawable still benefits from area-averaged downsample
            // (existing aliasing in the source gets smoothed out).
            let didSupersample = pass2InputTexture.width > drawableW || pass2InputTexture.height > drawableH

            guard let pass2Encoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPassDesc) else {
                return
            }

            let finalPipeline = is16 ? renderer.pipelineState16 : renderer.pipelineState
            pass2Encoder.setRenderPipelineState(finalPipeline)
            pass2Encoder.setFragmentTexture(pass2InputTexture, index: 0)

            var aaU = AAUniforms(
                brightness: brightness,
                contrast: contrast,
                saturation: saturation,
                applyResolve: didSupersample ? 1.0 : 0.0
            )
            pass2Encoder.setFragmentBytes(&aaU, length: MemoryLayout<AAUniforms>.size, index: 0)
            pass2Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            pass2Encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
            markFramePresented()
        }

        private func logDrawWait(_ reason: String, view: MTKView) {
            guard drawAttemptCount == 1 || drawAttemptCount == 5
                    || drawAttemptCount == 20 || drawAttemptCount == 80 else { return }
            AppLogger.windowState.warning(
                "[Metal \(self.diagnosticID, privacy: .public)] draw waiting label=\(self.diagnosticLabel, privacy: .public) attempt=\(self.drawAttemptCount, privacy: .public) reason=\(reason, privacy: .public) attached=\(view.window != nil, privacy: .public) bounds=\(Int(view.bounds.width), privacy: .public)x\(Int(view.bounds.height), privacy: .public) drawable=\(Int(view.drawableSize.width), privacy: .public)x\(Int(view.drawableSize.height), privacy: .public)"
            )
        }

        /// Allocate or reuse the offscreen RCAS target. Returns nil on failure.
        private func ensureIntermediate(
            device: MTLDevice,
            width: Int,
            height: Int,
            pixelFormat: MTLPixelFormat
        ) -> MTLTexture? {
            if let existing = intermediate,
               existing.width == width,
               existing.height == height,
               existing.pixelFormat == pixelFormat {
                return existing
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            let tex = device.makeTexture(descriptor: desc)
            intermediate = tex
            return tex
        }
    }
}

#else

/// macOS stub — see the gate comment above.
struct MetalImageView: View {
    let texture: MTLTexture?
    let brightness: Float
    let contrast: Float
    let saturation: Float
    let sharpen: Float
    var diagnosticLabel: String? = nil
    var onFramePresented: (() -> Void)? = nil
    var onRenderStalled: (() -> Void)? = nil

    var body: some View {
        Color.clear
    }
}

#endif
