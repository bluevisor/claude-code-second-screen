// Fullscreen clock — the fallback layout FrameLoop swaps in whenever the
// selected source has nothing meaningful to display (no active session, no
// recent events). Intentionally calm: deep sky gradient with a few stars,
// huge centered HH:MM, weekday + date underneath.

import AppKit
import CoreGraphics
import CoreText
import Foundation

final class ClockRenderer: FrameRenderer {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let stars: [(CGFloat, CGFloat, CGFloat)] = {
        // Pre-seeded scatter so the constellations don't dance frame to frame.
        var rng = SystemRandomNumberGenerator()
        return (0..<60).map { _ in
            let x = CGFloat.random(in: 30...1250, using: &rng)
            let y = CGFloat.random(in: 30...220, using: &rng)
            let r = CGFloat.random(in: 0.6...2.2, using: &rng)
            return (x, y, r)
        }
    }()

    init(size: CGSize = CGSize(width: 1280, height: 480)) {
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

        let hour = Calendar.current.component(.hour, from: now)
        let palette = palette(forHour: hour)

        // Background gradient.
        let grad = CGGradient(colorsSpace: colorSpace,
            colors: [palette.skyTop.cgColor, palette.skyBot.cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: size.height),
                               options: [])

        // Stars (twinkle gently with phase).
        for (i, star) in stars.enumerated() {
            let twinkle = 0.6 + 0.4 * sin(blink * 0.9 + Double(i) * 0.5)
            ctx.setFillColor(palette.star.withAlphaComponent(CGFloat(twinkle)).cgColor)
            ctx.fillEllipse(in: CGRect(x: star.0 - star.2, y: star.1 - star.2,
                                       width: star.2 * 2, height: star.2 * 2))
        }

        // Subtle ground line near the bottom.
        ctx.setStrokeColor(palette.horizon.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 60, y: size.height - 60))
        ctx.addLine(to: CGPoint(x: size.width - 60, y: size.height - 60))
        ctx.strokePath()

        // Big clock — HH:MM only. Seconds are too jittery for a quiet card.
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .weekday, .month, .day], from: now)
        let h12 = ((comps.hour ?? 0) + 11) % 12 + 1
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ampm = (comps.hour ?? 0) >= 12 ? "PM" : "AM"
        let clockText = "\(h12):\(mm)"

        let clockFont = font(150, weight: .heavy)
        let clockColor = palette.text
        let clockMid = CGPoint(x: size.width / 2, y: size.height / 2 - 14)
        let clockW = textWidth(clockText, font: clockFont)
        drawTextBaselineMid(ctx, clockText, font: clockFont, color: clockColor,
                            x: clockMid.x - clockW / 2, midY: clockMid.y)

        // AM/PM bubble next to the clock.
        let ampmFont = font(28, weight: .bold)
        drawTextBaselineMid(ctx, ampm, font: ampmFont, color: palette.textDim,
                            x: clockMid.x + clockW / 2 + 16,
                            midY: clockMid.y + 36)

        // Date line — uppercase, spaced.
        let weekdayName = DateFormatter().weekdaySymbols[(comps.weekday ?? 1) - 1].uppercased()
        let monthName = DateFormatter().monthSymbols[(comps.month ?? 1) - 1].uppercased()
        let dateText = "\(weekdayName) · \(monthName) \(comps.day ?? 0)"
        let dateFont = font(30, weight: .semibold)
        let dateW = textWidth(dateText, font: dateFont)
        drawTextBaselineMid(ctx, dateText, font: dateFont, color: palette.textDim,
                            x: size.width / 2 - dateW / 2,
                            midY: clockMid.y + 110)

        // Tiny status hint at bottom-left so the user knows why we're here.
        let hint = "no active session"
        let hintFont = font(13, weight: .medium)
        drawTextBaselineMid(ctx, hint, font: hintFont, color: palette.textDim,
                            x: 40, midY: size.height - 40)

        return ctx.makeImage()
    }

    // MARK: - Palette

    private struct Palette {
        let skyTop, skyBot, star, horizon, text, textDim: NSColor
    }

    private func palette(forHour h: Int) -> Palette {
        switch h {
        case 5..<8:
            return Palette(
                skyTop:   NSColor(srgbRed: 0.96, green: 0.74, blue: 0.55, alpha: 1),
                skyBot:   NSColor(srgbRed: 0.99, green: 0.92, blue: 0.78, alpha: 1),
                star:     NSColor(srgbRed: 1.00, green: 0.96, blue: 0.86, alpha: 0.6),
                horizon:  NSColor(srgbRed: 0.62, green: 0.40, blue: 0.26, alpha: 0.30),
                text:     NSColor(srgbRed: 0.30, green: 0.20, blue: 0.12, alpha: 1),
                textDim:  NSColor(srgbRed: 0.48, green: 0.32, blue: 0.22, alpha: 0.95))
        case 8..<17:
            return Palette(
                skyTop:   NSColor(srgbRed: 0.42, green: 0.66, blue: 0.92, alpha: 1),
                skyBot:   NSColor(srgbRed: 0.84, green: 0.95, blue: 1.00, alpha: 1),
                star:     NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.45),
                horizon:  NSColor(srgbRed: 0.20, green: 0.35, blue: 0.55, alpha: 0.35),
                text:     NSColor(srgbRed: 0.16, green: 0.22, blue: 0.36, alpha: 1),
                textDim:  NSColor(srgbRed: 0.30, green: 0.40, blue: 0.58, alpha: 0.95))
        case 17..<20:
            return Palette(
                skyTop:   NSColor(srgbRed: 1.00, green: 0.62, blue: 0.42, alpha: 1),
                skyBot:   NSColor(srgbRed: 1.00, green: 0.86, blue: 0.62, alpha: 1),
                star:     NSColor(srgbRed: 1.00, green: 0.96, blue: 0.86, alpha: 0.65),
                horizon:  NSColor(srgbRed: 0.42, green: 0.20, blue: 0.10, alpha: 0.35),
                text:     NSColor(srgbRed: 0.24, green: 0.12, blue: 0.06, alpha: 1),
                textDim:  NSColor(srgbRed: 0.44, green: 0.24, blue: 0.14, alpha: 0.95))
        default:
            return Palette(
                skyTop:   NSColor(srgbRed: 0.06, green: 0.08, blue: 0.22, alpha: 1),
                skyBot:   NSColor(srgbRed: 0.14, green: 0.18, blue: 0.34, alpha: 1),
                star:     NSColor(srgbRed: 0.95, green: 0.96, blue: 1.00, alpha: 0.9),
                horizon:  NSColor(srgbRed: 0.55, green: 0.65, blue: 0.85, alpha: 0.25),
                text:     NSColor(srgbRed: 0.95, green: 0.97, blue: 1.00, alpha: 1),
                textDim:  NSColor(srgbRed: 0.72, green: 0.80, blue: 0.95, alpha: 0.90))
        }
    }

    // MARK: - Text primitives

    private func font(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    private func textWidth(_ s: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded()
    }

    private func drawTextBaselineMid(_ ctx: CGContext, _ s: String,
                                     font: NSFont, color: NSColor,
                                     x: CGFloat, midY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: attrs))
        let cap = font.capHeight > 0 ? font.capHeight : font.pointSize * 0.7
        let topY = midY - cap / 2 - (font.ascender - cap)
        let baselineY = topY + font.ascender
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
