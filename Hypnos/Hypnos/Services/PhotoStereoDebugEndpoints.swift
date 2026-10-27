import CoreGraphics
import DebugTrace
import Foundation
import Metal
import RAVEMedia

/// Metadata only: no photo names, paths or rendered pixels are returned.
/// Also hosts the HDR photo knobs and test pattern (`HDRStills`).
@MainActor
enum PhotoStereoDebugEndpoints {
    static let windows = NSHashTable<PhotoWindowModel>.weakObjects()
    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        registerRenderDiagnostics()
        DebugSurface.shared.register([
            .query("photoStereoState", "Photo AI 3D: dimensions, resolution limits, depth precision and preparation state. "
                + "Windows are ordered by most recent interaction.") { _ in reply() },
            .command("photoStereo", "Enable AI 3D or change its resolution on a photo window. "
                + "separated selects the experimental antialiased disconnected renderer for all photo windows. "
                + "No image data is returned.", parameters: [
                    .integer("window", "window index, most recently used first", default: 0, range: 0 ... 64),
                    .boolean("enabled", "enable or disable photo AI 3D"),
                    .boolean("separated", "A/B compare separated boundaries and background fill"),
                    .integer("resolution", "per-window long-edge limit; 0 follows native within the stereo safety budget", range: 0 ... 8192)
                ]) { args in
                    if let separated = args.bool("separated") {
                        UserDefaults.standard.set(separated, forKey: "aiPhotoSeparateBoundaries")
                    }
                    let models = orderedWindows
                    if let index = args.int("window"), models.indices.contains(index) {
                        let model = models[index]
                        if let resolution = args.int("resolution") { await model.applyResolutionOverride(resolution) }
                        if let enabled = args.bool("enabled") { await model.setAIDepthMode(enabled, trackChange: false) }
                    }
                    return reply()
                },
            .command("photoHDR", "HDR photos: on/off, the display headroom highlights are tone mapped to, and the "
                + "mid-tone curve of the AI 3D HDR frame. Reopen or reload a photo to see a change.", parameters: [
                    .boolean("enabled", "decode HDR photos as HDR (default on)"),
                    .number("headroom", "display headroom in multiples of SDR white; 0 restores the default (2.5)", range: 0 ... 16),
                    .number("midGamma", "power on the AI 3D frame's linear picture; above 1 darkens mid-tones (default 1.09)", range: 0.5 ... 2)
                ]) { args in setHDR(args) },
            .command("photoHDRTest", "Show an HDR test pattern in place of a photo window's picture, drawn raw "
                + "through the flat EDR path. Left to right: " + testValues.map { String($0) }.joined(separator: ", ")
                + " times SDR white, each beside a 1.0 reference. dots: small dots over black (the ceiling); "
                + "patches: window-filling bars (the panel's brightness limiter). dots3d and patches3d send the pattern through AI 3D's video path instead. off reloads the photo.", parameters: [
                    .integer("window", "window index, most recently used first", default: 0, range: 0 ... 64),
                    .string("layout", "dots, patches, dots3d, patches3d, flip (dots and dots3d alternating) or off", required: true)
                ]) { args in await showHDRTest(args) }
        ])
    }

    private static func setHDR(_ args: DebugArguments) -> Reply {
        if let enabled = args.bool("enabled") { UserDefaults.standard.set(enabled, forKey: HDRStills.enabledKey) }
        if let headroom = args.double("headroom") {
            if headroom < 1 { UserDefaults.standard.removeObject(forKey: HDRStills.headroomKey) }
            else { UserDefaults.standard.set(Float(headroom), forKey: HDRStills.headroomKey) }
        }
        if let gamma = args.double("midGamma") {
            UserDefaults.standard.set(gamma, forKey: "aiPhotoHDRMidGamma")
        }
        return reply()
    }

    private static func showHDRTest(_ args: DebugArguments) async -> Reply {
        let models = orderedWindows
        guard let index = args.int("window"), models.indices.contains(index) else { return reply() }
        let model = models[index]
        let layout = args.string("layout") ?? "off"
        HDRTestFlipper.shared.task?.cancel()
        HDRTestFlipper.shared.task = nil
        if layout == "flip" {
            // Alternates flat and AI 3D every five seconds until another layout or `off`.
            HDRTestFlipper.shared.task = Task { @MainActor in
                var through3D = false
                while !Task.isCancelled {
                    await applyHDRTest(layout: through3D ? "dots3d" : "dots", to: model)
                    through3D.toggle()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            return reply()
        }
        await applyHDRTest(layout: layout, to: model)
        return reply()
    }

    @MainActor private final class HDRTestFlipper {
        static let shared = HDRTestFlipper()
        var task: Task<Void, Never>?
    }

    private static func applyHDRTest(layout: String, to model: PhotoWindowModel) async {
        if model.isAIDepthMode { await model.setAIDepthMode(false, trackChange: false) }
        // `dots3d` / `patches3d` send the same pattern through AI 3D's video path.
        let through3D = layout.hasSuffix("3d")
        let shape = through3D ? String(layout.dropLast(2)) : layout
        if shape == "dots" || shape == "patches",
           let pattern = testPattern(dots: shape == "dots") {
            model.showsDebugPattern = true
            model.displayTexture = pattern.texture
            model.currentDisplayMaxDimension = 0
            model.imageAspectRatio = CGFloat(pattern.texture.width) / CGFloat(pattern.texture.height)
            if through3D {
                // A tilt in the depth map keeps the depth range non-degenerate.
                let columns = 64, rows = 36
                let tilt = (0 ..< columns * rows).map { 0.45 + 0.1 * Float($0 % columns) / Float(columns - 1) }
                model.aiDepthSource = pattern.image
                model.aiDepthHeadroom = testValues.max() ?? 1
                model.aiDepthMap = StillDepthMap(width: columns, height: rows, normalizedValues: tilt)
                model.aiDepthSourceDimension = max(pattern.image.width, pattern.image.height)
                model.aiDepthPresentationReady = false
                await model.setAIDepthMode(true, trackChange: false)
            }
        } else {
            model.showsDebugPattern = false
            model.displayTexture = nil
            model.currentDisplayMaxDimension = 0
            await model.loadDisplayImage(for: model.lastWindowSize ?? model.appModel.mainWindowSize)
        }
    }

    static let testValues: [Float] = [0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 6, 8]

    /// Raw linear values, no tone map, registered with the highest as the
    /// texture's peak so the shader keeps them all.
    private static func testPattern(dots: Bool) -> (image: CGImage, texture: MTLTexture)? {
        let width = 1650, height = 900
        var pixels = [Float](repeating: 0, count: width * height * 4)
        func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ v: Float, orange: Bool = false) {
            for y in max(y0, 0) ..< min(y0 + h, height) {
                for x in max(x0, 0) ..< min(x0 + w, width) {
                    let i = (y * width + x) * 4
                    // Orange is the sunset's colour: red at v, green and blue a fraction of it.
                    pixels[i] = v; pixels[i + 1] = orange ? v * 0.45 : v; pixels[i + 2] = orange ? v * 0.05 : v; pixels[i + 3] = 1
                }
            }
        }
        for y in 0 ..< height { for x in 0 ..< width { pixels[(y * width + x) * 4 + 3] = 1 } }
        let column = width / testValues.count
        for (i, v) in testValues.enumerated() {
            let x = i * column
            if dots {
                fill(x + column / 2 - 12, height / 4 - 12, 24, 24, 1)
                fill(x + column / 2 - 12, height / 2 - 12, 24, 24, v)
                fill(x + column / 2 - 12, height * 3 / 4 - 12, 24, 24, v, orange: true)
            } else {
                fill(x + 4, 0, column - 8, height / 6, 1)
                fill(x + 4, height / 6 + 8, column - 8, height - height / 6 - 8, v)
            }
        }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                                  bytesPerRow: width * 16, space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let texture = MetalImageRenderer.shared?.createTexture(from: image, autoCropTransparentEdges: false) else {
            return nil
        }
        MetalImageRenderer.setHeadroom(testValues.max() ?? 1, of: texture)
        return (image, texture)
    }

    static func registerRenderDiagnostics() {
        DebugSurface.shared.register([
            .query("photoStereoRender", "Numeric renderer status and plane bounds for AI photo diagnostics.") { _ in
                #if os(visionOS)
                return RAVEStereoPhotoView.diagnosticState()
                #else
                return [[String: String]]()
                #endif
            }
        ])
    }

    private static var orderedWindows: [PhotoWindowModel] {
        windows.allObjects.sorted { $0.lastInteractionTime > $1.lastInteractionTime }
    }
    struct Reply: Encodable {
        let separated: Bool
        let hdrEnabled: Bool
        let hdrHeadroom: Float
        let hdrMidGamma: Double
        let windows: [Window]
    }
    struct Window: Encodable {
        let enabled: Bool
        let ready: Bool
        let processingDepth: Bool
        let sourceWidth: Int
        let sourceHeight: Int
        let effectiveLimit: Int
        let stereoTarget: Int
        let depthWidth: Int
        let depthHeight: Int
        let preciseDepth: Bool
        let aiHeadroom: Float
        let flatHeadroom: Float
    }
    private static func reply() -> Reply {
        Reply(separated: UserDefaults.standard.bool(forKey: "aiPhotoSeparateBoundaries"),
              hdrEnabled: HDRStills.isEnabled, hdrHeadroom: HDRStills.targetHeadroom,
              hdrMidGamma: UserDefaults.standard.object(forKey: "aiPhotoHDRMidGamma") as? Double ?? 1.09,
              windows: orderedWindows.map {
            Window(enabled: $0.isAIDepthMode, ready: $0.aiDepthPresentationReady, processingDepth: $0.isProcessingAIDepth,
                sourceWidth: $0.aiDepthSource?.width ?? 0, sourceHeight: $0.aiDepthSource?.height ?? 0,
                effectiveLimit: $0.effectiveMaxResolution, stereoTarget: $0.aiDepthTargetDimension(),
                depthWidth: $0.aiDepthMap?.width ?? 0, depthHeight: $0.aiDepthMap?.height ?? 0,
                preciseDepth: $0.aiDepthMap?.preciseValues != nil, aiHeadroom: $0.aiDepthHeadroom,
                flatHeadroom: $0.displayTexture.map { MetalImageRenderer.headroom(of: $0) } ?? 1)
        })
    }
}
