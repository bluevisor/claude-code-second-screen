// CGImage → JPEG Data via ImageIO. Allocates a fresh NSMutableData
// per call — bridged-to-Data on return, released deterministically by
// ARC when the caller drops it. Reusing one persistent buffer would
// require copying the bytes into a fresh Data on return to avoid the
// next encode mutating the value an earlier caller is still holding,
// which negates the saving.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class JPEGEncoder: @unchecked Sendable {
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
