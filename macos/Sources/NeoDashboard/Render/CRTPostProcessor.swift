// Final-pass CRT effect — red/blue chromatic shift on a Core Image
// pipeline. Cheap to run at 30 fps because the CIContext is reused.

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

final class CRTPostProcessor {
    private let context: CIContext
    /// Pixels of RGB separation per channel direction at the canvas edges.
    /// Kept low — 1.5 reads as a believable CRT seam, anything north of ~3
    /// starts to look like a misaligned colour separation.
    var chromaticShift: CGFloat = 1.5

    // Pre-built CIFilter instances reused across every frame. The
    // previous implementation rebuilt 5 filter trees per process() call
    // (3 ColorMatrix + 2 AdditionCompositing) plus 6 CIVector
    // allocations for the channel masks. Holding the filters here
    // collapses that to setting `inputImage` per call.
    private let redChannel: CIFilter & CIColorMatrix
    private let greenChannel: CIFilter & CIColorMatrix
    private let blueChannel: CIFilter & CIColorMatrix
    private let combineRG: CIFilter & CICompositeOperation
    private let combineRGB: CIFilter & CICompositeOperation
    // The shift transforms are scalar — applied via `.transformed(by:)`
    // on the channel filter output, which is a lightweight CIImage op.
    private var redShift = CGAffineTransform.identity
    private var blueShift = CGAffineTransform.identity
    /// Counter for periodic CIContext.clearCaches() — the Metal
    /// intermediate-texture cache grows monotonically across
    /// createCGImage calls and is documented as unbounded; without a
    /// periodic flush it pins hundreds of MB of GPU memory over hours.
    /// Flush every ~30 s at 30 fps.
    private var framesSinceFlush = 0
    private let framesPerFlush = 900

    init() {
        // Skip the software fallback — we ship to Metal-capable Macs only.
        self.context = CIContext(options: [.useSoftwareRenderer: false])

        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let r = CIVector(x: 1, y: 0, z: 0, w: 0)
        let g = CIVector(x: 0, y: 1, z: 0, w: 0)
        let b = CIVector(x: 0, y: 0, z: 1, w: 0)

        let red = CIFilter.colorMatrix()
        red.rVector = r; red.gVector = zero; red.bVector = zero
        self.redChannel = red

        let green = CIFilter.colorMatrix()
        green.rVector = zero; green.gVector = g; green.bVector = zero
        self.greenChannel = green

        let blue = CIFilter.colorMatrix()
        blue.rVector = zero; blue.gVector = zero; blue.bVector = b
        self.blueChannel = blue

        self.combineRG = CIFilter.additionCompositing()
        self.combineRGB = CIFilter.additionCompositing()

        self.redShift = CGAffineTransform(translationX: chromaticShift, y: 0)
        self.blueShift = CGAffineTransform(translationX: -chromaticShift, y: 0)
    }

    /// Returns a new CGImage with CRT post-effects applied. Falls back to
    /// the input on any filter setup error.
    func process(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent

        redChannel.inputImage = input
        greenChannel.inputImage = input
        blueChannel.inputImage = input
        guard
            let redIsolated = redChannel.outputImage,
            let greenIsolated = greenChannel.outputImage,
            let blueIsolated = blueChannel.outputImage
        else { return image }

        let redShifted = redIsolated.transformed(by: redShift)
        let blueShifted = blueIsolated.transformed(by: blueShift)

        combineRG.inputImage = greenIsolated
        combineRG.backgroundImage = redShifted
        guard let rg = combineRG.outputImage else { return image }
        combineRGB.inputImage = rg
        combineRGB.backgroundImage = blueShifted
        guard let combined = combineRGB.outputImage else { return image }

        let result = context.createCGImage(combined.cropped(to: extent), from: extent) ?? image
        framesSinceFlush += 1
        if framesSinceFlush >= framesPerFlush {
            framesSinceFlush = 0
            context.clearCaches()
        }
        return result
    }
}
