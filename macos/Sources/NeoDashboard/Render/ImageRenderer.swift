// Static-image fallback renderer. Loads a single bundled PNG and paints
// it scaled-to-fill the 1280×480 canvas. Used as a placeholder for new
// dashboard modes (WoW, Animal Crossing, …) until they get a real render
// pipeline.

import AppKit
import CoreGraphics
import CoreText
import Foundation

final class ImageRenderer: FrameRenderer, @unchecked Sendable {
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

    /// Themed idle/clock view — dimmed background image with the time
    /// painted in the centre. Keeps the placeholder's visual identity
    /// (Alliance blue, Horde red, Dragon Ball sand, …) while clearly
    /// communicating "no active session".
    func renderClock(blink: Double, now: Date) -> CGImage? {
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

        // 1. Backdrop = the placeholder image, aspect-filled.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if let img = loadImage() {
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
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
            ctx.restoreGState()
        }

        // 2. Darken so the clock pops.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // 3. Big centred HH:MM in the theme image's main visual contrast.
        let blinkOn = Calendar.current
            .component(.second, from: now)
            .isMultiple(of: 2)
        let timeStr = clockText(now)
        let ampm = amPm(now)

        let clockFont = roundedFont(size: 200, weight: .heavy)
        // Always include the colon glyph in the layout so the digits stay
        // pinned. Toggle the colon's foreground colour between white and
        // clear to blink it without shifting anything.
        let attr = NSMutableAttributedString(
            string: timeStr,
            attributes: [.font: clockFont, .foregroundColor: NSColor.white])
        if !blinkOn, let r = timeStr.range(of: ":") {
            attr.addAttribute(.foregroundColor, value: NSColor.clear,
                              range: NSRange(r, in: timeStr))
        }
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let baselineY = size.height / 2 + (bounds.origin.y + bounds.height / 2)
        let x = (size.width - bounds.width) / 2
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()

        // AM/PM beside the clock when in 12-hour mode.
        if !ampm.isEmpty {
            let ampmFont = roundedFont(size: 38, weight: .semibold)
            let line2 = CTLineCreateWithAttributedString(
                NSAttributedString(string: ampm,
                                   attributes: [.font: ampmFont,
                                                .foregroundColor: NSColor.white.withAlphaComponent(0.85)]))
            let b2 = CTLineGetBoundsWithOptions(line2, .useOpticalBounds)
            let x2 = x + bounds.width + 14
            let by2 = baselineY - bigOffset(for: bounds, into: b2)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: x2, y: by2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line2, ctx)
            ctx.restoreGState()
        }

        return ctx.makeImage()
    }

    /// Aligns the AM/PM glyph's baseline so it sits a touch above the
    /// digits' baseline — feels right with our rounded heavy face.
    private func bigOffset(for big: CGRect, into small: CGRect) -> CGFloat {
        // Move the small-text baseline up by ~half the big glyph height.
        big.height * 0.20 + small.height * 0.0
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
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
