/*
 Hypnos - Data Animated GIF Detection

 Helper to detect if image data contains an animated GIF by checking
 the frame count via CGImageSource.
 */

import ImageIO
import Foundation
import UniformTypeIdentifiers

extension Data {
    var isAnimatedGIF: Bool {
        guard let source = CGImageSourceCreateWithData(self as CFData, nil),
              let sourceType = CGImageSourceGetType(source) else {
            return false
        }

        let typeIdentifier = sourceType as String
        guard let type = UTType(typeIdentifier), type.conforms(to: .gif) else {
            return false
        }

        return CGImageSourceGetCount(source) > 1
    }

    /// ImageIO reads these bytes as a picture (WebP, GIF, PNG/APNG, HEIC, …).
    /// A video clip (MP4, WebM) is not one.
    var isImageFile: Bool {
        if isWebPContainer { return true }
        guard let source = CGImageSourceCreateWithData(self as CFData, nil),
              let sourceType = CGImageSourceGetType(source),
              let type = UTType(sourceType as String) else { return false }
        return type.conforms(to: .image)
    }

    var isAnimatedWebP: Bool {
        guard isWebPContainer else { return false }
        return hasAnimatedWebPChunks
    }

    var isWebP: Bool {
        isWebPContainer
    }

    private var isWebPContainer: Bool {
        guard count >= 12 else { return false }
        let riff = self[0...3]
        let webp = self[8...11]
        return String(decoding: riff, as: UTF8.self) == "RIFF"
            && String(decoding: webp, as: UTF8.self) == "WEBP"
    }

    private var hasAnimatedWebPChunks: Bool {
        var offset = 12

        while offset + 8 <= count {
            let chunkID = fourCC(at: offset)
            let chunkSize = littleEndianUInt32(at: offset + 4)
            let payloadOffset = offset + 8

            if chunkID == "ANIM" || chunkID == "ANMF" {
                return true
            }

            if chunkID == "VP8X", payloadOffset < count {
                // VP8X flags: bit 1 indicates animation.
                let flags = self[payloadOffset]
                if (flags & 0x02) != 0 {
                    return true
                }
            }

            let paddedChunkSize = Int(chunkSize) + (Int(chunkSize) % 2)
            offset = payloadOffset + paddedChunkSize
        }

        return false
    }

    private func fourCC(at offset: Int) -> String {
        guard offset + 4 <= count else { return "" }
        return String(decoding: self[offset..<(offset + 4)], as: UTF8.self)
    }

    private func littleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
