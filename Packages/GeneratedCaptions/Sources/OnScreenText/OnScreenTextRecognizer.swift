/*
 On-screen text: reading one frame with Vision.

 `.accurate` text recognition, limited to the subtitle region. Measured on an
 M-series Mac (2026-11-15) for the lower 45% of a 720p frame: ~90 ms accurate,
 ~30 ms fast; a 360p or 480p frame reads the same subtitles and costs about
 the same, since Vision scales internally.

 Two things the measurements forced:
 - **Accurate can return nothing, silently.** Mid-run, a stretch of frames
   with large clear subtitles came back with zero observations and no error,
   and the same frames read fine in a fresh process after its model had
   loaded (the first accurate request of a process took 43 s once). So the
   model is warmed before the first frame, and a frame accurate finds empty
   is read again at the fast level, whose answer is used if it has one.
 - **Most frames repeat the last one.** A subtitle stays several seconds; a
   coarse luminance map of the region (24 x 8 cells) that hasn't moved since
   the last frame read means the last reading still holds, at no cost. A
   fade changes the map, so a subtitle fading in is read again.
 */

import CoreGraphics
import CoreVideo
import Foundation
import Vision

public final class OnScreenTextRecognizer: @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        public var framesRead = 0
        public var framesReused = 0
        /// Frames accurate found empty and fast did not.
        public var fastFallbacks = 0
        public var lastReadMilliseconds = 0.0
    }

    private let lock = NSLock()
    private var lastMap: [UInt8] = []
    private var lastLines: [OnScreenTextLine] = []
    private var lastRegion: OnScreenTextRegion?
    private var stats = Statistics()
    private let languages: [String]?
    private var accurateLoaded = false

    /// `languages`: BCP-47 codes to prefer; nil keeps Vision's default.
    public init(languages: [String]? = nil) {
        self.languages = languages
    }

    public var statistics: Statistics { lock.withLock { stats } }

    /// Loads the recognizer's models so the first real frame isn't the one
    /// that pays for it (or comes back empty while it loads). The fast one is
    /// ready in moments; the accurate one took minutes on a Vision Pro, so
    /// `read` uses `.fast` until `warmUpAccurate` has finished.
    public func warmUp() {
        warmUpFast()
        warmUpAccurate()
    }

    public func warmUpFast() {
        guard let handler = Self.warmUpHandler() else { return }
        _ = try? perform(handler, level: .fast, region: nil)
    }

    public func warmUpAccurate() {
        guard let handler = Self.warmUpHandler() else { return }
        _ = try? perform(handler, level: .accurate, region: nil)
        lock.withLock { accurateLoaded = true }
    }

    /// A subtitle-sized frame with text on it: a tiny blank image left
    /// part of the model unloaded, and the first real frame paid for it.
    private static func warmUpHandler() -> VNImageRequestHandler? {
        let width = 1280, height = 320
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        // Blocky "letters": enough for the detector to find a text line.
        for i in 0..<18 {
            let x = 200 + i * 48
            context.fill(CGRect(x: x, y: 140, width: 10, height: 44))
            context.fill(CGRect(x: x, y: 140, width: 30, height: 10))
            context.fill(CGRect(x: x, y: 174, width: 30, height: 10))
        }
        guard let image = context.makeImage() else { return nil }
        return VNImageRequestHandler(cgImage: image)
    }

    /// Forgets the last reading (a seek: the next frame is unrelated).
    public func reset() {
        lock.withLock { lastMap = []; lastLines = []; lastRegion = nil }
    }

    /// The text lines in `region` of a 32BGRA frame. `force` reads it even
    /// when it looks like the last one (the map samples points, so a small
    /// change can slip past it; the caller forces a read now and then).
    public func read(_ buffer: CVPixelBuffer, region: OnScreenTextRegion, force: Bool = false) throws -> [OnScreenTextLine] {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return [] }
        let map = Self.luminanceMap(buffer, region: region)
        let reuse: [OnScreenTextLine]? = lock.withLock {
            guard !force, lastRegion == region, !map.isEmpty, map.count == lastMap.count else { return nil }
            var total = 0
            for i in map.indices { total += abs(Int(map[i]) - Int(lastMap[i])) }
            // Under 1.5 grey levels a cell on average: the same picture,
            // give or take compression noise.
            return Double(total) / Double(map.count) < 1.5 ? lastLines : nil
        }
        if let reuse {
            lock.withLock { stats.framesReused += 1 }
            return reuse
        }

        let started = Date()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer)
        let accurate = lock.withLock { accurateLoaded }
        var observations = accurate ? try perform(handler, level: .accurate, region: region) : []
        var fellBack = false
        if observations.isEmpty {
            observations = try perform(handler, level: .fast, region: region)
            fellBack = !observations.isEmpty
        }
        let lines = Self.lines(from: observations, in: buffer, region: region)
        lock.withLock {
            lastMap = map; lastLines = lines; lastRegion = region
            stats.framesRead += 1
            if fellBack { stats.fastFallbacks += 1 }
            stats.lastReadMilliseconds = Date().timeIntervalSince(started) * 1000
        }
        return lines
    }

    private func perform(_ handler: VNImageRequestHandler, level: VNRequestTextRecognitionLevel,
                         region: OnScreenTextRegion?) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        if let languages, !languages.isEmpty { request.recognitionLanguages = languages }
        if let region {
            // Vision's region of interest is normalised with the origin
            // bottom-left; ours is top-left.
            let rect = region.rect
            request.regionOfInterest = CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        }
        try handler.perform([request])
        return request.results ?? []
    }

    /// Observations to lines in whole-picture fractions, origin top-left,
    /// each with its glyphs' colour.
    private static func lines(from observations: [VNRecognizedTextObservation], in buffer: CVPixelBuffer,
                              region: OnScreenTextRegion) -> [OnScreenTextLine] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let roi = region.rect
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Boxes are relative to the region of interest, origin bottom-left.
            let b = observation.boundingBox
            let box = CGRect(x: roi.minX + b.minX * roi.width,
                             y: roi.minY + (1 - b.maxY) * roi.height,
                             width: b.width * roi.width, height: b.height * roi.height)
            let color = fillColor(buffer, box: box)
            return OnScreenTextLine(text: candidate.string, confidence: candidate.confidence, box: box,
                                    red: color.0, green: color.1, blue: color.2)
        }
    }

    /// Mean of the brightest eighth of the pixels in `box` (a BGRA buffer,
    /// already locked), sampled on a grid of at most ~2000 points.
    private static func fillColor(_ buffer: CVPixelBuffer, box: CGRect) -> (Double, Double, Double) {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let x0 = max(0, Int(box.minX * Double(width))), x1 = min(width, Int(box.maxX * Double(width)))
        let y0 = max(0, Int(box.minY * Double(height))), y1 = min(height, Int(box.maxY * Double(height)))
        guard x1 > x0, y1 > y0 else { return (0, 0, 0) }
        let step = max(1, Int(sqrt(Double((x1 - x0) * (y1 - y0)) / 2000)))
        var samples: [(luma: Int, r: Int, g: Int, b: Int)] = []
        samples.reserveCapacity(2200)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let o = y * stride + x * 4
                let b = Int(pixels[o]), g = Int(pixels[o + 1]), r = Int(pixels[o + 2])
                samples.append(((77 * r + 150 * g + 29 * b) >> 8, r, g, b))
                x += step
            }
            y += step
        }
        samples.sort { $0.luma > $1.luma }
        let top = samples.prefix(max(1, samples.count / 8))
        let n = Double(top.count) * 255
        return (Double(top.reduce(0) { $0 + $1.r }) / n,
                Double(top.reduce(0) { $0 + $1.g }) / n,
                Double(top.reduce(0) { $0 + $1.b }) / n)
    }

    /// 24 x 8 mean-luminance cells over the region.
    static func luminanceMap(_ buffer: CVPixelBuffer, region: OnScreenTextRegion) -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let columns = 24, rows = 8
        let left = Int(region.left * Double(width)), top = Int(region.top * Double(height))
        let regionWidth = max(columns, Int((region.right - region.left) * Double(width)))
        let regionHeight = max(rows, Int((region.bottom - region.top) * Double(height)))
        var map = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0
                // 4 x 4 samples a cell: small text changes still move it.
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let x = min(width - 1, left + (column * 4 + sx) * regionWidth / (columns * 4))
                        let y = min(height - 1, top + (row * 4 + sy) * regionHeight / (rows * 4))
                        let o = y * stride + x * 4
                        sum += (29 * Int(pixels[o]) + 150 * Int(pixels[o + 1]) + 77 * Int(pixels[o + 2])) >> 8
                    }
                }
                map[row * columns + column] = UInt8(sum / 16)
            }
        }
        return map
    }
}
