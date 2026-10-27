/*
 Hypnos - Metal Image Renderer

 Singleton service managing Metal device, command queue, render pipeline,
 and texture creation. Uploads CGImage/UIImage data to GPU-private
 MTLTexture objects so decoded pixels live in GPU memory (not dirty CPU
 pages), reducing jetsam pressure.

 Uses CIContext to render images into Metal textures, which handles all
 source pixel formats, color spaces, and bit depths correctly.
 Preserves 16-bit per channel color depth when the source image provides it.
 */

import CoreImage
import Metal
import MetalKit
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

/// Sendable wrapper for MTLTexture. Metal texture objects are thread-safe GPU
/// resource handles, but the protocol doesn't declare Sendable conformance.
struct SendableTexture: @unchecked Sendable {
    let texture: MTLTexture
}

/// Manages Metal resources for GPU-backed image display.
/// All texture creation is nonisolated and thread-safe through Metal's own guarantees.
final class MetalImageRenderer: Sendable {
    static let shared = MetalImageRenderer()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// Pass-2 pipeline (FXAA + brightness/contrast/saturation), 8-bit drawable.
    let pipelineState: MTLRenderPipelineState
    /// Pass-2 pipeline, 16-bit drawable.
    let pipelineState16: MTLRenderPipelineState
    /// Pass-1 RCAS pipeline, renders to an 8-bit intermediate.
    let rcasPipelineState: MTLRenderPipelineState
    /// Pass-1 RCAS pipeline, renders to a 16-bit intermediate.
    let rcasPipelineState16: MTLRenderPipelineState
    private let ciContext: CIContext

    /// Bounds the number of concurrent full-image CGImageSource decodes across
    /// the whole app. A single absurd-resolution source (e.g. a 90+ MP JXL with
    /// no progressive/DC structure) forces ImageIO to materialize the entire
    /// bitmap — ~360 MB at 91 MP — before any downscale can run; subsampling
    /// doesn't help because the decoder ignores it for such files. Multiple
    /// slideshow windows decoding in parallel stack those transients and trip
    /// jetsam, rebooting userspace. Capping concurrent decodes bounds peak
    /// transient memory to roughly (permits × largest-single-decode) regardless
    /// of how many windows are open.
    ///
    /// The decode entry points (`downsampledImage(from:)` and
    /// `createTexture(from url:)`) are synchronous and run on detached/background
    /// tasks, so a parked waiter holds its thread — but the decode it waits on
    /// would occupy a CPU thread anyway, so peak memory is bounded without
    /// changing effective thread pressure.
    private static let decodeGate = DispatchSemaphore(value: 2)

    /// Predicted full-decode size (in bytes) above which a source is treated as
    /// "oversized" and the memory-safety guard engages. ImageIO's JXL decoder
    /// streams cheaply up to ~35 MP (≈140 MB at 8-bit RGBA) and then degrades
    /// into a near-full-bitmap decode whose transient grows ~linearly with pixel
    /// count (see .claude/research/jxl-decode-memory-oom.md). 140 MB ≈ that knee,
    /// and because the figure is bytes (not megapixels) a 16-bit/deep-color source
    /// crosses it at half the pixel count — which is correct, since it costs 2×
    /// per pixel. Tunable.
    static let oversizedDecodeByteThreshold = 140 * 1024 * 1024

    /// Peak brightness, in multiples of SDR white, of each HDR texture made
    /// here (`HDRStills`); SDR textures aren't listed. Weak keys, so an entry
    /// goes with its texture, whichever cache or model held it.
    private nonisolated(unsafe) static let hdrPeaks = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()
    private static let hdrPeaksLock = NSLock()

    /// 1 for SDR; above 1 the texture holds HDR highlights up to that value.
    static func headroom(of texture: MTLTexture) -> Float {
        hdrPeaksLock.lock()
        defer { hdrPeaksLock.unlock() }
        return hdrPeaks.object(forKey: texture)?.floatValue ?? 1
    }

    static func setHeadroom(_ headroom: Float, of texture: MTLTexture) {
        hdrPeaksLock.lock()
        defer { hdrPeaksLock.unlock() }
        if headroom > 1 { hdrPeaks.setObject(NSNumber(value: headroom), forKey: texture) }
        else { hdrPeaks.removeObject(forKey: texture) }
    }

    /// Predicted bytes a full decode of `width`×`height` at `bitsPerComponent`
    /// would allocate, assuming 4 (RGBA) channels. Header-only — no decode.
    static func predictedDecodeBytes(width: Int, height: Int, bitsPerComponent: Int) -> Int {
        let bytesPerComponent = bitsPerComponent > 8 ? 2 : 1
        return width * height * 4 * bytesPerComponent
    }

    /// Current GPU allocation reported by Metal (shared-memory bytes). Used by
    /// callers (e.g. the slideshow's server-convert heuristic) to gauge pressure.
    var currentGPUAllocation: Int { device.currentAllocatedSize }

    /// Allocation above which we consider the device under GPU-memory pressure.
    /// Vision Pro has ~5.5 GB shared; 2 GB of textures is a conservative point to
    /// start shedding load (e.g. asking the slideshow server to send rescaled
    /// images instead of full-resolution sources). Tunable.
    static let highGPUAllocationThreshold = 2 * 1024 * 1024 * 1024

    /// True when GPU allocation has crossed `highGPUAllocationThreshold`.
    var isGPUMemoryHigh: Bool { currentGPUAllocation > Self.highGPUAllocationThreshold }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .outputPremultiplied: true
        ])

        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "imageVertexShader"),
              let aaTonalFn = library.makeFunction(name: "imageFragmentShader"),
              let rcasFn = library.makeFunction(name: "rcasFragmentShader") else {
            return nil
        }

        // Pass-2 (final): alpha blending enabled so transparent pixels (bg removal)
        // composite over whatever's behind the MTKView.
        let finalDesc = MTLRenderPipelineDescriptor()
        finalDesc.vertexFunction = vertexFunction
        finalDesc.fragmentFunction = aaTonalFn
        finalDesc.colorAttachments[0].isBlendingEnabled = true
        finalDesc.colorAttachments[0].rgbBlendOperation = .add
        finalDesc.colorAttachments[0].alphaBlendOperation = .add
        finalDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        finalDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        finalDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        finalDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Pass-1 (RCAS → intermediate): no blending — we want to write the
        // RCAS'd RGBA verbatim into the offscreen target so pass 2 can read it.
        let rcasDesc = MTLRenderPipelineDescriptor()
        rcasDesc.vertexFunction = vertexFunction
        rcasDesc.fragmentFunction = rcasFn
        rcasDesc.colorAttachments[0].isBlendingEnabled = false

        do {
            finalDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipelineState = try device.makeRenderPipelineState(descriptor: finalDesc)
            finalDesc.colorAttachments[0].pixelFormat = .rgba16Float
            self.pipelineState16 = try device.makeRenderPipelineState(descriptor: finalDesc)

            rcasDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.rcasPipelineState = try device.makeRenderPipelineState(descriptor: rcasDesc)
            rcasDesc.colorAttachments[0].pixelFormat = .rgba16Float
            self.rcasPipelineState16 = try device.makeRenderPipelineState(descriptor: rcasDesc)

        } catch {
            return nil
        }
    }

    // MARK: - Texture Creation

    /// Create a GPU-private texture from a CGImage.
    /// Uses CIContext to render into a Metal texture, correctly handling all
    /// source pixel formats, color spaces, and bit depths.
    /// Auto-crops fully transparent margins from the source so PNG / HEIC /
    /// JXL / WebP images with empty alpha borders display at their visible
    /// extents rather than at the raw image extents.
    /// Pass `autoCropTransparentEdges: false` for images where transparent
    /// borders are load-bearing — notably the diorama foreground, which
    /// holds the masked subject inside a full-source-frame canvas; cropping
    /// shifts and shrinks the subject so it no longer registers with the
    /// backdrop layer at the same window aspect.
    /// - Parameter forceStandardColorDepth: When true, render to an 8-bit
    ///   `bgra8Unorm` texture even if the source is deep-color. The memory-safety
    ///   guard sets this for oversized sources (when Dynamic Image Resolution is
    ///   on) to halve the GPU texture + render buffer for 16-bit JXL. It does not
    ///   reduce the upstream decode transient — ImageIO decodes at source depth —
    ///   but it bounds everything downstream of the decoded CGImage.
    func createTexture(from cgImage: CGImage, useLossyCompression: Bool = false, autoCropTransparentEdges: Bool = true, forceStandardColorDepth: Bool = false) -> MTLTexture? {
        let cgImage = autoCropTransparentEdges ? TransparentEdgeCropper.crop(cgImage) : cgImage
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // An HDR decode keeps its highlights, brought within the display's
        // headroom; the memory-safety guard's 8-bit texture can't hold them.
        let hdr = forceStandardColorDepth ? nil : HDRStills.toneMapped(cgImage)
        let isDeepColor = hdr != nil || (!forceStandardColorDepth && cgImage.bitsPerComponent > 8)
        let pixelFormat: MTLPixelFormat = isDeepColor ? .rgba16Float : .bgra8Unorm

        // Create a writable staging texture for CIContext to render into.
        // CIContext.render requires .shaderWrite, which is incompatible with
        // lossy compression, so we always render to an uncompressed texture first.
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        stagingDesc.usage = [.shaderRead, .shaderWrite]
        stagingDesc.storageMode = .private

        guard let stagingTexture = device.makeTexture(descriptor: stagingDesc),
              let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }

        // CIImage origin is bottom-left; Metal textures expect top-left.
        // Flip vertically so the rendered image isn't upside down.
        let ciImage = (hdr?.image ?? CIImage(cgImage: cgImage))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height)))

        // Render the CIImage directly into the private Metal texture.
        // CIContext handles all color space conversion and pixel format normalization.
        let colorSpace = isDeepColor
            ? (CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB())
            : CGColorSpaceCreateDeviceRGB()

        ciContext.render(
            ciImage,
            to: stagingTexture,
            commandBuffer: cmdBuf,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )

        // Explicit lossy texture compression requires newer Apple GPU
        // families and is only supported for standard 8-bit color formats.
        // Setting compressionType on older devices (for example the A13 in
        // iPad 9) aborts inside Metal's descriptor validation instead of
        // returning nil, so keep those devices on the ordinary private-texture
        // path even when the preference is enabled.
        if useLossyCompression,
           pixelFormat == .bgra8Unorm,
           device.supportsFamily(.apple7) {
            // Blit-copy from the uncompressed staging texture into a lossy-compressed
            // read-only texture. The staging texture is released after the copy completes.
            let lossyDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            lossyDesc.usage = [.shaderRead]
            lossyDesc.storageMode = .private
            lossyDesc.compressionType = .lossy

            guard let lossyTexture = device.makeTexture(descriptor: lossyDesc),
                  let blit = cmdBuf.makeBlitCommandEncoder() else {
                // Fall back to returning the uncompressed staging texture
                cmdBuf.commit()
                cmdBuf.waitUntilCompleted()
                return stagingTexture
            }

            blit.copy(
                from: stagingTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: lossyTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            return lossyTexture
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        if let hdr { Self.setHeadroom(hdr.headroom, of: stagingTexture) }
        return stagingTexture
    }

    /// Create a GPU-private texture from a UIImage.
    func createTexture(from uiImage: UIImage, useLossyCompression: Bool = false, autoCropTransparentEdges: Bool = true) -> MTLTexture? {
        guard let cgImage = uiImage.cgImage else { return nil }
        return createTexture(from: cgImage, useLossyCompression: useLossyCompression, autoCropTransparentEdges: autoCropTransparentEdges)
    }

    /// Downsample image data using the same CGImageSource logic as the URL path.
    /// Used by slideshow content providers which already hold the raw bytes from
    /// the network (and need to keep them around for GIF / file-type detection).
    /// - Parameters:
    ///   - data: Encoded image bytes.
    ///   - maxDimension: Maximum dimension for downsampling. 0 = no limit (full decode).
    /// - Returns: Decoded UIImage, or nil on failure.
    static func downsampledImage(from data: Data, maxDimension: CGFloat) -> UIImage? {
        decodeGate.wait()
        defer { decodeGate.signal() }
        return autoreleasepool {
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }

            // See createTexture(from url:) — only the thumbnail branch applies
            // EXIF orientation for itself.
            var orientationAlreadyApplied = false

            let cgImage: CGImage?
            if maxDimension <= 0 {
                let fullOptions: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: true
                ]
                cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, HDRStills.decodeOptions(fullOptions) as CFDictionary)
            } else {
                let nativeMaxDim: CGFloat
                if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                   let pw = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                   let ph = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
                    nativeMaxDim = max(CGFloat(pw), CGFloat(ph))
                } else {
                    nativeMaxDim = 0
                }

                if nativeMaxDim > 0 && maxDimension >= nativeMaxDim {
                    let fullOptions: [CFString: Any] = [
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, HDRStills.decodeOptions(fullOptions) as CFDictionary)
                } else {
                    let thumbOptions: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, HDRStills.decodeOptions(thumbOptions) as CFDictionary)
                    orientationAlreadyApplied = true
                }
            }

            guard let cgImage else { return nil }
            let oriented = orientationAlreadyApplied
                ? cgImage
                : applyingOrientation(to: cgImage, from: imageSource)
            return UIImage(cgImage: oriented)
        }
    }

    /// Downsample an image from a URL and upload directly to a GPU-private texture.
    /// Uses CGImageSource for memory-efficient decoding without loading the full image.
    /// When `forceFullDecode` is true or `maxDimension` >= native size, uses
    /// `CGImageSourceCreateImageAtIndex` for full-quality decode (avoids quality loss
    /// with certain codecs like JXL and prevents thumbnail API interpolation artifacts).
    func createTexture(from url: URL, maxDimension: CGFloat, useLossyCompression: Bool = false, forceFullDecode: Bool = false, autoCropTransparentEdges: Bool = true) -> MTLTexture? {
        Self.decodeGate.wait()
        defer { Self.decodeGate.signal() }
        return autoreleasepool {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return nil
            }

            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }

            // Set by the decode branch that applies the orientation itself.
            var orientationAlreadyApplied = false

            let cgImage: CGImage?
            // Set when the memory-safety guard fires (oversized source, Dynamic
            // Image Resolution on) so the downstream texture is forced to 8-bit.
            var reduceDepth = false
            if forceFullDecode {
                // Caller explicitly requested full-quality decode (effectiveMaxResolution == 0).
                // This is the user's manual override — Dynamic Image Resolution is off, so
                // they want the real image with no optimizations. The oversized guard below
                // is intentionally NOT applied here.
                let fullOptions: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: true
                ]
                cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, HDRStills.decodeOptions(fullOptions) as CFDictionary)
            } else {
                // Read native dimensions and bit depth to decide decode path.
                // Use NSNumber bridge for robust conversion — CGImageSource properties
                // may store pixel dimensions as integer CFNumber types.
                let nativeMaxDim: CGFloat
                let predictedBytes: Int
                if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                   let pw = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                   let ph = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
                    nativeMaxDim = max(CGFloat(pw), CGFloat(ph))
                    var depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
                    // An 8-bit HEIC with a gain map decodes to a deep HDR bitmap.
                    if HDRStills.hasGainMap(imageSource) { depth = max(depth, 16) }
                    predictedBytes = Self.predictedDecodeBytes(width: Int(pw), height: Int(ph), bitsPerComponent: depth)
                } else {
                    nativeMaxDim = 0
                    predictedBytes = 0
                }

                // Memory-safety guard: a source whose full decode would exceed the
                // threshold (e.g. a 90+ MP JXL ImageIO can't stream) must never take
                // the uncapped CGImageSourceCreateImageAtIndex branch, even when the
                // requested maxDimension meets/exceeds native — that would allocate the
                // whole bitmap and can trip jetsam. Force the thumbnail path and drop
                // to 8-bit downstream. See .claude/research/jxl-decode-memory-oom.md.
                let oversized = predictedBytes > Self.oversizedDecodeByteThreshold

                if !oversized && nativeMaxDim > 0 && maxDimension >= nativeMaxDim {
                    // Full-resolution decode — avoids thumbnail path quality loss
                    let fullOptions: [CFString: Any] = [
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, HDRStills.decodeOptions(fullOptions) as CFDictionary)
                } else {
                    // Downsampled decode via thumbnail API. For oversized sources cap the
                    // thumbnail to maxDimension (or native if maxDimension is unset) so we
                    // never request a larger-than-needed raster.
                    reduceDepth = oversized
                    let cap = maxDimension > 0 ? maxDimension : nativeMaxDim
                    let thumbOptions: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: cap,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, HDRStills.decodeOptions(thumbOptions) as CFDictionary)
                    orientationAlreadyApplied = true
                }
            }

            guard let cgImage else { return nil }

            // Only the thumbnail branch applies EXIF orientation, via
            // kCGImageSourceCreateThumbnailWithTransform. Both full-decode
            // branches use CGImageSourceCreateImageAtIndex, which returns the
            // stored pixels untransformed — so a rotated HEIC decoded sideways,
            // and *changed* rotation whenever a resize crossed the downsample
            // threshold, because that switches which branch runs.
            let oriented = orientationAlreadyApplied
                ? cgImage
                : Self.applyingOrientation(to: cgImage, from: imageSource)

            return createTexture(from: oriented, useLossyCompression: useLossyCompression, autoCropTransparentEdges: autoCropTransparentEdges, forceStandardColorDepth: reduceDepth)
        }
    }

    // MARK: - EXIF orientation

    /// Applies the source's stored EXIF orientation to an untransformed decode.
    ///
    /// `CGImageSourceCreateImageAtIndex` hands back pixels exactly as stored and
    /// ignores `kCGImagePropertyOrientation`. Cameras record a rotation flag
    /// rather than rotating pixels, so anything shot in portrait decodes
    /// sideways. Returns the image unchanged when there is nothing to do, which
    /// is the common case.
    static func applyingOrientation(to cgImage: CGImage, from source: CGImageSource) -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
              let orientation = CGImagePropertyOrientation(rawValue: raw),
              orientation != .up else {
            return cgImage
        }

        // Routed through CIImage.oriented so the rotate/flip matrix is not
        // hand-rolled per case. A context local to this call, because the shared
        // CIContext serves the render path and is not free for a synchronous
        // decode here.
        let ci = CIImage(cgImage: cgImage).oriented(orientation)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let rendered = context.createCGImage(ci, from: ci.extent) else {
            return cgImage
        }
        return rendered
    }
}
