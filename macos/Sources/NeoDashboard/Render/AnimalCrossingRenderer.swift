// "Cozy" — Animal Crossing-inspired LCD layout. Independent of MatrixRenderer:
// own palette, hand-drawn icons, custom panel chrome. The renderer reads the
// shared `Telemetry` but translates it into friendly, decorative output.
//
// Canvas layout (1280×480):
//
//   ┌─ wood plank background w/ subtle grain ───────────────────────┐
//   │  ┌── cream paper card (double border, corner stars) ───────┐  │
//   │  │  HEADER STRIP                                            │ │
//   │  │   🍃  FRIDAY · MAY 22       ☀  6:51 PM       ✦ MAX 5×    │ │
//   │  │  ─────────── decorative dotted divider ─────────────     │ │
//   │  │  ┌─ FRIEND ─┐  ┌── speech bubble ──────────┐  ┌─ POLAR.  │ │
//   │  │  │  o   o   │  │ "Pondering…"              │  │ 11/27    │ │
//   │  │  │   ___    │  │  body text wraps cleanly  │  │ 🍃 47%   │ │
//   │  │  │   CLAUDE │  │  ...                      │  │ 💰 1.2M  │ │
//   │  │  └──────────┘  └───────────────────────────┘  └──────────┘ │
//   │  │  bottom strip: ~/path  •  🌱 main  •  SESS 3476-E339       │ │
//   │  └─────────────────────────────────────────────────────────┘  │
//   └─────────────────────────────────────────────────────────────┘

import AppKit
import CoreGraphics
import CoreText
import Foundation

final class AnimalCrossingRenderer: FrameRenderer, @unchecked Sendable {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var renderCtx: CGContext?
    private var clockCtx: CGContext?

    init(size: CGSize = CGSize(width: 1280, height: 480)) {
        self.size = size
    }

    private func ensureContext(_ ctx: inout CGContext?) -> CGContext? {
        if let ctx { return ctx }
        let new = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx = new
        return new
    }

    func render(_ tel: Telemetry, blink: Double, now: Date,
                blackAlpha: Double = 0) -> CGImage? {
        guard let ctx = ensureContext(&renderCtx) else { return nil }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let hour = Calendar.current.component(.hour, from: now)
        let palette = Palette.forHour(hour)

        drawWoodPlanks(ctx, palette: palette)
        drawScatter(ctx, palette: palette, phase: blink)

        // Inset paper card occupies almost the whole canvas.
        let margin: CGFloat = 18
        let cardRect = CGRect(x: margin, y: margin,
                              width: size.width - 2 * margin,
                              height: size.height - 2 * margin)
        drawPaperCard(ctx, rect: cardRect, palette: palette)
        drawCornerStars(ctx, rect: cardRect, palette: palette)

        let pad: CGFloat = 22
        let inner = cardRect.insetBy(dx: pad, dy: pad)

        // Header strip.
        let headerH: CGFloat = 60
        let headerRect = CGRect(x: inner.minX, y: inner.minY,
                                width: inner.width, height: headerH)
        drawHeader(ctx, rect: headerRect, palette: palette, now: now,
                   hour: hour, tel: tel)
        // Dotted divider below header.
        drawDottedDivider(ctx,
                          from: CGPoint(x: inner.minX, y: headerRect.maxY + 8),
                          to:   CGPoint(x: inner.maxX, y: headerRect.maxY + 8),
                          color: palette.dim)

        // Footer strip (location/branch/session) at the bottom of the card.
        let footerH: CGFloat = 28
        let footerRect = CGRect(x: inner.minX, y: inner.maxY - footerH,
                                width: inner.width, height: footerH)
        drawFooter(ctx, rect: footerRect, palette: palette, tel: tel)

        // Body area between header and footer.
        let bodyTop = headerRect.maxY + 22
        let bodyBot = footerRect.minY - 14
        let body = CGRect(x: inner.minX, y: bodyTop,
                          width: inner.width, height: bodyBot - bodyTop)

        // Three-column body: friend tile · speech bubble · stats column.
        let gap: CGFloat = 16
        let friendW: CGFloat = 200
        let statsW: CGFloat = 260
        let bubbleW = body.width - friendW - statsW - 2 * gap

        let friendRect = CGRect(x: body.minX, y: body.minY,
                                width: friendW, height: body.height)
        let bubbleRect = CGRect(x: friendRect.maxX + gap, y: body.minY,
                                width: bubbleW, height: body.height)
        let statsRect = CGRect(x: bubbleRect.maxX + gap, y: body.minY,
                               width: statsW, height: body.height)

        drawFriendTile(ctx, rect: friendRect, palette: palette,
                       tel: tel, blink: blink)
        drawSpeechBubble(ctx, rect: bubbleRect, palette: palette,
                         tailY: friendRect.midY)
        drawSpeechContent(ctx, rect: bubbleRect.insetBy(dx: 22, dy: 18),
                          palette: palette, tel: tel)
        drawStatsColumn(ctx, rect: statsRect, palette: palette, tel: tel)

        applyFade(into: ctx, alpha: blackAlpha)
        let img = ctx.makeImage()
        ctx.restoreGState()
        return img
    }

    /// Themed idle/clock view — keeps the wood plank backdrop and the
    /// cream paper card, swapping the body for a huge rounded HH:MM.
    func renderClock(blink: Double, now: Date, blackAlpha: Double = 0) -> CGImage? {
        guard let ctx = ensureContext(&clockCtx) else { return nil }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let hour = Calendar.current.component(.hour, from: now)
        let palette = Palette.forHour(hour)

        drawWoodPlanks(ctx, palette: palette)
        drawScatter(ctx, palette: palette, phase: blink)

        let margin: CGFloat = 18
        let cardRect = CGRect(x: margin, y: margin,
                              width: size.width - 2 * margin,
                              height: size.height - 2 * margin)
        drawPaperCard(ctx, rect: cardRect, palette: palette)
        drawCornerStars(ctx, rect: cardRect, palette: palette)

        let pad: CGFloat = 22
        let inner = cardRect.insetBy(dx: pad, dy: pad)

        // Header strip — same as the main dashboard.
        let headerH: CGFloat = 60
        let headerRect = CGRect(x: inner.minX, y: inner.minY,
                                width: inner.width, height: headerH)
        drawHeader(ctx, rect: headerRect, palette: palette, now: now,
                   hour: hour, tel: .empty())
        drawDottedDivider(ctx,
                          from: CGPoint(x: inner.minX, y: headerRect.maxY + 8),
                          to:   CGPoint(x: inner.maxX, y: headerRect.maxY + 8),
                          color: palette.dim)

        // Big clock filling the body.
        let blinkOn = Calendar.current
            .component(.second, from: now).isMultiple(of: 2)
        let timeStr = clockText(now)
        let ampm = amPm(now)

        let clockFont = roundedFont(160, weight: .heavy)
        // Keep the colon in the layout always; toggle its colour to clear
        // when the blink is off so the digits don't shift.
        let attr = NSMutableAttributedString(
            string: timeStr,
            attributes: [.font: clockFont, .foregroundColor: palette.text])
        if !blinkOn, let r = timeStr.range(of: ":") {
            attr.addAttribute(.foregroundColor, value: NSColor.clear,
                              range: NSRange(r, in: timeStr))
        }
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let bodyMid = (headerRect.maxY + inner.maxY) / 2
        let baselineY = bodyMid + (bounds.origin.y + bounds.height / 2)
        let x = (size.width - bounds.width) / 2
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()

        // "Napping" tag under the clock, AC-style.
        let napFont = roundedFont(18, weight: .semibold)
        let nap = ampm.isEmpty ? "💤  taking a nap"
                                : "💤  \(ampm) — taking a nap"
        let napW = textWidth(nap, font: napFont)
        textBaselineMid(ctx, nap, font: napFont, color: palette.dim,
                        x: size.width / 2 - napW / 2, midY: bodyMid + 110)

        applyFade(into: ctx, alpha: blackAlpha)
        let img = ctx.makeImage()
        ctx.restoreGState()
        return img
    }

    /// Translucent black overlay used by FrameLoop's fade transitions.
    /// No-op when `alpha == 0`.
    private func applyFade(into ctx: CGContext, alpha: Double) {
        guard alpha > 0 else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(
            min(1, max(0, CGFloat(alpha)))).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
    }

    // MARK: - Backdrop

    private func drawWoodPlanks(_ ctx: CGContext, palette: Palette) {
        let plankH: CGFloat = 64
        var y: CGFloat = 0
        var alt = false
        while y < size.height {
            ctx.setFillColor(alt ? palette.woodB.cgColor : palette.woodA.cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: plankH))
            // Plank seam line (slightly darker).
            ctx.setFillColor(palette.woodSeam.cgColor)
            ctx.fill(CGRect(x: 0, y: y + plankH - 1, width: size.width, height: 2))
            // Subtle grain ticks every 130px or so.
            ctx.setFillColor(palette.woodSeam.withAlphaComponent(0.35).cgColor)
            for x in stride(from: CGFloat(20), to: size.width, by: 130) {
                let dy = CGFloat(((Int(x) + Int(y)) % 3))
                ctx.fill(CGRect(x: x, y: y + 18 + dy, width: 38, height: 1))
                ctx.fill(CGRect(x: x + 60, y: y + 38 - dy, width: 24, height: 1))
            }
            y += plankH
            alt.toggle()
        }
    }

    private func drawScatter(_ ctx: CGContext, palette: Palette, phase: Double) {
        // A handful of tiny stars/leaves drifting across the wood.
        let drift = CGFloat(phase.truncatingRemainder(dividingBy: 30) / 30) * 16
        let spots: [(CGFloat, CGFloat, String)] = [
            (90,  40,  "star"), (200, 360, "leaf"), (1110, 60, "leaf"),
            (1060, 410, "star"), (640, 20, "star"), (40, 240, "leaf"),
        ]
        for (x, y, kind) in spots {
            let p = CGPoint(x: x + drift, y: y - drift / 2)
            if kind == "star" {
                drawStar(ctx, at: p, radius: 7,
                         color: palette.starSparkle.withAlphaComponent(0.55))
            } else {
                drawLeaf(ctx, at: p, size: 18,
                         color: palette.leaf.withAlphaComponent(0.55))
            }
        }
    }

    // MARK: - Paper card

    private func drawPaperCard(_ ctx: CGContext, rect: CGRect, palette: Palette) {
        // Outer shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14,
                      color: NSColor(srgbRed: 0.18, green: 0.12, blue: 0.06, alpha: 0.45).cgColor)
        ctx.setFillColor(palette.paper.cgColor)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24,
                           transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // Double border — dark outer, cream gap, dark inner.
        let outer = rect.insetBy(dx: 4, dy: 4)
        ctx.setStrokeColor(palette.borderDark.cgColor)
        ctx.setLineWidth(3)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 20, cornerHeight: 20,
                           transform: nil))
        ctx.strokePath()
        let inner = rect.insetBy(dx: 10, dy: 10)
        ctx.setStrokeColor(palette.borderDark.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 16, cornerHeight: 16,
                           transform: nil))
        ctx.strokePath()
    }

    private func drawCornerStars(_ ctx: CGContext, rect: CGRect, palette: Palette) {
        let inset: CGFloat = 24
        let corners = [
            CGPoint(x: rect.minX + inset, y: rect.minY + inset),
            CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
            CGPoint(x: rect.minX + inset, y: rect.maxY - inset),
            CGPoint(x: rect.maxX - inset, y: rect.maxY - inset),
        ]
        for c in corners {
            drawStar(ctx, at: c, radius: 7, color: palette.starAccent)
        }
    }

    // MARK: - Header

    private func drawHeader(_ ctx: CGContext, rect: CGRect,
                            palette: Palette, now: Date, hour: Int, tel: Telemetry) {
        // Left cluster: leaf + date.
        var x = rect.minX
        let leafY = rect.midY
        drawLeaf(ctx, at: CGPoint(x: x + 14, y: leafY), size: 28, color: palette.leaf)
        x += 36
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.weekday, .day, .month], from: now)
        let weekday = DateFormatter().weekdaySymbols[(comps.weekday ?? 1) - 1].uppercased()
        let monthName = DateFormatter().monthSymbols[(comps.month ?? 1) - 1]
        let dateText = "\(weekday) · \(monthName.uppercased()) \(comps.day ?? 0)"
        let dateFont = roundedFont(28, weight: .heavy)
        textBaselineMid(ctx, dateText, font: dateFont, color: palette.text,
                        x: x + 6, midY: rect.midY)

        // Right cluster: weather icon + clock + plan badge.
        var rx = rect.maxX
        let planFont = roundedFont(14, weight: .heavy)
        let planText = tel.quota.plan.uppercased()
        let planW = textWidth(planText, font: planFont) + 22
        let planRect = CGRect(x: rx - planW, y: rect.midY - 14, width: planW, height: 28)
        ctx.setFillColor(palette.accent.cgColor)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: planRect, cornerWidth: 14, cornerHeight: 14,
                           transform: nil))
        ctx.fillPath()
        textBaselineMid(ctx, planText, font: planFont, color: palette.paper,
                        x: planRect.minX + 11, midY: planRect.midY)
        rx -= planW + 18

        let clockFont = roundedFont(26, weight: .heavy)
        let clockText = timeText(for: now)
        let clockW = textWidth(clockText, font: clockFont)
        textBaselineMid(ctx, clockText, font: clockFont, color: palette.text,
                        x: rx - clockW, midY: rect.midY)
        rx -= clockW + 16

        drawWeatherIcon(ctx, at: CGPoint(x: rx - 14, y: rect.midY),
                        hour: hour, palette: palette)
    }

    private func timeText(for now: Date) -> String {
        let suffix = amPm(now)
        return suffix.isEmpty ? clockText(now) : "\(clockText(now)) \(suffix)"
    }

    // MARK: - Friend tile (avatar on a polaroid)

    private func drawFriendTile(_ ctx: CGContext, rect: CGRect,
                                palette: Palette, tel: Telemetry, blink: Double) {
        // Polaroid card.
        let card = rect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8,
                      color: NSColor(srgbRed: 0.15, green: 0.10, blue: 0.05, alpha: 0.30).cgColor)
        ctx.setFillColor(palette.polaroid.cgColor)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 14, cornerHeight: 14,
                           transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // Tape strip across the top corner.
        ctx.saveGState()
        ctx.translateBy(x: card.midX, y: card.minY)
        ctx.rotate(by: -.pi / 14)
        let tape = CGRect(x: -50, y: -8, width: 100, height: 18)
        ctx.setFillColor(palette.tape.cgColor)
        ctx.fill(tape)
        ctx.restoreGState()

        // Title.
        textBaselineMid(ctx, "TODAY'S FRIEND",
                        font: roundedFont(12, weight: .heavy),
                        color: palette.accent, x: card.minX + 16, midY: card.minY + 22)

        // Round avatar background.
        let avatarSize: CGFloat = 130
        let avatar = CGRect(x: card.midX - avatarSize / 2,
                            y: card.minY + 38,
                            width: avatarSize, height: avatarSize)
        ctx.setFillColor(palette.avatarBG.cgColor)
        ctx.fillEllipse(in: avatar)
        ctx.setStrokeColor(palette.borderDark.cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: avatar.insetBy(dx: 1.25, dy: 1.25))

        // Face overlay (eyes + mouth + leaf hat).
        drawFriendFace(ctx, rect: avatar, palette: palette,
                       status: tel.agent.status, blink: blink)

        // Name plate at the bottom.
        let nameY = avatar.maxY + 28
        let nameText = tel.agent.kind.uppercased().replacingOccurrences(of: "-", with: " ")
        let nameFont = roundedFont(18, weight: .heavy)
        let nameW = textWidth(nameText, font: nameFont)
        let plate = CGRect(x: card.midX - nameW / 2 - 14,
                           y: nameY - 14, width: nameW + 28, height: 26)
        ctx.setFillColor(palette.namePlate.cgColor)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 13, cornerHeight: 13,
                           transform: nil))
        ctx.fillPath()
        textBaselineMid(ctx, nameText, font: nameFont, color: palette.text,
                        x: plate.minX + 14, midY: plate.midY)
    }

    private func drawFriendFace(_ ctx: CGContext, rect: CGRect, palette: Palette,
                                status: AgentStatus, blink: Double) {
        let cx = rect.midX
        let cy = rect.midY
        // Leaf on top of the head.
        drawLeaf(ctx, at: CGPoint(x: cx + 12, y: rect.minY + 8),
                 size: 22, color: palette.leafBright)

        // Eyes — blink occasionally.
        let blinking = (blink.truncatingRemainder(dividingBy: 4.0)) < 0.18
        let eyeY = cy - 8
        let eyeDX: CGFloat = 18
        ctx.setFillColor(palette.text.cgColor)
        for sign in [CGFloat(-1), CGFloat(1)] {
            let center = CGPoint(x: cx + sign * eyeDX, y: eyeY)
            if blinking {
                ctx.fill(CGRect(x: center.x - 6, y: center.y - 1, width: 12, height: 2))
            } else {
                ctx.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 5,
                                            width: 8, height: 10))
            }
        }
        // Cheek blush.
        ctx.setFillColor(palette.blush.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 36, y: cy + 6, width: 14, height: 8))
        ctx.fillEllipse(in: CGRect(x: cx + 22, y: cy + 6, width: 14, height: 8))

        // Mouth — varies with status.
        ctx.setStrokeColor(palette.text.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        let mouthRect: CGRect
        switch status {
        case .error:
            // Sad mouth — frown.
            mouthRect = CGRect(x: cx - 14, y: cy + 18, width: 28, height: 14)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: mouthRect.minX, y: mouthRect.maxY))
            path.addQuadCurve(to: CGPoint(x: mouthRect.maxX, y: mouthRect.maxY),
                              control: CGPoint(x: mouthRect.midX, y: mouthRect.minY))
            ctx.addPath(path)
        case .idle:
            // Tiny line.
            ctx.move(to: CGPoint(x: cx - 8, y: cy + 22))
            ctx.addLine(to: CGPoint(x: cx + 8, y: cy + 22))
        default:
            // Smile.
            mouthRect = CGRect(x: cx - 16, y: cy + 12, width: 32, height: 14)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: mouthRect.minX, y: mouthRect.minY))
            path.addQuadCurve(to: CGPoint(x: mouthRect.maxX, y: mouthRect.minY),
                              control: CGPoint(x: mouthRect.midX, y: mouthRect.maxY + 4))
            ctx.addPath(path)
        }
        ctx.strokePath()
    }

    // MARK: - Speech bubble

    private func drawSpeechBubble(_ ctx: CGContext, rect: CGRect,
                                  palette: Palette, tailY: CGFloat) {
        // Drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8,
                      color: NSColor(srgbRed: 0.15, green: 0.10, blue: 0.05, alpha: 0.28).cgColor)
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: 20, cornerHeight: 20)
        // Tail pointing left.
        let tailH: CGFloat = 22
        let tx = rect.minX
        let ty = max(rect.minY + 30, min(rect.maxY - 30 - tailH, tailY - tailH / 2))
        path.move(to: CGPoint(x: tx, y: ty))
        path.addLine(to: CGPoint(x: tx - 18, y: ty + tailH / 2))
        path.addLine(to: CGPoint(x: tx, y: ty + tailH))
        path.closeSubpath()
        ctx.setFillColor(palette.bubble.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        // Outline.
        ctx.setStrokeColor(palette.borderDark.cgColor)
        ctx.setLineWidth(2.5)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawSpeechContent(_ ctx: CGContext, rect: CGRect,
                                   palette: Palette, tel: Telemetry) {
        let verb = friendlyVerb(for: tel.agent)
        let verbFont = roundedFont(34, weight: .heavy)
        // Verb baseline near the top.
        let verbY = rect.minY + 8
        let advance = drawTextTopLeft(ctx, verb, font: verbFont,
                                      color: palette.text,
                                      at: CGPoint(x: rect.minX, y: verbY),
                                      maxWidth: rect.width)
        // Decorative trailing accent (star) after the verb if there's room.
        let starX = rect.minX + advance + 16
        let starY = verbY + verbFont.capHeight / 2 + (verbFont.ascender - verbFont.capHeight)
        if starX + 18 < rect.maxX {
            drawStar(ctx, at: CGPoint(x: starX, y: starY),
                     radius: 9, color: palette.starAccent)
        }

        // Body paragraph.
        let body = tel.agent.currentTask.isEmpty
            ? "Just hanging out and watching the leaves drift by…"
            : tel.agent.currentTask
        let bodyFont = roundedFont(17, weight: .medium)
        let bodyTop = verbY + verbFont.ascender + 10
        drawWrapped(ctx, text: body, font: bodyFont, color: palette.dim,
                    x: rect.minX, y: bodyTop, maxWidth: rect.width,
                    maxLines: 4, lineHeight: 23)

        // Tool detail (if any) — small tag at the bottom-left.
        if let tool = tel.agent.currentTool {
            let tagY = rect.maxY - 24
            let tagText = "tool · \(tool)"
            let tagFont = roundedFont(12, weight: .heavy)
            let w = textWidth(tagText, font: tagFont) + 18
            let tag = CGRect(x: rect.minX, y: tagY, width: w, height: 22)
            ctx.setFillColor(palette.toolChip.cgColor)
            ctx.beginPath()
            ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 11, cornerHeight: 11,
                               transform: nil))
            ctx.fillPath()
            textBaselineMid(ctx, tagText, font: tagFont, color: palette.text,
                            x: tag.minX + 9, midY: tag.midY)
        }
    }

    // MARK: - Stats column

    private func drawStatsColumn(_ ctx: CGContext, rect: CGRect,
                                 palette: Palette, tel: Telemetry) {
        let gap: CGFloat = 12
        let cellH = (rect.height - 2 * gap) / 3
        let tiles = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cellH),
            CGRect(x: rect.minX, y: rect.minY + cellH + gap, width: rect.width, height: cellH),
            CGRect(x: rect.minX, y: rect.minY + 2 * (cellH + gap), width: rect.width, height: cellH),
        ]
        for (i, tile) in tiles.enumerated() {
            drawPolaroidTile(ctx, rect: tile, palette: palette, tiltSign: i % 2 == 0 ? -1 : 1)
        }
        drawActivityTile(ctx, rect: tiles[0], palette: palette, tel: tel)
        drawEnergyTile(ctx, rect: tiles[1], palette: palette, tel: tel)
        drawBellsTile(ctx, rect: tiles[2], palette: palette, tel: tel)
    }

    private func drawPolaroidTile(_ ctx: CGContext, rect: CGRect,
                                  palette: Palette, tiltSign: Int) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6,
                      color: NSColor(srgbRed: 0.10, green: 0.06, blue: 0.02, alpha: 0.28).cgColor)
        ctx.setFillColor(palette.tile.cgColor)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12,
                           transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(palette.borderDark.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                           cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.strokePath()
        // Tiny tilted tape strip at the top.
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.minY)
        ctx.rotate(by: .pi / 16 * CGFloat(tiltSign))
        ctx.setFillColor(palette.tape.cgColor)
        ctx.fill(CGRect(x: -28, y: -6, width: 56, height: 12))
        ctx.restoreGState()
    }

    private func drawActivityTile(_ ctx: CGContext, rect: CGRect,
                                  palette: Palette, tel: Telemetry) {
        let pad: CGFloat = 14
        textBaselineMid(ctx, "TODAY'S ACTIVITY",
                        font: roundedFont(11, weight: .heavy),
                        color: palette.accent,
                        x: rect.minX + pad, midY: rect.minY + 18)
        // Big stat: tools read/edit.
        let read = "\(tel.agent.filesRead)"
        let write = "\(tel.agent.filesEdited)"
        let bigFont = roundedFont(28, weight: .heavy)
        let smallFont = roundedFont(13, weight: .medium)
        let lineY = rect.midY - 2
        let rw = textWidth(read, font: bigFont)
        let ww = textWidth(write, font: bigFont)
        let labelR = "read", labelW = "write"
        let labelRw = textWidth(labelR, font: smallFont)
        let labelWw = textWidth(labelW, font: smallFont)
        let total = rw + 4 + labelRw + 14 + ww + 4 + labelWw
        var x = rect.midX - total / 2
        textBaselineMid(ctx, read, font: bigFont, color: palette.text,
                        x: x, midY: lineY)
        x += rw + 4
        textBaselineMid(ctx, labelR, font: smallFont, color: palette.dim,
                        x: x, midY: lineY + 4)
        x += labelRw + 14
        textBaselineMid(ctx, write, font: bigFont, color: palette.text,
                        x: x, midY: lineY)
        x += ww + 4
        textBaselineMid(ctx, labelW, font: smallFont, color: palette.dim,
                        x: x, midY: lineY + 4)

        // Sub: turns / session length.
        let elapsed = Int(Date.now.timeIntervalSince(tel.agent.startedAt))
        let sub = "\(tel.agent.turn) turn\(tel.agent.turn == 1 ? "" : "s") · \(prettyDuration(elapsed))"
        let subFont = roundedFont(12, weight: .regular)
        let subW = textWidth(sub, font: subFont)
        textBaselineMid(ctx, sub, font: subFont, color: palette.dim,
                        x: rect.midX - subW / 2, midY: rect.maxY - 14)
    }

    private func drawEnergyTile(_ ctx: CGContext, rect: CGRect,
                                palette: Palette, tel: Telemetry) {
        let pad: CGFloat = 14
        textBaselineMid(ctx, "ENERGY (5H)",
                        font: roundedFont(11, weight: .heavy),
                        color: palette.accent,
                        x: rect.minX + pad, midY: rect.minY + 18)
        let w = tel.quota.windows.first
        let pct = max(0, min(1, (w?.used ?? 0) / max(w?.cap ?? 1, 1)))
        // 8 leaf pips.
        let pips = 8
        let pipSize: CGFloat = 18
        let pipGap: CGFloat = 6
        let totalW = CGFloat(pips) * pipSize + CGFloat(pips - 1) * pipGap
        let startX = rect.midX - totalW / 2
        let pipY = rect.midY - 3
        for i in 0..<pips {
            let lit = Double(i) / Double(pips) < pct
            let cx = startX + CGFloat(i) * (pipSize + pipGap) + pipSize / 2
            drawLeaf(ctx, at: CGPoint(x: cx, y: pipY),
                     size: pipSize, color: lit ? palette.leafBright : palette.dim.withAlphaComponent(0.30))
        }
        // Sub: "47% used · resets in 4h 58m"
        let sub = String(format: "%.0f%% used · resets in %@",
                         pct * 100, prettyDuration(w?.resetInSec ?? 0))
        let subFont = roundedFont(12, weight: .regular)
        let subW = textWidth(sub, font: subFont)
        textBaselineMid(ctx, sub, font: subFont, color: palette.dim,
                        x: rect.midX - subW / 2, midY: rect.maxY - 14)
    }

    private func drawBellsTile(_ ctx: CGContext, rect: CGRect,
                               palette: Palette, tel: Telemetry) {
        let pad: CGFloat = 14
        textBaselineMid(ctx, "BELLS USED",
                        font: roundedFont(11, weight: .heavy),
                        color: palette.accent,
                        x: rect.minX + pad, midY: rect.minY + 18)
        // Big bell icon + token count.
        let bellY = rect.midY - 3
        drawBell(ctx, at: CGPoint(x: rect.minX + pad + 18, y: bellY),
                 size: 32, palette: palette)
        let total = tel.model.inputTokens + tel.model.outputTokens
            + tel.model.cacheReadTokens + tel.model.cacheWriteTokens
        let bigText = fmtTokens(total)
        let bigFont = roundedFont(28, weight: .heavy)
        textBaselineMid(ctx, bigText, font: bigFont, color: palette.text,
                        x: rect.minX + pad + 44, midY: bellY)
        // Sub: model name.
        let sub = "with \(tel.model.name)"
        let subFont = roundedFont(12, weight: .regular)
        let subW = textWidth(sub, font: subFont)
        textBaselineMid(ctx, sub, font: subFont, color: palette.dim,
                        x: rect.midX - subW / 2, midY: rect.maxY - 14)
    }

    // MARK: - Footer

    private func drawFooter(_ ctx: CGContext, rect: CGRect, palette: Palette, tel: Telemetry) {
        let font = roundedFont(13, weight: .semibold)
        var x = rect.minX
        // Folder icon + path
        drawFolder(ctx, at: CGPoint(x: x + 8, y: rect.midY), color: palette.text)
        x += 22
        let pathText = tel.agent.cwd
        textBaselineMid(ctx, pathText, font: font, color: palette.text,
                        x: x, midY: rect.midY)
        x += textWidth(pathText, font: font) + 16
        textBaselineMid(ctx, "•", font: font, color: palette.dim,
                        x: x, midY: rect.midY)
        x += textWidth("•", font: font) + 12
        if !tel.agent.gitBranch.isEmpty {
            drawLeaf(ctx, at: CGPoint(x: x + 6, y: rect.midY),
                     size: 18, color: palette.leafBright)
            x += 18
            let branch = "\(tel.agent.gitBranch)\(tel.agent.gitDirty ? "•" : "")"
            textBaselineMid(ctx, branch, font: font, color: palette.text,
                            x: x, midY: rect.midY)
            x += textWidth(branch, font: font) + 16
            textBaselineMid(ctx, "•", font: font, color: palette.dim,
                            x: x, midY: rect.midY)
            x += textWidth("•", font: font) + 12
        }
        let sess = "SESS \(tel.agent.sessionID)"
        textBaselineMid(ctx, sess, font: font, color: palette.dim,
                        x: x, midY: rect.midY)

        // Right side: turn count + verb.
        let verb = friendlyVerb(for: tel.agent)
        let rText = "▶ \(verb)"
        let rw = textWidth(rText, font: font)
        textBaselineMid(ctx, rText, font: font, color: palette.accent,
                        x: rect.maxX - rw, midY: rect.midY)
    }

    // MARK: - Icon primitives

    private func drawStar(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat, color: NSColor) {
        let path = CGMutablePath()
        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let rad = i % 2 == 0 ? r : r * 0.45
            let p = CGPoint(x: c.x + cos(angle) * rad, y: c.y + sin(angle) * rad)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path); ctx.fillPath()
    }

    private func drawLeaf(_ ctx: CGContext, at c: CGPoint, size s: CGFloat, color: NSColor) {
        // Almond-shape leaf with a center vein.
        let w = s
        let h = s * 1.4
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y - h / 2))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + h / 2),
                          control: CGPoint(x: c.x + w / 2 + 4, y: c.y))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h / 2),
                          control: CGPoint(x: c.x - w / 2 - 4, y: c.y))
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path); ctx.fillPath()
        // Vein.
        ctx.setStrokeColor(color.shadow(withLevel: 0.35)?.cgColor ?? color.cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: c.x, y: c.y - h / 2))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + h / 2))
        ctx.strokePath()
    }

    private func drawBell(_ ctx: CGContext, at c: CGPoint, size s: CGFloat, palette: Palette) {
        // Round bell with a small loop on top, body shaded.
        let r = s / 2
        ctx.setFillColor(palette.bellGold.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: s, height: s))
        // Loop
        ctx.setStrokeColor(palette.bellGold.shadow(withLevel: 0.4)?.cgColor ?? palette.bellGold.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: c.x - 4, y: c.y - r - 6, width: 8, height: 6))
        // Center sparkle.
        ctx.setFillColor(palette.bellSparkle.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 4, width: 6, height: 6))
    }

    private func drawFolder(_ ctx: CGContext, at c: CGPoint, color: NSColor) {
        let w: CGFloat = 16, h: CGFloat = 12
        let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        ctx.setFillColor(color.cgColor)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 4))
        path.addLine(to: CGPoint(x: rect.minX + 5, y: rect.minY + 4))
        path.addLine(to: CGPoint(x: rect.minX + 7, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        ctx.addPath(path); ctx.fillPath()
    }

    private func drawWeatherIcon(_ ctx: CGContext, at c: CGPoint, hour: Int, palette: Palette) {
        if (6..<18).contains(hour) {
            // Sun with rays.
            let r: CGFloat = 14
            ctx.setFillColor(palette.sun.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(palette.sun.cgColor)
            ctx.setLineWidth(2.5)
            ctx.setLineCap(.round)
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                let p1 = CGPoint(x: c.x + cos(a) * (r + 4), y: c.y + sin(a) * (r + 4))
                let p2 = CGPoint(x: c.x + cos(a) * (r + 10), y: c.y + sin(a) * (r + 10))
                ctx.move(to: p1); ctx.addLine(to: p2)
            }
            ctx.strokePath()
        } else {
            // Crescent moon.
            let r: CGFloat = 16
            ctx.saveGState()
            ctx.setFillColor(palette.moon.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setBlendMode(.destinationOut)
            ctx.fillEllipse(in: CGRect(x: c.x - r + 6, y: c.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
            // Tiny star next to it.
            drawStar(ctx, at: CGPoint(x: c.x + 14, y: c.y - 14), radius: 4,
                     color: palette.starAccent)
        }
    }

    private func drawDottedDivider(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, color: NSColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [2, 6])
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Text primitives

    /// Mirrors `MatrixTheme.fontScale` — one knob to nudge every glyph in
    /// the Cozy dashboard at once.
    private static let fontScale: CGFloat = 1.10

    private func roundedFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let scaled = (size * Self.fontScale).rounded()
        let base = NSFont.systemFont(ofSize: scaled, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: scaled) ?? base
    }

    /// Draw text where `(x, y)` is the top-left of the cap-box.
    /// Returns the typographic advance width.
    @discardableResult
    private func drawTextTopLeft(_ ctx: CGContext, _ s: String, font: NSFont,
                                 color: NSColor, at pos: CGPoint,
                                 maxWidth: CGFloat? = nil) -> CGFloat {
        let drawn = (maxWidth.map { ellipsize(s, font: font, maxWidth: $0) }) ?? s
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: drawn, attributes: attrs))
        let baselineY = pos.y + font.ascender
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: pos.x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded()
    }

    /// Draw text whose visual vertical center sits at `midY`.
    private func textBaselineMid(_ ctx: CGContext, _ s: String, font: NSFont,
                                 color: NSColor, x: CGFloat, midY: CGFloat,
                                 maxWidth: CGFloat? = nil) {
        let cap = font.capHeight > 0 ? font.capHeight : font.pointSize * 0.7
        let topY = midY - cap / 2 - (font.ascender - cap)
        drawTextTopLeft(ctx, s, font: font, color: color,
                        at: CGPoint(x: x, y: topY), maxWidth: maxWidth)
    }

    private func textWidth(_ s: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded()
    }

    private func ellipsize(_ s: String, font: NSFont, maxWidth: CGFloat) -> String {
        if textWidth(s, font: font) <= maxWidth { return s }
        var out = s
        let ell = "…"
        while !out.isEmpty, textWidth(out + ell, font: font) > maxWidth {
            out.removeLast()
        }
        return out + ell
    }

    private func drawWrapped(_ ctx: CGContext, text: String, font: NSFont,
                             color: NSColor, x: CGFloat, y: CGFloat,
                             maxWidth: CGFloat, maxLines: Int, lineHeight: CGFloat) {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var lines: [String] = []
        var cur = ""
        for w in words {
            let candidate = cur.isEmpty ? w : cur + " " + w
            if textWidth(candidate, font: font) <= maxWidth {
                cur = candidate
            } else {
                if !cur.isEmpty { lines.append(cur) }
                if lines.count >= maxLines - 1 { cur = w; break }
                cur = w
            }
        }
        if !cur.isEmpty, lines.count < maxLines { lines.append(cur) }
        if lines.count == maxLines, let last = lines.last,
           textWidth(last, font: font) > maxWidth {
            lines[lines.count - 1] = ellipsize(last, font: font, maxWidth: maxWidth)
        }
        for (i, line) in lines.enumerated() {
            drawTextTopLeft(ctx, line, font: font, color: color,
                            at: CGPoint(x: x, y: y + CGFloat(i) * lineHeight))
        }
    }

    // MARK: - Friendly copy

    private func friendlyVerb(for a: Agent) -> String {
        switch a.status {
        case .idle: return "Napping…"
        case .waiting: return "Waiting on you!"
        case .processing: return "Listening…"
        case .thinking: return "Pondering…"
        case .writing: return "Writing…"
        case .error: return "Oh, dear…"
        case .tool:
            if let t = a.currentTool { return "Using \(t)…" }
            return "Tinkering…"
        }
    }

    private func prettyDuration(_ secs: Int) -> String {
        let s = max(0, secs)
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02dm", (s % 3600) / 60))" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    private func fmtTokens(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return "\(Int(n))"
    }
}

// MARK: - Palette (time-of-day aware)

private struct Palette {
    let woodA: NSColor          // plank base
    let woodB: NSColor          // alternating plank
    let woodSeam: NSColor       // dark line between planks

    let paper: NSColor          // main card
    let borderDark: NSColor

    let polaroid: NSColor       // friend tile bg
    let tile: NSColor           // small stat tiles
    let tape: NSColor           // cute washi-tape accent
    let bubble: NSColor
    let namePlate: NSColor
    let avatarBG: NSColor
    let toolChip: NSColor

    let text: NSColor
    let dim: NSColor
    let accent: NSColor

    let leaf: NSColor           // muted
    let leafBright: NSColor     // saturated
    let blush: NSColor
    let starAccent: NSColor
    let starSparkle: NSColor
    let bellGold: NSColor
    let bellSparkle: NSColor
    let sun: NSColor
    let moon: NSColor

    static func forHour(_ h: Int) -> Palette {
        let warm = h >= 5 && h < 18
        return Palette(
            woodA:       NSColor(srgbRed: warm ? 0.84 : 0.42, green: warm ? 0.66 : 0.32, blue: warm ? 0.42 : 0.22, alpha: 1),
            woodB:       NSColor(srgbRed: warm ? 0.78 : 0.36, green: warm ? 0.60 : 0.27, blue: warm ? 0.37 : 0.18, alpha: 1),
            woodSeam:    NSColor(srgbRed: warm ? 0.38 : 0.14, green: warm ? 0.24 : 0.09, blue: warm ? 0.14 : 0.05, alpha: 1),

            paper:       NSColor(srgbRed: 1.00, green: 0.97, blue: 0.91, alpha: 0.98),
            borderDark:  NSColor(srgbRed: 0.42, green: 0.28, blue: 0.16, alpha: 1.00),

            polaroid:    NSColor(srgbRed: 1.00, green: 0.99, blue: 0.96, alpha: 1),
            tile:        NSColor(srgbRed: 1.00, green: 0.98, blue: 0.93, alpha: 1),
            tape:        NSColor(srgbRed: 0.99, green: 0.83, blue: 0.55, alpha: 0.85),
            bubble:      NSColor(srgbRed: 1.00, green: 0.99, blue: 0.95, alpha: 1),
            namePlate:   NSColor(srgbRed: 0.98, green: 0.86, blue: 0.55, alpha: 1),
            avatarBG:    NSColor(srgbRed: 0.99, green: 0.92, blue: 0.78, alpha: 1),
            toolChip:    NSColor(srgbRed: 0.86, green: 0.92, blue: 0.78, alpha: 1),

            text:        NSColor(srgbRed: 0.32, green: 0.21, blue: 0.10, alpha: 1),
            dim:         NSColor(srgbRed: 0.50, green: 0.38, blue: 0.26, alpha: 1),
            accent:      NSColor(srgbRed: 0.84, green: 0.34, blue: 0.20, alpha: 1),

            leaf:        NSColor(srgbRed: 0.45, green: 0.65, blue: 0.36, alpha: 1),
            leafBright:  NSColor(srgbRed: 0.46, green: 0.74, blue: 0.32, alpha: 1),
            blush:       NSColor(srgbRed: 0.96, green: 0.62, blue: 0.62, alpha: 0.85),
            starAccent:  NSColor(srgbRed: 1.00, green: 0.78, blue: 0.32, alpha: 1),
            starSparkle: NSColor(srgbRed: 1.00, green: 0.96, blue: 0.78, alpha: 1),
            bellGold:    NSColor(srgbRed: 0.96, green: 0.72, blue: 0.16, alpha: 1),
            bellSparkle: NSColor(srgbRed: 1.00, green: 0.97, blue: 0.85, alpha: 1),
            sun:         NSColor(srgbRed: 1.00, green: 0.82, blue: 0.32, alpha: 1),
            moon:        NSColor(srgbRed: 0.98, green: 0.95, blue: 0.86, alpha: 1)
        )
    }
}
