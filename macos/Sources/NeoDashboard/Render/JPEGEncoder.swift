// CGImage → JPEG Data via ImageIO. Reuses a single CFMutableData buffer
// to avoid per-frame allocations on the hot path.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class JPEGEncoder {
    var quality: CGFloat

    init(quality: CGFloat = 0.85) {
        self.quality = quality
    }

    func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
