// CRT chromatic aberration — shifts red channel right and blue channel
// left by `chromaticShift` pixels in-place on an existing CGContext's
// pixel buffer. No image copy, no Core Image, no Metal.

import CoreGraphics
import Foundation
import QuartzCore

final class CRTPostProcessor {
    var chromaticShift: Int = 2
    private(set) var lastProcessMs: Double = 0

    /// Apply chromatic shift in-place on `ctx`'s pixel buffer. Call this
    /// BEFORE `ctx.makeImage()` — the shift modifies the backing store
    /// directly so the subsequent makeImage captures the result with
    /// zero copy. The context must use BGRA byte order (byteOrder32Little
    /// + premultipliedFirst).
    func applyInPlace(ctx: CGContext) {
        let t0 = CACurrentMediaTime()
        guard let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
            lastProcessMs = 0
            return
        }
        let w = ctx.width
        let h = ctx.height
        let shift = chromaticShift
        guard w > shift * 2 else { return }
        let bpr = ctx.bytesPerRow

        // BGRA: byte 0=B, 1=G, 2=R, 3=A
        for y in 0..<h {
            let row = ptr.advanced(by: y * bpr)

            // Red (offset 2): shift right — copy right-to-left
            var x = w - 1
            while x >= shift {
                row[x &* 4 &+ 2] = row[(x &- shift) &* 4 &+ 2]
                x &-= 1
            }
            while x >= 0 {
                row[x &* 4 &+ 2] = 0
                x &-= 1
            }

            // Blue (offset 0): shift left — copy left-to-right
            x = 0
            let limit = w &- shift
            while x < limit {
                row[x &* 4] = row[(x &+ shift) &* 4]
                x &+= 1
            }
            while x < w {
                row[x &* 4] = 0
                x &+= 1
            }
        }
        lastProcessMs = (CACurrentMediaTime() - t0) * 1000
    }
}
