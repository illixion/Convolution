// Runs VideoToolbox's VTLowLatencyFrameInterpolation over pairs of raw frames,
// for the Smooth Motion quality check (scripts/interp-quality.py, phase E1 of
// docs/plans/blu-ray-3d-smooth-motion.md). macOS 26+, Apple silicon, not the simulator.
//
//     swiftc -O scripts/vt-interp-helper.swift -o build/interp-quality/vt-interp-helper
//     vt-interp-helper PAIRS.yuv OUT.yuv WIDTH HEIGHT PHASES
//
// PAIRS.yuv holds frames as planar I420 (ffmpeg's yuv420p, video range), two per
// pair: the earlier frame, then the later one. PHASES is a comma-separated list
// of in-between moments, e.g. "0.5" or "0.25,0.5,0.75". OUT.yuv receives, per pair,
// one I420 frame per phase. The processor only takes '420v', so each frame is
// copied into a biplanar IOSurface buffer and back; video-range Y'CbCr passes
// through unchanged. Prints the median milliseconds per call on stderr.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@main
struct VTInterpHelper {
    static func main() async throws {
        let a = CommandLine.arguments
        guard a.count == 6, let w = Int(a[3]), let h = Int(a[4]) else {
            FileHandle.standardError.write("usage: vt-interp-helper PAIRS.yuv OUT.yuv WIDTH HEIGHT PHASES\n".data(using: .utf8)!)
            exit(2)
        }
        let phases = a[5].split(separator: ",").map { Float($0)! }
        // 2^n − 1 points are available for n interpolated frames.
        var n = 1
        while (1 << n) - 1 < phases.count || !phases.allSatisfy({ ($0 * Float(1 << n)).rounded() == $0 * Float(1 << n) }) { n += 1 }
        guard let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: n) else {
            fatalError("configuration refused \(w)x\(h) n=\(n)")
        }
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: a[1]))
        FileManager.default.createFile(atPath: a[2], contents: nil)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: a[2]))
        let frameBytes = w * h * 3 / 2
        var times: [Double] = []
        var index: Int64 = 0
        while true {
            guard let d0 = try input.read(upToCount: frameBytes), d0.count == frameBytes,
                  let d1 = try input.read(upToCount: frameBytes), d1.count == frameBytes else { break }
            let prev = try makeBuffer(from: d0, w, h), next = try makeBuffer(from: d1, w, h)
            let dests = try phases.map { _ in try makeBuffer(from: nil, w, h) }
            let pf = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: CMTime(value: index * 2, timescale: 48))!
            let nf = VTFrameProcessorFrame(buffer: next, presentationTimeStamp: CMTime(value: index * 2 + 2, timescale: 48))!
            let df = dests.enumerated().map { i, b in
                VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: index * 2 + 1, timescale: 48 + Int32(i)))!
            }
            guard let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: nf, previousFrame: pf,
                                                                       interpolationPhase: phases, destinationFrames: df) else {
                fatalError("parameters refused")
            }
            let start = Date()
            // The async `process(parameters:)` overload returns a sequence; the
            // completion-handler form is the one that waits for the frames.
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                processor.process(parameters: params) { _, error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
            times.append(Date().timeIntervalSince(start) * 1000)
            for b in dests { output.write(readI420(b, w, h)) }
            index += 1
        }
        times.sort()
        let median = times.isEmpty ? 0 : times[times.count / 2]
        FileHandle.standardError.write(String(format: "vt-interp-helper: %d pairs, n=%d, median %.1f ms\n", times.count, n, median).data(using: .utf8)!)
    }

    static func makeBuffer(from data: Data?, _ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { fatalError("CVPixelBufferCreate \(status)") }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        guard let data else { return buffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for r in 0..<h { memcpy(y + r * yStride, src.baseAddress! + r * w, w) }
            let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let u = src.baseAddress!.assumingMemoryBound(to: UInt8.self) + w * h
            let v = u + (w / 2) * (h / 2)
            for r in 0..<(h / 2) {
                let row = uv + r * uvStride
                for c in 0..<(w / 2) {
                    row[2 * c] = u[r * (w / 2) + c]
                    row[2 * c + 1] = v[r * (w / 2) + c]
                }
            }
        }
        return buffer
    }

    static func readI420(_ buffer: CVPixelBuffer, _ w: Int, _ h: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var out = Data(count: w * h * 3 / 2)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let d = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for r in 0..<h { memcpy(d + r * w, y + r * yStride, w) }
            let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let u = d + w * h, v = u + (w / 2) * (h / 2)
            for r in 0..<(h / 2) {
                let row = uv + r * uvStride
                for c in 0..<(w / 2) {
                    u[r * (w / 2) + c] = row[2 * c]
                    v[r * (w / 2) + c] = row[2 * c + 1]
                }
            }
        }
        return out
    }
}
