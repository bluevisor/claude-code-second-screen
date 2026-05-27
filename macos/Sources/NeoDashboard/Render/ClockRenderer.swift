// Fullscreen clock — fallback layout the FrameLoop swaps in whenever the
// selected source reports no active session. Visually styled to match the
// rest of the dashboard: phosphor palette, JetBrains Mono digits, matrix
// rain background, scanlines + vignette + chromatic aberration on top.

import AppKit
import CoreGraphics
import CoreText
import Foundation

final class ClockRenderer: FrameRenderer, @unchecked Sendable {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let rain: RainPainter
    private let showRain: Bool
    private let crt = CRTPostProcessor()
    var lastCRTMs: Double { crt.lastProcessMs }
    /// Cached layer that holds every element that doesn't change between
    /// most frames — gradient, corner brackets, top strip date, bottom
    /// strip weather, status pill. Invalidated when `date` or `weather`
    /// strings change (~minutely and ~10 min respectively).
    private var staticLayer: (key: String, image: CGImage)?
    /// Reusable per-frame context. See MatrixRenderer for the COW note.
    /// The cached-static-layer context (in cachedStaticLayer) is left
    /// allocated fresh on each cache miss since misses happen once per
    /// minute, not per frame.
    private var renderCtx: CGContext?

    private lazy var vignetteGradient: CGGradient = {
        CGGradient(colorsSpace: colorSpace,
                   colors: [
                    NSColor.black.withAlphaComponent(0).cgColor,
                    NSColor.black.withAlphaComponent(0.42).cgColor,
                   ] as CFArray,
                   locations: [0, 1])!
    }()

    private lazy var scanlineImage: CGImage? = {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.30 * 0.78).cgColor)
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: 1))
            y += 2
        }
        return ctx.makeImage()
    }()

    init(size: CGSize = MatrixTheme.canvasSize, showRain: Bool = true) {
        self.size = size
        self.showRain = showRain
        self.rain = RainPainter(canvasSize: size, stepHz: 15)
    }

    func render(_ telemetry: Telemetry, blink: Double, now: Date,
                blackAlpha: Double = 0) -> CGImage? {
        if renderCtx == nil {
            renderCtx = CGContext(
                data: nil,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
        guard let ctx = renderCtx else { return nil }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // Lay down the cached static layer first — gradient, brackets,
        // date/weather strips. Cheap rect blit replaces 4–6 ms of draws.
        if let cached = cachedStaticLayer(now: now) {
            // `ctx` is already y-flipped for our screen-coord helpers, so
            // a naive `ctx.draw(image, in:)` would render the cache
            // upside-down. Flip once more locally to land it upright.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cached, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        // Rain animates, so draw it per-frame on top of the static layer.
        if showRain {
            rain.draw(into: ctx, now: now.timeIntervalSinceReferenceDate)
        }
        // Scanlines darken the backdrop + rain only — drawing the clock
        // digits after the scanline pass keeps the huge HH:MM glyphs from
        // being striped (matrix dashboard's smaller text still reads fine
        // with scanlines on top, but the clock face benefits from a clean
        // unbroken silhouette).
        drawScanlines(into: ctx, opacity: 0.78)
        drawClock(into: ctx, now: now, blink: blink)
        drawVignette(into: ctx, strength: 0.42)

        // Fade overlay before CRT — matches FrameLoop's old post-process
        // semantics but folded into the existing context.
        if blackAlpha > 0 {
            ctx.setFillColor(NSColor.black.withAlphaComponent(
                min(1, max(0, CGFloat(blackAlpha)))).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        guard let raw = ctx.makeImage() else { return nil }
        return crt.process(raw) ?? raw
    }

    /// Returns the cached background layer, rebuilding only when the
    /// date/weather text underneath it would change.
    private func cachedStaticLayer(now: Date) -> CGImage? {
        let dateKey = dateLabel(now: now)
        let weather = WeatherService.shared.summaryUppercased ?? "—"
        let key = "\(dateKey)|\(weather)"
        if let cached = staticLayer, cached.key == key { return cached.image }

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

        // Bake the same paint order minus the per-frame layers.
        let grad = CGGradient(colorsSpace: colorSpace,
            colors: [MatrixTheme.bgTop.cgColor, MatrixTheme.bgBot.cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: size.height),
                               options: [])
        drawCornerBrackets(into: ctx)
        drawTopStrip(into: ctx, dateLabel: dateKey)
        drawBottomStrip(into: ctx, weather: weather)

        guard let img = ctx.makeImage() else { return nil }
        staticLayer = (key, img)
        return img
    }

    private func dateLabel(now: Date) -> String {
        let weekday = MatrixTheme.weekday(now)
        return "\(weekday)  \(dateText(now))"
    }

    // MARK: - Background

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

    private func drawTopStrip(into ctx: CGContext, dateLabel: String) {
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
        let dw = stringWidth(dateLabel, font: font)
        _ = drawText(ctx, dateLabel, font: font, color: MatrixTheme.inkDim,
                     position: CGPoint(x: size.width - 36 - dw, y: y))
    }

    private func drawBottomStrip(into ctx: CGContext, weather: String) {
        let font = MatrixTheme.font(13)
        let tagFont = MatrixTheme.font(13, weight: .bold)
        // Mirror the top strip's 32px inset. `drawText` interprets `y` as
        // the cap-box top, so to put the cap-box bottom 32px above the
        // canvas bottom we shift up by one cap-height. `font.capHeight`
        // is well-defined for JBM Bold; the 0.7×pointSize fallback
        // covers any system-font fallback path.
        let cap = tagFont.capHeight > 0 ? tagFont.capHeight
                                        : tagFont.pointSize * 0.7
        let y = size.height - 32 - cap
        let tag = "▸ STANDBY"
        _ = drawText(ctx, tag, font: tagFont,
                     color: MatrixTheme.phosphor,
                     position: CGPoint(x: 36, y: y))
        let w = stringWidth(weather, font: font)
        _ = drawText(ctx, weather, font: font, color: MatrixTheme.inkDim,
                     position: CGPoint(x: size.width - 36 - w, y: y))
    }

    // MARK: - Clock

    private func drawClock(into ctx: CGContext, now: Date, blink: Double) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.hour, .minute, .second], from: now)
        let format = UserPrefs.timeFormat
        let hourPart: String
        switch format {
        case .h24: hourPart = String(format: "%02d", comps.hour ?? 0)
        case .h12: hourPart = String(((comps.hour ?? 0) + 11) % 12 + 1)
        }
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)
        let blinkOn = (comps.second ?? 0).isMultiple(of: 2)
        let colon = blinkOn ? ":" : " "

        // Fit-to-width: measure the full HH:MM:SS string at the
        // landscape-tuned reference size and shrink uniformly so the
        // hero fills ~95% of the canvas. Measure on the concatenated
        // string (not per-part) — per-part stringWidth rounds each
        // result individually and the accumulated error noticeably
        // undersized the result on the narrow portrait canvas. Don't
        // pre-round the scaled point size either; `MatrixTheme.font`
        // already rounds once after applying the fontScale.
        let parts = [hourPart, colon, mm, colon, ss]
        let referencePt: CGFloat = 150
        let marginFrac: CGFloat = 0.025
        let referenceFont = MatrixTheme.font(referencePt, weight: .heavy)
        let refTotal = stringWidth(parts.joined(), font: referenceFont)
        let targetW = size.width * (1 - 2 * marginFrac)
        let scale: CGFloat = refTotal > 0
            ? min(1, targetW / refTotal)
            : 1
        let bigFont = MatrixTheme.font(referencePt * scale, weight: .heavy)
        let widths = parts.map { stringWidth($0, font: bigFont) }
        let total = widths.reduce(0, +)
        var x = (size.width - total) / 2

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

        // Secondary label below — AM/PM in 12h mode, weekday otherwise.
        // Scale with the same factor as the main digits so the
        // sub-label and baseline gap track the hero proportions, with
        // a small floor for legibility.
        let subFont = MatrixTheme.font(max(10, 18 * scale), weight: .bold)
        let subGap: CGFloat = max(10, 32 * scale)
        let sub: String = {
            switch format {
            case .h12:
                let h12 = ((comps.hour ?? 0) + 11) % 12 + 1
                return String(format: "%02d:%02d %@", h12,
                              comps.minute ?? 0, amPm(now))
            case .h24:
                return MatrixTheme.weekday(now)
            }
        }()
        let sw = stringWidth(sub, font: subFont)
        _ = drawText(ctx, sub, font: subFont, color: MatrixTheme.inkFaint,
                     position: CGPoint(x: size.width / 2 - sw / 2,
                                       y: baselineY + subGap))
    }

    // MARK: - Scanlines / vignette

    private func drawScanlines(into ctx: CGContext, opacity: CGFloat) {
        _ = opacity
        guard let img = scanlineImage else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        ctx.restoreGState()
    }

    private func drawVignette(into ctx: CGContext, strength: CGFloat) {
        _ = strength
        let centerX = size.width / 2
        let centerY = size.height / 2
        let inner = min(size.width, size.height) * 0.32
        let outer = hypot(centerX, centerY) * 1.05
        ctx.drawRadialGradient(vignetteGradient,
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
