// TRCC Type 2 ("H" variant) framing — pure byte plumbing, no I/O.
//
// Protocol facts (from `thermalright-trcc-linux`, see CLAUDE.md / hid.py):
//
// Init packet (handshake), 512 bytes total:
//     DA DB DC DD            magic
//     00 00 00 00 00 00 00 00 reserved (8 bytes)
//     01 00 00 00             command = 1
//     00 00 00 00             reserved
//     ...padding to 512
//
// Init response (validate):
//     resp[0..<4] == magic
//     resp[12]     == 0x01
//     resp[5] = PM byte, resp[4] = SUB byte → FBL → resolution
//
// Frame packet (JPEG mode), 20-byte header + JPEG payload, padded to 512:
//     DA DB DC DD            magic
//     02 00                  cmd_type = PICTURE
//     00 00                  mode = JPEG
//     WW WW                  width (little-endian uint16)
//     HH HH                  height (little-endian uint16)
//     02 00 00 00            sub-flag
//     LL LL LL LL            payload length (little-endian uint32)
//     [JPEG bytes]
//     [zero pad to 512-multiple]
//
// The macOS HID layer reassembles by chunking this packet into 512-byte
// output reports (report id 0x00).

import Foundation

enum TRCCFraming {
    static let magic: [UInt8] = [0xDA, 0xDB, 0xDC, 0xDD]
    static let initSize = 512
    static let responseSize = 512
    static let bulkAlignment = 512

    static func buildInitPacket() -> Data {
        var d = Data(magic)
        d.append(Data(repeating: 0, count: 8))
        d.append(Data([0x01, 0x00, 0x00, 0x00]))
        d.append(Data(repeating: 0, count: 4))
        d.append(Data(repeating: 0, count: initSize - d.count))
        precondition(d.count == initSize)
        return d
    }

    static func validateResponse(_ resp: Data) -> Bool {
        guard resp.count >= 20 else { return false }
        let prefix = resp.prefix(4)
        if Array(prefix) != magic { return false }
        return resp[12] == 0x01
    }

    /// (resolution, pm, sub) parsed from a validated response.
    static func parseDeviceInfo(_ resp: Data) -> (width: Int, height: Int, pm: UInt8, sub: UInt8) {
        let pm = resp[5]
        let sub = resp[4]
        let fbl = pmToFBL(pm: pm, sub: sub)
        let (w, h) = fblToResolution(fbl: fbl, pm: pm)
        return (w, h, pm, sub)
    }

    /// JPEG-mode frame packet (matches Mode 2 in C# FormCZTV.ImageToJpg).
    /// The render pipeline only produces JPEGs (the LCD detects via FF D8).
    static func buildFramePacket(jpeg: Data, width: Int, height: Int) -> Data {
        precondition(jpeg.count >= 2 && jpeg[jpeg.startIndex] == 0xFF
                     && jpeg[jpeg.startIndex + 1] == 0xD8,
                     "buildFramePacket requires JPEG bytes (FF D8 magic)")

        var d = Data(capacity: ceilTo512(20 + jpeg.count))
        d.append(contentsOf: magic)                       // 4
        d.append(contentsOf: [0x02, 0x00])                // 2 — cmd PICTURE
        d.append(contentsOf: [0x00, 0x00])                // 2 — mode JPEG
        d.appendLEUInt16(UInt16(width))                   // 2
        d.appendLEUInt16(UInt16(height))                  // 2
        d.append(contentsOf: [0x02, 0x00, 0x00, 0x00])    // 4 — sub-flag
        d.appendLEUInt32(UInt32(jpeg.count))              // 4 — payload length
        d.append(jpeg)                                    // payload
        let padded = ceilTo512(d.count)
        if padded > d.count {
            d.append(Data(repeating: 0, count: padded - d.count))
        }
        return d
    }

    private static func ceilTo512(_ n: Int) -> Int {
        let aligned = (n / bulkAlignment) * bulkAlignment
        return aligned + (n % bulkAlignment == 0 ? 0 : bulkAlignment)
    }

    // MARK: - FBL / PM lookup (just enough for Trofeo Vision 1280×480)

    private static let pmToFBLOverrides: [UInt8: Int] = [
        5: 50, 7: 64, 9: 224, 10: 224, 11: 224, 12: 224,
        13: 224, 14: 64, 15: 224, 16: 224, 17: 224,
        32: 100, 50: 50, 63: 114, 64: 114, 65: 192, 66: 192,
        68: 192,   // 1280×480 (Trofeo Vision)
        69: 192,
    ]
    private static let pmSubToFBL: [String: Int] = [
        "1,48": 114,
        "1,49": 192,
    ]

    private static func pmToFBL(pm: UInt8, sub: UInt8) -> Int {
        if let v = pmSubToFBL["\(pm),\(sub)"] { return v }
        if let v = pmToFBLOverrides[pm] { return v }
        return Int(pm)
    }

    private static let fblResolution: [Int: (Int, Int)] = [
        36: (240, 240), 37: (240, 240),
        50: (320, 240), 51: (320, 240), 52: (320, 240), 53: (320, 240),
        54: (360, 360), 58: (320, 240), 64: (640, 480),
        72: (480, 480), 100: (320, 320), 101: (320, 320), 102: (320, 320),
        114: (1600, 720),
        128: (1280, 480),
        129: (480, 480),
        192: (1920, 462),   // overridden below by pm for 1280×480
        224: (854, 480),
    ]
    private static let fbl192ByPM: [UInt8: (Int, Int)] = [
        68: (1280, 480),
        69: (1920, 440),
    ]

    private static func fblToResolution(fbl: Int, pm: UInt8) -> (Int, Int) {
        if fbl == 192 {
            if let r = fbl192ByPM[pm] { return r }
        }
        return fblResolution[fbl] ?? (1280, 480)
    }
}

private extension Data {
    mutating func appendLEUInt16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendLEUInt32(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8(v >> 24))
    }
}
