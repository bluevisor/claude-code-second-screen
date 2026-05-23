// Static-image fallback renderer. Loads a single bundled PNG and paints
// it scaled-to-fill the 1280×480 canvas. Used as a placeholder for new
// dashboard modes (WoW, Animal Crossing, …) until they get a real render
// pipeline.

import AppKit
import CoreGraphics
import Foundation

final class ImageRenderer: FrameRenderer {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let resourceName: String
    /// Cached on the first successful load — bundle lookups + IIO decode are
    /// surprisingly expensive at 30 fps.
    private var cached: CGImage?

    init(resourceName: String,
         size: CGSize = CGSize(width: 1280, height: 480)) {
        self.resourceName = resourceName
        self.size = size
    }

    func render(_ telemetry: Telemetry, blink: Double, now: Date) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        guard let img = loadImage() else { return ctx.makeImage() }

        // Aspect-fill (cover) — keep the placeholder filling the panel so
        // the LCD doesn't show black bars.
        let imgAspect = CGFloat(img.width) / CGFloat(img.height)
        let canvasAspect = size.width / size.height
        let drawW: CGFloat
        let drawH: CGFloat
        if imgAspect > canvasAspect {
            drawH = size.height
            drawW = drawH * imgAspect
        } else {
            drawW = size.width
            drawH = drawW / imgAspect
        }
        let x = (size.width - drawW) / 2
        let y = (size.height - drawH) / 2

        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -drawH)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private func loadImage() -> CGImage? {
        if let cached { return cached }
        let fm = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("\(resourceName).png"),
            Bundle.main.resourceURL?
                .appendingPathComponent("icons")
                .appendingPathComponent("\(resourceName).png"),
        ].compactMap { $0 }
        for url in candidates where fm.fileExists(atPath: url.path) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            cached = img
            return img
        }
        return nil
    }
}
