/*
 Hypnos - Background Remover

 Uses the Vision framework's VNGenerateForegroundInstanceMaskRequest
 to detect foreground subjects and CoreImage to composite the result
 with a transparent background.
 */

import CoreImage
import CoreImage.CIFilterBuiltins
import DebugTrace
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO
import Vision

actor BackgroundRemover {
    static let shared = BackgroundRemover()

    /// Cap on the long edge (in pixels) of the image fed into Vision.
    /// Vision's segmentation model resamples internally to ~512–1024px regardless of input,
    /// so feeding a 33MP source just multiplies pre/post-processing and composite cost
    /// without improving silhouette quality. 2560 keeps mask edges crisp at panel-resolution
    /// viewing while cutting work ~10-16x on 8K sources.
    private static let maxLongEdgeForSegmentation: CGFloat = 2560

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Color decontamination kernel. At each silhouette-band pixel (where
    /// alpha is in (0,1)), inverts the matte equation observed = α·F + (1-α)·B
    /// to recover the contaminant-free foreground color. Without this, soft-
    /// alpha pixels carry the original background color (e.g. white halo
    /// around black ink lines on a white page) and render incorrectly when
    /// composited onto a new backdrop. CIColorKernel runs per-pixel with no
    /// neighbor sampling — the background estimate is supplied as a
    /// precomputed heavy blur of the source.
    ///
    /// FIXME: the CI-Kernel-Language `init(source:)` is deprecated in favor
    /// of Metal-based CIKernels. Migrating requires adding a `.ci.metal`
    /// file with custom build settings, which this project hasn't set up.
    /// Functional on visionOS; revisit if Apple removes the GL path.
    private static let decontaminationKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 decontaminate(__sample input, __sample mask, __sample bg) {
            float a = mask.r;
            if (a < 0.001) {
                return vec4(0.0, 0.0, 0.0, 0.0);
            }
            if (a > 0.999) {
                return vec4(input.rgb, 1.0);
            }
            vec3 clean = (input.rgb - (1.0 - a) * bg.rgb) / a;
            return vec4(clamp(clean, 0.0, 1.0), a);
        }
    """)

    private init() {}

    /// Remove the background from a UIImage and return the foreground at the
    /// source's original frame size (no transparent-margin cropping). Used by
    /// diorama mode where the foreground must align with the unmodified
    /// backdrop via z-offset layering.
    func removeBackgroundUncropped(from image: UIImage) async throws -> UIImage? {
        try await generateDioramaPair(from: image).foreground
    }

    /// Generate the foreground + a subject-removed backdrop in a single Vision
    /// pass. The backdrop replaces the subject region with a heavily blurred
    /// version of the original so the diorama overlay doesn't show a doubled
    /// silhouette behind the floating foreground when viewed off-axis. The
    /// non-subject regions stay sharp at full resolution.
    func generateDioramaPair(from image: UIImage) async throws -> (foreground: UIImage?, backdrop: UIImage?) {
        guard let sourceCG = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for diorama pair")
            return (nil, nil)
        }

        // Sticker-style sources (PNGs with a fully-transparent background)
        // have no real backdrop to recover. The iterative blur-and-fill would
        // diffuse transparency into the subject hole, producing a corrupted
        // halo on black; the foreground would also visually duplicate the
        // already-cut-out subject. Skip diorama for these — callers fall
        // back to the plain image display.
        if Self.hasSignificantTransparency(sourceCG) {
            AppLogger.backgroundRemover.debug("Skipping diorama: source has transparent background")
            return (nil, nil)
        }

        let cgImage = Self.downsampleIfNeeded(sourceCG)
        let (maskCIImage, originalCIImage) = try generateForegroundMask(cgImage: cgImage)
        let extent = originalCIImage.extent

        // Match output bit depth + color space to the source so deep-color
        // sources (16-bit JXL upscales, etc.) stay deep through the
        // diorama pipeline. The downstream MTLTexture pipeline picks
        // rgba16Float automatically for these, so the foreground and
        // backdrop layers preserve the same color fidelity as the base.
        let isDeepSource = cgImage.bitsPerComponent > 8
        let outputFormat: CIFormat = isDeepSource ? .RGBA16 : .RGBA8
        let outputColorSpace: CGColorSpace = isDeepSource
            ? (CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB())
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())

        // Foreground with color decontamination via subject color extension.
        //
        // Silhouette pixels carry the contamination `α·F + (1-α)·B` from the
        // original background — for a black ink line on a white page,
        // α=0.3 gives an observed pixel that's mostly white-tinted gray, so
        // when composited against a non-white backdrop a white halo bleeds
        // through. Pixelmator's "decontaminate colors" inverts the matte
        // equation analytically; CIMaskedVariableBlur is a built-in filter
        // that approximates the same effect by smearing nearby subject
        // colors *outward* into the silhouette band, replacing the
        // contaminated colors with extrapolated subject colors.
        //
        // Variable-blur reads its mask as a per-pixel blur radius driver
        // (lighter mask = more blur). We pass the inverted alpha mask, so:
        //   - Subject interior (α=1, inverted=0) → no blur, stays sharp
        //   - Silhouette band (α=0.5, inverted=0.5) → moderate blur, smears
        //     adjacent subject colors over the contaminated band
        //   - Background (α=0, inverted=1) → max blur (irrelevant, will be
        //     masked out by the subsequent blendWithMask)
        let foregroundImage: UIImage? = {
            let invertFilter = CIFilter.colorInvert()
            invertFilter.inputImage = maskCIImage
            let invertedMask = invertFilter.outputImage?.cropped(to: extent) ?? maskCIImage

            let varBlur = CIFilter.maskedVariableBlur()
            varBlur.inputImage = originalCIImage
            varBlur.mask = invertedMask
            varBlur.radius = 10
            let extendedForeground = varBlur.outputImage?.cropped(to: extent) ?? originalCIImage

            let blendFilter = CIFilter.blendWithMask()
            blendFilter.inputImage = extendedForeground
            blendFilter.backgroundImage = CIImage.empty()
            blendFilter.maskImage = maskCIImage

            guard let outputCIImage = blendFilter.outputImage else { return nil }
            guard let outputCGImage = ciContext.createCGImage(
                outputCIImage,
                from: extent,
                format: outputFormat,
                colorSpace: outputColorSpace
            ) else {
                AppLogger.backgroundRemover.warning("Failed to render diorama foreground CGImage")
                return nil
            }
            AppLogger.backgroundRemover.debug("Generated diorama foreground: \(outputCGImage.width, privacy: .public)×\(outputCGImage.height, privacy: .public), alphaInfo=\(String(describing: outputCGImage.alphaInfo), privacy: .public)"
            )
            return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
        }()

        // Backdrop: iterative blur-and-replace fill. Each pass blurs the
        // whole image then pastes the known background back on top, so
        // background colors progressively diffuse inward into the subject
        // hole without bright-halo artifacts (unlike morphological max
        // which picks the brightest neighbor and bleeds subject colors).
        //
        // Passes × blur radius controls fill depth. 20 passes × 4px ≈
        // 80px of inward fill, enough for most subjects at 2560px.

        let dilateRadius: Float = 15
        let fillBlurRadius: Float = 4
        let fillPasses = 20

        // Dilated mask marking the fill zone.
        let backdropDilate = CIFilter.morphologyMaximum()
        backdropDilate.inputImage = maskCIImage
        backdropDilate.radius = dilateRadius
        let dilatedMask = backdropDilate.outputImage?.cropped(to: extent) ?? maskCIImage

        // Seed: replace subject region with a heavy initial blur so the
        // iterative fill has something to diffuse from (avoids the sharp
        // subject being visible through early blur passes).
        let seedBlurRadius = max(20.0, Double(max(extent.width, extent.height)) * 0.02)
        let seedBlurFilter = CIFilter.gaussianBlur()
        seedBlurFilter.inputImage = originalCIImage.clampedToExtent()
        seedBlurFilter.radius = Float(seedBlurRadius)
        let seedBlur = seedBlurFilter.outputImage?.cropped(to: extent) ?? originalCIImage

        let seedBlend = CIFilter.blendWithMask()
        seedBlend.inputImage = seedBlur
        seedBlend.backgroundImage = originalCIImage
        seedBlend.maskImage = dilatedMask
        var filled = seedBlend.outputImage?.cropped(to: extent) ?? originalCIImage

        for _ in 0..<fillPasses {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = filled.clampedToExtent()
            blur.radius = fillBlurRadius
            let blurred = blur.outputImage?.cropped(to: extent) ?? filled

            let blend = CIFilter.blendWithMask()
            blend.inputImage = blurred
            blend.backgroundImage = originalCIImage
            blend.maskImage = dilatedMask
            filled = blend.outputImage?.cropped(to: extent) ?? filled
        }

        // Feather the mask boundary for a gradual sharp→filled transition.
        let featherRadius = max(8.0, Double(dilateRadius) * 0.8)
        let featherBlur = CIFilter.gaussianBlur()
        featherBlur.inputImage = dilatedMask.clampedToExtent()
        featherBlur.radius = Float(featherRadius)
        let featheredMask = featherBlur.outputImage?.cropped(to: extent) ?? dilatedMask

        let bgFilter = CIFilter.blendWithMask()
        bgFilter.inputImage = filled
        bgFilter.backgroundImage = originalCIImage
        bgFilter.maskImage = featheredMask

        let backdropImage: UIImage? = {
            guard let outputCIImage = bgFilter.outputImage,
                  let outputCGImage = ciContext.createCGImage(
                    outputCIImage,
                    from: extent,
                    format: outputFormat,
                    colorSpace: outputColorSpace
                  ) else {
                return nil
            }
            return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
        }()

        return (foregroundImage, backdropImage)
    }

    /// Remove the background from a UIImage. Keeps the subject at the source
    /// frame size — transparent margins are NOT trimmed. Tight alpha-bounds
    /// cropping shifts the subject's position and aspect ratio when the
    /// source has asymmetric padding around the subject, which surfaces as
    /// the viewer "jumping" on toggle. The downstream display already
    /// letterboxes transparent areas correctly.
    func removeBackground(from image: UIImage) async throws -> UIImage? {
        guard let sourceCG = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for background removal")
            return nil
        }

        let cgImage = Self.downsampleIfNeeded(sourceCG)
        let (maskCIImage, originalCIImage) = try generateForegroundMask(cgImage: cgImage)

        if let decontaminated = decontaminatedRGBA(input: originalCIImage, mask: maskCIImage) {
            return render(decontaminated, extent: originalCIImage.extent, scale: image.scale, orientation: image.imageOrientation)
        }
        return applyMask(
            inputImage: originalCIImage,
            maskImage: maskCIImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }

    /// Remove background and produce both regular and auto-enhanced variants.
    /// The foreground mask is generated once from the original image for stable edge
    /// detection. Auto-enhancement is applied to the full original (preserving context
    /// for correct exposure analysis), then the same mask is composited over it.
    /// Returns (regular, autoEnhanced) — either may be nil on failure.
    func removeBackgroundWithAutoEnhance(from image: UIImage) async throws -> (regular: UIImage?, autoEnhanced: UIImage?) {
        guard let sourceCG = image.cgImage else {
            AppLogger.backgroundRemover.warning("No CGImage available for background removal")
            return (nil, nil)
        }

        let cgImage = Self.downsampleIfNeeded(sourceCG)
        let (maskCIImage, originalCIImage) = try generateForegroundMask(cgImage: cgImage)
        let extent = originalCIImage.extent

        // 1. Regular variant — decontaminated + mask alpha baked in.
        let regularResult: UIImage? = {
            if let decontaminated = decontaminatedRGBA(input: originalCIImage, mask: maskCIImage) {
                return render(decontaminated, extent: extent, scale: image.scale, orientation: image.imageOrientation)
            }
            return applyMask(
                inputImage: originalCIImage,
                maskImage: maskCIImage,
                scale: image.scale,
                orientation: image.imageOrientation
            )
        }()

        // 2. Auto-enhance the original CIImage (full-image context for correct analysis)
        let autoFilters = originalCIImage.autoAdjustmentFilters(options: [
            .enhance: true,
            .redEye: false
        ])
        var enhancedCI = originalCIImage
        for filter in autoFilters {
            filter.setValue(enhancedCI, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                enhancedCI = output
            }
        }

        // 3. Enhanced variant — decontaminate using post-enhance colors so the
        // bg estimate matches the pixels we're un-mixing against.
        let enhancedResult: UIImage? = {
            if let decontaminated = decontaminatedRGBA(input: enhancedCI, mask: maskCIImage) {
                return render(decontaminated, extent: extent, scale: image.scale, orientation: image.imageOrientation)
            }
            return applyMask(
                inputImage: enhancedCI,
                maskImage: maskCIImage,
                scale: image.scale,
                orientation: image.imageOrientation
            )
        }()

        return (regularResult, enhancedResult)
    }

    /// Render a CIImage that already carries final alpha (from the
    /// decontamination kernel) to a CGImage at the source frame size.
    /// Transparent margins are intentionally preserved so the subject keeps
    /// its position relative to the original image.
    private func render(_ image: CIImage, extent: CGRect, scale: CGFloat, orientation: UIImage.Orientation) -> UIImage? {
        guard let outputCGImage = ciContext.createCGImage(image, from: extent) else { return nil }
        return UIImage(cgImage: outputCGImage, scale: scale, orientation: orientation)
    }

    /// Apply color decontamination to `input` using `mask`. Computes a heavy
    /// gaussian blur of `input` as the bg estimate and runs the kernel.
    /// Returns nil if the kernel isn't available or extent is empty.
    private func decontaminatedRGBA(input: CIImage, mask: CIImage) -> CIImage? {
        let extent = input.extent
        guard extent.width > 0, extent.height > 0,
              let kernel = Self.decontaminationKernel else { return nil }

        let blurRadius = max(20.0, Double(max(extent.width, extent.height)) * 0.025)
        let clamped = input.clampedToExtent()
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = clamped
        blurFilter.radius = Float(blurRadius)
        let bgEstimate = blurFilter.outputImage?.cropped(to: extent) ?? input

        return kernel.apply(extent: extent, arguments: [input, mask, bgEstimate])
    }

    /// Generate the foreground mask from a CGImage using Vision.
    /// Returns the mask CIImage and the original CIImage.
    private func generateForegroundMask(cgImage: CGImage) throws -> (mask: CIImage, original: CIImage) {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        try handler.perform([request])

        guard let result = request.results?.first else {
            AppLogger.backgroundRemover.warning("No foreground mask results")
            throw BackgroundRemovalError.noMaskResults
        }

        let maskPixelBuffer = try result.generateScaledMaskForImage(
            forInstances: result.allInstances,
            from: handler
        )

        let rawMask = CIImage(cvPixelBuffer: maskPixelBuffer)
        return (refineMask(rawMask), CIImage(cgImage: cgImage))
    }

    /// Clean up Vision's soft probabilistic mask before compositing.
    ///
    /// Pipeline:
    ///  1. Morphological closing fills small holes left by Vision's
    ///     probabilistic interior output.
    ///  2. **Linear firming** via `CIColorMatrix` with scale=5, offset=-1.
    ///     Maps Vision's mask values: ≤0.2 → 0 (clean background), ≥0.4 →
    ///     1 (subject interior fully opaque), 0.2-0.4 → linear ramp for
    ///     silhouette anti-aliasing and thin features. Built-in CIFilter
    ///     so always available — replaces the prior CIColorKernel-based
    ///     smoothstep which could fail silently when the deprecated
    ///     CI-Kernel-Language compiler returned nil and leave the mask too
    ///     soft for the diorama foreground to composite opaquely.
    ///  3. **Flood-fill enclosed holes** — anything not reachable from the
    ///     image boundary via background pixels gets forced to opaque,
    ///     fixing large interior cavities morphology can't close.
    private func refineMask(_ mask: CIImage) -> CIImage {
        let extent = mask.extent

        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = mask
        dilate.radius = 10
        guard let dilated = dilate.outputImage else { return mask }

        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = dilated
        erode.radius = 10
        guard let closed = erode.outputImage?.cropped(to: extent) else { return mask }

        // Linear firming via color matrix: out = in * 5 - 1, then clamped.
        let firming = CIFilter.colorMatrix()
        firming.inputImage = closed
        firming.rVector = CIVector(x: 5, y: 0, z: 0, w: 0)
        firming.gVector = CIVector(x: 0, y: 5, z: 0, w: 0)
        firming.bVector = CIVector(x: 0, y: 0, z: 5, w: 0)
        firming.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        firming.biasVector = CIVector(x: -1, y: -1, z: -1, w: 0)
        let firmed = firming.outputImage?.cropped(to: extent) ?? closed

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = firmed
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let clamped = clamp.outputImage?.cropped(to: extent) ?? firmed

        return fillEnclosedHoles(clamped) ?? clamped
    }

    /// Fill mask regions that aren't reachable from the image boundary via
    /// background pixels. CPU pass — converts the mask to an 8-bit grayscale
    /// buffer, flood-fills from the four edges marking everything reachable
    /// through pixels below threshold, then forces any unmarked sub-threshold
    /// pixel to opaque (interior hole). Preserves the silhouette band's soft
    /// alpha by only modifying pixels that were already binarized to
    /// background by the contrast step.
    ///
    /// Cost: O(width × height) once per image. ~3.7M pixels at 2560×1440.
    /// Stack-based iterative flood fill to avoid recursion depth issues.
    private func fillEnclosedHoles(_ mask: CIImage) -> CIImage? {
        let extent = mask.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // Render to a single-channel 8-bit buffer via CIContext. Going through
        // a CGContext + draw(CGImage) path doesn't work for this — the mask
        // CIImage from `cvPixelBuffer:` doesn't have an addressable CGImage
        // until rendered. CIContext.render writes directly to a bitmap.
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let graySpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            ciContext.render(
                mask,
                toBitmap: base,
                rowBytes: bytesPerRow,
                bounds: extent,
                format: .L8,
                colorSpace: graySpace
            )
        }

        // Background threshold matches the contrast step's effective cutoff.
        // After clamp, interior pixels are at 255 and background at 0; the
        // soft silhouette band is in between. We treat anything < 128 as
        // background-candidate for flood-fill purposes — silhouette pixels
        // above 128 are subject and won't be visited.
        let threshold: UInt8 = 128
        var visited = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        stack.reserveCapacity(max(width, height) * 2)

        // Seed with all four image edges.
        for x in 0..<width {
            if pixels[x] < threshold { stack.append(x) }
            let bottomIdx = (height - 1) * width + x
            if pixels[bottomIdx] < threshold { stack.append(bottomIdx) }
        }
        for y in 1..<(height - 1) {
            let leftIdx = y * width
            if pixels[leftIdx] < threshold { stack.append(leftIdx) }
            let rightIdx = leftIdx + width - 1
            if pixels[rightIdx] < threshold { stack.append(rightIdx) }
        }

        // 4-connectivity flood fill. Marks every background pixel reachable
        // from the boundary; anything left unmarked is by definition enclosed.
        while let idx = stack.popLast() {
            if visited[idx] { continue }
            visited[idx] = true
            let x = idx % width
            let y = idx / width
            if x > 0 {
                let n = idx - 1
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
            if x < width - 1 {
                let n = idx + 1
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
            if y > 0 {
                let n = idx - width
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
            if y < height - 1 {
                let n = idx + width
                if !visited[n] && pixels[n] < threshold { stack.append(n) }
            }
        }

        // Fill: any sub-threshold pixel not visited is an enclosed hole.
        // Set to fully opaque so blendWithMask treats it as subject.
        for i in 0..<pixels.count {
            if !visited[i] && pixels[i] < threshold {
                pixels[i] = 255
            }
        }

        // Reconstruct CIImage from the modified pixel buffer.
        guard let outCtx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let outCG = outCtx.makeImage() else {
            return nil
        }
        let filled = CIImage(cgImage: outCG)
        // Translate to match the original mask's extent origin (rare to be
        // non-zero, but mask buffers from Vision can be).
        return filled.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
    }

    enum BackgroundRemovalError: Error {
        case noMaskResults
    }

    /// Detect whether a CGImage has a meaningfully transparent background.
    /// Renders the image into a tiny 32×32 RGBA buffer and counts pixels
    /// with low alpha. Cheap (1024 samples) and correct regardless of how
    /// the source was decoded, since we re-render through CGContext.
    private static func hasSignificantTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var transparent = 0
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] < 250 {
            transparent += 1
        }
        // >5% transparent pixels in the downsampled view — treat as sticker.
        return transparent > (side * side) / 20
    }

    /// Downsample a CGImage so its long edge does not exceed `maxLongEdgeForSegmentation`.
    /// Returns the original image if it's already within the cap.
    /// Uses `CGContext` resampling for predictable quality and to avoid the ImageIO
    /// thumbnail path (which requires a CGImageSource and we only have a CGImage here).
    private static func downsampleIfNeeded(_ image: CGImage) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longEdge = max(w, h)
        guard longEdge > maxLongEdgeForSegmentation else { return image }

        let scale = maxLongEdgeForSegmentation / longEdge
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())

        return CGImageDeepColor.redraw(image, size: (newW, newH)) ?? image
    }

    /// Apply a foreground mask to an image at the source frame size.
    /// Transparent margins are preserved (see `render(_:extent:...)`).
    private func applyMask(
        inputImage: CIImage,
        maskImage: CIImage,
        scale: CGFloat,
        orientation: UIImage.Orientation
    ) -> UIImage? {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = inputImage
        filter.backgroundImage = CIImage.empty()
        filter.maskImage = maskImage

        guard let outputCIImage = filter.outputImage else {
            AppLogger.backgroundRemover.warning("CIFilter blendWithMask produced no output")
            return nil
        }

        guard let outputCGImage = ciContext.createCGImage(
            outputCIImage,
            from: inputImage.extent
        ) else {
            AppLogger.backgroundRemover.warning("Failed to render CIImage to CGImage")
            return nil
        }

        return UIImage(cgImage: outputCGImage, scale: scale, orientation: orientation)
    }
}
