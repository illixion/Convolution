import CoreGraphics
import DebugTrace
import Foundation
import RAVEMedia

/// Metadata only: no photo names, paths or rendered pixels are returned.
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
                }
        ])
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
    }
    private static func reply() -> Reply {
        Reply(separated: UserDefaults.standard.bool(forKey: "aiPhotoSeparateBoundaries"), windows: orderedWindows.map {
            Window(enabled: $0.isAIDepthMode, ready: $0.aiDepthPresentationReady, processingDepth: $0.isProcessingAIDepth,
                sourceWidth: $0.aiDepthSource?.width ?? 0, sourceHeight: $0.aiDepthSource?.height ?? 0,
                effectiveLimit: $0.effectiveMaxResolution, stereoTarget: $0.aiDepthTargetDimension(),
                depthWidth: $0.aiDepthMap?.width ?? 0, depthHeight: $0.aiDepthMap?.height ?? 0,
                preciseDepth: $0.aiDepthMap?.preciseValues != nil)
        })
    }
}
