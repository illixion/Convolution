/*
 Hypnos - Video Window Model: working out what a video is

 A video is 2D, packed 3D (side by side or over-under, full or half, eyes
 in either order) or VR (180°, 360°, fisheye; mono or stereo). Nobody
 should have to say which: once the native player has frames, a few are
 taken (`VideoFormatSampler`) and Vergence's `VideoFormatAnalyzer` reads
 them, with the file's name, and the answer is kept per video
 (`VideoFormatAnalysisStore`). `detectedFormat` uses it when it is sure,
 and falls back to the tags and name until then.

 The viewer can still say otherwise in the 3D panel (`Video3DPanelView`),
 which shows the video with each eye's part marked and changes the
 picture as it is edited; that choice is `vrOverride`.
 */

import AVFoundation
import CoreGraphics
import DebugTrace
import Foundation
import VergenceApple

extension VideoWindowModel {
    /// Looks at the picture once per video, when it hasn't been looked at
    /// yet: frames from the native player as it plays.
    func analyzeFormatIfNeeded() {
        guard formatAnalysis == nil else { return }
        takeFormatFrames(analyze: true)
    }

    /// A frame for the 3D panel's preview, when there is none yet (an
    /// analysis read from the cache took none).
    func refreshFormatPreview() {
        guard formatPreview == nil else { return }
        takeFormatFrames(analyze: formatAnalysis == nil)
    }

    private func takeFormatFrames(analyze: Bool) {
        guard formatAnalysisTask == nil, let player = nativePlayer else { return }
        let identity = video.identity
        let name = video.fileName ?? video.title ?? video.streamURL.lastPathComponent
        AppLogger.videoWindow.info("Format: looking at the picture\(analyze ? "" : " (preview only)", privacy: .public)")
        formatAnalysisTask = Task { [weak self] in
            let sample = await VideoFormatSampler.sample(player, count: analyze ? 4 : 1)
            guard let self, !Task.isCancelled, self.video.identity == identity else { return }
            defer { self.formatAnalysisTask = nil }
            guard let sample else {
                AppLogger.videoWindow.info("Format: no usable frame to look at; trying again in 10 s")
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, self.video.identity == identity else { return }
                    if analyze { self.analyzeFormatIfNeeded() } else { self.refreshFormatPreview() }
                }
                return
            }
            self.formatPreview = sample.preview
            guard analyze else { return }
            let frames = sample.frames, size = sample.frameSize
            let analysis = await Task.detached(priority: .utility) {
                VideoFormatAnalyzer.analyze(frames: frames, frameSize: size, fileName: name)
            }.value
            guard self.video.identity == identity else { return }
            self.formatAnalysis = analysis
            VideoFormatAnalysisStore.shared.set(analysis, for: identity)
            AppLogger.videoWindow.info("""
                Format: \(analysis.summary, privacy: .public) at \(analysis.confidence, format: .fixed(precision: 2), privacy: .public) \
                (projection by \(analysis.projectionSource.rawValue, privacy: .public), \
                layout by \(analysis.layoutSource.rawValue, privacy: .public), \
                eyes by \(analysis.eyeOrderSource.rawValue, privacy: .public)) from \(frames.count, privacy: .public) frames \
                \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public)
                """)
        }
    }

    /// The 3D panel's choice; nil goes back to what was detected. The window
    /// and the sphere show it from the next frame.
    func chooseFormat(_ format: VRFormat?) {
        recordFormatChoice(format)
        // 3D chosen for a video that was playing flat, or 2D for one in 3D.
        if let format, !format.projection.isImmersive {
            stereoscopicOverride = format.layout != nil
        } else if format == nil {
            stereoscopicOverride = nil
        }
        video3DSettings = nil
        if !isVRVideo, wantsVR { wantsVR = false }
    }

    private func recordFormatChoice(_ format: VRFormat?) {
        vrOverride = format
    }

    // MARK: - Comparing guesses

    /// Blender's fisheye camera (Equidistant) default.
    static let renderedFisheyeFieldOfView = 180.0

    /// Whether the projection is the picture's guess (no name, tag or
    /// metadata said it): worth offering the alternatives.
    var formatIsGuessed: Bool {
        guard isVRVideo, vrOverride == nil, let analysis = formatAnalysis else { return false }
        // A name or tag that only says "180" or "VR" leaves the lens open too.
        if analysis.projectionSource == .name || analysis.projectionSource == .container { return false }
        // A tag or name that says fisheye (MKX200, FISHEYE190) names the lens.
        return !(video.vrFormat?.projection.isFisheye ?? false)
    }

    /// The likely readings of this VR video, in a fixed order so a button
    /// stays where it was; each keeps the current packing and eye order.
    func formatCandidates() -> [FormatCandidate] {
        let current = videoFormat
        guard current.projection.isImmersive else { return [] }
        func with(_ projection: VRProjection) -> VRFormat {
            VRFormat(layout: current.layout, projection: projection)
        }
        let ellipse: EyeEllipse = if case .fisheye(_, let fitted) = current.projection { fitted } else { .inscribed }
        switch current.projection {
        case .equirectangular(let degrees) where degrees > 270:
            return [FormatCandidate(title: "360°", format: with(.vr360)),
                    FormatCandidate(title: "180°", format: with(.vr180))]
        default:
            return [FormatCandidate(title: "Fisheye 180°", format: with(.fisheye(fieldOfView: 180, ellipse: ellipse))),
                    FormatCandidate(title: "Fisheye 190°", format: with(.fisheye(fieldOfView: 190, ellipse: ellipse))),
                    FormatCandidate(title: "Flat 180°", format: with(.vr180))]
        }
    }

    func startFormatCompare() {
        let candidates = formatCandidates()
        formatCompare = candidates.isEmpty ? nil : candidates
    }

    /// Shows `format` now, as the 3D panel would.
    func previewFormat(_ format: VRFormat) {
        chooseFormat(format == detectedFormat ? nil : format)
    }

    func swapEyesInPreview() {
        var format = videoFormat
        guard format.layout != nil else { return }
        format.layout?.eyesReversed.toggle()
        previewFormat(format)
    }

    func endFormatCompare() { formatCompare = nil }
}

/// One reading of a VR video, a button of the compare bar.
struct FormatCandidate: Identifiable, Equatable {
    let title: String
    let format: VRFormat
    var id: String { title }

    /// Whether `shown` is this reading (the lens circle and eye order aside).
    func matches(_ shown: VRFormat) -> Bool {
        switch (format.projection, shown.projection) {
        case (.fisheye(let a, _), .fisheye(let b, _)): abs(a - b) < 0.5
        default: format.projection == shown.projection
        }
    }
}

/// Settings: a VR video opens around the viewer (on by default; the 3D
/// panel's toggle).
enum VROpening {
    static let key = "video.opensVRAroundYou"
    static var automatically: Bool {
        HypnosDefaults.store.object(forKey: key) as? Bool ?? true
    }
}

extension VRProjection {
    var isFisheye: Bool { if case .fisheye = self { true } else { false } }
}

extension VideoFormatAnalysis {
    /// "VR 180° fisheye, over-under, eyes swapped", for the log and the panel.
    var summary: String { format.summary }
}

extension VRFormat {
    var summary: String {
        var parts: [String] = []
        switch projection {
        case .flat: parts.append(layout == nil ? "2D" : "3D")
        case .equirectangular(let degrees): parts.append("VR \(Int(degrees.rounded()))°")
        case .fisheye(let fieldOfView, _): parts.append("VR fisheye \(Int(fieldOfView.rounded()))°")
        }
        if let layout {
            parts.append(layout.arrangement == .sideBySide ? "side by side" : "over-under")
            if layout.isHalfResolution { parts.append("half") }
            if layout.eyesReversed { parts.append("eyes swapped") }
        } else if projection.isImmersive {
            parts.append("mono")
        }
        return parts.joined(separator: ", ")
    }
}
