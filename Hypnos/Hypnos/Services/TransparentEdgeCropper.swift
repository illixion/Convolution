/*
 Hypnos - Transparent Edge Cropper

 Scans a CGImage's alpha channel to find the bounding box of pixels
 with non-zero alpha and returns a cropped copy with fully transparent
 margins removed. Used for the background-removal pipeline and for
 display of any image with an alpha channel (PNG, JXL, WebP) so the
 viewer window only takes the space the visible content needs.

 Pixel-format-agnostic: draws the source into a controlled sRGB / RGBA8
 buffer (optionally downsampled) before scanning, so the same code works
 for 8-bit and 16-bit inputs regardless of color space or byte order.
 */

import CoreGraphics
import DebugTrace

enum TransparentEdgeCropper {
    /// Maximum dimension used for the alpha-bounds scan. Large images are
    /// downsampled to this size before scanning — edge-crop precision within
    /// a pixel or two at full res is not meaningful, and the 2048 cap keeps
    /// the scan under ~16 MB of scratch memory regardless of source size.
    private static let maxScanDimension = 2048

    /// Return a copy of `cgImage` with fully transparent margins cropped away.
    /// Returns the original image unchanged when:
    ///   - no margins are fully transparent (includes all opaque images)
    ///   - the image is entirely transparent
    ///   - the alpha scan fails
    ///
    /// Runs the scan unconditionally rather than gating on `cgImage.alphaInfo`:
    /// format decoders (HEIC, WebP, JXL) aren't always consistent about
    /// advertising an alpha channel, and the scan itself is the source of
    /// truth. An opaque image drawn into the scan buffer ends up with
    /// alpha=255 everywhere, so no crop is performed.
    static func crop(_ cgImage: CGImage) -> CGImage {
        guard let bounds = nonTransparentBounds(of: cgImage) else {
            return cgImage
        }

        let width = cgImage.width
        let height = cgImage.height

        // Nothing to trim — bounds already cover the full image
        if bounds.origin.x <= 0,
           bounds.origin.y <= 0,
           Int(bounds.maxX) >= width,
           Int(bounds.maxY) >= height {
            return cgImage
        }

        guard let cropped = cgImage.cropping(to: bounds) else {
            AppLogger.backgroundRemover.warning("Failed to crop CGImage to alpha bounds")
            return cgImage
        }

        // `cropping(to:)` returns a CGImage that shares the parent buffer and
        // carries an internal offset. Some downstream drawing paths (notably
        // `UIImage.draw(in:)` via `UIGraphicsImageRenderer`) draw the parent
        // extent rather than the cropped region, which manifests as the
        // subject appearing shrunken inside extra padding. Rebake into a
        // fresh standalone buffer so the result has no parent dependency.
        return CGImageDeepColor.redraw(cropped) ?? cropped
    }

    /// Find the tightest image-space rect containing pixels with alpha > 0.
    /// For very large images the scan runs on a downsampled copy and the
    /// result is mapped back to image coordinates. Returns nil if the image
    /// is entirely transparent or the scan can't be set up.
    private static func nonTransparentBounds(of cgImage: CGImage) -> CGRect? {
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        let maxSide = max(imageWidth, imageHeight)
        let scale: Double = maxSide > maxScanDimension
            ? Double(maxScanDimension) / Double(maxSide)
            : 1.0

        let scanWidth = max(1, Int((Double(imageWidth) * scale).rounded()))
        let scanHeight = max(1, Int((Double(imageHeight) * scale).rounded()))

        let bytesPerPixel = 4
        let bytesPerRow = scanWidth * bytesPerPixel

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        var buffer = [UInt8](repeating: 0, count: bytesPerRow * scanHeight)

        let didDraw: Bool = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: scanWidth,
                height: scanHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }

            // CGContext's default origin is bottom-left; flip so buffer row 0
            // maps to the top of the image (matching CGImage.cropping coords).
            ctx.translateBy(x: 0, y: CGFloat(scanHeight))
            ctx.scaleBy(x: 1, y: -1)
            ctx.clear(CGRect(x: 0, y: 0, width: scanWidth, height: scanHeight))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: scanWidth, height: scanHeight))
            return true
        }

        guard didDraw else { return nil }

        var minX = scanWidth
        var maxX = -1
        var minY = scanHeight
        var maxY = -1

        buffer.withUnsafeBufferPointer { bufferPtr in
            guard let base = bufferPtr.baseAddress else { return }
            for y in 0..<scanHeight {
                let rowStart = base + y * bytesPerRow
                for x in 0..<scanWidth {
                    let alpha = rowStart[x * bytesPerPixel + 3]
                    if alpha > 0 {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
        }

        guard minX <= maxX, minY <= maxY else { return nil }

        // Map scan-space bounds back to image-space. Use floor on the lower
        // edges and ceil on the upper edges so downsampling can't push the
        // crop inside an edge that's visible at full resolution.
        let inverseScale = 1.0 / scale
        let origMinX = max(0, Int(floor(Double(minX) * inverseScale)))
        let origMinY = max(0, Int(floor(Double(minY) * inverseScale)))
        let origMaxX = min(imageWidth - 1, Int(ceil(Double(maxX + 1) * inverseScale)) - 1)
        let origMaxY = min(imageHeight - 1, Int(ceil(Double(maxY + 1) * inverseScale)) - 1)

        guard origMinX <= origMaxX, origMinY <= origMaxY else { return nil }

        return CGRect(
            x: origMinX,
            y: origMinY,
            width: origMaxX - origMinX + 1,
            height: origMaxY - origMinY + 1
        )
    }
}
