// Offline GPU ray-cast for the experimental matte layers. This does not alter
// the app renderer; it isolates the expensive per-eye warp from CPU matting.
import CoreGraphics
import Foundation
import ImageIO
import Metal

private let shader = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Params { uint width, height; int radius; float strength, convergence, eye; };
  static inline float feather(float x, uint width) {
      float u=(x+0.5)/float(width);
      float a=smoothstep(0.0,0.05,u), b=smoothstep(0.0,0.05,1.0-u);
      return a*a*(3.0-2.0*a)*b*b*(3.0-2.0*b);
  }
  static inline float3 intersect(texture2d<float,access::sample> z, sampler s,
                                 uint x, uint y, constant Params &p) {
      float target=float(x)+0.5, best=-INFINITY, source=float(x), found=0.0;
      for (int offset=-p.radius; offset<=p.radius; ++offset) {
          int i=clamp(int(x)+offset,0,int(p.width)-1), j=min(i+1,int(p.width)-1);
          float x0=float(i)+0.5, x1=float(j)+0.5;
          float d0=z.sample(s,float2((x0)/p.width,(float(y)+0.5)/p.height)).r;
          float d1=z.sample(s,float2((x1)/p.width,(float(y)+0.5)/p.height)).r;
          float q0=x0+p.eye*p.strength*float(p.width)*(d0-p.convergence)*feather(x0-0.5,p.width);
          float q1=x1+p.eye*p.strength*float(p.width)*(d1-p.convergence)*feather(x1-0.5,p.width);
          float delta=q1-q0;
          if (abs(delta)<1e-5 || target<min(q0,q1) || target>max(q0,q1)) continue;
          float t=clamp((target-q0)/delta,0.0,1.0), d=mix(d0,d1,t);
          if (d>best) { best=d; source=mix(float(i),float(j),t); found=1.0; }
      }
      // The CPU reference clamps source coordinates at the frame edge. A small
      // outward ray beyond that clamped domain has no segment intersection.
      if (found==0.0 && (x==0 || x+1==p.width)) { source=float(x); found=1.0; }
      return float3((source+0.5)/p.width,(float(y)+0.5)/p.height,found);
  }
  kernel void layerRaycast(texture2d<float,access::sample> premult [[texture(0)]],
                           texture2d<float,access::sample> alpha [[texture(1)]],
                           texture2d<float,access::sample> background [[texture(2)]],
                           texture2d<float,access::sample> nearZ [[texture(3)]],
                           texture2d<float,access::sample> farZ [[texture(4)]],
                           texture2d<float,access::write> output [[texture(5)]],
                           constant Params &p [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
      if (xy.x>=p.width || xy.y>=p.height) return;
      constexpr sampler s(filter::linear,address::clamp_to_edge);
      float3 n=intersect(nearZ,s,xy.x,xy.y,p), f=intersect(farZ,s,xy.x,xy.y,p);
      float a=alpha.sample(s,n.xy).r;
      float3 c=premult.sample(s,n.xy).rgb+(1.0-a)*background.sample(s,f.xy).rgb;
      output.write(float4(c,n.z*f.z),xy);
  }
  """#

private func imageBytes(_ url: URL, width: Int, height: Int) throws -> [UInt8] {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
    image.width == width, image.height == height
  else { throw Failure("bad image: \(url.lastPathComponent)") }
  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  let space = CGColorSpaceCreateDeviceRGB()
  let ctx = CGContext(
    data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return bytes
}
private struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}

guard CommandLine.arguments.count == 6 else {
  fputs(
    "usage: swift stereo-matte-gpu-warp.swift MATTE_DIR EYE strength convergence OUTPUT.rgba\n",
    stderr)
  exit(2)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let eyeName = CommandLine.arguments[2]
let strength = Float(CommandLine.arguments[3])!
let convergence = Float(CommandLine.arguments[4])!
let outputURL = URL(fileURLWithPath: CommandLine.arguments[5])
let meta =
  try JSONSerialization.jsonObject(
    with: Data(contentsOf: dir.appendingPathComponent("layer-map.json"))) as! [String: Any]
let width = meta["width"] as! Int
let height = meta["height"] as! Int
guard eyeName == "left" || eyeName == "right", let device = MTLCreateSystemDefaultDevice(),
  let queue = device.makeCommandQueue(),
  let library = try? device.makeLibrary(source: shader, options: nil),
  let function = library.makeFunction(name: "layerRaycast"),
  let pipeline = try? device.makeComputePipelineState(function: function)
else { throw Failure("Metal unavailable") }
func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) throws
  -> MTLTexture
{
  let d = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: format, width: w, height: h, mipmapped: false)
  d.storageMode = .shared
  d.usage = usage
  guard let t = device.makeTexture(descriptor: d) else {
    throw Failure("texture allocation failed")
  }
  return t
}
func rgba(_ name: String) throws -> MTLTexture {
  let t = try texture(.rgba8Unorm, width, height, [.shaderRead])
  var b = try imageBytes(dir.appendingPathComponent(name), width: width, height: height)
  t.replace(
    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: &b,
    bytesPerRow: width * 4)
  return t
}
func depth(_ name: String) throws -> MTLTexture {
  let t = try texture(.r32Float, width, height, [.shaderRead])
  var b = try Data(contentsOf: dir.appendingPathComponent(name)).withUnsafeBytes {
    Array($0.bindMemory(to: UInt8.self))
  }
  guard b.count == width * height * 4 else { throw Failure("bad depth data: \(name)") }
  t.replace(
    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: &b,
    bytesPerRow: width * 4)
  return t
}
let pTex = try rgba("foreground-premult.png")
let aTex = try rgba("alpha.png")
let bTex = try rgba("background.png")
let nTex = try depth("near-depth.f32")
let fTex = try depth("far-depth.f32")
let out = try texture(.rgba8Unorm, width, height, [.shaderWrite])
let maxShift = Float(width) * abs(strength) * max(abs(convergence), abs(1 - convergence))
struct Uniforms {
  var width: UInt32
  var height: UInt32
  var radius: Int32
  var strength: Float
  var convergence: Float
  var eye: Float
}
var u = Uniforms(
  width: UInt32(width), height: UInt32(height), radius: Int32(min(128, ceil(maxShift) + 2)),
  strength: strength,
  convergence: convergence, eye: eyeName == "left" ? 1 : -1)
let command = queue.makeCommandBuffer()!
let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
for (index, t) in [pTex, aTex, bTex, nTex, fTex, out].enumerated() {
  encoder.setTexture(t, index: index)
}
encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
let tw = pipeline.threadExecutionWidth
let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
encoder.dispatchThreads(
  MTLSize(width: width, height: height, depth: 1),
  threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
guard command.status == .completed else { throw command.error ?? Failure("GPU command failed") }
var bytes = [UInt8](repeating: 0, count: width * height * 4)
out.getBytes(
  &bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
try Data(bytes).write(to: outputURL)
print(
  "GPU raycast \(eyeName): \(width)x\(height), radius \(u.radius), \(String(format:"%.3f",command.gpuEndTime-command.gpuStartTime)) s"
)
