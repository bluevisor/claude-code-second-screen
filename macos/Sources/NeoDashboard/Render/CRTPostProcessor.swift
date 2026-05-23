// Final-pass CRT effect — red/blue chromatic shift on a Core Image
// pipeline. Cheap to run at 30 fps because the CIContext is reused.

import CoreGraphics
import CoreImage
import Foundation

final class CRTPostProcessor {
    private let context: CIContext
    /// Pixels of RGB separation per channel direction at the canvas edges.
    /// Kept low — 1.5 reads as a believable CRT seam, anything north of ~3
    /// starts to look like a misaligned colour separation.
    var chromaticShift: CGFloat = 1.5

    init() {
        // Skip the software fallback — we ship to Metal-capable Macs only.
        self.context = CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Returns a new CGImage with CRT post-effects applied. Falls back to
    /// the input on any filter setup error.
    func process(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent

        // Chromatic aberration — red shifts right, blue shifts left.
        let red   = isolate(.red,   input)
            .transformed(by: CGAffineTransform(translationX: chromaticShift, y: 0))
        let green = isolate(.green, input)
        let blue  = isolate(.blue,  input)
            .transformed(by: CGAffineTransform(translationX: -chromaticShift, y: 0))
        let combined = green
            .applyingFilter("CIAdditionCompositing",
                            parameters: [kCIInputBackgroundImageKey: red])
            .applyingFilter("CIAdditionCompositing",
                            parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: extent)

        return context.createCGImage(combined, from: extent) ?? image
    }

    private enum Channel {
        case red, green, blue
        var rgb: (CIVector, CIVector, CIVector) {
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            switch self {
            case .red:   return (CIVector(x: 1, y: 0, z: 0, w: 0), zero, zero)
            case .green: return (zero, CIVector(x: 0, y: 1, z: 0, w: 0), zero)
            case .blue:  return (zero, zero, CIVector(x: 0, y: 0, z: 1, w: 0))
            }
        }
    }

    private func isolate(_ channel: Channel, _ image: CIImage) -> CIImage {
        let (r, g, b) = channel.rgb
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": r,
            "inputGVector": g,
            "inputBVector": b,
        ])
    }
}
