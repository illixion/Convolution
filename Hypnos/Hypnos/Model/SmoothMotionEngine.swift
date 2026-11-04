import VergenceApple

/// Settings › Videos › Smooth Motion's interpolator for flat 2D videos
/// (`AppModel.smoothMotionEngine`).
enum SmoothMotionEngine: String, CaseIterable, Codable, Sendable {
    /// VideoToolbox's interpolator for 24-30 fps, the GPU one for 50-60 fps.
    case automatic
    /// The GPU one for every rate up to 60 fps.
    case gpu

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .gpu: "Fast (GPU)"
        }
    }

    #if canImport(Metal) && canImport(VideoToolbox)
    var vergenceEngine: InterpolatingFrameSource.Engine {
        switch self {
        case .automatic: .automatic
        case .gpu: .gpu
        }
    }
    #endif
}
