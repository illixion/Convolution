/*
 MatroskaRemux - writing ISO BMFF boxes

 Big-endian fields and nested boxes whose 32-bit size is patched once the
 body is written. Nothing here is large enough to need 64-bit box sizes: a
 media segment's mdat is a few tens of megabytes at most.
 */

import Foundation

struct BoxWriter {
    var bytes: [UInt8] = []

    init() {}

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes += [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    mutating func u24(_ value: UInt32) {
        bytes += [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    mutating func u32(_ value: UInt32) {
        bytes += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(value >> 32))
        u32(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func fourCC(_ code: String) {
        let ascii = Array(code.utf8)
        bytes += (ascii + [0x20, 0x20, 0x20, 0x20]).prefix(4)
    }

    mutating func zeros(_ count: Int) { bytes += repeatElement(0, count: count) }

    mutating func box(_ type: String, _ body: (inout BoxWriter) -> Void) {
        let start = bytes.count
        u32(0)
        fourCC(type)
        body(&self)
        patchSize(at: start)
    }

    mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout BoxWriter) -> Void) {
        box(type) { w in
            w.u8(version)
            w.u24(flags)
            body(&w)
        }
    }

    /// A box whose body is `payload` verbatim.
    mutating func box(_ type: String, payload: [UInt8]) {
        box(type) { $0.bytes += payload }
    }

    mutating func patchSize(at start: Int) {
        let size = UInt32(bytes.count - start)
        bytes[start] = UInt8(size >> 24)
        bytes[start + 1] = UInt8(size >> 16 & 0xFF)
        bytes[start + 2] = UInt8(size >> 8 & 0xFF)
        bytes[start + 3] = UInt8(size & 0xFF)
    }

    mutating func patchU32(at offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value >> 24)
        bytes[offset + 1] = UInt8(value >> 16 & 0xFF)
        bytes[offset + 2] = UInt8(value >> 8 & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    static let unityMatrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
}
