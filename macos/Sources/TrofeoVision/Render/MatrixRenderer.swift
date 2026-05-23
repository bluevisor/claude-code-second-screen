// Matrix theme renderer — 1280×480 CGContext painter.
//
// Mirrors `agent_dashboard/themes/matrix.py` with the same panel layout:
//
//     [rail (chips + date)]
//     [agent 400] [model flex] [quota 400 / sub-agents 400]
//     [footer (stats · clock · tz)]
//
// Drawing model: we use a Core Graphics bitmap context the size of the
// canvas. Core Text handles text. Layout math (paddings, gaps, cell sizes)
// is copied 1:1 from the Python source so the visual matches.

import AppKit
import CoreGraphics
import CoreText
import Foundation

final class MatrixRenderer {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var staticBackground: CGImage?
    private let rain: RainPainter
    private let showRain: Bool

    init(size: CGSize = MatrixTheme.canvasSize,
         showRain: Bool = true,
         rainFPS: Double = 12) {
        self.size = size
        self.showRain = showRain
        self.rain = RainPainter(canvasSize: size, stepHz: rainFPS)
    }

    /// Render one frame and return the resulting CGImage. `blink` is a
    /// monotonically-increasing phase used for the caret + scan animations.
    func render(_ tel: Telemetry, blink: Double, now: Date) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // CGContext y-axis points up. We work in "screen coords" (y-down),
        // so flip the CTM once and stay there.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        drawBackground(into: ctx, now: now)

        // 18 px outer padding; rail 34; gaps 10/8; footer 38.
        let padX: CGFloat = 18
        let padTop: CGFloat = 12
        let padBot: CGFloat = 12
        let railH: CGFloat = 34
        let footerH: CGFloat = 38
        let gapAbove: CGFloat = 10
        let gapBelow: CGFloat = 8
        let frameW = size.width - 2 * padX
        let mainH = size.height - padTop - padBot - railH - footerH - gapAbove - gapBelow
        let railRect = CGRect(x: padX, y: padTop, width: frameW, height: railH)
        let mainTop = padTop + railH + gapAbove
        let mainRect = CGRect(x: padX, y: mainTop, width: frameW, height: mainH)
        let footerRect = CGRect(x: padX, y: mainTop + mainH + gapBelow,
                                width: frameW, height: footerH)

        let gap: CGFloat = 14
        let colL: CGFloat = 400
        let colR: CGFloat = 400
        let colM = frameW - colL - colR - 2 * gap
        let agentRect = CGRect(x: mainRect.minX, y: mainRect.minY, width: colL, height: mainH)
        let modelRect = CGRect(x: mainRect.minX + colL + gap, y: mainRect.minY,
                               width: colM, height: mainH)
        let rightX = mainRect.maxX - colR + 1
        let quotaH: CGFloat = 158
        let vGap: CGFloat = 8
        let quotaRect = CGRect(x: rightX, y: mainRect.minY, width: colR, height: quotaH)
        let subsRect = CGRect(x: rightX, y: mainRect.minY + quotaH + vGap,
                              width: colR, height: mainH - quotaH - vGap)

        drawRail(into: ctx, rect: railRect, tel: tel, now: now)
        drawPanel(ctx, rect: agentRect)
        drawAgentPanel(into: ctx, rect: agentRect, tel: tel, blink: blink)
        drawPanel(ctx, rect: modelRect)
        drawModelPanel(into: ctx, rect: modelRect, tel: tel)
        drawPanel(ctx, rect: quotaRect)
        drawQuotaPanel(into: ctx, rect: quotaRect, tel: tel)
        drawPanel(ctx, rect: subsRect)
        drawSubAgentsPanel(into: ctx, rect: subsRect, tel: tel)
        drawFooter(into: ctx, rect: footerRect, tel: tel, now: now)

        drawScanlines(into: ctx, opacity: 0.55)

        return ctx.makeImage()
    }

    // MARK: - Background

    private func drawBackground(into ctx: CGContext, now: Date) {
        let rect = CGRect(origin: .zero, size: size)
        // Vertical phosphor gradient.
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

    private func drawScanlines(into ctx: CGContext, opacity: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.22 * opacity).cgColor)
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: 1))
            y += 2
        }
        ctx.restoreGState()
    }

    // MARK: - Panel chrome

    private func drawPanel(_ ctx: CGContext, rect: CGRect) {
        // Translucent background gradient.
        let bgGrad = CGGradient(colorsSpace: colorSpace,
            colors: [
                NSColor(srgbRed: 8/255.0, green: 22/255.0, blue: 18/255.0, alpha: 0.97).cgColor,
                NSColor(srgbRed: 4/255.0, green: 12/255.0, blue: 10/255.0, alpha: 0.94).cgColor,
            ] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addRect(rect); ctx.clip()
        ctx.drawLinearGradient(bgGrad,
                               start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.minX, y: rect.maxY),
                               options: [])
        // Subtle inner phosphor sheen.
        let sheen = CGGradient(colorsSpace: colorSpace,
            colors: [
                NSColor(srgbRed: 41/255.0, green: 255/255.0, blue: 140/255.0, alpha: 12/255.0).cgColor,
                NSColor.black.withAlphaComponent(0).cgColor,
            ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen,
                               start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.maxX, y: rect.maxY),
                               options: [])
        ctx.restoreGState()

        // Border.
        ctx.setStrokeColor(MatrixTheme.panelBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

        // Corner brackets.
        ctx.setStrokeColor(MatrixTheme.phosphor.cgColor)
        ctx.setLineWidth(1)
        let L: CGFloat = 10
        // TL
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.minX + L, y: rect.minY))
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.minY + L))
        // TR
        ctx.move(to: CGPoint(x: rect.maxX - L, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + L))
        // BL
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY - L))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.minX + L, y: rect.maxY))
        // BR
        ctx.move(to: CGPoint(x: rect.maxX - L, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.maxY - L))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.strokePath()
    }

    // MARK: - Rail

    private func drawRail(into ctx: CGContext, rect: CGRect, tel: Telemetry, now: Date) {
        let chipTop = rect.minY + 6
        let chipH: CGFloat = 22
        let rowMid = chipTop + chipH / 2

        let labelFont = MatrixTheme.font(13, weight: .bold)
        let sessFont = MatrixTheme.font(11)
        let dateFont = MatrixTheme.font(12, weight: .bold)

        let ledColor: NSColor = {
            switch tel.agent.status {
            case .error: return MatrixTheme.magenta
            case .idle:  return MatrixTheme.amber
            default:     return MatrixTheme.phosphor
            }
        }()
        var cx = rect.minX
        ctx.setFillColor(ledColor.withAlphaComponent(0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 4, y: rowMid - 9, width: 18, height: 18))
        ctx.setFillColor(ledColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx, y: rowMid - 5, width: 10, height: 10))
        cx += 22

        let label = tel.agent.kind.uppercased().replacingOccurrences(of: "-", with: " ")
        let advLabel = drawText(ctx, label, font: labelFont, color: MatrixTheme.ink,
                                position: capTopOrigin(rowMid: rowMid, font: labelFont, x: cx))
        cx += advLabel + 12

        cx += drawChip(ctx, x: cx, y: chipTop, text: tel.agent.cwd) + 8
        let branchText = tel.agent.gitBranch.isEmpty ? ""
            : "⎇ \(tel.agent.gitBranch)\(tel.agent.gitDirty ? "●" : "")"
        if !branchText.isEmpty {
            cx += drawChip(ctx, x: cx, y: chipTop, text: branchText) + 8
        }

        let sess = "SESS \(tel.agent.sessionID)"
        cx += drawText(ctx, sess, font: sessFont, color: MatrixTheme.inkFaint,
                       position: capTopOrigin(rowMid: rowMid, font: sessFont, x: cx)) + 12

        // Right side — weekday + date.
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.weekday, .day, .month, .year], from: now)
        let weekdayStr: String = {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: now).uppercased()
        }()
        let dateText = String(format: "%@  %02d.%02d.%04d", weekdayStr,
                              comps.month ?? 0, comps.day ?? 0, comps.year ?? 0)
        let dateWidth = stringWidth(dateText, font: dateFont)
        let dateX = rect.maxX - dateWidth
        _ = drawText(ctx, dateText, font: dateFont, color: MatrixTheme.inkDim,
                     position: capTopOrigin(rowMid: rowMid, font: dateFont, x: dateX))

        // Separator gradient between left cluster and date.
        let sepLeft = cx + 4
        let sepRight = dateX - 12
        if sepRight > sepLeft {
            let sepGrad = CGGradient(colorsSpace: colorSpace,
                colors: [
                    MatrixTheme.phosphor.withAlphaComponent(0).cgColor,
                    MatrixTheme.phosphor.withAlphaComponent(0.30).cgColor,
                    MatrixTheme.phosphor.withAlphaComponent(0).cgColor,
                ] as CFArray, locations: [0, 0.5, 1])!
            ctx.saveGState()
            ctx.addRect(CGRect(x: sepLeft, y: rowMid, width: sepRight - sepLeft, height: 1))
            ctx.clip()
            ctx.drawLinearGradient(sepGrad,
                                   start: CGPoint(x: sepLeft, y: rowMid),
                                   end: CGPoint(x: sepRight, y: rowMid),
                                   options: [])
            ctx.restoreGState()
        }
    }

    // MARK: - Agent panel

    private func drawAgentPanel(into ctx: CGContext, rect: CGRect, tel: Telemetry, blink: Double) {
        var cx = rect.minX + 16
        var cy = rect.minY + 14

        // Title.
        _ = drawText(ctx, "▸ AGENT", font: MatrixTheme.font(12, weight: .bold),
                     color: MatrixTheme.phosphor, position: CGPoint(x: cx, y: cy))
        // Meta right-aligned.
        let dur = Int(Date.now.timeIntervalSince(tel.agent.startedAt))
        let meta = "T\(tel.agent.turn) · \(fmtDur(dur)) · \(tel.agent.filesRead)R/\(tel.agent.filesEdited)W"
        let metaFont = MatrixTheme.font(10)
        let mw = stringWidth(meta, font: metaFont)
        _ = drawText(ctx, meta, font: metaFont, color: MatrixTheme.inkFaint,
                     position: CGPoint(x: rect.maxX - 16 - mw, y: cy + 2))
        cy += 24

        // Status verb.
        let verb: String = {
            if tel.agent.status == .tool, let t = tel.agent.currentTool,
               let v = MatrixTheme.toolVerbs[t] { return v }
            if tel.agent.status == .waiting { return "Waiting Input…" }
            return MatrixTheme.statusVerbs[tel.agent.status] ?? "—"
        }()
        let verbFont = MatrixTheme.font(34, weight: .heavy)
        let verbAdv = drawText(ctx, verb, font: verbFont, color: MatrixTheme.phosphor,
                               position: CGPoint(x: cx, y: cy))
        // Caret.
        if tel.agent.status != .idle, tel.agent.status != .waiting,
           (blink.truncatingRemainder(dividingBy: 1)) < 0.5 {
            let capH: CGFloat = max(18, capHeight(of: verbFont))
            let topY = cy + verbFont.ascender - capH
            let caret = CGRect(x: cx + verbAdv + 6, y: topY, width: 13, height: capH)
            ctx.setFillColor(MatrixTheme.phosphor.cgColor)
            ctx.fill(caret)
        }
        cy += 52

        // Current task (wrapped, 40% panel area).
        let promptAreaH = rect.height * 0.40
        let promptTop = cy
        let padY: CGFloat = 8
        let padX: CGFloat = 6
        let taskFont = MatrixTheme.font(12)
        let lineH: CGFloat = 17
        let bodyX = cx + padX + 14
        let maxW = rect.maxX - 16 - padX - bodyX
        _ = drawText(ctx, "▸", font: MatrixTheme.font(12, weight: .bold),
                     color: MatrixTheme.phosphor,
                     position: CGPoint(x: cx + padX, y: cy + padY))
        let contentH = max(lineH, promptAreaH - 2 * padY)
        let maxLines = max(2, Int(contentH / lineH))
        drawWrappedText(ctx, text: tel.agent.currentTask.isEmpty ? "—" : tel.agent.currentTask,
                        font: taskFont, color: MatrixTheme.ink,
                        x: bodyX, y: cy + padY, maxW: maxW, maxLines: maxLines, lineH: lineH)
        cy = promptTop + promptAreaH

        // Detail line.
        var detailParts: [String] = []
        if let t = tel.agent.currentTool { detailParts.append("\(t)( … )") }
        detailParts.append(tel.agent.detail)
        let detail = detailParts.joined(separator: "  ")
        let detailFont = MatrixTheme.font(11)
        _ = drawText(ctx, elide(detail, font: detailFont, maxW: maxW),
                     font: detailFont, color: MatrixTheme.inkFaint,
                     position: CGPoint(x: bodyX, y: cy))
        cy += 22

        // Log rows.
        let logAreaTop = cy
        let logAreaBot = rect.maxY - 12
        let rowH: CGFloat = 15
        let maxRows = max(0, Int((logAreaBot - logAreaTop) / rowH))
        for (i, row) in tel.agent.log.prefix(maxRows).enumerated() {
            let ry = logAreaTop + CGFloat(i) * rowH
            let tsFont = MatrixTheme.font(10)
            _ = drawText(ctx, row.ts, font: tsFont, color: MatrixTheme.inkFaint,
                         position: CGPoint(x: cx, y: ry))
            let tagColor: NSColor = {
                switch row.tag {
                case .ok: return MatrixTheme.phosphor
                case .warn: return MatrixTheme.amber
                case .err: return MatrixTheme.magenta
                case .info: return MatrixTheme.cyan
                }
            }()
            let tagGlyph: String = {
                switch row.tag {
                case .ok: return "✓"; case .warn: return "!"
                case .err: return "✗"; case .info: return "·"
                }
            }()
            _ = drawText(ctx, tagGlyph, font: MatrixTheme.font(10, weight: .bold),
                         color: tagColor, position: CGPoint(x: cx + 68, y: ry))
            let msg = elide(row.msg, font: MatrixTheme.font(10),
                            maxW: rect.width - 32 - 88)
            _ = drawText(ctx, msg, font: MatrixTheme.font(10),
                         color: MatrixTheme.ink, position: CGPoint(x: cx + 86, y: ry))
        }
    }

    // MARK: - Model panel

    private func drawModelPanel(into ctx: CGContext, rect: CGRect, tel: Telemetry) {
        let m = tel.model
        let cx = rect.minX + 16
        var cy = rect.minY + 14

        _ = drawText(ctx, "▸ MODEL", font: MatrixTheme.font(12, weight: .bold),
                     color: MatrixTheme.phosphor, position: CGPoint(x: cx, y: cy))
        cy += 22

        // Modhead (left text + badge box, but no badge image yet — TODO load asset).
        let badgeSize: CGFloat = 84
        let badgeX = rect.maxX - 16 - badgeSize
        let leftW = rect.width - 32 - badgeSize - 14

        let nameFont = MatrixTheme.font(22, weight: .heavy)
        let nameMid = cy + capHeight(of: nameFont) / 2 + (nameFont.ascender - capHeight(of: nameFont))
        let badgeY = nameMid - badgeSize / 2

        drawModelBadge(ctx, rect: CGRect(x: badgeX, y: badgeY, width: badgeSize, height: badgeSize),
                       provider: m.provider)

        let vText = "v\(m.version)"
        let vFont = MatrixTheme.font(10, weight: .bold)
        let vPillW = stringWidth(vText, font: vFont) + 14
        let nameMax = leftW - vPillW - 8
        let nameDisp = elide(m.name, font: nameFont, maxW: nameMax)
        let nw = drawText(ctx, nameDisp, font: nameFont, color: MatrixTheme.ink,
                          position: CGPoint(x: cx, y: cy))
        // Pill rectangle.
        ctx.setFillColor(MatrixTheme.phosphor.cgColor)
        ctx.fill(CGRect(x: cx + nw + 8, y: cy + 8, width: vPillW, height: 18))
        _ = drawText(ctx, vText, font: vFont,
                     color: NSColor(srgbRed: 2/255.0, green: 24/255.0, blue: 15/255.0, alpha: 1),
                     position: CGPoint(x: cx + nw + 8 + 7, y: cy + 8 + 3))
        cy += 32

        // P50 / P95.
        let sub = "P50 \(Int(m.p50ms))MS · P95 \(Int(m.p95ms))MS"
        let subFont = MatrixTheme.font(11)
        _ = drawText(ctx, elide(sub, font: subFont, maxW: leftW),
                     font: subFont, color: MatrixTheme.inkDim,
                     position: CGPoint(x: cx, y: cy))
        cy = max(cy + 16, badgeY + badgeSize) + 14

        // 2×2 spec grid.
        let specW = (rect.width - 32 - 12) / 2
        let specH: CGFloat = 50
        let padL: CGFloat = 10
        let padR: CGFloat = 10
        let ctxMaxStr: String = {
            if m.contextMax >= 1_000_000 { return String(format: "%.0fM", m.contextMax / 1_000_000) }
            return "\(Int(m.contextMax / 1000))K"
        }()
        let cacheHitPct: Double = {
            let denom = max(m.cacheReadTokens + m.inputTokens, 1)
            return m.cacheReadTokens / denom * 100
        }()
        let specs: [(String, String, String)] = [
            ("CONTEXT WINDOW", ctxMaxStr, "tok"),
            ("TOKENS IN · OUT",
             "\(fmtTok(m.inputTokens)) / \(fmtTok(m.outputTokens))", ""),
            ("CACHE READ", String(format: "%.2fM", m.cacheReadTokens / 1e6), "tok"),
            ("CACHE HIT", String(format: "%.1f", cacheHitPct), "%"),
        ]
        let vf = MatrixTheme.font(16, weight: .bold)
        let uf = MatrixTheme.font(11)
        let lf = MatrixTheme.font(10, weight: .bold)
        for (i, spec) in specs.enumerated() {
            let col = CGFloat(i % 2)
            let row = CGFloat(i / 2)
            let sx = cx + col * (specW + 12)
            let sy = cy + row * (specH + 8)
            ctx.setStrokeColor(MatrixTheme.panelBorder.cgColor)
            ctx.setFillColor(NSColor(srgbRed: 2/255.0, green: 16/255.0, blue: 12/255.0, alpha: 0.45).cgColor)
            ctx.fill(CGRect(x: sx, y: sy, width: specW, height: specH))
            ctx.stroke(CGRect(x: sx, y: sy, width: specW, height: specH))
            let innerW = specW - padL - padR
            let labelText = elide(spec.0, font: lf, maxW: innerW)
            _ = drawText(ctx, labelText, font: lf, color: MatrixTheme.inkFaint,
                         position: CGPoint(x: sx + padL, y: sy + 9))
            let uWidth = spec.2.isEmpty ? 0 : stringWidth(spec.2, font: uf) + 3
            let vDisp = elide(spec.1, font: vf, maxW: innerW - uWidth)
            let vw = drawText(ctx, vDisp, font: vf, color: MatrixTheme.ink,
                              position: CGPoint(x: sx + padL, y: sy + 26))
            if !spec.2.isEmpty {
                _ = drawText(ctx, spec.2, font: uf, color: MatrixTheme.inkDim,
                             position: CGPoint(x: sx + padL + vw + 3, y: sy + 31))
            }
        }
        cy += 2 * (specH + 8) + 4

        // Context bar.
        cy += 6
        let ctxPct = max(0, min(100, m.contextUsed / max(m.contextMax, 1) * 100))
        let ctxColor: NSColor = ctxPct > 90 ? MatrixTheme.magenta
            : ctxPct > 75 ? MatrixTheme.amber : MatrixTheme.phosphor
        _ = drawText(ctx, "CONTEXT", font: MatrixTheme.font(11),
                     color: MatrixTheme.inkDim, position: CGPoint(x: cx, y: cy))
        let rightText = "\(fmtTok(m.contextUsed)) / \(fmtTok(m.contextMax)) · \(String(format: "%.1f%%", ctxPct))"
        let rf = MatrixTheme.font(11)
        let rw = stringWidth(rightText, font: rf)
        _ = drawText(ctx, rightText, font: rf, color: MatrixTheme.ink,
                     position: CGPoint(x: rect.maxX - 16 - rw, y: cy))
        cy += 22
        drawTrack(ctx, rect: CGRect(x: cx, y: cy, width: rect.width - 32, height: 7),
                  pct: ctxPct, color: ctxColor)
    }

    private func drawModelBadge(_ ctx: CGContext, rect: CGRect, provider: String) {
        // The bundled anthropic-figure.png is the same asset as the Python app.
        let resourceName = provider == "anthropic" ? "anthropic-figure" : "openai-logo"
        guard let img = Self.badgeImage(named: resourceName) else { return }
        // Draw flush with the top of the reserved box, aspect-fit.
        let aspect = CGFloat(img.width) / CGFloat(img.height)
        let drawH = min(rect.height, rect.width / aspect)
        let drawW = drawH * aspect
        let x = rect.midX - drawW / 2
        // Center vertically inside the reserved badge rect so the figure
        // sits next to the cap-mid of the model name rather than floating
        // above it.
        let y = rect.midY - drawH / 2
        ctx.saveGState()
        // Image is in y-down coords like the rest of our painting.
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -drawH)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
        ctx.restoreGState()
    }

    // MARK: - Quota panel

    private func drawQuotaPanel(into ctx: CGContext, rect: CGRect, tel: Telemetry) {
        let q = tel.quota
        let cx = rect.minX + 16
        var cy = rect.minY + 14
        _ = drawText(ctx, "▸ QUOTA", font: MatrixTheme.font(12, weight: .bold),
                     color: MatrixTheme.phosphor, position: CGPoint(x: cx, y: cy))
        // Plan pill (right).
        let planFont = MatrixTheme.font(10, weight: .bold)
        let pw = stringWidth(q.plan, font: planFont) + 16
        let ph: CGFloat = 18
        ctx.setFillColor(MatrixTheme.phosphor.cgColor)
        ctx.fill(CGRect(x: rect.maxX - 16 - pw, y: cy, width: pw, height: ph))
        _ = drawText(ctx, q.plan, font: planFont,
                     color: NSColor(srgbRed: 2/255.0, green: 20/255.0, blue: 13/255.0, alpha: 1),
                     position: CGPoint(x: rect.maxX - 16 - pw + 8, y: cy + 3))
        cy += 24

        let showCost = !MatrixTheme.isSubscriptionPlan(q.plan)
        for w in q.windows {
            let pct = max(0, min(100, w.used / max(w.cap, 1) * 100))
            let color = pctColor(headroom: 100 - pct)
            _ = drawText(ctx, "\(w.label) WINDOW", font: MatrixTheme.font(10, weight: .bold),
                         color: MatrixTheme.inkFaint, position: CGPoint(x: cx, y: cy + 2))
            let vals = "\(fmtTok(w.used)) / \(fmtTok(w.cap))"
            let vf = MatrixTheme.font(11, weight: .bold)
            let pctText = String(format: "  %d%%", Int(pct))
            let pf = MatrixTheme.font(11, weight: .bold)
            let totalW = stringWidth(vals, font: vf) + stringWidth(pctText, font: pf)
            _ = drawText(ctx, vals, font: vf, color: MatrixTheme.ink,
                         position: CGPoint(x: rect.maxX - 16 - totalW, y: cy))
            _ = drawText(ctx, pctText, font: pf, color: color,
                         position: CGPoint(x: rect.maxX - 16 - stringWidth(pctText, font: pf), y: cy))
            cy += 22
            drawTrack(ctx, rect: CGRect(x: cx, y: cy, width: rect.width - 32, height: 7),
                      pct: pct, color: color)
            cy += 13
            let resetFont = MatrixTheme.font(10)
            _ = drawText(ctx, "resets \(fmtDur(w.resetInSec))",
                         font: resetFont, color: MatrixTheme.inkFaint,
                         position: CGPoint(x: cx, y: cy))
            if showCost {
                let cost = String(format: "$%.2f spent", w.costUSD)
                let cw = stringWidth(cost, font: resetFont)
                _ = drawText(ctx, cost, font: resetFont, color: MatrixTheme.inkFaint,
                             position: CGPoint(x: rect.maxX - 16 - cw, y: cy))
            }
            cy += 16
        }
    }

    // MARK: - Sub-agents panel

    private func drawSubAgentsPanel(into ctx: CGContext, rect: CGRect, tel: Telemetry) {
        let cx = rect.minX + 16
        var cy = rect.minY + 14
        let subs = tel.agent.subAgents
        let running = subs.filter { $0.status == .running }.count
        _ = drawText(ctx, "▸ SUB-AGENTS", font: MatrixTheme.font(12, weight: .bold),
                     color: MatrixTheme.phosphor, position: CGPoint(x: cx, y: cy))
        if !subs.isEmpty {
            let txt = "\(running) live · \(subs.count) recent"
            let f = MatrixTheme.font(10)
            let tw = stringWidth(txt, font: f)
            _ = drawText(ctx, txt, font: f, color: MatrixTheme.inkFaint,
                         position: CGPoint(x: rect.maxX - 16 - tw, y: cy + 2))
        }
        cy += 22
        if subs.isEmpty {
            _ = drawText(ctx, "(none in this session)",
                         font: MatrixTheme.font(11), color: MatrixTheme.inkDim,
                         position: CGPoint(x: cx, y: cy))
            return
        }
        let rowH: CGFloat = 16
        let maxRows = max(0, Int((rect.maxY - 12 - cy) / rowH))
        for sa in subs.prefix(maxRows) {
            let color: NSColor = {
                switch sa.status {
                case .running: return MatrixTheme.phosphor
                case .done: return MatrixTheme.inkDim
                case .error: return MatrixTheme.magenta
                }
            }()
            let glyph: String = {
                switch sa.status {
                case .running: return "●"; case .done: return "✓"; case .error: return "✗"
                }
            }()
            _ = drawText(ctx, glyph, font: MatrixTheme.font(11, weight: .bold),
                         color: color, position: CGPoint(x: cx, y: cy))
            let typeText = String(sa.subagentType.prefix(14))
            let typeFont = MatrixTheme.font(11, weight: .bold)
            let typeW = drawText(ctx, typeText, font: typeFont, color: MatrixTheme.ink,
                                 position: CGPoint(x: cx + 16, y: cy))
            let descX = cx + 16 + typeW + 8
            let descFont = MatrixTheme.font(11)
            let desc = elide(sa.description, font: descFont, maxW: rect.maxX - 16 - descX)
            _ = drawText(ctx, desc, font: descFont, color: MatrixTheme.inkDim,
                         position: CGPoint(x: descX, y: cy))
            cy += rowH
        }
    }

    // MARK: - Footer

    private func drawFooter(into ctx: CGContext, rect: CGRect, tel: Telemetry, now: Date) {
        let m = tel.model
        let q = tel.quota
        var lx = rect.minX + 16
        let ly = rect.midY + 4
        let parts: [(String, String)] = [
            ("\(Int(m.lastRequestMs))", "ms last"),
            ("P95 ", "\(Int(m.p95ms))ms"),
            ("CACHE ",
             String(format: "%d%%", Int(m.cacheReadTokens
                 / max(m.cacheReadTokens + m.inputTokens, 1) * 100))),
        ]
        for (a, b) in parts {
            let aw = drawText(ctx, a, font: MatrixTheme.font(13, weight: .bold),
                              color: MatrixTheme.phosphor, position: CGPoint(x: lx, y: ly))
            lx += aw + 3
            let bw = drawText(ctx, b, font: MatrixTheme.font(13),
                              color: MatrixTheme.inkDim, position: CGPoint(x: lx, y: ly))
            lx += bw + 18
        }

        // Clock (center).
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: now)
        let hh = String(format: "%02d", comps.hour ?? 0)
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)
        let colon = (comps.second ?? 0).isMultiple(of: 2) ? ":" : " "
        let clockFont = MatrixTheme.font(36, weight: .heavy)
        let hw = stringWidth(hh, font: clockFont)
        let cw = stringWidth(colon, font: clockFont)
        let mw = stringWidth(mm, font: clockFont)
        let sw = stringWidth(ss, font: clockFont)
        let total = hw + cw + mw + cw + sw
        var x = rect.midX - total / 2
        // Center glyphs by their tight bounding box. CT uses a baseline-origin
        // y-up rect: origin.y is the distance from baseline to the bottom of
        // the inked box (≥ 0 for ASCII digits). In our flipped y-down canvas
        // the baseline therefore sits *below* the visual center by that span.
        let glyphSample = NSAttributedString(string: "0123456789:",
                                             attributes: [.font: clockFont])
        let glyphLine = CTLineCreateWithAttributedString(glyphSample)
        let tight = CTLineGetBoundsWithOptions(glyphLine, .useOpticalBounds)
        let baselineY = rect.midY + (tight.origin.y + tight.height / 2)
        for part in [hh, colon, mm, colon, ss] {
            _ = drawText(ctx, part, font: clockFont, color: MatrixTheme.ink,
                         position: CGPoint(x: x, y: baselineY - clockFont.ascender))
            x += stringWidth(part, font: clockFont)
        }

        // Right stats.
        let tz = TimeZone.current
        let offsetSec = tz.secondsFromGMT()
        let sign = offsetSec >= 0 ? "+" : "-"
        let absM = abs(offsetSec) / 60
        let tzText = String(format: "UTC%@%02d:%02d", sign, absM / 60, absM % 60)
        var rx = rect.maxX - 16
        let rf = MatrixTheme.font(13)
        if !MatrixTheme.isSubscriptionPlan(q.plan) {
            let cost = q.windows.first?.costUSD ?? 0
            let txt = String(format: "5H  $%.2f", cost)
            let cw2 = stringWidth(txt, font: MatrixTheme.font(13, weight: .bold))
            _ = drawText(ctx, txt, font: MatrixTheme.font(13, weight: .bold),
                         color: MatrixTheme.phosphor,
                         position: CGPoint(x: rx - cw2, y: ly))
            rx -= cw2 + 16
        }
        let tzW = stringWidth(tzText, font: rf)
        _ = drawText(ctx, tzText, font: rf, color: MatrixTheme.inkDim,
                     position: CGPoint(x: rx - tzW, y: ly))
    }

    // MARK: - Generic helpers

    private func drawTrack(_ ctx: CGContext, rect: CGRect, pct: Double, color: NSColor) {
        ctx.setStrokeColor(MatrixTheme.panelBorder.cgColor)
        ctx.setFillColor(NSColor(srgbRed: 41/255.0, green: 255/255.0, blue: 140/255.0, alpha: 0.08).cgColor)
        ctx.fill(rect)
        ctx.stroke(rect)
        if pct > 0 {
            let fw = rect.width * CGFloat(max(0, min(100, pct))) / 100
            let fr = CGRect(x: rect.minX + 1, y: rect.minY + 1,
                            width: max(0, fw - 2), height: rect.height - 2)
            ctx.setFillColor(color.cgColor)
            ctx.fill(fr)
            ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
            ctx.fill(CGRect(x: fr.minX, y: fr.minY - 2, width: fr.width, height: 2))
            ctx.fill(CGRect(x: fr.minX, y: fr.maxY, width: fr.width, height: 2))
        }
    }

    private func drawChip(_ ctx: CGContext, x: CGFloat, y: CGFloat, text: String) -> CGFloat {
        let f = MatrixTheme.font(11)
        let w = stringWidth(text, font: f) + 16
        let h: CGFloat = 22
        ctx.setStrokeColor(MatrixTheme.panelBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: x, y: y, width: w, height: h))
        _ = drawText(ctx, text, font: f, color: MatrixTheme.inkDim,
                     position: CGPoint(x: x + 8, y: y + 3))
        return w
    }

    private func drawWrappedText(_ ctx: CGContext, text: String, font: NSFont,
                                 color: NSColor,
                                 x: CGFloat, y: CGFloat, maxW: CGFloat,
                                 maxLines: Int, lineH: CGFloat)
    {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.isEmpty { return }
        var lines: [String] = []
        var cur = ""
        for word in words {
            let candidate = cur.isEmpty ? word : cur + " " + word
            if stringWidth(candidate, font: font) <= maxW {
                cur = candidate
            } else {
                if !cur.isEmpty { lines.append(cur) }
                if lines.count >= maxLines - 1 { cur = word; break }
                cur = word
            }
        }
        if !cur.isEmpty, lines.count < maxLines { lines.append(cur) }
        if lines.count == maxLines, let last = lines.last {
            lines[lines.count - 1] = elide(last, font: font, maxW: maxW)
        }
        for (i, line) in lines.enumerated() {
            _ = drawText(ctx, line, font: font, color: color,
                         position: CGPoint(x: x, y: y + CGFloat(i) * lineH))
        }
    }

    // MARK: - Text primitives

    private func capTopOrigin(rowMid: CGFloat, font: NSFont, x: CGFloat) -> CGPoint {
        // y_text = rowMid - capHeight/2 - (ascent - capHeight)
        let y = rowMid - capHeight(of: font) / 2 - (font.ascender - capHeight(of: font))
        return CGPoint(x: x, y: y)
    }

    private func capHeight(of font: NSFont) -> CGFloat {
        return font.capHeight > 0 ? font.capHeight : font.pointSize * 0.7
    }

    /// Draw a string with its (x, y) interpreted as the top-left of the
    /// cap-box (matches `_text()` in matrix.py). Returns advance width.
    private func drawText(_ ctx: CGContext, _ s: String, font: NSFont,
                          color: NSColor, position: CGPoint) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        // Move to baseline. Caller's y is "top of ascent"; baseline = y + ascent.
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
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded()
    }

    private func elide(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        if stringWidth(s, font: font) <= maxW { return s }
        var out = s
        let ellipsis = "…"
        while !out.isEmpty, stringWidth(out + ellipsis, font: font) > maxW {
            out.removeLast()
        }
        return out + ellipsis
    }

    // MARK: - Formatting helpers (copied from matrix.py)

    private func fmtTok(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", n / 1_000_000) }
        if n >= 1000 { return String(format: "%.0fK", n / 1000) }
        return "\(Int(n.rounded()))"
    }

    private func fmtDur(_ secs: Int) -> String {
        let s = max(0, secs)
        if s >= 86400 { return "\(s / 86400)d\((s % 86400) / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m" }
        return "\(s / 60)m\(String(format: "%02d", s % 60))s"
    }

    private func pctColor(headroom: Double) -> NSColor {
        if headroom < 10 { return MatrixTheme.magenta }
        if headroom < 25 { return MatrixTheme.amber }
        return MatrixTheme.phosphor
    }

    // MARK: - Image cache

    /// One-time-loaded CGImages keyed by base name. Bundle resources are
    /// flat (Contents/Resources/<name>.png) — we probe both layouts but
    /// check existence first so missing files never spam the IIO error log.
    // NSCache is documented thread-safe per the cocoa headers; the warning
    // exists only because the type isn't formally `Sendable`.
    private nonisolated(unsafe) static let imageCache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 16
        return c
    }()

    private static func badgeImage(named name: String) -> CGImage? {
        if let cached = imageCache.object(forKey: name as NSString) { return cached }
        let fm = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png"),
            Bundle.main.resourceURL?
                .appendingPathComponent("icons")
                .appendingPathComponent("\(name).png"),
        ].compactMap { $0 }
        for url in candidates where fm.fileExists(atPath: url.path) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            imageCache.setObject(img, forKey: name as NSString)
            return img
        }
        return nil
    }
}
