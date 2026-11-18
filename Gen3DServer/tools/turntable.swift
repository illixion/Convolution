// Renders a contact sheet of a USDZ/GLB-converted model from several azimuths,
// so engines can be compared without a headset: front, 45°, side, 135°, back, ...
//
//   swiftc -O tools/turntable.swift -o /tmp/turntable
//   /tmp/turntable model.usdz sheet.png [columns=4] [cell=384]
//
// Lit by a neutral three-point rig, grey background. Camera distance follows the
// bounding sphere, the model is centred, and +Y is up (glTF/USDZ convention).
import AppKit
import SceneKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: turntable <model.usdz> <out.png> [columns] [cell]\n".utf8))
    exit(2)
}
let columns = args.count > 3 ? Int(args[3]) ?? 4 : 4
let cell = args.count > 4 ? Int(args[4]) ?? 384 : 384
let azimuths: [Double] = [0, 45, 90, 135, 180, 225, 270, 315]

let scene = try SCNScene(url: URL(fileURLWithPath: args[1]), options: nil)
let content = SCNNode()
for child in scene.rootNode.childNodes { content.addChildNode(child) }
let (lo, hi) = content.boundingBox
let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
let radius = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) / 2 * 1.35
content.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)

let root = SCNScene()
root.background.contents = NSColor(white: 0.5, alpha: 1)
root.rootNode.addChildNode(content)

func light(_ type: SCNLight.LightType, intensity: CGFloat, at p: SCNVector3) -> SCNNode {
    let n = SCNNode(); n.light = SCNLight(); n.light!.type = type; n.light!.intensity = intensity
    n.position = p; n.look(at: SCNVector3Zero); return n
}
let r = radius * 4
root.rootNode.addChildNode(light(.omni, intensity: 900, at: SCNVector3(r, r, r)))
root.rootNode.addChildNode(light(.omni, intensity: 500, at: SCNVector3(-r, r * 0.5, r)))
root.rootNode.addChildNode(light(.omni, intensity: 400, at: SCNVector3(0, r * 0.5, -r)))
let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 450
root.rootNode.addChildNode(amb)

let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.fieldOfView = 35
camera.camera!.zFar = Double(radius) * 20; camera.camera!.zNear = Double(radius) * 0.05
root.rootNode.addChildNode(camera)

let device = MTLCreateSystemDefaultDevice()!
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = root
renderer.pointOfView = camera
let dist = Double(radius) / tan(35.0 / 2 * .pi / 180)

let rows = (azimuths.count + columns - 1) / columns
let sheet = NSImage(size: NSSize(width: columns * cell, height: rows * cell))
sheet.lockFocus()
for (i, az) in azimuths.enumerated() {
    let a = az * .pi / 180
    camera.position = SCNVector3(dist * sin(a), Double(radius) * 0.25, dist * cos(a))
    camera.look(at: SCNVector3Zero)
    let img = renderer.snapshot(atTime: 0, with: CGSize(width: cell * 2, height: cell * 2), antialiasingMode: .multisampling4X)
    let x = (i % columns) * cell, y = (rows - 1 - i / columns) * cell
    img.draw(in: NSRect(x: x, y: y, width: cell, height: cell))
}
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
