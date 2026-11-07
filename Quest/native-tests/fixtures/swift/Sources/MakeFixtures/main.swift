// make-fixtures <out.vgat>          writes the fixture track
// make-fixtures --sums <track.vgat> prints the first pair's and disparities' sums
import Compression
import Foundation
import VergenceCore

func deflate(_ data: Data) throws -> Data {
    let capacity = data.count + data.count / 2 + 1024
    var out = Data(count: capacity)
    let written = out.withUnsafeMutableBytes { dst in
        data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    out.count = written
    return out
}

func inflate(_ data: Data, _ size: Int) throws -> Data {
    var out = Data(count: size)
    let written = out.withUnsafeMutableBytes { dst in
        data.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    out.count = written
    return out
}

/// The values both generators write (and native-tests/test_analysis.cpp expects).
func flow(_ c: Int, _ x: Int, _ y: Int, _ pair: Int) -> Float {
    c < 4 ? Float(c + 1) * 0.75 + Float(x) * 0.5 - Float(y) * 0.25 + Float(pair) : Float(x + y) / 12
}
func disparity(_ x: Int, _ y: Int, _ frame: Int) -> Float { -2 + Float(x) * 0.5 + Float(y) * 0.25 + Float(frame) * 0.1 }

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--sums" {
    let index = try AnalysisTrackIndex(Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: .alwaysMapped))
    guard let pair = index.entries.first(where: { $0.kind == .flowPair }) else { fatalError("no flow pair") }
    let record = try index.record(pair).inflated(using: inflate)
    let d0 = try index.record(index.nearest(.disparity, eye: .right, to: pair.time, within: 0.01)!).inflated(using: inflate)
    let d1 = try index.record(index.nearest(.disparity, eye: .right, to: pair.endTime, within: 0.01)!).inflated(using: inflate)
    func sum(_ values: [Float]) -> Double { values.reduce(0) { $0 + Double($1) } }
    print(String(format: "records %d pair %.6f-%.6f %dx%d flow %.4f disparity %.4f %.4f",
                 index.entries.count, pair.time.seconds, pair.endTime.seconds, record.width, record.height,
                 sum(record.values()), sum(d0.values()), sum(d1.values())))
    exit(0)
}
guard arguments.count == 2 else { fatalError("usage: make-fixtures <out.vgat> | --sums <track.vgat>") }

let (fw, fh, dw, dh) = (8, 5, 6, 4)
var track = try AnalysisTrack.header(AnalysisTrackHeader(
    mediaID: "fixture", producer: "VergenceCore fixture", models: ["flowPair": "fixture", "disparity": "fixture"],
    sourceWidth: 64, sourceHeight: 32))
func time(_ frame: Int) -> AnalysisTime { AnalysisTime(value: Int64(frame) * 1001, timescale: 24000) }
for frame in 0 ..< 4 {
    var d = [Float]()
    for y in 0 ..< dh { for x in 0 ..< dw { d.append(disparity(x, y, frame)) } }
    track.append(AnalysisTrack.record(try AnalysisRecord.encoding(
        d, kind: .disparity, eye: .right, as: .int16, channels: 1, width: dw, height: dh, time: time(frame),
        maxMagnitude: 8).deflated(using: deflate)))
    guard frame < 3 else { continue }
    var f = [Float]()
    for c in 0 ..< 5 { for y in 0 ..< fh { for x in 0 ..< fw { f.append(flow(c, x, y, frame)) } } }
    track.append(AnalysisTrack.record(try AnalysisRecord.encoding(
        f, kind: .flowPair, as: .int16, channels: 5, width: fw, height: fh, time: time(frame), endTime: time(frame + 1),
        maxMagnitude: 16).deflated(using: deflate)))
}
// The other encodings, plain and deflated.
var depth = [Float]()
for y in 0 ..< 3 { for x in 0 ..< 4 { depth.append(Float(x) * 0.25 + Float(y) * 0.5) } }
track.append(AnalysisTrack.record(AnalysisRecord.encoding(depth, kind: .depth, as: .float16, channels: 1, width: 4,
                                                          height: 3, time: time(0))))
var gain = [Float]()
for c in 0 ..< 2 { for y in 0 ..< 2 { for x in 0 ..< 3 { gain.append(Float(c * 6 + y * 3 + x) / 3) } } }
track.append(AnalysisTrack.record(try AnalysisRecord.encoding(gain, kind: .gainMap, as: .uint8, channels: 2, width: 3,
                                                              height: 2, time: time(0), range: 0 ... 4).deflated(using: deflate)))
try track.write(to: URL(fileURLWithPath: arguments[1]))
