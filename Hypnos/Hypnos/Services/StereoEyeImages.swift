/*
 Hypnos - one 3D frame's eyes as images, for the debug server

 `stereoEyes` (FilmDebugEndpoints) captures the next frame the stereo pump
 draws (Vergence's `StereoEyeCapture`) and returns one view of it as a PNG:
 either eye, the source frame, the depth map, an anaglyph (left in red,
 right in cyan) or the eyes' difference. A crop zooms in on a region.
 Debug only; nothing is kept on disk.
 */

#if os(visionOS)
import CoreImage
import CoreVideo
import Foundation
import RAVEMedia

enum StereoEyeImages {
    enum View: String, CaseIterable {
        case left, right, source, depth, anaglyph, difference
    }

    enum Failure: Error, CustomStringConvertible {
        case noFrame
        case render
        var description: String {
            switch self {
            case .noFrame: "No 3D frame arrived within 2 s: is an AI 3D picture showing?"
            case .render: "The frame couldn't be turned into an image."
            }
        }
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// A lossless replay fixture. Image/depth bytes are base64 in the JSON payload.
    static func replayData(of frame: StereoEyeCapture.Frame) throws -> Data {
        guard let depth = frame.depth,
              CVPixelBufferGetPixelFormatType(frame.source) == kCVPixelFormatType_32BGRA else {
            throw Failure.render
        }
        struct Replay: Encodable {
            let version = 1
            let width: Int
            let height: Int
            let depthWidth: Int
            let depthHeight: Int
            let itemSeconds: Double
            let strength: Float
            let convergence: Float
            let warp: StereoEyeCapture.WarpMetadata
            let sourceBGRA: Data
            let depthFloat32: Data
            let leftPNG: Data
            let rightPNG: Data
        }
        let source = frame.source
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(source) else { throw Failure.render }
        let stride = CVPixelBufferGetBytesPerRow(source)
        var pixels = Data(capacity: width * height * 4)
        for row in 0..<height { pixels.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
        let floats = depth.values.withUnsafeBytes { Data($0) }
        return try JSONEncoder().encode(Replay(
            width: width, height: height, depthWidth: depth.width, depthHeight: depth.height,
            itemSeconds: frame.itemSeconds, strength: frame.depthStrength, convergence: frame.convergence,
            warp: frame.warp, sourceBGRA: pixels, depthFloat32: floats,
            leftPNG: try png(.left, of: frame, crop: nil), rightPNG: try png(.right, of: frame, crop: nil)))
    }

    /// A fresh capture, waiting up to two seconds for the pump to draw one.
    static func capture(recomputingDepth: Bool = false) async throws -> StereoEyeCapture.Frame {
        let generation = StereoEyeCapture.request(recomputingDepth: recomputingDepth)
        for _ in 0..<40 {
            if let frame = StereoEyeCapture.latest(after: generation) { return frame }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.noFrame
    }

    /// `crop` is x, y, width, height as fractions of the frame (top left origin).
    static func png(_ view: View, of frame: StereoEyeCapture.Frame, crop: CGRect?) throws -> Data {
        var image: CIImage
        switch view {
        case .left: image = CIImage(cvPixelBuffer: frame.left)
        case .right: image = CIImage(cvPixelBuffer: frame.right)
        case .source: image = CIImage(cvPixelBuffer: frame.source)
        case .depth:
            guard let depth = depthImage(frame) else { throw Failure.render }
            image = depth
        case .anaglyph:
            let left = CIImage(cvPixelBuffer: frame.left), right = CIImage(cvPixelBuffer: frame.right)
            let red = left.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
            let cyan = right.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
            image = red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: cyan])
        case .difference:
            let left = CIImage(cvPixelBuffer: frame.left), right = CIImage(cvPixelBuffer: frame.right)
            image = left.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: right])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 4])
        }
        if let crop {
            let extent = image.extent
            // CIImage's origin is bottom left.
            let rect = CGRect(x: extent.minX + crop.minX * extent.width,
                              y: extent.minY + (1 - crop.maxY) * extent.height,
                              width: crop.width * extent.width, height: crop.height * extent.height)
            image = image.cropped(to: rect.integral)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: space) else { throw Failure.render }
        return data
    }

    /// The depth map as grey (near white), stretched over its own range.
    private static func depthImage(_ frame: StereoEyeCapture.Frame) -> CIImage? {
        guard let depth = frame.depth, depth.width > 0, depth.height > 0 else { return nil }
        let lo = depth.values.min() ?? 0, hi = depth.values.max() ?? 1
        let span = max(hi - lo, 1e-6)
        var bytes = [UInt8](repeating: 0, count: depth.width * depth.height)
        for i in bytes.indices {
            bytes[i] = UInt8(max(0, min(255, (depth.values[i] - lo) / span * 255)))
        }
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: depth.width,
                       size: CGSize(width: depth.width, height: depth.height), format: .L8, colorSpace: space)
    }
}
#endif
