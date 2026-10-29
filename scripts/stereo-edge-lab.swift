import CoreGraphics
// Offline diagnostic only. Replays the production mesh shader using a display
// depth PNG; its normalized 8-bit values cannot reproduce raw shot-space depth.
// Usage: swiftc -O scripts/stereo-edge-lab.swift -o /tmp/stereo-edge-lab
// /tmp/stereo-edge-lab CAPTURE_DIR NEW_OUTPUT_DIR [StereoShaders.metal]
import Foundation
import ImageIO
import Metal
import MetalKit

struct Uniforms {
  var brightness: Float = 0, contrast: Float = 1, saturation: Float = 1
  var depthStrength: Float = 0.008, convergence: Float = 1, eyeSign: Float = 1
  var mirror: Float = 0, useDepth: Float = 1
  var uvScale = SIMD2<Float>(1, 1), uvOffset = SIMD2<Float>(0, 0)
  var valueScale: Float = 1, valueBias: Float = 0
  var budget = SIMD2<Float>(0, 1)
  var edgeFill: Float = 0, extendedRange: Float = 0
}
func require<T>(_ x: T?) throws -> T {
  guard let x else { throw NSError(domain: "Lab", code: 1) }
  return x
}
let args = CommandLine.arguments
guard (3...4).contains(args.count) else {
  FileHandle.standardError.write(
    Data("Usage: stereo-edge-lab CAPTURE_DIR NEW_OUTPUT_DIR [StereoShaders.metal]\n".utf8))
  exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
guard !FileManager.default.fileExists(atPath: output.path) else {
  FileHandle.standardError.write(
    Data("Output directory exists; preserve it and choose a new path.\n".utf8))
  exit(2)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let device = try require(MTLCreateSystemDefaultDevice())
let queue = try require(device.makeCommandQueue())
let defaultShader = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("vergence/Sources/VergenceApple/Stereo/StereoShaders.metal").path
let shaderPath = args.count == 4 ? args[3] : defaultShader
let shader = try String(contentsOfFile: shaderPath, encoding: .utf8)
let loader = MTKTextureLoader(device: device)
let source = try loader.newTexture(
  URL: input.appendingPathComponent("source.png"),
  options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
let depthImage = try require(
  CGImageSourceCreateImageAtIndex(
    try require(
      CGImageSourceCreateWithURL(input.appendingPathComponent("depth.png") as CFURL, nil)), 0, nil))
let dw = depthImage.width
let dh = depthImage.height
var gray = [UInt8](repeating: 0, count: dw * dh)
let graySpace = try require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
gray.withUnsafeMutableBytes { bytes in
  let c = CGContext(
    data: bytes.baseAddress, width: dw, height: dh, bitsPerComponent: 8, bytesPerRow: dw,
    space: graySpace, bitmapInfo: 0)!
  c.draw(depthImage, in: CGRect(x: 0, y: 0, width: dw, height: dh))
}
// This is a normalized display PNG, not raw floating-point depth. Invert its
// display gamma; range/shot mapping are intentionally approximate.
let depthValues = gray.map { pow(Float($0) / 255, 2.2) }
func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ samples: Int = 1) throws -> MTLTexture
{
  let d = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: format, width: w, height: h, mipmapped: false)
  d.usage = [.shaderRead, .renderTarget]
  d.storageMode = samples > 1 ? .private : .shared
  if samples > 1 {
    d.textureType = .type2DMultisample
    d.sampleCount = samples
  }
  return try require(device.makeTexture(descriptor: d))
}
let depth = try texture(.r32Float, dw, dh)
depth.replace(
  region: MTLRegionMake2D(0, 0, dw, dh), mipmapLevel: 0, withBytes: depthValues, bytesPerRow: dw * 4
)
func save(_ pixels: [UInt8], _ w: Int, _ h: Int, _ name: String) throws {
  let data = Data(pixels)
  let image = try require(
    CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: try require(CGDataProvider(data: data as CFData)), decode: nil,
      shouldInterpolate: false, intent: .defaultIntent))
  let dest = try require(
    CGImageDestinationCreateWithURL(
      output.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "PNG", code: 1) }
}
struct Variant {
  let name: String
  let nx: Int
  let ny: Int
  let samples: Int
  let sampleShading: Bool
  let scale: Int
}
let variants = [
  Variant(name: "grid193-msaa4", nx: 193, ny: 109, samples: 4, sampleShading: false, scale: 1),
  Variant(name: "baseline", nx: 769, ny: 433, samples: 4, sampleShading: false, scale: 1),
  Variant(name: "no-msaa", nx: 769, ny: 433, samples: 1, sampleShading: false, scale: 1),
  Variant(name: "msaa8", nx: 769, ny: 433, samples: 8, sampleShading: false, scale: 1),
  Variant(name: "sample-shading4", nx: 769, ny: 433, samples: 4, sampleShading: true, scale: 1),
  Variant(name: "sample-shading8", nx: 769, ny: 433, samples: 8, sampleShading: true, scale: 1),
  Variant(name: "grid1537", nx: 1537, ny: 865, samples: 4, sampleShading: false, scale: 1),
  Variant(name: "supersample2", nx: 769, ny: 433, samples: 4, sampleShading: false, scale: 2),
  Variant(name: "supersample4", nx: 769, ny: 433, samples: 4, sampleShading: false, scale: 4),
  Variant(name: "footprint4", nx: 769, ny: 433, samples: 4, sampleShading: false, scale: 1),
]
// Shader-time numbers are exploratory host measurements, not AVP budgets.
var report: [[String: Any]] = []
for v in variants where device.supportsTextureSampleCount(v.samples) {
  var code = shader
  if v.sampleShading {
    code = code.replacingOccurrences(
      of: "float2 texCoord;\n    // Screen distance",
      with: "float2 texCoord [[sample_perspective]];\n    // Screen distance")
    code = code.replacingOccurrences(
      of: "fragment float4 videoStereoMeshFragment(\n    MeshVertexOut in [[stage_in]],",
      with:
        "fragment float4 videoStereoMeshFragment(\n    MeshVertexOut in [[stage_in]], uint sampleID [[sample_id]],"
    )
  }
  if v.name == "footprint4" {
    code = code.replacingOccurrences(
      of: "float4 color = tex.sample(texSampler, tc);",
      with:
        "float2 dx = dfdx(tc) * 0.25, dy = dfdy(tc) * 0.25; float4 color = (tex.sample(texSampler,tc-dx-dy)+tex.sample(texSampler,tc+dx-dy)+tex.sample(texSampler,tc-dx+dy)+tex.sample(texSampler,tc+dx+dy))*0.25;"
    )
  }
  let library = try device.makeLibrary(source: code, options: nil)
  let d = MTLRenderPipelineDescriptor()
  d.vertexFunction = library.makeFunction(name: "videoStereoMeshVertex")
  d.fragmentFunction = library.makeFunction(name: "videoStereoMeshFragment")
  d.colorAttachments[0].pixelFormat = .rgba8Unorm
  d.depthAttachmentPixelFormat = .depth32Float
  d.rasterSampleCount = v.samples
  let pipeline = try device.makeRenderPipelineState(descriptor: d)
  let zd = MTLDepthStencilDescriptor()
  zd.depthCompareFunction = .lessEqual
  zd.isDepthWriteEnabled = true
  let state = try require(device.makeDepthStencilState(descriptor: zd))
  var vertices: [SIMD2<Float>] = []
  var indices: [UInt32] = []
  for y in 0..<v.ny {
    for x in 0..<v.nx {
      vertices.append(SIMD2(Float(x) / Float(v.nx - 1), Float(y) / Float(v.ny - 1)))
    }
  }
  for y in 0..<(v.ny - 1) {
    for x in 0..<(v.nx - 1) {
      let a = UInt32(y * v.nx + x)
      let r = UInt32(v.nx)
      indices += [a, a + r, a + 1, a + 1, a + r, a + r + 1]
    }
  }
  let vb = try require(device.makeBuffer(bytes: vertices, length: vertices.count * 8))
  let ib = try require(device.makeBuffer(bytes: indices, length: indices.count * 4))
  let w = source.width * v.scale
  let h = source.height * v.scale
  let dest = try texture(.rgba8Unorm, w, h)
  let z = try texture(.depth32Float, w, h, v.samples)
  let color = v.samples > 1 ? try texture(.rgba8Unorm, w, h, v.samples) : dest
  var times: [Double] = []
  for eye: Float in [1, -1] {
    for iteration in 0..<4 {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = color
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
      pass.colorAttachments[0].storeAction = v.samples > 1 ? .multisampleResolve : .store
      if v.samples > 1 { pass.colorAttachments[0].resolveTexture = dest }
      pass.depthAttachment.texture = z
      pass.depthAttachment.loadAction = .clear
      pass.depthAttachment.clearDepth = 1
      pass.depthAttachment.storeAction = .dontCare
      let cmd = try require(queue.makeCommandBuffer())
      let enc = try require(cmd.makeRenderCommandEncoder(descriptor: pass))
      var u = Uniforms()
      u.eyeSign = eye
      enc.setRenderPipelineState(pipeline)
      enc.setDepthStencilState(state)
      enc.setVertexBuffer(vb, offset: 0, index: 0)
      enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
      enc.setVertexTexture(depth, index: 0)
      enc.setFragmentTexture(source, index: 0)
      enc.setFragmentTexture(depth, index: 1)
      enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
      enc.drawIndexedPrimitives(
        type: .triangle, indexCount: indices.count, indexType: .uint32, indexBuffer: ib,
        indexBufferOffset: 0)
      enc.endEncoding()
      cmd.commit()
      cmd.waitUntilCompleted()
      guard cmd.status == .completed else { throw cmd.error! }
      if iteration > 0 { times.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1000) }
    }
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    dest.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    if v.scale > 1 {
      var small = [UInt8](repeating: 0, count: source.width * source.height * 4)
      for y in 0..<source.height {
        for x in 0..<source.width {
          for c in 0..<4 {
            var sum = 0
            for sy in 0..<v.scale {
              for sx in 0..<v.scale {
                sum += Int(pixels[((y * v.scale + sy) * w + x * v.scale + sx) * 4 + c])
              }
            }
            small[(y * source.width + x) * 4 + c] = UInt8(
              (sum + v.scale * v.scale / 2) / (v.scale * v.scale))
          }
        }
      }
      pixels = small
    }
    try save(pixels, source.width, source.height, v.name + (eye > 0 ? "-left" : "-right"))
  }
  report.append(["variant": v.name, "gpuMsPerEye": times.reduce(0, +) / Double(times.count)])
  print("Rendered \(v.name)")
}
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
  to: output.appendingPathComponent("timings.json"))
