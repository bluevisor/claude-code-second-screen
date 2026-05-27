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

final class MatrixRenderer: @unchecked Sendable {
    private let size: CGSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var staticBackground: CGImage?
    private let rain: RainPainter
    private let showRain: Bool
    private let crt = CRTPostProcessor()
    var lastCRTMs: Double { crt.lastProcessMs }

    /// Portrait when the canvas is taller than it is wide — triggers the
    /// vertical-stack layout used on 90°/270° rotations.
    private var isPortrait: Bool { size.height > size.width }

    // MARK: - Cached gradients
    //
    // These depend only on the renderer's color space + (for vignette
    // and background) canvas size — all instance-lifetime constants.
    // `lazy var` is fine here: `MatrixRenderer` is single-threaded on
    // the FrameLoop's work queue.
    private lazy var backgroundGradient: CGGradient = {
        CGGradient(colorsSpace: colorSpace,
                   colors: [MatrixTheme.bgTop.cgColor,
                            MatrixTheme.bgBot.cgColor] as CFArray,
                   locations: [0, 1])!
    }()
    private lazy var vignetteGradient: CGGradient = {
        // `drawVignette` is only ever called with strength=0.42 from the
        // matrix-theme paths; bake it in. If we ever need variable
        // strength, swap to a small per-strength cache.
        CGGradient(colorsSpace: colorSpace,
                   colors: [
                    NSColor.black.withAlphaComponent(0).cgColor,
                    NSColor.black.withAlphaComponent(0.42).cgColor,
                   ] as CFArray,
                   locations: [0, 1])!
    }()
    private lazy var panelBgGradient: CGGradient = {
        CGGradient(colorsSpace: colorSpace,
                   colors: [
                    NSColor(srgbRed: 8/255.0, green: 22/255.0, blue: 18/255.0, alpha: 0.97).cgColor,
                    NSColor(srgbRed: 4/255.0, green: 12/255.0, blue: 10/255.0, alpha: 0.94).cgColor,
                   ] as CFArray,
                   locations: [0, 1])!
    }()
    private lazy var panelSheenGradient: CGGradient = {
        CGGradient(colorsSpace: colorSpace,
                   colors: [
                    NSColor(srgbRed: 41/255.0, green: 255/255.0, blue: 140/255.0, alpha: 12/255.0).cgColor,
                    NSColor.black.withAlphaComponent(0).cgColor,
                   ] as CFArray,
                   locations: [0, 1])!
    }()
    private lazy var railSeparatorGradient: CGGradient = {
        CGGradient(colorsSpace: colorSpace,
                   colors: [
                    MatrixTheme.phosphor.withAlphaComponent(0).cgColor,
                    MatrixTheme.phosphor.withAlphaComponent(0.30).cgColor,
                    MatrixTheme.phosphor.withAlphaComponent(0).cgColor,
                   ] as CFArray,
                   locations: [0, 0.5, 1])!
    }()

    /// Pre-baked scanline + vignette overlay — combines both effects into
    /// one `ctx.draw` per frame instead of two (scanline image stamp +
    /// radial gradient draw).
    private lazy var overlayImage: CGImage? = {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Scanlines
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.30 * 0.78).cgColor)
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: 1))
            y += 2
        }
        // Vignette (y-up native CG coords, no flip needed)
        let cx = size.width / 2, cy = size.height / 2
        let inner = min(size.width, size.height) * 0.32
        let outer = hypot(cx, cy) * 1.05
        ctx.drawRadialGradient(vignetteGradient,
            startCenter: CGPoint(x: cx, y: cy), startRadius: inner,
            endCenter: CGPoint(x: cx, y: cy), endRadius: outer,
            options: [])
        return ctx.makeImage()
    }()

    /// Reusable bitmap context for the main render pass. Allocated
    /// lazily on first render and reused for the lifetime of this
    /// renderer instance (renderers are rebuilt on rotation flip, so
    /// the canvas size is stable). Saves ~2.4 MB allocator churn per
    /// frame compared to allocating fresh. `ctx.makeImage()` returns
    /// a COW-shared CGImage; the next frame's first draw call triggers
    /// a copy for any still-held image (preview-window path), so
    /// downstream consumers never see torn pixels.
    private var renderCtx: CGContext?

    /// Pre-rendered panel chrome (gradient bg + border + corner brackets)
    /// for all panels in the current layout. Built once on first render,
    /// stamped as a single `ctx.draw` each frame instead of 4-5
    /// individual gradient+stroke sequences (~3-4ms savings).
    private var panelChromeImage: CGImage?

    init(size: CGSize = MatrixTheme.canvasSize,
         showRain: Bool = true,
         rainFPS: Double = 15) {
        self.size = size
        self.showRain = showRain
        self.rain = RainPainter(canvasSize: size, stepHz: rainFPS)
    }

    /// Render one frame and return the resulting CGImage. `blink` is a
    /// monotonically-increasing phase used for the caret + scan animations.
    /// `blackAlpha` (0…1) overlays a translucent black fill on top of the
    /// composite — used by FrameLoop's fade machine.
    func render(_ tel: Telemetry, blink: Double, now: Date,
                blackAlpha: Double = 0) -> CGImage? {
        guard let ctx = ensureRenderContext() else { return nil }

        // Reset any CTM leftover from the previous frame and bracket
        // the per-frame draws so saveGState/restoreGState pairs inside
        // helpers can't drift the persistent context's state.
        ctx.saveGState()

        // CGContext y-axis points up. We work in "screen coords" (y-down),
        // so flip the CTM once and stay there.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        drawBackground(into: ctx, now: now)

        if isPortrait {
            layoutPortrait(into: ctx, tel: tel, blink: blink, now: now)
        } else {
            layoutLandscape(into: ctx, tel: tel, blink: blink, now: now)
        }

        drawOverlay(into: ctx)

        // Fade overlay (if active) goes on top before CRT so it darkens
        // the chromatic-aberration pass too — visually identical to the
        // old post-process step that wrapped the final image.
        applyFade(into: ctx, alpha: blackAlpha)

        ctx.restoreGState()
        crt.applyInPlace(ctx: ctx)
        return ctx.makeImage()
    }

    private func ensureRenderContext() -> CGContext? {
        if let renderCtx { return renderCtx }
        let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        renderCtx = ctx
        return ctx
    }

    /// Composite a translucent black fill across the whole canvas. Caller
    /// passes `0` to skip; we still no-op explicitly so the cheap path is
    /// `alpha > 0` check, no GState push.
    private func applyFade(into ctx: CGContext, alpha: Double) {
        guard alpha > 0 else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(
            min(1, max(0, CGFloat(alpha)))).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
    }

    // MARK: - Layouts

    /// Original 1280×480 layout — rail on top, three columns underneath
    /// (agent · model · quota+subs), footer with center clock.
    private func layoutLandscape(into ctx: CGContext, tel: Telemetry,
                                 blink: Double, now: Date) {
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

        drawCachedPanelChrome(into: ctx)
        drawRail(into: ctx, rect: railRect, tel: tel, now: now)
        drawAgentPanel(into: ctx, rect: agentRect, tel: tel, blink: blink, now: now)
        drawModelPanel(into: ctx, rect: modelRect, tel: tel)
        drawQuotaPanel(into: ctx, rect: quotaRect, tel: tel)
        drawSubAgentsPanel(into: ctx, rect: subsRect, tel: tel)
        drawFooter(into: ctx, rect: footerRect, tel: tel, now: now)
    }

    private func layoutPortrait(into ctx: CGContext, tel: Telemetry,
                                blink: Double, now: Date) {
        let padX: CGFloat = 18
        let padTop: CGFloat = 12
        let padBot: CGFloat = 12
        let railH: CGFloat = 56
        let footerH: CGFloat = 72
        let gap: CGFloat = 10
        let frameW = size.width - 2 * padX
        let stackTop = padTop + railH + gap
        let stackBot = size.height - padBot - footerH - gap
        let stackH = max(0, stackBot - stackTop)
        let interGap: CGFloat = 10
        let totalGaps = 3 * interGap
        let usable = max(0, stackH - totalGaps)
        let agentH = (usable * 0.29).rounded()
        let modelH = (usable * 0.41).rounded()
        let quotaH = (usable * 0.16).rounded()
        let subsH  = max(0, usable - agentH - modelH - quotaH)
        let railRect = CGRect(x: padX, y: padTop, width: frameW, height: railH)
        var y = stackTop
        let agentRect = CGRect(x: padX, y: y, width: frameW, height: agentH)
        y += agentH + interGap
        let modelRect = CGRect(x: padX, y: y, width: frameW, height: modelH)
        y += modelH + interGap
        let quotaRect = CGRect(x: padX, y: y, width: frameW, height: quotaH)
        y += quotaH + interGap
        let subsRect = CGRect(x: padX, y: y, width: frameW, height: subsH)
        let footerRect = CGRect(x: padX,
                                y: size.height - padBot - footerH,
                                width: frameW, height: footerH)

        drawCachedPanelChrome(into: ctx)
        drawRailPortrait(into: ctx, rect: railRect, tel: tel, now: now)
        drawAgentPanel(into: ctx, rect: agentRect, tel: tel, blink: blink, now: now)
        drawModelPanel(into: ctx, rect: modelRect, tel: tel)
        drawQuotaPanel(into: ctx, rect: quotaRect, tel: tel)
        drawSubAgentsPanel(into: ctx, rect: subsRect, tel: tel)
        drawFooterPortrait(into: ctx, rect: footerRect, tel: tel, now: now)
    }

    // MARK: - Background

    private func drawBackground(into ctx: CGContext, now: Date) {
        // Vertical phosphor gradient.
        ctx.drawLinearGradient(backgroundGradient,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: size.height),
                               options: [])
        if showRain {
            rain.draw(into: ctx, now: now.timeIntervalSinceReferenceDate)
        }
    }

    private func drawOverlay(into ctx: CGContext) {
        guard let img = overlayImage else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        ctx.restoreGState()
    }

    // MARK: - Panel chrome

    private func ensurePanelChrome() -> CGImage? {
        if let panelChromeImage { return panelChromeImage }
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
        let rects: [CGRect]
        if isPortrait {
            rects = panelRectsPortrait()
        } else {
            rects = panelRectsLandscape()
        }
        for r in rects { drawPanelChrome(ctx, rect: r) }
        panelChromeImage = ctx.makeImage()
        return panelChromeImage
    }

    private func drawCachedPanelChrome(into ctx: CGContext) {
        guard let img = ensurePanelChrome() else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    private func panelRectsLandscape() -> [CGRect] {
        let padX: CGFloat = 18
        let padTop: CGFloat = 12
        let padBot: CGFloat = 12
        let railH: CGFloat = 34
        let footerH: CGFloat = 38
        let gapAbove: CGFloat = 10
        let gapBelow: CGFloat = 8
        let frameW = size.width - 2 * padX
        let mainH = size.height - padTop - padBot - railH - footerH - gapAbove - gapBelow
        let mainTop = padTop + railH + gapAbove
        let mainRect = CGRect(x: padX, y: mainTop, width: frameW, height: mainH)
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
        return [agentRect, modelRect, quotaRect, subsRect]
    }

    private func panelRectsPortrait() -> [CGRect] {
        let padX: CGFloat = 18
        let padTop: CGFloat = 12
        let padBot: CGFloat = 12
        let railH: CGFloat = 56
        let footerH: CGFloat = 72
        let gap: CGFloat = 10
        let frameW = size.width - 2 * padX
        let stackTop = padTop + railH + gap
        let stackBot = size.height - padBot - footerH - gap
        let stackH = max(0, stackBot - stackTop)
        let interGap: CGFloat = 10
        let totalGaps = 3 * interGap
        let usable = max(0, stackH - totalGaps)
        let agentH = (usable * 0.29).rounded()
        let modelH = (usable * 0.41).rounded()
        let quotaH = (usable * 0.16).rounded()
        let subsH  = max(0, usable - agentH - modelH - quotaH)
        var y = stackTop
        let agentRect = CGRect(x: padX, y: y, width: frameW, height: agentH)
        y += agentH + interGap
        let modelRect = CGRect(x: padX, y: y, width: frameW, height: modelH)
        y += modelH + interGap
        let quotaRect = CGRect(x: padX, y: y, width: frameW, height: quotaH)
        y += quotaH + interGap
        let subsRect = CGRect(x: padX, y: y, width: frameW, height: subsH)
        return [agentRect, modelRect, quotaRect, subsRect]
    }

    private func drawPanelChrome(_ ctx: CGContext, rect: CGRect) {
        // Translucent background gradient.
        ctx.saveGState()
        ctx.addRect(rect); ctx.clip()
        ctx.drawLinearGradient(panelBgGradient,
                               start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.minX, y: rect.maxY),
                               options: [])
        // Subtle inner phosphor sheen.
        ctx.drawLinearGradient(panelSheenGradient,
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
            : "⎇ \(tel.agent.gitBranch)\(tel.agent.gitDirty ? " ●" : "")"
        if !branchText.isEmpty {
            cx += drawChip(ctx, x: cx, y: chipTop, text: branchText) + 8
        }

        let sess = "SESS \(tel.agent.sessionID)"
        cx += drawText(ctx, sess, font: sessFont, color: MatrixTheme.inkFaint,
                       position: capTopOrigin(rowMid: rowMid, font: sessFont, x: cx)) + 12

        // Right side — weekday + date.
        let weekdayStr = MatrixTheme.weekday(now)
        let dateString = "\(weekdayStr)  \(dateText(now))"
        let dateWidth = stringWidth(dateString, font: dateFont)
        let dateX = rect.maxX - dateWidth
        _ = drawText(ctx, dateString, font: dateFont, color: MatrixTheme.inkDim,
                     position: capTopOrigin(rowMid: rowMid, font: dateFont, x: dateX))

        // Separator gradient between left cluster and date.
        let sepLeft = cx + 4
        let sepRight = dateX - 12
        if sepRight > sepLeft {
            ctx.saveGState()
            ctx.addRect(CGRect(x: sepLeft, y: rowMid, width: sepRight - sepLeft, height: 1))
            ctx.clip()
            ctx.drawLinearGradient(railSeparatorGradient,
                                   start: CGPoint(x: sepLeft, y: rowMid),
                                   end: CGPoint(x: sepRight, y: rowMid),
                                   options: [])
            ctx.restoreGState()
        }
    }

    // MARK: - Rail (portrait)

    /// Two-row rail for the 480-wide portrait layout. Top row: LED +
    /// agent label, weekday/date right-aligned. Bottom row: cwd chip +
    /// git branch chip + session id (elided to fit).
    private func drawRailPortrait(into ctx: CGContext, rect: CGRect,
                                  tel: Telemetry, now: Date) {
        let row1Top = rect.minY + 4
        let row1H: CGFloat = 22
        let row1Mid = row1Top + row1H / 2
        let row2Top = rect.minY + 30
        let row2H: CGFloat = 22

        let labelFont = MatrixTheme.font(13, weight: .bold)
        let dateFont = MatrixTheme.font(11, weight: .bold)

        // LED.
        let ledColor: NSColor = {
            switch tel.agent.status {
            case .error: return MatrixTheme.magenta
            case .idle:  return MatrixTheme.amber
            default:     return MatrixTheme.phosphor
            }
        }()
        var cx = rect.minX
        ctx.setFillColor(ledColor.withAlphaComponent(0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 4, y: row1Mid - 9, width: 18, height: 18))
        ctx.setFillColor(ledColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx, y: row1Mid - 5, width: 10, height: 10))
        cx += 22

        // Agent label.
        let label = tel.agent.kind.uppercased().replacingOccurrences(of: "-", with: " ")
        let weekday = MatrixTheme.weekday(now, short: true)
        let dateStr = "\(weekday) \(dateText(now))"
        let dateW = stringWidth(dateStr, font: dateFont)
        let labelMax = rect.maxX - dateW - 12 - cx
        let labelDisp = elide(label, font: labelFont, maxW: labelMax)
        _ = drawText(ctx, labelDisp, font: labelFont, color: MatrixTheme.ink,
                     position: capTopOrigin(rowMid: row1Mid, font: labelFont, x: cx))

        _ = drawText(ctx, dateStr, font: dateFont, color: MatrixTheme.inkDim,
                     position: capTopOrigin(rowMid: row1Mid,
                                            font: dateFont,
                                            x: rect.maxX - dateW))

        // Row 2 — cwd / branch / sess. Elide chips so they always fit.
        var bx = rect.minX
        let sessFont = MatrixTheme.font(10)
        let sess = "SESS \(tel.agent.sessionID)"
        let sessW = stringWidth(sess, font: sessFont) + 8
        let chipBudget = rect.width - sessW - 8
        // Render two chips left-to-right and clamp each to half of the
        // budget so neither one starves the other on long branch names.
        let branchText = tel.agent.gitBranch.isEmpty ? ""
            : "⎇ \(tel.agent.gitBranch)\(tel.agent.gitDirty ? " ●" : "")"
        let chipFont = MatrixTheme.font(11)
        let cwdMax: CGFloat = branchText.isEmpty
            ? chipBudget - 0
            : (chipBudget - 8) * 0.55
        let cwdDisp = elide(tel.agent.cwd, font: chipFont, maxW: cwdMax - 16)
        bx += drawChip(ctx, x: bx, y: row2Top, text: cwdDisp) + 8
        if !branchText.isEmpty {
            let branchMax = rect.maxX - sessW - 8 - bx
            let branchDisp = elide(branchText, font: chipFont,
                                   maxW: max(20, branchMax - 16))
            _ = drawChip(ctx, x: bx, y: row2Top, text: branchDisp)
        }
        _ = drawText(ctx, sess, font: sessFont, color: MatrixTheme.inkFaint,
                     position: capTopOrigin(rowMid: row2Top + row2H / 2,
                                            font: sessFont,
                                            x: rect.maxX - stringWidth(sess, font: sessFont)))
    }

    // MARK: - Agent panel

    private func drawAgentPanel(into ctx: CGContext, rect: CGRect, tel: Telemetry, blink: Double, now: Date) {
        let cx = rect.minX + 16
        var cy = rect.minY + 14

        // Title.
        _ = drawText(ctx, "▸ PROMPT", font: MatrixTheme.font(12, weight: .bold),
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
        // Caret blink — synced to the footer clock's colon: on during the
        // same even-second beat so the two animations breathe together.
        let caretOn = Calendar.current.component(.second, from: now).isMultiple(of: 2)
        if tel.agent.status != .idle, tel.agent.status != .waiting, caretOn {
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
        _ = drawText(ctx, elide(detail, font: detailFont, maxW: maxW + (bodyX - cx)),
                     font: detailFont, color: MatrixTheme.inkFaint,
                     position: CGPoint(x: cx, y: cy))
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

        // Modhead (left text + provider badge). Every badge gets the same
        // visual height; landscape figures (anthropic) end up wider than
        // square logos (openai), so `leftW` is derived from the actual
        // rendered width to keep the name from colliding.
        let badgeH: CGFloat = 84
        let badgeW = Self.badgeRenderWidth(provider: m.provider, height: badgeH)
        let badgeX = rect.maxX - 16 - badgeW
        let leftW = rect.width - 32 - badgeW - 14

        let nameFont = MatrixTheme.font(22, weight: .heavy)
        let nameMid = cy + capHeight(of: nameFont) / 2 + (nameFont.ascender - capHeight(of: nameFont))
        let badgeY = nameMid - badgeH / 2

        drawModelBadge(ctx, rect: CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH),
                       provider: m.provider)

        let vText = "v\(m.version)"
        let vFont = MatrixTheme.font(10, weight: .bold)
        let vPillW = stringWidth(vText, font: vFont) + 14
        let nameMax = leftW - vPillW - 8
        // Prefer the full "CLAUDE SONNET 1M" — but if it doesn't fit,
        // drop the "CLAUDE " prefix before falling back to ellipsis so
        // the model family + tier are still legible.
        let nameDisp: String = {
            if stringWidth(m.name, font: nameFont) <= nameMax { return m.name }
            let stripped = m.name.hasPrefix("CLAUDE ")
                ? String(m.name.dropFirst("CLAUDE ".count))
                : m.name
            return elide(stripped, font: nameFont, maxW: nameMax)
        }()
        let nw = drawText(ctx, nameDisp, font: nameFont, color: MatrixTheme.ink,
                          position: CGPoint(x: cx, y: cy))
        // Pill rectangle.
        let vPill = CGRect(x: cx + nw + 8, y: cy + 8, width: vPillW, height: 18)
        ctx.setFillColor(MatrixTheme.phosphor.cgColor)
        ctx.fill(vPill)
        _ = drawText(ctx, vText, font: vFont,
                     color: NSColor(srgbRed: 2/255.0, green: 24/255.0, blue: 15/255.0, alpha: 1),
                     position: capTopOrigin(rowMid: vPill.midY,
                                            font: vFont,
                                            x: vPill.minX + 7))
        cy += 32

        // Thinking mode (replaces the old P50/P95 line — latency now
        // lives in the response-time sparkline at the bottom of the
        // panel). Models with a graded knob (Codex / o-series) show the
        // effort string; Claude shows ON/OFF.
        let (subLabel, subColor): (String, NSColor) = {
            switch m.thinking {
            case .effort(let level):
                return ("THINKING · \(level.uppercased())", MatrixTheme.phosphor)
            case .on:
                return ("THINKING ON", MatrixTheme.phosphor)
            case .off:
                return ("THINKING OFF", MatrixTheme.inkDim)
            case .unknown:
                return ("THINKING —", MatrixTheme.inkFaint)
            }
        }()
        let subFont = MatrixTheme.font(11, weight: .bold)
        _ = drawText(ctx, elide(subLabel, font: subFont, maxW: leftW),
                     font: subFont, color: subColor,
                     position: CGPoint(x: cx, y: cy))
        cy = max(cy + 16, badgeY + badgeH) + 14

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
            // Denominator is total prompt tokens this session — fresh
            // input + cache reads + cache writes. Omitting writes (the
            // miss-and-seed path) inflates the hit rate to ~100%.
            let denom = max(m.cacheReadTokens + m.inputTokens + m.cacheWriteTokens, 1)
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
        cy += 7 + 14

        // Latency sparkline — fills whatever remains of the model panel.
        let graphTop = cy
        let graphBot = rect.maxY - 12
        if graphBot - graphTop >= 30 {
            drawLatencyGraph(into: ctx,
                             rect: CGRect(x: cx, y: graphTop,
                                          width: rect.width - 32,
                                          height: graphBot - graphTop),
                             history: m.latencyHistory,
                             lastMs: m.lastRequestMs,
                             p95ms: m.p95ms)
        }
    }

    /// Sparkline of recent assistant-turn round-trip latencies. Y-axis is
    /// auto-scaled to the largest observed value with a soft minimum so a
    /// quiet session doesn't render as flat-line noise. P95 is overlaid as
    /// a dim guideline.
    private func drawLatencyGraph(into ctx: CGContext, rect: CGRect,
                                  history: [Double], lastMs: Double, p95ms: Double) {
        // Header row.
        let labelFont = MatrixTheme.font(11, weight: .bold)
        _ = drawText(ctx, "RESPONSE TIME", font: labelFont,
                     color: MatrixTheme.inkFaint,
                     position: CGPoint(x: rect.minX, y: rect.minY))
        let valFont = MatrixTheme.font(11)
        let valText = history.isEmpty
            ? "—"
            : "\(Int(lastMs))MS · P95 \(Int(p95ms))MS"
        let vw = stringWidth(valText, font: valFont)
        _ = drawText(ctx, valText, font: valFont, color: MatrixTheme.ink,
                     position: CGPoint(x: rect.maxX - vw, y: rect.minY))

        // Plot area sits under the header row.
        let plot = CGRect(x: rect.minX,
                          y: rect.minY + 18,
                          width: rect.width,
                          height: max(0, rect.height - 18))
        guard plot.height >= 12 else { return }

        // Frame the plot subtly.
        ctx.setStrokeColor(MatrixTheme.panelBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(plot.insetBy(dx: 0.5, dy: 0.5))

        guard !history.isEmpty else {
            let hint = "waiting for samples…"
            _ = drawText(ctx, hint, font: valFont, color: MatrixTheme.inkFaint,
                         position: CGPoint(x: plot.midX - stringWidth(hint, font: valFont) / 2,
                                           y: plot.midY - 6))
            return
        }

        // Auto-scale y axis. Force a floor so jitter doesn't dominate.
        let maxV = max(history.max() ?? 1, 1000)

        // P95 guideline.
        if p95ms > 0, p95ms <= maxV {
            let py = plot.maxY - CGFloat(p95ms / maxV) * (plot.height - 4) - 2
            ctx.saveGState()
            ctx.setStrokeColor(MatrixTheme.amber.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: plot.minX + 2, y: py))
            ctx.addLine(to: CGPoint(x: plot.maxX - 2, y: py))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Line + dot at the most recent sample.
        let n = history.count
        let step = (plot.width - 4) / CGFloat(max(n - 1, 1))
        let path = CGMutablePath()
        for (i, v) in history.enumerated() {
            let x = plot.minX + 2 + CGFloat(i) * step
            let y = plot.maxY - CGFloat(v / maxV) * (plot.height - 4) - 2
            i == 0 ? path.move(to: CGPoint(x: x, y: y))
                   : path.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.setStrokeColor(MatrixTheme.phosphor.cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()

        if let last = history.last {
            let x = plot.maxX - 2
            let y = plot.maxY - CGFloat(last / maxV) * (plot.height - 4) - 2
            ctx.setFillColor(MatrixTheme.phosphor.cgColor)
            ctx.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
        }
    }

    private func drawModelBadge(_ ctx: CGContext, rect: CGRect, provider: String) {
        // The caller has already sized `rect` to the badge's natural aspect
        // ratio at the desired height (see `badgeRenderWidth`) — so we just
        // fill it. Image is in y-down coords like the rest of our painting.
        let resourceName: String
        if provider == "anthropic" {
            resourceName = "anthropic-figure"
        } else if provider == "google" {
            resourceName = "google-logo"
        } else {
            resourceName = "openai-logo"
        }
        if let img = Self.badgeImage(named: resourceName) {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -rect.height)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
            return
        }
        // Procedural fallback — used for `google` when no PNG is bundled.
        // Draws the four-color Google "G" mark from CG primitives so the
        // badge slot doesn't render blank.
        if provider == "google" {
            drawGoogleGBadge(into: ctx, rect: rect)
        }
    }

    /// Render a simplified Google "G" mark in the brand quadrant colors.
    /// Filled ring with the right-middle quadrant cut by a horizontal bar
    /// to suggest the G crossbar. Not a pixel-exact reproduction of the
    /// official logo — recognisable enough as a Gemini/Google indicator.
    private func drawGoogleGBadge(into ctx: CGContext, rect: CGRect) {
        let cx = rect.midX
        let cy = rect.midY
        let outerR = min(rect.width, rect.height) / 2 * 0.92
        let strokeW = outerR * 0.30
        let innerR = outerR - strokeW

        // Brand quadrant colors. Using the published Material/Google
        // palette so the indicator reads as the canonical G mark even
        // without the exact letter form.
        let blue   = NSColor(srgbRed: 66/255.0,  green: 133/255.0, blue: 244/255.0, alpha: 1).cgColor
        let red    = NSColor(srgbRed: 234/255.0, green:  67/255.0, blue:  53/255.0, alpha: 1).cgColor
        let yellow = NSColor(srgbRed: 251/255.0, green: 188/255.0, blue:   4/255.0, alpha: 1).cgColor
        let green  = NSColor(srgbRed:  52/255.0, green: 168/255.0, blue:  83/255.0, alpha: 1).cgColor

        // Y-axis is flipped (screen coords) — angles in CG are CCW in y-up,
        // so in our frame "positive sweep" reads as clockwise. We draw four
        // colored arcs each spanning ~90°, leaving a notch on the right for
        // the G crossbar and a horizontal slot cut from the center outward.
        let quadrants: [(CGFloat, CGFloat, CGColor)] = [
            // Start, end (radians, CG convention), color.
            (-.pi / 2,  0,           blue),    // top → right (≈ blue band)
            (.pi,      -.pi / 2,     red),     // left → top (≈ red band)
            (.pi / 2,  .pi,          yellow),  // bottom → left (≈ yellow band)
            (0,        .pi / 2,      green),   // right → bottom (≈ green band)
        ]
        for (start, end, color) in quadrants {
            ctx.saveGState()
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx + cos(start) * innerR,
                                 y: cy + sin(start) * innerR))
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: outerR,
                       startAngle: start, endAngle: end, clockwise: false)
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: innerR,
                       startAngle: end, endAngle: start, clockwise: true)
            ctx.closePath()
            ctx.setFillColor(color)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Crossbar slot — punch a horizontal channel from the center out
        // through the right side so the ring reads as a "G".
        let barH = strokeW * 0.85
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(x: cx, y: cy - barH / 2,
                        width: outerR + 2, height: barH))
        ctx.restoreGState()
    }

    /// Natural pixel width of the provider badge at a given height. Falls
    /// back to a square if the asset can't be loaded.
    fileprivate static func badgeRenderWidth(provider: String, height: CGFloat) -> CGFloat {
        let name: String
        if provider == "anthropic" {
            name = "anthropic-figure"
        } else if provider == "google" {
            name = "google-logo"
        } else {
            name = "openai-logo"
        }
        guard let img = badgeImage(named: name), img.height > 0 else { return height }
        return height * CGFloat(img.width) / CGFloat(img.height)
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
        let planPill = CGRect(x: rect.maxX - 16 - pw, y: cy, width: pw, height: ph)
        ctx.setFillColor(MatrixTheme.phosphor.cgColor)
        ctx.fill(planPill)
        _ = drawText(ctx, q.plan, font: planFont,
                     color: NSColor(srgbRed: 2/255.0, green: 20/255.0, blue: 13/255.0, alpha: 1),
                     position: capTopOrigin(rowMid: planPill.midY,
                                            font: planFont,
                                            x: planPill.minX + 8))
        cy += 24

        if isAPIBillingPlan(q.plan) {
            drawAPIBillingSummary(into: ctx, rect: rect, topY: cy, quota: q)
            return
        }

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

    private func drawAPIBillingSummary(into ctx: CGContext,
                                       rect: CGRect,
                                       topY: CGFloat,
                                       quota: Quota) {
        let usage = quota.windows.max(by: { $0.resetInSec < $1.resetInSec })
        let tokenText = fmtTok(usage?.used ?? 0)
        let costText = String(format: "$%.2f", usage?.costUSD ?? 0)
        let labelFont = MatrixTheme.font(10, weight: .bold)
        let valueFont = MatrixTheme.font(20, weight: .heavy)
        let rowInset: CGFloat = 16
        let rowH: CGFloat = 42
        var y = topY

        for (label, value, color) in [
            ("TOKENS USED", tokenText, MatrixTheme.ink),
            ("EST. COST", costText, MatrixTheme.phosphor),
        ] as [(String, String, NSColor)] {
            let row = CGRect(x: rect.minX + rowInset,
                             y: y,
                             width: rect.width - rowInset * 2,
                             height: rowH)
            ctx.setFillColor(MatrixTheme.phosphor.withAlphaComponent(0.055).cgColor)
            ctx.fill(row)
            ctx.setStrokeColor(MatrixTheme.panelBorder.cgColor)
            ctx.stroke(row.insetBy(dx: 0.5, dy: 0.5))

            _ = drawText(ctx, label, font: labelFont,
                         color: MatrixTheme.inkFaint,
                         position: CGPoint(x: row.minX + 10, y: row.minY + 8))
            let valueW = stringWidth(value, font: valueFont)
            _ = drawText(ctx, value, font: valueFont,
                         color: color,
                         position: CGPoint(x: row.maxX - 10 - valueW,
                                           y: row.minY + 13))
            y += rowH + 8
        }
    }

    private func isAPIBillingPlan(_ plan: String) -> Bool {
        plan.uppercased().contains("API")
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
        var lx = rect.minX + 16
        // Center the clock digits optically inside the footer rect, then
        // share that baseline with the small left/right stats so every
        // element on the row sits on one common bottom baseline.
        let smallFont = MatrixTheme.font(13)
        let smallBoldFont = MatrixTheme.font(13, weight: .bold)
        let clockFont = MatrixTheme.font(36, weight: .heavy)
        let clockGlyphs = NSAttributedString(string: "0123456789:",
                                             attributes: [.font: clockFont])
        let tight = CTLineGetBoundsWithOptions(
            CTLineCreateWithAttributedString(clockGlyphs), .useOpticalBounds)
        let baseY = rect.midY + (tight.origin.y + tight.height / 2)
        let smallTopY = baseY - smallFont.ascender
        let clockTopY = baseY - clockFont.ascender
        // Show "—" instead of "0ms" / "0%" before any samples have
        // arrived (fresh session / context-window reset). Zero is the
        // sentinel the telemetry sources emit when no request has
        // completed yet — not a real measurement.
        let lastText = m.lastRequestMs > 0 ? "\(Int(m.lastRequestMs))" : "—"
        let lastUnit = m.lastRequestMs > 0 ? "ms last" : " last"
        let p95Text = m.p95ms > 0 ? "\(Int(m.p95ms))ms" : "—"
        let parts: [(String, String)] = [
            (lastText, lastUnit),
            ("P95 ", p95Text),
            ("CACHE ",
             String(format: "%d%%", Int(m.cacheReadTokens
                 / max(m.cacheReadTokens + m.inputTokens + m.cacheWriteTokens, 1) * 100))),
        ]
        for (a, b) in parts {
            let aw = drawText(ctx, a, font: smallBoldFont,
                              color: MatrixTheme.phosphor,
                              position: CGPoint(x: lx, y: smallTopY))
            lx += aw + 3
            let bw = drawText(ctx, b, font: smallFont,
                              color: MatrixTheme.inkDim,
                              position: CGPoint(x: lx, y: smallTopY))
            lx += bw + 18
        }

        // Clock (center). User chooses 12h / 24h; the AM/PM suffix sits
        // beside the digits in 12h mode.
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: now)
        let h: String = {
            switch UserPrefs.timeFormat {
            case .h24: return String(format: "%02d", comps.hour ?? 0)
            case .h12: return String(((comps.hour ?? 0) + 11) % 12 + 1)
            }
        }()
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)
        let colon = (comps.second ?? 0).isMultiple(of: 2) ? ":" : " "
        let clockParts = [h, colon, mm, colon, ss]
        let widths = clockParts.map { stringWidth($0, font: clockFont) }
        let total = widths.reduce(0, +)
        var x = rect.midX - total / 2
        for (part, w) in zip(clockParts, widths) {
            _ = drawText(ctx, part, font: clockFont, color: MatrixTheme.ink,
                         position: CGPoint(x: x, y: clockTopY))
            x += w
        }
        // AM / PM suffix beside the clock in 12-hour mode.
        let ampm = amPm(now)
        if !ampm.isEmpty {
            _ = drawText(ctx, ampm, font: smallBoldFont, color: MatrixTheme.inkDim,
                         position: CGPoint(x: x + 6, y: smallTopY))
        }

        // Right stats. Weather replaces the legacy UTC-offset chip; until
        // the first network refresh succeeds we show a placeholder.
        let weatherText = WeatherService.shared.summaryUppercased ?? "—"
        let weatherW = stringWidth(weatherText, font: smallFont)
        _ = drawText(ctx, weatherText, font: smallFont, color: MatrixTheme.inkDim,
                     position: CGPoint(x: rect.maxX - weatherW, y: smallTopY))
    }

    // MARK: - Footer (portrait)

    /// Two-row portrait footer: big centered clock on top, stats +
    /// weather on a small row below. Same visual hierarchy as the
    /// landscape footer (clock is the hero), just stacked.
    private func drawFooterPortrait(into ctx: CGContext, rect: CGRect,
                                    tel: Telemetry, now: Date) {
        let m = tel.model
        let clockFont = MatrixTheme.font(32, weight: .heavy)
        let smallFont = MatrixTheme.font(11)
        let smallBoldFont = MatrixTheme.font(11, weight: .bold)

        // Clock baseline using optical bounds of the glyph set.
        let clockGlyphs = NSAttributedString(string: "0123456789:",
                                             attributes: [.font: clockFont])
        let tight = CTLineGetBoundsWithOptions(
            CTLineCreateWithAttributedString(clockGlyphs), .useOpticalBounds)
        let clockRowMid = rect.minY + rect.height * 0.36
        let clockBaselineY = clockRowMid + (tight.origin.y + tight.height / 2)
        let clockTopY = clockBaselineY - clockFont.ascender

        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: now)
        let h: String = {
            switch UserPrefs.timeFormat {
            case .h24: return String(format: "%02d", comps.hour ?? 0)
            case .h12: return String(((comps.hour ?? 0) + 11) % 12 + 1)
            }
        }()
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)
        let colon = (comps.second ?? 0).isMultiple(of: 2) ? ":" : " "
        let clockParts = [h, colon, mm, colon, ss]
        let widths = clockParts.map { stringWidth($0, font: clockFont) }
        let ampm = amPm(now)
        let ampmW = ampm.isEmpty ? 0 : stringWidth(ampm, font: smallBoldFont) + 6
        let total = widths.reduce(0, +) + ampmW
        var x = rect.midX - total / 2
        for (part, w) in zip(clockParts, widths) {
            _ = drawText(ctx, part, font: clockFont, color: MatrixTheme.ink,
                         position: CGPoint(x: x, y: clockTopY))
            x += w
        }
        if !ampm.isEmpty {
            _ = drawText(ctx, ampm, font: smallBoldFont, color: MatrixTheme.inkDim,
                         position: capTopOrigin(rowMid: clockRowMid,
                                                font: smallBoldFont,
                                                x: x + 6))
        }

        // Stats row underneath the clock. Three colored beats on the
        // left, weather on the right — mirrors the landscape layout but
        // squeezed onto one narrow line.
        let statsRowMid = rect.maxY - 14
        let statsTopY = statsRowMid - smallFont.ascender / 2 - 1
        let lastText = m.lastRequestMs > 0 ? "\(Int(m.lastRequestMs))" : "—"
        let lastUnit = m.lastRequestMs > 0 ? "ms" : ""
        let p95Text = m.p95ms > 0 ? "\(Int(m.p95ms))ms" : "—"
        let cachePct = Int(m.cacheReadTokens
            / max(m.cacheReadTokens + m.inputTokens + m.cacheWriteTokens, 1) * 100)
        let parts: [(String, String)] = [
            (lastText, lastUnit),
            ("P95 ", p95Text),
            ("CACHE ", "\(cachePct)%"),
        ]
        var lx = rect.minX + 4
        for (a, b) in parts {
            let aw = drawText(ctx, a, font: smallBoldFont,
                              color: MatrixTheme.phosphor,
                              position: CGPoint(x: lx, y: statsTopY))
            lx += aw + 2
            let bw = drawText(ctx, b, font: smallFont,
                              color: MatrixTheme.inkDim,
                              position: CGPoint(x: lx, y: statsTopY))
            lx += bw + 10
        }

        let weatherText = WeatherService.shared.summaryUppercased ?? "—"
        let weatherW = stringWidth(weatherText, font: smallFont)
        // Clamp weather to whatever space the stats left so it never
        // collides — elide before drawing if necessary.
        let weatherMax = max(0, rect.maxX - 4 - lx - 6)
        let weatherDisp = weatherW <= weatherMax
            ? weatherText
            : elide(weatherText, font: smallFont, maxW: weatherMax)
        let weatherFinalW = stringWidth(weatherDisp, font: smallFont)
        _ = drawText(ctx, weatherDisp, font: smallFont, color: MatrixTheme.inkDim,
                     position: CGPoint(x: rect.maxX - 4 - weatherFinalW,
                                       y: statsTopY))
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

        // Helper: push current line and reset; respects maxLines.
        func flush() {
            if !cur.isEmpty {
                lines.append(cur)
                cur = ""
            }
        }

        wrapLoop: for word in words {
            if lines.count >= maxLines { break }

            // Single word longer than the panel — character-break it so
            // long paths / URLs don't blow past the container edge.
            if stringWidth(word, font: font) > maxW {
                flush()
                var chunk = ""
                for ch in word {
                    if lines.count >= maxLines { break wrapLoop }
                    let cand = chunk + String(ch)
                    if stringWidth(cand, font: font) <= maxW {
                        chunk = cand
                    } else if chunk.isEmpty {
                        // Single character wider than maxW — give up.
                        break wrapLoop
                    } else {
                        lines.append(chunk)
                        chunk = String(ch)
                    }
                }
                if !chunk.isEmpty, lines.count < maxLines { cur = chunk }
                continue
            }

            let candidate = cur.isEmpty ? word : cur + " " + word
            if stringWidth(candidate, font: font) <= maxW {
                cur = candidate
            } else {
                flush()
                if lines.count >= maxLines { break }
                cur = word
            }
        }
        if !cur.isEmpty, lines.count < maxLines { lines.append(cur) }
        if lines.count == maxLines, let last = lines.last {
            lines[lines.count - 1] = elide(last, font: font, maxW: maxW)
        }
        for (i, line) in lines.enumerated() {
            // Safety net: even if our wrap logic let something through
            // (e.g. unusual fonts where stringWidth disagrees), elide so
            // the glyphs never cross the container's right edge.
            let fitted = stringWidth(line, font: font) <= maxW
                ? line
                : elide(line, font: font, maxW: maxW)
            _ = drawText(ctx, fitted, font: font, color: color,
                         position: CGPoint(x: x, y: y + CGFloat(i) * lineH))
        }
    }

    // MARK: - Text primitives

    private func capTopOrigin(rowMid: CGFloat, font: NSFont, x: CGFloat) -> CGPoint {
        // y_text = rowMid - capHeight/2 - (ascent - capHeight)
        let m = MatrixTheme.metrics(of: font)
        let y = rowMid - m.capHeight / 2 - (m.ascender - m.capHeight)
        return CGPoint(x: x, y: y)
    }

    private func capHeight(of font: NSFont) -> CGFloat {
        MatrixTheme.metrics(of: font).capHeight
    }

    /// LRU CTLine cache. Keyed by (string, font identity, color identity).
    /// Most dashboard labels ("▸ PROMPT", "▸ MODEL", "CONTEXT", etc.)
    /// repeat every frame — the cache turns ~40 CTLine+NSAttributedString
    /// allocations per frame into ~5-10 misses (dynamic values only).
    private var ctLineSlots: [(key: UInt64, line: CTLine)] = []
    private let ctLineCacheSize = 24

    private func ctLine(_ s: String, font: NSFont, color: NSColor) -> CTLine {
        var h = Hasher()
        h.combine(s)
        h.combine(ObjectIdentifier(font))
        h.combine(ObjectIdentifier(color))
        let key = UInt64(bitPattern: Int64(h.finalize()))

        if let idx = ctLineSlots.firstIndex(where: { $0.key == key }) {
            let hit = ctLineSlots[idx]
            if idx > 0 {
                ctLineSlots.remove(at: idx)
                ctLineSlots.insert(hit, at: 0)
            }
            return hit.line
        }
        let attrs = MatrixTheme.attributes(font: font, color: color)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: attrs))
        ctLineSlots.insert((key, line), at: 0)
        if ctLineSlots.count > ctLineCacheSize {
            ctLineSlots.removeLast()
        }
        return line
    }

    /// Draw a string with its (x, y) interpreted as the top-left of the
    /// cap-box (matches `_text()` in matrix.py). Returns advance width.
    private func drawText(_ ctx: CGContext, _ s: String, font: NSFont,
                          color: NSColor, position: CGPoint) -> CGFloat {
        let line = ctLine(s, font: font, color: color)
        ctx.saveGState()
        // Move to baseline. Caller's y is "top of ascent"; baseline = y + ascent.
        let baselineY = position.y + MatrixTheme.metrics(of: font).ascender
        ctx.textMatrix = .identity
        ctx.translateBy(x: position.x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded()
    }

    /// Measure the typographic width of a string. Optionally passes a
    /// color through so measure-then-draw with the same args hits the
    /// CTLine cache. Default color (`ink`) covers the bulk of body
    /// text; non-ink draws can pass an explicit color to opt in.
    private func stringWidth(_ s: String, font: NSFont,
                             color: NSColor = MatrixTheme.ink) -> CGFloat {
        let line = ctLine(s, font: font, color: color)
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
