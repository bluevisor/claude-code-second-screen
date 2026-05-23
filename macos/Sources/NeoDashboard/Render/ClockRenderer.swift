// Fullscreen clock — fallback layout the FrameLoop swaps in whenever the
// selected source reports no active session. Visually styled to match the
// rest of the dashboard: phosphor palette, JetBrains Mono digits, matrix
// rain background, scanlines + vignette + chromatic aberration on top.

import AppKit
import CoreGraphics
import CoreText
import Foundation

final class ClockRenderer: FrameRenderer {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let rain: RainPainter
    private let showRain: Bool
    private let crt = CRTPostProcessor()

    init(size: CGSize = MatrixTheme.canvasSize, showRain: Bool = true) {
        self.size = size
        self.showRain = showRain
        self.rain = RainPainter(canvasSize: size, stepHz: 10)
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

        drawBackground(into: ctx, now: now)
        drawCornerBrackets(into: ctx)
        drawTopStrip(into: ctx, now: now)
        drawClock(into: ctx, now: now, blink: blink)
        drawBottomStrip(into: ctx)
        drawScanlines(into: ctx, opacity: 0.78)
        drawVignette(into: ctx, strength: 0.42)

        guard let raw = ctx.makeImage() else { return nil }
        return crt.process(raw) ?? raw
    }

    // MARK: - Background

    private func drawBackground(into ctx: CGContext, now: Date) {
        let grad = CGGradient(colorsSpace: colorSpace,
            colors: [MatrixTheme.bgTop.cgColor, MatrixTheme.bgBot.cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: size.height),
                               options: [])
        if showRain {
            rain.draw(into: ctx, now: now.timeIntervalSinceReferenceDate)
        }
    }

    private func drawCornerBrackets(into ctx: CGContext) {
        let inset: CGFloat = 18
        let r = CGRect(x: inset, y: inset,
                       width: size.width - 2 * inset,
                       height: size.height - 2 * inset)
        ctx.setStrokeColor(MatrixTheme.phosphor.cgColor)
        ctx.setLineWidth(1.5)
        let L: CGFloat = 22
        // TL
        ctx.move(to: CGPoint(x: r.minX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.minX + L, y: r.minY))
        ctx.move(to: CGPoint(x: r.minX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.minX, y: r.minY + L))
        // TR
        ctx.move(to: CGPoint(x: r.maxX - L, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        ctx.move(to: CGPoint(x: r.maxX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + L))
        // BL
        ctx.move(to: CGPoint(x: r.minX, y: r.maxY - L))
        ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        ctx.move(to: CGPoint(x: r.minX, y: r.maxY))
        ctx.addLine(to: CGPoint(x: r.minX + L, y: r.maxY))
        // BR
        ctx.move(to: CGPoint(x: r.maxX - L, y: r.maxY))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.move(to: CGPoint(x: r.maxX, y: r.maxY - L))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.strokePath()
    }

    // MARK: - Strips

    private func drawTopStrip(into ctx: CGContext, now: Date) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.weekday, .day, .month, .year], from: now)
        let weekday: String = {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: now).uppercased()
        }()
        let dateText = String(format: "%@  %02d.%02d.%04d", weekday,
                              comps.month ?? 0, comps.day ?? 0, comps.year ?? 0)
        let font = MatrixTheme.font(13, weight: .bold)
        let y: CGFloat = 32
        // Status pill on the left.
        let status = "NO ACTIVE SESSION"
        let statusFont = MatrixTheme.font(13, weight: .bold)
        let sw = stringWidth(status, font: statusFont) + 16
        let pillRect = CGRect(x: 36, y: y - 4, width: sw, height: 22)
        ctx.setStrokeColor(MatrixTheme.amber.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(pillRect)
        _ = drawText(ctx, status, font: statusFont, color: MatrixTheme.amber,
                     position: CGPoint(x: pillRect.minX + 8, y: pillRect.minY + 3))
        // Date right-aligned.
        let dw = stringWidth(dateText, font: font)
        _ = drawText(ctx, dateText, font: font, color: MatrixTheme.inkDim,
                     position: CGPoint(x: size.width - 36 - dw, y: y))
    }

    private func drawBottomStrip(into ctx: CGContext) {
        let weather = (WeatherService.shared.summary ?? "—").uppercased()
        let font = MatrixTheme.font(13)
        let y = size.height - 38
        // Tag at left
        let tag = "▸ STANDBY"
        _ = drawText(ctx, tag, font: MatrixTheme.font(13, weight: .bold),
                     color: MatrixTheme.phosphor,
                     position: CGPoint(x: 36, y: y))
        // Weather at right
        let w = stringWidth(weather, font: font)
        _ = drawText(ctx, weather, font: font, color: MatrixTheme.inkDim,
                     position: CGPoint(x: size.width - 36 - w, y: y))
    }

    // MARK: - Clock

    private func drawClock(into ctx: CGContext, now: Date, blink: Double) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.hour, .minute, .second], from: now)
        let hh = String(format: "%02d", comps.hour ?? 0)
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)
        let blinkOn = (comps.second ?? 0).isMultiple(of: 2)
        let colon = blinkOn ? ":" : " "

        let bigFont = MatrixTheme.font(150, weight: .heavy)
        let parts = [hh, colon, mm, colon, ss]
        let widths = parts.map { stringWidth($0, font: bigFont) }
        let total = widths.reduce(0, +)
        var x = (size.width - total) / 2

        // Vertically centre using tight cap bounds — keeps the digits
        // visually centred without descender drift.
        let sample = NSAttributedString(string: "0123456789:",
                                        attributes: [.font: bigFont])
        let tight = CTLineGetBoundsWithOptions(
            CTLineCreateWithAttributedString(sample), .useOpticalBounds)
        let baselineY = size.height / 2 + (tight.origin.y + tight.height / 2)
        let topY = baselineY - bigFont.ascender

        for (part, w) in zip(parts, widths) {
            _ = drawText(ctx, part, font: bigFont, color: MatrixTheme.ink,
                         position: CGPoint(x: x, y: topY))
            x += w
        }

        // Secondary label below the clock.
        let cal12 = ((comps.hour ?? 0) + 11) % 12 + 1
        let ampm = (comps.hour ?? 0) >= 12 ? "PM" : "AM"
        let sub = String(format: "%02d:%02d %@", cal12, comps.minute ?? 0, ampm)
        let subFont = MatrixTheme.font(18, weight: .bold)
        let sw = stringWidth(sub, font: subFont)
        _ = drawText(ctx, sub, font: subFont, color: MatrixTheme.inkFaint,
                     position: CGPoint(x: size.width / 2 - sw / 2,
                                       y: baselineY + 32))
    }

    // MARK: - Scanlines / vignette

    private func drawScanlines(into ctx: CGContext, opacity: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.30 * opacity).cgColor)
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: 1))
            y += 2
        }
        ctx.restoreGState()
    }

    private func drawVignette(into ctx: CGContext, strength: CGFloat) {
        let centerX = size.width / 2
        let centerY = size.height / 2
        let inner = min(size.width, size.height) * 0.32
        let outer = hypot(centerX, centerY) * 1.05
        let grad = CGGradient(colorsSpace: colorSpace,
            colors: [
                NSColor.black.withAlphaComponent(0).cgColor,
                NSColor.black.withAlphaComponent(strength).cgColor,
            ] as CFArray,
            locations: [0, 1])!
        ctx.drawRadialGradient(grad,
            startCenter: CGPoint(x: centerX, y: centerY),
            startRadius: inner,
            endCenter: CGPoint(x: centerX, y: centerY),
            endRadius: outer,
            options: [])
    }

    // MARK: - Text primitives (mirror MatrixRenderer's semantics)

    @discardableResult
    private func drawText(_ ctx: CGContext, _ s: String, font: NSFont,
                          color: NSColor, position: CGPoint) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        let baselineY = position.y + font.ascender
        ctx.textMatrix = .identity
        ctx.translateBy(x: position.x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded()
    }

    private func stringWidth(_ s: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded()
    }
}
