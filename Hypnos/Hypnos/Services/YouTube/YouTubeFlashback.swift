/*
 Hypnos - rolling visual flashback detection (sideload YouTube builds only)

 The native player keeps compact per-frame fingerprints for the last ten
 seconds. On request, this detector finds short visual changes followed by a
 return to the preceding picture. It never stores decoded frames or uploads
 image data.
 */

#if HYPNOS_YOUTUBE
import CoreVideo
import Foundation

struct YouTubeFlashbackFrame {
    let time: Double
    let tiles: [UInt8]
}

struct YouTubeFlashbackCandidate: Identifiable, Sendable {
    let id: Int
    let time: Double
    let duration: Double
    let change: Double
}

enum YouTubeFlashback {
    static let window: Double = 10
    private static let columns = 24
    private static let rows = 14
    private static let maximumInterruptionDuration = 3.0

    /// Low resolution luminance map. Tile values make small corner inserts
    /// visible even when most of the frame is unchanged.
    static func fingerprint(_ buffer: CVPixelBuffer, time: Double) -> YouTubeFlashbackFrame? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var values = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x0 = column * width / columns
                let x1 = max(x0 + 1, (column + 1) * width / columns)
                let y0 = row * height / rows
                let y1 = max(y0 + 1, (row + 1) * height / rows)
                var luma = 0
                for sampleY in 1...2 {
                    for sampleX in 1...2 {
                        let x = x0 + sampleX * (x1 - x0) / 3
                        let y = y0 + sampleY * (y1 - y0) / 3
                        let offset = y * stride + x * 4
                        // Integer approximation of Rec. 709 luma.
                        luma += (29 * Int(pixels[offset]) + 150 * Int(pixels[offset + 1]) + 77 * Int(pixels[offset + 2])) >> 8
                    }
                }
                values[row * columns + column] = UInt8(luma / 4)
            }
        }
        return YouTubeFlashbackFrame(time: time, tiles: values)
    }

    /// Sensitivity is 0...1; higher values admit smaller visual changes.
    static func candidates(in frames: [YouTubeFlashbackFrame], sensitivity: Double) -> [YouTubeFlashbackCandidate] {
        guard frames.count >= 4 else { return [] }
        let sensitivity = min(max(sensitivity, 0), 1)
        let changeFloor = 34.0 - sensitivity * 31.0
        let returnCeiling = 19.0 + sensitivity * 25.0
        var found: [YouTubeFlashbackCandidate] = []
        var index = 1
        while index < frames.count - 2 {
            let before = frames[index - 1]
            let onset = frames[index]
            let onsetDifference = distance(before, onset)
            guard onsetDifference >= changeFloor else { index += 1; continue }

            let last = min(frames.count - 1,
                           index + max(2, Int((onset.time + maximumInterruptionDuration - before.time) * 90)))
            var returned: Int?
            if index + 1 <= last {
                for candidate in (index + 1)...last
                    where frames[candidate].time - onset.time >= 0.015
                        && frames[candidate].time - onset.time <= maximumInterruptionDuration {
                    if distance(before, frames[candidate]) <= returnCeiling {
                        returned = candidate
                        break
                    }
                }
            }
            if let returned {
                found.append(YouTubeFlashbackCandidate(id: found.count, time: onset.time,
                    duration: max(0, frames[returned].time - onset.time), change: onsetDifference))
                index = returned + 1
            } else {
                index += 1
            }
        }
        return found
    }

    private static func distance(_ lhs: YouTubeFlashbackFrame, _ rhs: YouTubeFlashbackFrame) -> Double {
        guard lhs.tiles.count == rhs.tiles.count, !lhs.tiles.isEmpty else { return .infinity }
        var total = 0
        for i in lhs.tiles.indices { total += abs(Int(lhs.tiles[i]) - Int(rhs.tiles[i])) }
        return Double(total) / Double(lhs.tiles.count)
    }
}
#endif
