/*
 Hypnos - AI HDR

 Gives an SDR photo a gain map, so it shows as HDR through the same path as
 a real one (`HDRStills`). The gain map comes from GMNet (Liao et al.,
 "Learning Gain Map for Inverse Tone Mapping", ICLR 2025, MIT), converted by
 `scripts/convert-gainmap-model.py` and bundled as `GainMapGMNet`.

 The model sees the photo at about a megapixel and returns the linear
 multiplier for each pixel (1 = SDR, up to 5x: the real-world checkpoint's
 peak); HDR linear = SDR linear x gain. The map is smooth, so it is made once
 per photo, cached, and stretched over whatever resolution the window decodes.
 The result is an extended linear P3 half-float image carrying its
 `contentHeadroom`, which `HDRStills` tone maps to the display like any HDR
 photo, flat and in AI 3D.

 Opt-in per window from Adjustments ("AI HDR"); the last choice is the
 default for the next window (`enabledKey`).
 */

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation
import Vision

final class GainMapHDR: @unchecked Sendable {
    static let shared = GainMapHDR()
    static let enabledKey = "aiHDRPhotos"

    /// The input sizes the model was converted with (w, h); keep in step with
    /// `SIZES` in scripts/convert-gainmap-model.py.
    private static let inputSizes: [(Int, Int)] = [(1024, 768), (768, 1024), (1024, 576), (576, 1024), (896, 896)]
    /// Below this the photo gains nothing worth an HDR texture.
    private static let minimumHeadroom: Float = 1.05

    private final class GainMap {
        let image: CIImage
        let headroom: Float
        init(image: CIImage, headroom: Float) {
            self.image = image
            self.headroom = headroom
        }
    }

    private let modelURL: URL?
    private let lock = NSLock()
    private var model: MLModel?
    private var modelFailed = false
    private let cache: NSCache<NSString, GainMap> = {
        let cache = NSCache<NSString, GainMap>()
        cache.countLimit = 24
        return cache
    }()

    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private lazy var context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])

    /// `modelURL` is a compiled model; the app's bundled one by default.
    init(modelURL: URL? = Bundle.main.url(forResource: "GainMapGMNet", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    struct Result {
        let image: CGImage
        let headroom: Float
        /// Time spent in the model; 0 when the gain map was cached.
        let inferenceMilliseconds: Double
    }

    /// `sdr` with its generated gain map applied, as extended linear P3 with
    /// `contentHeadroom` set. Nil for a photo that is HDR already, has
    /// transparency (the multiply would light up its clear areas), gains
    /// nothing, or when the model can't run. `key` names the photo for the
    /// cache; any resolution of the same photo shares one gain map.
    func hdrImage(from sdr: CGImage, key: String) -> Result? {
        guard sdr.contentHeadroom <= 1 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard isOpaque(sdr) else { return nil }
        var milliseconds = 0.0
        let gain: GainMap
        if let cached = cache.object(forKey: key as NSString) {
            gain = cached
        } else {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let made = makeGainMap(for: sdr) else { return nil }
            milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            cache.setObject(made, forKey: key as NSString)
            gain = made
        }
        guard gain.headroom >= Self.minimumHeadroom, let image = apply(gain, to: sdr) else { return nil }
        return Result(image: image, headroom: gain.headroom, inferenceMilliseconds: milliseconds)
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Model

    private func loadedModel() -> MLModel? {
        if let model { return model }
        guard !modelFailed, let modelURL else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
            model = loaded
            return loaded
        } catch {
            modelFailed = true
            return nil
        }
    }

    private func makeGainMap(for sdr: CGImage) -> GainMap? {
        guard let model = loadedModel() else { return nil }
        let aspect = Double(sdr.width) / Double(max(sdr.height, 1))
        let (width, height) = Self.inputSizes.min {
            abs(log(Double($0.0) / Double($0.1) / aspect)) < abs(log(Double($1.0) / Double($1.1) / aspect))
        }!
        // Squeezed to the input, as the paper's thumbnail is: the nearest
        // aspect is close, and the gain map is stretched back over the photo.
        let options: [MLFeatureValue.ImageOption: Any] = [
            .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue
        ]
        guard let image = try? MLFeatureValue(cgImage: sdr, pixelsWide: width, pixelsHigh: height,
                                              pixelFormatType: kCVPixelFormatType_32BGRA, options: options),
              let thumbnail = try? MLFeatureValue(cgImage: sdr, pixelsWide: 256, pixelsHigh: 256,
                                                  pixelFormatType: kCVPixelFormatType_32BGRA, options: options),
              let inputs = try? MLDictionaryFeatureProvider(dictionary: ["image": image, "thumbnail": thumbnail]),
              let output = try? model.prediction(from: inputs),
              let gain = output.featureValue(for: "gain")?.multiArrayValue,
              let headroom = output.featureValue(for: "headroom")?.multiArrayValue,
              let buffer = Self.pixelBuffer(fromHalfFloat: gain) else { return nil }
        let map = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        return GainMap(image: map, headroom: headroom[0].floatValue)
    }

    /// The model's 1 x 1 x H x W float16 output as a one-channel half-float
    /// pixel buffer, copied as raw bits (no Float16 type on Intel Macs).
    private static func pixelBuffer(fromHalfFloat array: MLMultiArray) -> CVPixelBuffer? {
        guard array.dataType == .float16, array.shape.count == 4 else { return nil }
        let height = array.shape[2].intValue, width = array.shape[3].intValue
        let rowStride = array.strides[2].intValue, columnStride = array.strides[3].intValue
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent16Half,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        array.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt16.self)
            for y in 0 ..< height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                if columnStride == 1 {
                    row.update(from: source.baseAddress!.advanced(by: y * rowStride), count: width)
                } else {
                    for x in 0 ..< width { row[x] = source[y * rowStride + x * columnStride] }
                }
            }
        }
        return buffer
    }

    // MARK: - Applying

    private func apply(_ gain: GainMap, to sdr: CGImage) -> CGImage? {
        let picture = CIImage(cgImage: sdr)
        let extent = picture.extent
        let map = gain.image
        // The gain is one channel; spread it over red, green and blue.
        let spread = CIFilter.colorMatrix()
        spread.inputImage = map.samplingLinear().clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / map.extent.width,
                                               y: extent.height / map.extent.height))
            .cropped(to: extent)
        spread.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        spread.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        spread.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        spread.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        spread.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = spread.outputImage
        multiply.backgroundImage = picture
        guard let result = multiply.outputImage,
              let baked = context.createCGImage(result, from: extent, format: .RGBAh, colorSpace: linear) else { return nil }
        return CGImageCreateCopyWithContentHeadroom(gain.headroom, baked)
    }

    /// ImageIO hands most opaque photos over with an alpha channel (a HEIC
    /// decodes premultiplied), so an image that has one is measured: its
    /// smallest alpha, in one pass on the GPU.
    private func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: break
        }
        let picture = CIImage(cgImage: image)
        let minimum = CIFilter.areaMinimum()
        minimum.inputImage = picture
        minimum.extent = picture.extent
        guard let output = minimum.outputImage else { return false }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return pixel[3] >= 0.999
    }
}
